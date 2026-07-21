#!/usr/bin/env bats
# 文件说明：覆盖 NFS 快照启停、外部 Secret、授权 peer、SLM 参数及非法配置场景。

find_python() {
  # 选择同时提供 PyYAML 和 cryptography 的结构化断言解释器。
  local candidate
  for candidate in "${PYTHON_BIN:-python3}" python3.11; do
    # 依赖不完整时继续探测兼容的备用 Python。
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import cryptography, yaml' >/dev/null 2>&1; then
      PYTHON_BIN="$candidate"
      return 0
    fi
  done
  echo "PyYAML and cryptography are required; set PYTHON_BIN to a compatible Python interpreter" >&2
  return 1
}

setup() {
  # 每个测试独立定位 Chart、fixture、断言脚本和临时渲染文件。
  CHART_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIXTURE="$BATS_TEST_DIRNAME/fixtures/valid-values.yaml"
  ASSERT_SNAPSHOT="$BATS_TEST_DIRNAME/assert_snapshot.py"
  RENDERED="$BATS_TEST_TMPDIR/rendered.yaml"
  find_python
}

render_fixture() {
  # 统一从有效离线 fixture 渲染，并允许单个测试传入覆盖值。
  helm template es-cluster "$CHART_DIR" -n uino -f "$FIXTURE" "$@"
}

assert_invalid_value() {
  # 每次仅覆盖一个输入，确保 Helm 错误可归因到目标快照字段。
  run render_fixture --set "$1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$2"* ]]
}

# 前置：fixture 提供独立 NFS、SLM 和 ARM64 节点选择器。
# 目的：验证 ES 挂载、path.repo 和 Hook 的完整运行安全契约。
# 约束：Hook 复用私有 digest 镜像、TLS CA、密码 Secret 和 ARM64 节点。
# 约束：API 注册、验证和策略调用均有边界且失败即退出。
# 失败：任一挂载、选择器、请求体或网络标签漂移都必须失败。
# 范围：只解析 Helm 输出，不访问 Kubernetes 或 Elasticsearch。
# 结果：默认快照资源必须通过结构化断言。
@test "snapshot renders NFS repository and bounded ARM64 initialization hook" {
  # 结构化断言避免 YAML 排版差异掩盖资源结构回归。
  # Hook peer 还必须精确限制到当前 release 的快照组件。
  # Hook 的 nodeSelector 必须与 StatefulSet 保持同一 ARM64 调度边界。
  # 镜像校验与节点选择器共同防止 Hook 被调度到错误架构的节点。
  run render_fixture
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$RENDERED"
  run "$PYTHON_BIN" "$ASSERT_SNAPSHOT" enabled "$RENDERED"
  [ "$status" -eq 0 ]
}

# 前置：客户以外部 credentials 与 TLS Secret 接管身份材料。
# 目的：确认 Hook 和 StatefulSet 始终消费同一对外部 Secret。
# 约束：快照初始化不能生成第二套密码、CA 或公共镜像引用。
# 失败：任一名称重写、Secret 漏挂载或镜像漂移都会失败。
# 范围：仅覆盖 Hook 引用，不伪造 Kubernetes Secret 内容。
# 结果：外部对象名称必须原样进入 Job。
@test "snapshot reuses external credential and TLS Secrets" {
  # 两类外部 Secret 都必须由一个非 root Hook Pod 消费。
  # 外部身份模式仍要求 ARM64 节点选择器保持不变。
  # 不读取 Secret 内容，避免测试输出产生凭据泄漏。
  # Secret 引用和 CA volume 的结构由 Python 断言精确验证。
  run render_fixture --set security.existingCredentialsSecret=managed-es-credentials \
    --set tls.existingSecret=managed-es-tls
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$RENDERED"
  run "$PYTHON_BIN" "$ASSERT_SNAPSHOT" external "$RENDERED"
  [ "$status" -eq 0 ]
}

# 前置：显式关闭快照，其他离线集群输入继续有效。
# 目的：确认关闭开关会彻底移除快照运行面。
# 约束：不能残留 path.repo、NFS volume、mount 或 Hook Job。
# 失败：任何残留快照资源都会扩大关闭状态的攻击面。
# 范围：核心集群和外部访问资源仍由其他测试覆盖。
# 结果：结构化输出中不存在快照工作负载引用。
@test "snapshot disabled omits repository resources" {
  # 固定 mountPath 值在关闭状态保留为配置契约，但不渲染到 Pod。
  # 关闭快照不应影响 StatefulSet 的核心节点选择器。
  # 该分支同时防止禁用时残留可执行的 Hook 资源。
  run render_fixture --set snapshot.enabled=false
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$RENDERED"
  run "$PYTHON_BIN" "$ASSERT_SNAPSHOT" disabled "$RENDERED"
  [ "$status" -eq 0 ]
}

