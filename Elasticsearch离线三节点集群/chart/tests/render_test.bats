#!/usr/bin/env bats

find_python() {
  # 选择同时具备结构化 YAML 和 X.509 解析能力的解释器。
  local candidate
  for candidate in "${PYTHON_BIN:-python3}" python3.11; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import cryptography, yaml' >/dev/null 2>&1; then
      PYTHON_BIN="$candidate"
      return 0
    fi
  done
  echo "PyYAML and cryptography are required; set PYTHON_BIN to a compatible Python interpreter" >&2
  return 1
}

setup() {
  # 统一初始化每个独立测试使用的 Chart 和临时文件路径。
  CHART_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIXTURE="$BATS_TEST_DIRNAME/fixtures/valid-values.yaml"
  ASSERT_RENDER="$BATS_TEST_DIRNAME/assert_render.py"
  RENDERED="$BATS_TEST_TMPDIR/rendered.yaml"
  ADDITIVE_RENDERED="$BATS_TEST_TMPDIR/additive.yaml"
  CREDENTIALS_TEMPLATE="$CHART_DIR/templates/credentials-secret.yaml"
  TLS_TEMPLATE="$CHART_DIR/templates/tls-secret.yaml"
  find_python
}

render_fixture() {
  # 使用有效离线部署输入渲染 Chart，并透传覆盖参数。
  helm template es-cluster "$CHART_DIR" -n uino -f "$FIXTURE" "$@"
}

assert_invalid_value() {
  # 校验无效覆盖值被 schema 拒绝且错误包含目标字段。
  run render_fixture --set "$1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$2"* ]]
}

# 前置：不提供部署环境和私有镜像输入。
# 目的：确认严格 schema 拒绝不可部署的默认配置。
# 约束：默认值不能指向公共镜像或隐式 latest 标签。
# 约束：环境与快照输入由后续条件任务负责。
# 失败：Helm 应返回 image 或 digest 字段错误。
# 范围：只验证 values schema，不渲染资源断言。
# 结果：错误输出不应出现可接受的环境或快照缺失错误。
@test "core cluster requires a private digest-pinned image" {
  # 默认值不得隐式指向任何公共镜像。
  run helm template es-cluster "$CHART_DIR" -n uino
  [ "$status" -ne 0 ]
  [[ "$output" == *"/image"* && "$output" == *"digest"* ]]
  [[ "$output" != *"loadBalancerIP"* && "$output" != *"/snapshot"* ]]
}

# 前置：使用完整离线 fixture 作为有效基线。
# 目的：覆盖镜像、IP 和外部 Secret 名称的输入边界。
# 约束：tag 必须固定，digest 必须小写十六进制。
# 约束：IPv4 八位组和 DNS-1123 Secret 名称必须有效。
# 失败：每个覆盖值都应在 Helm schema 阶段被拒绝。
# 范围：每次调用只改变一个输入字段。
# 结果：错误信息应包含对应字段名，便于运维定位。
@test "core cluster rejects invalid schema values" {
  # 镜像、网络与 Secret 外部输入必须经过严格约束。
  assert_invalid_value "image.tag=7.10.3-arm64" "image/tag"
  assert_invalid_value "image.digest=sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "digest"
  assert_invalid_value "environment.loadBalancerIP=999.999.999.999" "loadBalancerIP"
  assert_invalid_value "image.pullSecrets[0].name=Bad_Name" "pullSecrets"
  assert_invalid_value "security.existingCredentialsSecret=Bad_Name" "existingCredentialsSecret"
  assert_invalid_value "tls.existingSecret=abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijkl" "existingSecret"
}

# 前置：使用完整 fixture，镜像和调度约束均有效。
# 目的：确认 heap 仍可按受控格式覆盖。
# 约束：Xms 和 Xmx 使用正数 m 或 g 单位。
# 约束：默认 4g 不因 schema 放宽而被移除。
# 失败：非法 heap 应由 schema 拒绝而非容器启动失败。
# 范围：只检查一个合法的 2g 覆盖值。
# 结果：渲染的 ES_JAVA_OPTS 必须保留覆盖内容。
@test "core cluster accepts a validated heap override" {
  run render_fixture --set heap='-Xms2g -Xmx2g'
  [ "$status" -eq 0 ]
  [[ "$output" == *'value: "-Xms2g -Xmx2g"'* ]]
  # Xms 与 Xmx 不一致时由 Helm helper 显式阻断渲染。
  run render_fixture --set heap='-Xms2g -Xmx4g'
  [ "$status" -ne 0 ]
  [[ "$output" == *"heap Xms and Xmx must match"* ]]
}

