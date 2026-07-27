# Elasticsearch 7.10.2 ARM64 离线三节点集群部署设计

**目标：** 在麒麟 V10 ARM64 Kubernetes 环境中，通过一个离线 Helm Chart 在 `uino` 命名空间部署三节点 Elasticsearch 7.10.2 集群，并提供持久化、安全加固和 NFS 快照能力。

## 背景与约束

- 客户环境离线，部署时不能访问公共 Helm 仓库或公共镜像仓库。
- Kubernetes 支持 Helm，并可从客户私有仓库拉取镜像。
- 本地 Git 仓库只保存 Chart、设计说明和验证资料，不保存容器镜像、离线镜像包或凭据。
- 目标 CPU 架构为 `linux/arm64`，宿主机操作系统为麒麟 V10。
- Elasticsearch 版本固定为 `7.10.2`。
- 集群固定为三个 Elasticsearch 节点。
- Kubernetes 命名空间固定为 `uino`。
- 所有 Worker 将同一个 NFS 共享目录挂载到 `/data/uinnova/apps/es`，该目录用于 Elasticsearch 数据持久化。
- Elasticsearch 快照使用独立的 NFS 共享目录。
- 客户希望只上传一个 Chart 包并执行一次 `helm install`。

## 方案选择

使用自维护的原生 Helm Chart 创建 StatefulSet、Service、Secret、NetworkPolicy、PodDisruptionBudget 和初始化 Job，不引入 ECK Operator。

选择该方案的原因：

- 不依赖 Elasticsearch CRD 或 ECK Operator 生命周期。
- 可以在单个 Chart 中完成命名空间内资源部署。
- 适合离线、固定版本、固定三节点的客户交付场景。
- Kubernetes 运维人员可以直接通过原生资源排查问题。

ECK 更适合平台团队统一维护 Operator、部署多个 Elasticsearch 集群并持续执行扩缩容和升级的环境，不作为本次交付方案。

## 总体架构

Chart 创建一个三副本 StatefulSet：

```text
uino
  |- Service/es-cluster-headless
  |- Service/es-cluster-http
  |- StatefulSet/es-cluster
  |    |- es-cluster-0: master + data + ingest
  |    |- es-cluster-1: master + data + ingest
  |    `- es-cluster-2: master + data + ingest
  |- Secret/es-cluster-credentials
  |- Secret/es-cluster-tls
  |- NetworkPolicy/es-cluster
  |- PodDisruptionBudget/es-cluster
  `- Job/es-cluster-bootstrap
```

Headless Service 为 Elasticsearch 节点提供稳定 DNS 名称和节点发现。HTTP Service 使用 MetalLB `LoadBalancer`，通过客户保留的固定 IP 对外提供 HTTPS `9200`；Chart 不创建 Ingress，也不暴露节点通信端口 `9300`。

三个节点均承担 `master`、`data` 和 `ingest` 角色。Pod 使用强制反亲和规则分散到不同 Worker，因此生产环境至少需要三个可调度 Worker。

## 镜像与离线交付

官方 `docker.elastic.co/elasticsearch/elasticsearch:7.10.2` manifest 已确认包含 `linux/arm64` 镜像。离线准备镜像时必须显式选择 ARM64，并记录源镜像 digest。

镜像准备在客户指定的远程 ARM64 下载服务器完成：

1. 拉取官方 ARM64 Elasticsearch 7.10.2 镜像。
2. 基于官方镜像制作 Log4j 加固镜像。
3. 对加固镜像执行架构检查和安全扫描。
4. 将镜像推送到客户私有仓库，或导出为客户认可的离线镜像包。
5. 在交付清单中记录镜像名称、tag、digest、架构和扫描结果。

远程服务器密码、私有仓库密码、Elasticsearch 密码和证书私钥不得写入 Git、Chart 默认值或交付文档。

Chart 通过以下值引用客户私有仓库：