# 前置：保留 NFS 仓库，但显式关闭 SLM 自动策略。
# 目的：允许仅注册并验证仓库的运维模式，不要求无效的策略字段。
# 约束：仓库 NFS 参数仍由 schema 强制；Hook 仍需得到 false 开关。
# 失败：若 SLM 条件校验仍无条件要求字段，Helm 会在渲染前失败。
# 范围：仅覆盖 SLM 关闭时的 values 契约。
# 结果：渲染成功，Hook 环境变量明确传入 false。
@test "snapshot allows repository verification without SLM policy" {
  # SLM 关闭后，名称、计划和保留值不参与 API 请求。
  run render_fixture --set snapshot.slm.enabled=false --set snapshot.slm.name='' \
    --set snapshot.slm.schedule='' --set snapshot.slm.snapshotName='' \
    --set snapshot.slm.retention.expireAfter=''
  [ "$status" -eq 0 ]
  [[ "$output" == *'name: SLM_ENABLED'* && "$output" == *'value: "false"'* ]]
}

# 前置：逐一覆盖缺失、注入、路径逃逸、运行目录重叠和计数倒置。
# 目的：在渲染前阻止不安全快照输入进入 Job 环境变量或 ES 配置。
# 约束：mountPath 只能是独立的固定 NFS 目录，clusterPath 必须有真实名称段。
# 约束：JSON 或 shell 元字符、点段和错误保留范围均不可放宽。
# 失败：每个非法值必须非零退出并指出对应字段或计数关系。
# 范围：不修改有效 fixture 的 NFS 地址与 SLM 默认策略。
# 结果：schema 或模板必须拒绝全部危险输入。
@test "snapshot rejects incomplete unsafe and inconsistent values" {
  # 必填仓库和 NFS 地址为空时不能启动可能写错位置的集群。
  assert_invalid_value "snapshot.repositoryName=" "repositoryName"
  assert_invalid_value "snapshot.nfs.server=" "server"
  assert_invalid_value 'snapshot.nfs.server=bad;id' "server"
  assert_invalid_value "snapshot.nfs.path=" "path"
  # 任意运行目录、点段与路径穿越必须在 schema 阶段失败。
  # 固定目录可避免快照 NFS 覆盖 Elasticsearch 的数据或证书路径。
  assert_invalid_value "snapshot.mountPath=relative" "mountPath"
  assert_invalid_value "snapshot.mountPath=/usr/share/elasticsearch/data" "mountPath"
  assert_invalid_value "snapshot.clusterPath=." "clusterPath"
  assert_invalid_value "snapshot.clusterPath=../escape" "clusterPath"
  # 计划表达式、名称和保留数量不能携带注入输入或无效范围。
  # 计数关系由模板在渲染前执行额外比较。
  assert_invalid_value 'snapshot.slm.schedule=0 1 * * *;id' "schedule"
  assert_invalid_value 'snapshot.slm.name=bad\"name' "name"
  assert_invalid_value "snapshot.slm.retention.expireAfter=0d" "expireAfter"
  assert_invalid_value "snapshot.slm.retention.minCount=0" "minCount"
  run render_fixture --set snapshot.slm.retention.minCount=10 --set snapshot.slm.retention.maxCount=5
  [ "$status" -ne 0 ]
  [[ "$output" == *"minCount must not exceed maxCount"* ]]
}

# 前置：将用户可配置 peer 改为与默认客户端完全不同的标签。
# 目的：确认 Chart 仍无条件放行本 release 的快照 Hook 到 ES 9200。
# 约束：可配置 peer 是附加授权，不能成为 Hook 连通性的唯一来源。
# 约束：默认 peer 和自定义 peer 都必须保留在同一 HTTP ingress 规则。
# 失败：替换 authorizedPeers 后缺少 Hook peer 会阻断 post-install Hook。
# 范围：只检查 NetworkPolicy 结构，不改变 Service selector。
# 结果：断言同时发现固定 Hook peer 和自定义 peer。
@test "snapshot keeps Hook authorization when authorized peers are customized" {
  # 转义 qualified-label 键，避免 Helm 将点号解释为嵌套对象。
  # 同时覆盖完整的三标签 peer，证明可配置来源仍被保留。
  run render_fixture \
    --set-string 'networkPolicy.authorizedPeers[0].namespaceSelector.matchLabels.kubernetes\.io/metadata\.name=custom-ns' \
    --set-string 'networkPolicy.authorizedPeers[0].podSelector.matchLabels.app\.kubernetes\.io/name=custom-client' \
    --set-string 'networkPolicy.authorizedPeers[0].podSelector.matchLabels.app\.kubernetes\.io/instance=custom-release' \
    --set-string 'networkPolicy.authorizedPeers[0].podSelector.matchLabels.app\.kubernetes\.io/component=custom-component'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$RENDERED"
  run "$PYTHON_BIN" "$ASSERT_SNAPSHOT" custom-peer "$RENDERED"
  [ "$status" -eq 0 ]
}
