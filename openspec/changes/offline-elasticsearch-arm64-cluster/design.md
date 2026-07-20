## Context

客户环境是麒麟 V10 ARM64 的离线 Kubernetes 集群，允许使用 Helm、客户私有镜像仓库和 MetalLB，但要求以单个 Chart 完成 `uino` 命名空间内的部署。Elasticsearch 版本因业务兼容固定为已 EOL 的 7.10.2。三个 Worker 已将同一 NFS export 挂载到 `/data/uinnova/apps/es`，快照使用另一条 NFS export。详细的已批准方案保存在 `Elasticsearch离线三节点集群/README.md`。

## Goals / Non-Goals

**Goals:**

- 交付一个可离线安装的原生 Helm Chart，固定运行三个 Elasticsearch 7.10.2 ARM64 节点。
- 对共享 NFS 数据目录进行 Pod 级隔离，并确保 Helm 生命周期不删除业务数据。
- 使用独立 NFS 仓库执行快照注册、验证和 SLM 策略配置。
- 默认启用 transport/HTTP TLS、账号认证和网络访问控制。
- 使用 MetalLB `first-pool` 为 HTTPS `9200` 绑定客户保留的固定 IP。
- 通过可重复的模板测试、lint、渲染和打包校验形成离线交付证据。

**Non-Goals:**

- 不部署 ECK Operator、NFS、MetalLB、CNI 或私有镜像仓库。
- 不在 Chart 中使用特权容器修改 Worker 内核参数。
- 不在 Git 中保存镜像、镜像 tar、服务器密码、仓库密码或证书私钥。
- 不自动执行快照恢复、数据迁移、扩缩容或 Elasticsearch 大版本升级。
- 不消除 Elasticsearch 7.10.2 EOL 和共享 NFS 单一故障域带来的固有风险。

## Decisions

### 使用原生 StatefulSet 而不是 ECK

Chart 直接管理 StatefulSet、Service、ConfigMap、Secret、NetworkPolicy、PodDisruptionBudget 和初始化 Job。该方式满足单 Chart 和命名空间内可排障要求，也避免引入 CRD、ClusterRole 与 Operator 升级生命周期。代价是滚动升级、证书生命周期和快照初始化必须由 Chart 明确实现。

### 固定三个混合角色节点

StatefulSet 固定 `replicas: 3`，节点名为 `es-cluster-0..2`，每个节点均承担 `master`、`data` 和 `ingest` 角色。Headless Service 提供稳定发现地址，强制 Pod 反亲和将节点分散到三个 Worker。PodDisruptionBudget 使用 `minAvailable: 2`。

### 使用已挂载 NFS hostPath 并按 Pod 隔离

数据卷使用 Worker 上已存在的 `/data/uinnova/apps/es` hostPath。初始化容器创建并验证与 Pod 名称一致的子目录，主容器通过 `subPathExpr` 只挂载自己的目录。Chart 不创建或删除数据 PV/PVC，也不执行自动清空、迁移或权限递归修改。

本方案接受共享 NFS 的性能和单点风险。相比每节点独立 RWO 块存储，该方案故障隔离较弱，但符合客户现有存储约束。

### 使用独立 NFS volume 作为 fs 快照仓库

快照 volume 由 `snapshot.nfs.server` 和 `snapshot.nfs.path` 直接挂载到所有 ES Pod 的同一路径，并加入 `path.repo`。一个 post-install/post-upgrade Helm Hook Job 复用 Elasticsearch 加固镜像中的 `curl`，等待集群可用后注册仓库、执行 `_verify` 并应用 SLM 策略。Job 不执行恢复或删除快照。

### 使用 Helm 生成并复用 Secret

Chart 支持引用客户已有凭据和 TLS Secret。未提供时，首次安装使用 Helm 模板函数生成密码、CA 和带集群 DNS SAN 的证书；升级通过 `lookup` 复用已有 Secret，避免密码和证书意外轮换。Secret 设置 `helm.sh/resource-policy: keep`，卸载后保留，重新安装时由同名 Secret 接续。

