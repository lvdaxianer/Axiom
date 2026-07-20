## ADDED Requirements

### Requirement: 单 Chart 离线部署

系统 SHALL 提供一个不依赖公网 Helm 仓库或公共镜像仓库的 Helm Chart，并在 `uino` 命名空间完成 Elasticsearch 集群所需资源的部署。

#### Scenario: 从本地 Chart 安装

- **WHEN** 运维人员使用客户 values 对本地 `.tgz` Chart 执行 `helm install`
- **THEN** Helm 渲染的全部工作负载镜像必须来自配置的客户私有仓库，且安装过程不请求公网资源

#### Scenario: 拒绝不完整离线配置

- **WHEN** 私有镜像仓库地址、镜像 digest 或必要的环境参数为空
- **THEN** Helm values schema 或模板校验必须在创建工作负载前使安装失败并指出缺失字段

### Requirement: 固定三节点 Elasticsearch 7.10.2 集群

系统 MUST 创建恰好三个 Elasticsearch 7.10.2 节点，每个节点 MUST 同时承担 `master`、`data` 和 `ingest` 角色。

#### Scenario: 首次形成集群

- **WHEN** 三个 Pod 首次启动且数据目录中没有既有集群元数据
- **THEN** 节点必须通过稳定 DNS 发现并形成同一个 Elasticsearch 集群

#### Scenario: 已有数据节点重启

- **WHEN** 任意 Pod 使用已有集群元数据重新启动
- **THEN** 该节点必须加入现有集群且不得触发新集群引导

### Requirement: 节点级高可用调度

系统 MUST 将三个 Elasticsearch Pod 调度到不同 Kubernetes Worker，并在自愿驱逐期间保持至少两个 Pod 可用。

#### Scenario: Worker 数量不足

- **WHEN** 可满足调度约束的 Worker 少于三个
- **THEN** 未满足反亲和规则的 Pod 必须保持 Pending，而不得与已有 ES Pod 调度到同一 Worker

#### Scenario: 单节点滚动更新

- **WHEN** StatefulSet 模板发生可滚动更新
- **THEN** 系统必须按顺序一次更新一个 Pod，并等待前一个 Pod Ready 后再继续

### Requirement: 资源与宿主机前置条件

Chart SHALL 提供 CPU、内存和 JVM Heap 参数，并 MUST 在文档中要求所有合格 Worker 满足 `vm.max_map_count=262144` 和 `nofile >= 65535`。

#### Scenario: 使用默认资源

- **WHEN** 客户没有覆盖资源参数
- **THEN** 每个 Pod 必须请求 2 CPU 和 8Gi 内存、限制为 4 CPU 和 8Gi 内存，并使用 `-Xms4g -Xmx4g`

#### Scenario: 宿主机参数不合格

- **WHEN** Worker 的必要内核参数不满足 Elasticsearch 启动要求
- **THEN** 启动检查必须失败且 Chart 不应通过特权容器自动修改宿主机
