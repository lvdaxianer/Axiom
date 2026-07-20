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
  ASSERT_ACCESS="$BATS_TEST_DIRNAME/assert_access.py"
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
  [[ "$output" == *"loadBalancerIP"* && "$output" != *"/snapshot"* ]]
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
  assert_invalid_value "service.loadBalancerIP=999.999.999.999" "loadBalancerIP"
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

# 前置：fixture 仅在 service 下提供固定 IP。
# 目的：确认 TLS SAN 与 HTTP Service 共用单一 IP 来源。
# 约束：过渡期 environment.loadBalancerIP 不再被 fixture 提供。
# 约束：证书必须包含固定 IP 和 HTTP Service DNS。
# 失败：旧路径依赖会使证书缺失固定 IP。
# 范围：通过核心结构化断言检查 TLS Secret。
# 结果：渲染证书 SAN 应完整包含单一服务地址。
@test "core cluster sources TLS SAN from the service fixed IP" {
  run render_fixture
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$RENDERED"
  run "$PYTHON_BIN" "$ASSERT_RENDER" tls-service-ip "$RENDERED"
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

# 前置：fixture 配置固定 IP、legacy MetalLB 契约和授权来源。
# 目的：验证外部只暴露 HTTPS 9200，9300 仅供 ES Pod 互通。
# 约束：Service 选择器必须精确匹配 ES Pod。
# 约束：NetworkPolicy 的 HTTP 来源只能是授权 Pod 和 CIDR。
# 失败：任一保留注解、端口或 peer 偏移都应结构化报错。
# 范围：只解析 Helm 渲染的 Service 和 NetworkPolicy。
# 结果：固定 IP 外部访问与集群内通信边界同时成立。
@test "secure access renders fixed HTTPS and authorized ingress only" {
  run render_fixture
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$RENDERED"
  run "$PYTHON_BIN" "$ASSERT_ACCESS" secure "$RENDERED"
  [ "$status" -eq 0 ]
}

# 前置：fixture 配置外部来源 CIDR 和集群 DNS 选择器。
# 目的：保留客户端源地址，并将 ES 出站限制为 transport 与 DNS。
# 约束：Local 是 ipBlock 正确识别外部 CIDR 的必要条件。
# 约束：出站只能访问同一 ES 选择器的 9300 和 DNS 的 TCP/UDP 53。
# 失败：Cluster 策略、缺少 Egress 或任意宽泛出站都会触发结构化失败。
# 范围：解析 Service 和 NetworkPolicy，不依赖 YAML 文本顺序。
# 结果：来源控制和默认拒绝出站必须同时成立。
@test "secure access preserves client source and isolates egress" {
  run render_fixture
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$RENDERED"
  run "$PYTHON_BIN" "$ASSERT_ACCESS" secure "$RENDERED"
  [ "$status" -eq 0 ]
}

# 前置：从有效 fixture 分别清空固定 IP 或覆盖非法网络值。
# 目的：在渲染前拒绝动态 IP、非法 IPv4/CIDR 和空 peer 标签。
# 约束：CIDR 前缀只能为 0..32，IP 八位组不能越界。
# 约束：授权 namespace 与 pod 选择器都必须有有效标签。
# 失败：Helm schema 必须指出对应 service 或 networkPolicy 字段。
# 范围：每次仅替换一个输入，避免错误归因。
# 结果：所有不安全输入都必须非零退出。
@test "secure access rejects missing or invalid network inputs" {
  assert_invalid_value "service.loadBalancerIP=" "loadBalancerIP"
  assert_invalid_value "service.loadBalancerIP=999.1.1.1" "loadBalancerIP"
  assert_invalid_value "service.loadBalancerSourceRanges[0]=198.51.100.0/33" "loadBalancerSourceRanges"
  assert_invalid_value "networkPolicy.authorizedPeers[0].podSelector.matchLabels.app\\.kubernetes\\.io/name=" "matchLabels"
}

# 前置：fixture 默认使用批准的 first-pool 地址池。
# 目的：确认客户不能将固定 IP 请求切换到其他 MetalLB 地址池。
# 约束：地址池是已批准的部署边界，不是任意 DNS 标签配置。
# 约束：只覆盖 addressPool，其他服务和网络策略输入保持有效。
# 失败：second-pool 若能渲染，固定地址池契约即被绕过。
# 范围：在 Helm schema 阶段验证，不依赖 YAML 文本匹配。
# 结果：错误必须明确指向 addressPool 字段。
@test "secure access requires the approved first address pool" {
  assert_invalid_value "service.addressPool=second-pool" "addressPool"
}

# 前置：用户尝试通过自定义注解写入 MetalLB 保留键。
# 目的：同时阻断 legacy 与 modern API 别名绕过固定配置。
# 约束：两套地址池、固定 IP、协议和共享键别名均由 Chart 独占。
# 约束：schema 必须在模板执行前拒绝保留键输入。
# 失败：任一别名可渲染都会形成第二条配置来源。
# 范围：分别覆盖 legacy 与 modern 地址池代表键。
# 结果：两次渲染均应非零退出并指向 annotations。
@test "secure access rejects legacy and modern reserved annotation aliases" {
  run render_fixture --set-string 'service.annotations.metallb\.universe\.tf/address-pool=evil-pool'
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid propertyName"* && "$output" == *"metallb.universe.tf/address-pool"* ]]

  run render_fixture --set-string 'service.annotations.metallb\.io/address-pool=evil-pool'
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid propertyName"* && "$output" == *"metallb.io/address-pool"* ]]
}

# 前置：用户提供不符合 Kubernetes qualified-name 的注解键。
# 目的：避免生成 API Server 会拒绝的 Service metadata。
# 约束：注解前缀必须是 DNS subdomain，名称必须是合法 qualified name。
# 约束：合法 example.com/owner 注解仍由 secure 结构化测试覆盖。
# 失败：带下划线的 DNS 前缀若通过，会把错误推迟到集群安装阶段。
# 范围：只覆盖 service.annotations 的 propertyNames 校验。
# 结果：schema 必须拒绝 bad_prefix/owner。
@test "secure access rejects invalid custom annotation keys" {
  run render_fixture --set-string 'service.annotations.bad_prefix/owner=platform'
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid propertyName"* && "$output" == *"bad_prefix/owner"* ]]
}

# 前置：fixture 默认关闭共享 IP。
# 目的：确认关闭时省略注解，启用时只渲染显式共享键。
# 约束：客户自定义注解可合并，保留 MetalLB 键不可被覆盖。
# 约束：共享键必须是 DNS-safe 名称，字面量 true 必须拒绝。
# 失败：泛化 true 共享组或恶意保留注解都会破坏固定配置。
# 范围：结构化断言注解映射，不依赖 YAML 文本顺序。
# 结果：默认省略，显式开启渲染指定共享键。
@test "secure access controls shared IP and reserved annotations" {
  run render_fixture
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$RENDERED"
  run "$PYTHON_BIN" "$ASSERT_ACCESS" no-sharing "$RENDERED"
  [ "$status" -eq 0 ]

  run render_fixture --set service.allowSharedIP=true --set service.sharedIPKey=es-http-shared
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$RENDERED"
  run "$PYTHON_BIN" "$ASSERT_ACCESS" shared "$RENDERED"
  [ "$status" -eq 0 ]

  run render_fixture --set service.allowSharedIP=true --set-string service.sharedIPKey=true
  [ "$status" -ne 0 ]
  [[ "$output" == *"sharedIPKey"* ]]
}
