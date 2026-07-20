## ADDED Requirements

### Requirement: 加固 ARM64 私有镜像

系统 MUST 使用客户私有仓库中的 Elasticsearch 7.10.2 `linux/arm64` 加固镜像，并同时固定版本 tag 与镜像 digest。

#### Scenario: 正确配置加固镜像

- **WHEN** 客户 values 提供私有 repository、`7.10.2-arm64-hardened` tag 和 digest
- **THEN** StatefulSet 与初始化 Job 必须引用同一个 digest 固定的私有镜像

#### Scenario: 镜像交付审计

- **WHEN** 准备离线交付包
- **THEN** 交付清单必须记录源镜像 ARM64 架构、加固镜像 digest、Log4j 加固动作和安全扫描结果，且不得包含仓库凭据

### Requirement: Elasticsearch TLS 与认证

系统 MUST 启用 X-Pack Security、transport TLS、HTTP TLS 和管理员密码认证。

#### Scenario: 首次安装未提供 Secret

- **WHEN** 客户没有提供已有密码或 TLS Secret
- **THEN** Chart 必须生成密码、CA 和覆盖 Service/Pod DNS 的证书，并仅保存在 Kubernetes Secret 中

#### Scenario: Helm 升级复用 Secret

- **WHEN** 同一 Release 执行 Helm 升级
- **THEN** Chart 必须复用已有密码和 TLS Secret，不得自动生成新身份材料

#### Scenario: 未认证 HTTP 请求

- **WHEN** 客户端不提供有效 TLS 信任或 Elasticsearch 凭据访问 `9200`
- **THEN** Elasticsearch 必须拒绝请求

### Requirement: MetalLB 固定 IP 服务

系统 SHALL 通过 MetalLB `LoadBalancer` Service 从 `first-pool` 绑定客户指定的固定 IP，并只向外提供 HTTPS `9200`。

#### Scenario: 固定 IP 配置完整

- **WHEN** 客户 values 提供 `service.loadBalancerIP` 和 `first-pool`
- **THEN** Service 必须渲染客户兼容的 address-pool、loadBalancerIPs 和 layer2 注解并请求该固定 IP

#### Scenario: 未配置固定 IP

- **WHEN** `service.loadBalancerIP` 为空
- **THEN** Helm 必须拒绝安装而不得让 MetalLB 动态分配其他 IP

#### Scenario: 共享 IP 默认关闭

- **WHEN** 客户没有显式启用共享 IP
- **THEN** Service 不得渲染 `allow-shared-ip` 注解

#### Scenario: 显式启用共享 IP

- **WHEN** 客户启用共享 IP 并提供共享键
- **THEN** Service 必须使用该显式共享键且不得自动使用 `"true"` 作为共享组

### Requirement: 网络访问限制

系统 MUST 阻止 `9300` 对外暴露，并通过 NetworkPolicy 与 LoadBalancer 来源 CIDR 限制 `9200` 访问。

#### Scenario: Elasticsearch 节点通信

- **WHEN** 三个 Elasticsearch Pod 通过 transport 端口通信
- **THEN** NetworkPolicy 必须允许同一集群 Pod 之间的 TLS `9300` 流量

#### Scenario: 授权外部客户端访问

- **WHEN** 客户端来自配置的 `loadBalancerSourceRanges` 并提供有效 TLS 与认证信息
- **THEN** 客户端必须能够通过固定 IP 的 `9200` 访问 Elasticsearch

#### Scenario: 未授权来源访问

- **WHEN** 客户端不在允许来源范围或 Pod 不匹配允许的 NetworkPolicy 规则
- **THEN** 网络层或 Elasticsearch 认证层必须拒绝访问