# 前置：fixture 提供私有摘要镜像、固定 IP 和 pull Secret。
# 目的：验证核心三节点 StatefulSet 的完整结构。
# 约束：Python 解析器检查安全、TLS、数据和调度契约。
# 约束：证书 SAN 和 Secret 数据必须可被结构化读取。
# 失败：任何核心资源缺失或字段漂移都应导致断言失败。
# 范围：只读取 Helm 输出，不访问 Kubernetes API。
# 结果：核心资源渲染必须通过全部结构化断言。
@test "core cluster renders secured resources" {
  run render_fixture
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$RENDERED"
  run "$PYTHON_BIN" "$ASSERT_RENDER" core "$RENDERED"
  [ "$status" -eq 0 ]
}

# 前置：先渲染当前核心资源，再追加未来任务的文档。
# 目的：确保 Task 2 Service 和 Task 3 Job 不破坏核心断言。
# 约束：核心无头 Service 仍必须通过 clusterIP 和名称识别。
# 约束：额外 Service 不得被误当成发现 Service。
# 失败：精确 kind 白名单会在这里暴露不兼容设计。
# 范围：追加文档只模拟输出，不改变 Chart 模板。
# 结果：核心断言应忽略增量资源并继续检查核心字段。
@test "core cluster assertions allow future additive resources" {
  # 模拟后续任务追加 HTTP Service 和快照 Hook Job。
  render_fixture > "$ADDITIVE_RENDERED"
  printf '%s\n' '---' 'apiVersion: v1' 'kind: Service' 'metadata: {name: es-http}' \
    'spec: {clusterIP: 10.0.0.20}' '---' 'apiVersion: batch/v1' 'kind: Job' \
    'metadata: {name: es-snapshot-hook}' 'spec: {}' >> "$ADDITIVE_RENDERED"
  run "$PYTHON_BIN" "$ASSERT_RENDER" core "$ADDITIVE_RENDERED"
  [ "$status" -eq 0 ]
}

# 前置：fixture 的 fixed IP 被显式覆盖为空字符串。
# 目的：验证空地址不会污染生成证书 SAN。
# 约束：127.0.0.1 和服务 DNS SAN 仍必须存在。
# 约束：证书生成不得插入空或无效 IP 条目。
# 失败：空 IP 若进入 SAN，X.509 解析断言将失败。
# 范围：只检查 TLS Secret，不改变其他核心字段。
# 结果：渲染成功且空 fixed IP 不出现在证书地址集合。
@test "core cluster omits an empty fixed IP from TLS SAN" {
  run render_fixture --set environment.loadBalancerIP=
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$RENDERED"
  run "$PYTHON_BIN" "$ASSERT_RENDER" empty-service-ip "$RENDERED"
  [ "$status" -eq 0 ]
}

# 前置：指定由外部系统管理 credentials 和 TLS Secret。
# 目的：确认 Chart 只引用外部名称，不生成同名 Secret。
# 约束：合法名称必须原样进入 Secret 引用。
# 约束：密码环境变量和 TLS volume 都必须指向外部对象。
# 失败：生成 Secret 或静默改名都会破坏外部托管契约。
# 范围：Helm 输出只验证引用关系，不伪造 API Secret。
# 结果：输出中不得包含 Chart 生成的 Secret 文档。
@test "core cluster supports external Secret references" {
  run render_fixture --set security.existingCredentialsSecret=managed-es-credentials \
    --set tls.existingSecret=managed-es-tls
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$RENDERED"
  run "$PYTHON_BIN" "$ASSERT_RENDER" existing-secrets "$RENDERED"
  [ "$status" -eq 0 ]
}

# 前置：Helm lookup 可能返回 Chart 之前保留的托管 Secret。
# 目的：确保缺键或空值不会触发随机身份材料重生成。
# 约束：credentials 必须含非空 elastic-password。
# 约束：TLS 必须同时含非空 crt、key 和 ca。
# 失败：模板必须调用 fail 终止渲染，而不是静默降级。
# 范围：源模板断言覆盖 API lookup 的错误处理路径。
# 结果：两个 Secret 模板都必须包含显式 fail 保护。
@test "core cluster rejects corrupt managed lookup Secrets" {
  # lookup 找到损坏的托管 Secret 时必须停止渲染，不能重生身份材料。
  run grep -Eq 'fail.*elastic-password' "$CREDENTIALS_TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -Eq 'fail.*tls.crt.*tls.key.*ca.crt' "$TLS_TEMPLATE"
  [ "$status" -eq 0 ]
}