```yaml
image:
  repository: "<客户私有仓库>/elasticsearch"
  tag: "7.10.2-arm64-hardened"
  digest: "<加固镜像 digest>"
  pullPolicy: IfNotPresent
  pullSecrets: []
```

`repository` 和 `digest` 是部署前必须填写的值，不提供可误用的公共仓库默认值。

在 x86_64/AMD64 测试环境中，可叠加仓库提供的测试覆盖文件。它只替换镜像和节点架构，其他离线、MetalLB、NFS 和安全参数仍复用有效 fixture：

```bash
helm template es-cluster ./chart \
  --namespace uino \
  -f ./chart/tests/fixtures/valid-values.yaml \
  -f ./chart/values.x86.example.yaml
```

`values.x86.example.yaml` 使用 `10.100.30.139/library/elasticsearch:7.10.2` 的 AMD64 digest，仅用于 x86 测试。客户 ARM64 环境继续使用 `values.customer.example.yaml` 或自己的 ARM64 镜像覆盖值，不要将 x86 覆盖文件用于 ARM64 Worker。

## 数据持久化

三个 Pod 使用共享挂载点下相互隔离的数据子目录：

```text
/data/uinnova/apps/es/
  |- es-cluster-0/
  |- es-cluster-1/
  `- es-cluster-2/
```

StatefulSet 使用 `hostPath` 引用 Worker 已挂载的 `/data/uinnova/apps/es`，不创建数据 PVC 或 PV。Pod 名称决定数据子目录，容器通过 `subPathExpr` 只挂载自己的目录。任何两个节点都不能写入同一个 `path.data`。启动检查负责确认目标目录存在、可写并且没有错误的节点锁；检查失败时 Pod 保持未就绪，Chart 不清空或迁移已有数据。

因为 `hostPath` 指向的实际内容来自同一个 NFS export，Pod 调度到任一合格 Worker 都能看到相同的节点子目录。Chart 仍通过强制反亲和确保三个 Pod 不会同时落在同一个 Worker。

共享 NFS 是已接受的环境约束，同时也是单一故障域。NFS 故障可能导致三个 Elasticsearch 节点同时不可用。部署前必须验证 NFS 的文件锁、`fsync` 语义、并发写入能力、延迟和故障恢复行为。推荐使用 NFSv4.1 和 `hard` 挂载。

Helm 升级和卸载不得删除 `/data/uinnova/apps/es` 下的数据。

## 快照仓库

快照使用与数据目录隔离的 NFS 共享目录。Chart 通过 Kubernetes `nfs` volume 的 `server` 和 `path` 直接挂载，不创建快照 PV 或 PVC。三个 Elasticsearch Pod 必须以相同容器路径挂载该目录，例如 `/mnt/es-snapshots`。

Chart 提供以下值：

```yaml
snapshot:
  enabled: true
  repositoryName: uino-es-snapshot
  nfs:
    server: "<NFS 服务器地址>"
    path: "<NFS 导出目录>"
    mountPath: /mnt/es-snapshots
    clusterPath: uino/es-cluster
  policy:
    enabled: true
    name: daily-snapshot
    schedule: "0 30 2 * * ?"
    retention:
      expireAfter: 30d
      minCount: 7
      maxCount: 30
```

Elasticsearch 配置包含：

```yaml
path.repo:
  - /mnt/es-snapshots