transport TLS 使用共享证书并按证书链验证；HTTP TLS 证书包含固定 Service DNS 和通配 Headless Service DNS。私钥只出现在 Kubernetes Secret 中，不进入 values 或文档。

### 使用 MetalLB LoadBalancer 暴露固定 HTTPS 地址

HTTP Service 类型固定为 `LoadBalancer`，兼容客户现有 `metallb.universe.tf/*` 注解，通过 `first-pool` 绑定 `service.loadBalancerIP`。`externalTrafficPolicy` 固定为 `Local`，让 Pod 侧 NetworkPolicy 能按原始客户端 CIDR 执行授权；三个 Worker 均有一个本地 Elasticsearch endpoint。`loadBalancerSourceRanges` 与 NetworkPolicy 共同限制授权来源。`9300` 仅在 Headless Service 和 ES Pod 之间开放。

`allow-shared-ip` 默认关闭；启用时使用显式共享键，不以 `"true"` 作为通用共享组。额外注解由 `service.annotations` 合并。

NetworkPolicy 同时隔离 ingress 和 egress。出站只允许 Elasticsearch 节点间 TLS `9300` 以及集群 DNS 的 TCP/UDP `53`，禁止 Elasticsearch Pod 直接访问公网。

### 使用 ARM64 加固镜像并固定 digest

Chart 不引用公共仓库，要求填写客户私有仓库路径和加固镜像 digest。加固镜像在客户授权的远程 ARM64 主机上基于官方 7.10.2 镜像制作，删除 Log4j `JndiLookup` 后执行架构检查与安全扫描。镜像准备不在本地 Git 工作树产生二进制文件。

### 使用 Bats 和结构化 YAML 断言测试模板

测试先运行 `helm template`，再由 PyYAML 解析全部资源，通过 Bats 断言资源数量、StatefulSet 结构、NFS 隔离、TLS、安全配置、MetalLB 注解、NetworkPolicy、PDB 和快照 Job。`helm lint`、默认值渲染、覆盖值渲染与 `helm package` 作为更广验证。

## Risks / Trade-offs

- [Elasticsearch 7.10.2 已 EOL] -> 使用加固 ARM64 镜像、TLS、认证、digest 固定和网络隔离，并在交付清单记录剩余风险。
- [共享 NFS 同时影响三个节点] -> 每个 Pod 使用独立子目录，部署前验证锁与 `fsync`，快照使用独立 NFS 故障域。
- [MetalLB 注解与版本耦合] -> 默认使用客户已确认的 legacy 注解，并允许通过 values 合并额外注解。
- [Helm 自动生成 Secret 可能在升级时轮换] -> 使用 `lookup` 优先复用现有 Secret，并增加连续两次渲染/升级测试。
- [Hook Job 在集群未就绪时失败] -> Job 使用有界重试与明确退出码，失败保留日志并使 Helm 原子安装/升级失败。
- [NetworkPolicy 能力依赖 CNI] -> 文档要求客户确认 CNI 执行策略；不支持时由防火墙提供等价控制。
- [单个 Chart 耦合多个资源] -> 模板按职责拆分，values schema 提前拒绝缺失固定 IP、镜像 digest 或快照地址的安装。

## Migration Plan

1. 在远程 ARM64 下载服务器准备并扫描 7.10.2 加固镜像，推送私有仓库并记录 digest。
2. 客户确认三个 Worker 的 NFS 数据挂载、内核参数、快照 NFS 权限及 MetalLB 固定 IP。
3. 使用客户 values 执行 `helm lint` 和离线渲染检查。
4. 在 `uino` 命名空间执行一次 `helm install --atomic --wait`。
5. 验证三节点、固定 IP、TLS/认证、数据目录、仓库 `_verify`、测试快照与恢复。
6. 回滚 Chart 配置时使用 `helm rollback --wait`；禁止删除三个数据子目录或快照目录。
7. 如必须卸载，先确认最新快照成功，再执行 `helm uninstall`；保留 NFS 数据、快照和 keep Secret。

## Open Questions

无。客户专用 values 在部署前填写私有镜像地址与 digest、固定 IP、允许来源 CIDR、快照 NFS server/export path 以及可选的已有 Secret 名称。
