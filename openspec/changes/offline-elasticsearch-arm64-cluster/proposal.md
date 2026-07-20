## Why

客户需要在麒麟 V10 ARM64 的离线 Kubernetes 环境中，以单个 Helm Chart 部署固定版本的三节点 Elasticsearch 7.10.2 集群。现有仓库没有可直接交付的部署资产，必须补齐离线镜像约束、共享 NFS 数据隔离、快照、安全认证以及 MetalLB 固定 IP 访问能力。

## What Changes

- 新增自维护的 Elasticsearch 7.10.2 ARM64 Helm Chart，固定创建三个 `master + data + ingest` 节点。
- 新增基于 Worker 预挂载共享 NFS 的独立节点数据目录，并保留数据和快照的卸载安全边界。
- 新增独立 NFS `fs` 快照仓库注册、验证和 SLM 定时保留策略。
- 新增 transport/HTTP TLS、密码认证、NetworkPolicy 与私有加固镜像配置。
- 新增 MetalLB `LoadBalancer` Service，通过 `first-pool` 绑定客户指定的固定外部 IP，仅暴露 HTTPS `9200`。
- 新增 Helm 模板测试、渲染校验、离线交付说明和客户验收步骤。

## Capabilities

### New Capabilities

- `offline-elasticsearch-deployment`: 在 `uino` 命名空间通过单个离线 Chart 部署并运行三节点 Elasticsearch 7.10.2 ARM64 集群。
- `elasticsearch-data-protection`: 隔离三个节点的共享 NFS 数据目录，并配置可验证、可保留的独立 NFS 快照仓库与 SLM 策略。
- `elasticsearch-secure-access`: 通过 TLS、认证、NetworkPolicy 和 MetalLB 固定 IP 向授权外部客户端提供 Elasticsearch HTTP 服务。

### Modified Capabilities

无。

## Impact

- 新增 `Elasticsearch离线三节点集群/chart/` 下的 Helm Chart、模板和测试。
- 更新解决方案 README 与根目录方案索引。
- 新增 OpenSpec 变更资产、离线镜像准备说明和部署验收命令。
- 运行环境依赖三个可调度 Worker、预挂载的数据 NFS、独立快照 NFS、MetalLB `first-pool`、私有 ARM64 镜像仓库以及满足 Elasticsearch 要求的宿主机内核参数。
- Elasticsearch 7.10.2 已 EOL；交付使用加固镜像与网络隔离降低风险，但不消除旧版本风险。