```

集群健康后，初始化 Job 通过 Elasticsearch API：

1. 注册 `fs` 类型快照仓库。
2. 执行 `POST /_snapshot/<repository>/_verify`。
3. 创建 SLM 定时快照和保留策略。

仓库验证必须证明三个 Elasticsearch 节点均能访问快照目录。恢复操作不由安装或升级流程自动执行。Helm 卸载不得删除 NFS 上的快照。

同一个可写快照子目录只允许一个 Elasticsearch 集群使用。快照 NFS 最好位于与数据 NFS 不同的存储设备或故障域。

## 安全设计

Elasticsearch 7.10.2 已停止维护，存在已知安全风险。固定版本是业务兼容约束，设计通过以下措施降低风险，但不能等价于升级到受支持版本：

- 基于官方 ARM64 镜像制作加固镜像，移除 Log4j `JndiLookup` 类并执行安全扫描。
- 启用 `xpack.security.enabled`。
- 节点间 `9300` transport 通信强制启用 TLS。
- `9200` HTTP 通信默认启用 TLS 和密码认证。
- 管理员密码与证书使用 Kubernetes Secret 保存。
- 首次安装生成或导入的密码和证书在 Helm 升级时必须复用，不能自动轮换。
- NetworkPolicy 仅允许三个 Elasticsearch Pod 互访 `9300`。
- NetworkPolicy 和 `loadBalancerSourceRanges` 仅允许显式配置的业务来源访问 `9200`。
- Elasticsearch Pod 不允许访问公网；如果 CNI 不支持 NetworkPolicy，应由客户防火墙提供等价隔离。
- 镜像同时固定 tag 和 digest，避免私有仓库同名 tag 被覆盖。

如客户提供已有证书 Secret，Chart 优先复用；否则 Chart 在首次安装时生成集群内部证书并在后续升级中保留。

## 资源与运行参数

默认资源基线：

```yaml
resources:
  requests:
    cpu: "2"
    memory: 8Gi
  limits:
    cpu: "4"
    memory: 8Gi

javaOpts: "-Xms4g -Xmx4g"
```

JVM `Xms` 与 `Xmx` 必须相同，Heap 默认不超过容器内存的 50%。资源值允许在安装时覆盖。

所有可能承载 Elasticsearch 的 Worker 必须提前配置：

```text
vm.max_map_count=262144
nofile >= 65535
```

Chart 默认不使用特权容器修改宿主机内核参数。宿主机配置由客户运维在安装前完成并提供验证结果。

## MetalLB 固定外部访问 IP

Elasticsearch HTTP Service 使用 `LoadBalancer` 类型，从 MetalLB `first-pool` 地址池绑定客户指定的固定 IP。Chart 提供以下值：

```yaml
service:
  type: LoadBalancer
  port: 9200
  loadBalancerIP: "<客户保留的固定 IP>"
  addressPool: first-pool
  protocol: layer2
  externalTrafficPolicy: Local
  loadBalancerSourceRanges: []
  allowSharedIP: false
  sharedIPKey: uino-es-cluster
  annotations: {}
```

Service 按客户现有 MetalLB 版本生成兼容注解：

```yaml
annotations:
  metallb.universe.tf/address-pool: first-pool
  metallb.universe.tf/loadBalancerIPs: "<客户保留的固定 IP>"
  metallb.universe.tf/protocol: layer2
```

只有客户明确要求多个 Service 共享同一个 IP 时，才增加：

```yaml
metallb.universe.tf/allow-shared-ip: uino-es-cluster
```

`allow-shared-ip` 的值是共享分组键，不使用宽泛的 `"true"` 作为默认值，避免无关 Service 意外加入同一共享组。额外的客户注解可通过 `service.annotations` 合并。

固定 IP 必须由客户提前从 `first-pool` 中保留并确认无冲突。外部只开放带 TLS 和认证的 `9200`；`9300` 仅允许 Elasticsearch Pod 之间通过 Headless Service 访问。

`externalTrafficPolicy: Local` 用于保留外部客户端源 IP，使 NetworkPolicy 的 CIDR 规则可预测生效。三个 Elasticsearch Pod 强制分布到不同 Worker，每个 Worker 都有本地 endpoint。NetworkPolicy 同时限制出站，只允许节点间 `9300` 和集群 DNS 的 TCP/UDP `53`，不允许 Elasticsearch Pod 直接访问公网。

## 健康检查与升级

- `startupProbe` 为首次启动和分片恢复提供充足时间。
- `readinessProbe` 使用 TLS 和认证检查节点是否可服务。
- `livenessProbe` 只判断本地进程或端口，不能因为集群短暂处于 yellow 状态而反复重启节点。
- `terminationGracePeriodSeconds` 默认为 120 秒。
- StatefulSet 使用有序滚动更新，一次只替换一个 Pod，并等待前一个 Pod Ready。
- PodDisruptionBudget 设置 `minAvailable: 2`，限制日常自愿驱逐。
- 安装、升级或初始化失败时保留 Elasticsearch 数据和快照，不执行自动清理。

首次集群引导与后续升级必须区分。启动逻辑仅在目标数据目录没有 Elasticsearch 集群元数据时注入稳定的 `cluster.initial_master_nodes` 列表；已有集群元数据的节点启动时不注入该参数。升级流程不得重新初始化集群，删除全部三个数据子目录被视为显式创建新集群。

## Helm 安装接口

客户侧最终使用本地 Chart 包安装：

```bash
helm install es-cluster ./elasticsearch-offline-arm64-<chart-version>.tgz \
  --namespace uino \
  --create-namespace \
  -f customer-values.yaml
