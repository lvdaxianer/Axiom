## Why

现场每年产生约 50 亿条电力时序数据，原始变化点仅在线保留一年。现有接口同时要求设备曲线、全网曲线、秒级补点、历史状态、事件列表和设备层级查询；若仅按业务实体建单一明细表，长时间范围和全网查询会扫描大量原始数据，且删除、冷热迁移和缓存失效缺少统一边界。

需要形成一份面向生产部署的 Apache Doris 架构方案，以查询路径驱动物理表结构和数据生命周期，使接口能够在不依赖全量结果缓存的前提下稳定读取受限数据集。

## What Changes

- 新增一年在线留存的时序数据分层模型，包含原始变化点、当前状态、对象聚合、全网聚合、事件和配置维表。
- 定义以对象曲线、全网曲线、地图/列表、历史时刻状态和事件分页为目标的分区、排序键、分桶和查询路由。
- 定义热数据、温数据、归档和分区删除的迁移状态、校验与回退原则。
- 定义 Tarsier 后端的白名单映射、补点职责和 SQL 构造边界。
- 定义本地缓存、Redis 和 Doris 缓存的适用范围、键设计与一致性失效策略。
- 明确生产集群拓扑、复制、容量计算方式和版本兼容降级方案。

## Capabilities

### New Capabilities

- `doris-telemetry-data-lifecycle`: 定义一年在线保留的分区存储、冷热迁移、备份归档和安全删除规则。
- `doris-query-oriented-schema`: 定义面向对象、全网、状态和事件查询的 Doris 逻辑表及物理访问路径。
- `timeline-query-routing`: 定义时间轴、秒级、状态和事件接口的白名单映射与查询路由。
- `telemetry-cache-consistency`: 定义配置、当前状态和聚合结果的缓存及一致性策略。

### Modified Capabilities

- None.

## Impact

- 新增生产技术方案与 OpenSpec 架构契约，不修改现有业务 API、Tarsier 服务代码或 Doris 集群配置。
- 方案依赖 Apache Doris、可选 Kafka/消息总线、Redis 和可选 S3/OSS/HDFS 归档存储。
- 现有 `time-series-read-benchmark` 变更只覆盖离线读压测，不替代本生产架构方案。
