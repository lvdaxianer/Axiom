## ADDED Requirements

### Requirement: 节点数据目录隔离

系统 MUST 使用 Worker 上预挂载的 `/data/uinnova/apps/es`，并为三个 StatefulSet Pod 分配与 Pod 名称一致且互不重叠的数据子目录。

#### Scenario: 三节点挂载数据目录

- **WHEN** `es-cluster-0`、`es-cluster-1` 和 `es-cluster-2` 启动
- **THEN** 它们必须分别只使用 `/data/uinnova/apps/es/es-cluster-0`、`es-cluster-1` 和 `es-cluster-2` 对应的子目录

#### Scenario: 数据目录不可写

- **WHEN** 某个节点的数据子目录不存在且无法创建、不可写或存在错误的节点锁
- **THEN** 该 Pod 必须启动失败且不得删除、清空或递归修改共享目录中的已有数据

### Requirement: 数据生命周期独立于 Helm

系统 MUST 在安装失败、升级、回滚和卸载过程中保留 Elasticsearch 数据目录。

#### Scenario: Helm 卸载

- **WHEN** 运维人员卸载 Helm Release
- **THEN** Chart 资源可以删除，但 `/data/uinnova/apps/es` 及三个节点子目录中的内容必须保留

#### Scenario: Helm 升级失败

- **WHEN** Helm 升级因 Pod 或 Hook Job 失败而回滚
- **THEN** 已有节点数据不得被初始化、迁移或清理

### Requirement: 独立 NFS 快照仓库

系统 SHALL 将配置的独立 NFS export 挂载到所有 Elasticsearch Pod 的相同路径，并将该路径加入 `path.repo`。

#### Scenario: 启用快照

- **WHEN** `snapshot.enabled=true` 且提供 NFS server、export path 和集群子目录
- **THEN** 三个 Pod 必须挂载同一个快照 volume，并使用独立的集群子目录注册 `fs` 类型仓库

#### Scenario: 快照参数不完整

- **WHEN** 启用了快照但 NFS server、export path、repository name 或 cluster path 缺失
- **THEN** Helm 必须在创建 StatefulSet 前拒绝该配置

### Requirement: 快照验证与保留策略

系统 MUST 在集群可用后注册快照仓库、执行仓库 `_verify`，并在启用时创建 SLM 定时快照和保留策略。

#### Scenario: 仓库验证成功

- **WHEN** 三个节点均可读写配置的快照目录
- **THEN** 初始化 Job 必须完成仓库注册、验证和 SLM 策略配置并以零状态退出

#### Scenario: 仓库验证失败

- **WHEN** 任意节点无法访问快照目录或 Elasticsearch API 返回错误
- **THEN** 初始化 Job 必须以非零状态退出、保留日志且不得删除已有快照

#### Scenario: Helm 卸载保留快照

- **WHEN** 运维人员卸载 Helm Release
- **THEN** NFS 快照文件必须保留且 Chart 不执行自动恢复或快照删除 API