```

安装前必须提供或确认：

- 私有镜像仓库地址和加固镜像 digest。
- 如需鉴权，提供 `imagePullSecret`。
- MetalLB `first-pool` 中预留的固定 IP，以及允许访问该 IP 的来源 CIDR。
- Elasticsearch 数据 NFS 挂载点已在所有 Worker 的 `/data/uinnova/apps/es` 可用。
- 快照 NFS 的 server、export path 和目录权限。
- 允许访问 `9200` 的业务命名空间或 Pod 标签。
- Worker 内核参数满足要求。

## 验收标准

1. Chart 可在无公网访问的环境中完成安装。
2. 所有工作负载镜像均来自客户私有仓库且为 `linux/arm64`。
3. `uino` 命名空间中存在三个 Ready 的 Elasticsearch Pod。
4. 三个 Pod 分布在三个不同 Worker。
5. Elasticsearch 集群状态达到 green，三个节点均加入同一集群。
6. MetalLB 从 `first-pool` 绑定指定固定 IP，外部授权客户端可通过该 IP 的 `9200` 端口访问。
7. TLS、密码认证、来源 CIDR 限制和 NetworkPolicy 生效，未授权访问被拒绝，`9300` 未对外暴露。
8. 每个 Pod 只使用自己的 NFS 数据子目录。
9. 重启任意一个 Pod 后数据保留，节点能重新加入集群。
10. 停止任意一个 Worker 后，剩余两个节点仍可选主并提供服务。
11. 快照仓库 `_verify` 成功，测试快照可以恢复为测试索引。
12. Helm 升级不会更换固定 IP、密码或证书，不会删除数据、删除快照或重新初始化集群。
13. Helm 卸载不会删除 NFS 数据目录或快照目录。

## 风险与边界

- Elasticsearch 7.10.2 已 EOL，加固只能降低部分风险，不能替代版本升级。
- 共享 NFS 数据盘会形成性能瓶颈和单一故障域，不能提供真正的存储级高可用。
- PDB 只约束自愿驱逐，不能防止 Worker、NFS 或网络故障。
- 三节点高可用依赖三个独立 Worker、可靠网络和正确的时间同步。
- 固定外部 IP 依赖客户 MetalLB 地址池和 Layer 2 广播正常工作；Chart 不负责部署或修复 MetalLB。
- Chart 不负责部署 NFS 服务、私有镜像仓库、CNI 或宿主机内核参数。
- Chart 不自动执行快照恢复、数据迁移或 Elasticsearch 大版本升级。

## 后续演进

- 在业务兼容后升级到仍受维护的 Elasticsearch 版本。
- 将数据盘迁移到每节点独立的本地 SSD 或块存储 RWO PVC。
- 将快照存储迁移到独立故障域或对象存储。
- 当客户平台统一管理多个 Elasticsearch 集群时，再评估引入 ECK Operator。
