# Doris 时序数据生产架构设计

## 1. 结论

本方案面向每年约 50 亿条电力时序数据、原始变化点在线保留一年的生产系统。核心决策是：以查询路径拆分原始变化点、当前状态、对象聚合、全网聚合和事件表；以日分区完成冷热迁移与删除；由 Tarsier 服务负责参数白名单、查询路由和补点；缓存仅覆盖配置、当前状态和固定聚合结果。

这不是压测方案。本文不定义压测脚本、并发梯度或性能验收阈值，也不以缓存替代正确的表结构和查询路由。

## 2. 约束与边界

- 年数据量：约 50 亿条原始变化点，平均约 1370 万条/日。
- 在线留存：原始变化点最多 365 天；超过期限的数据先归档，再删除在线分区。
- 业务接口：对象/站内多对象曲线、全网功率曲线、地图和列表当前状态、历史时间指针、事件与作业分页、单对象秒级曲线。
- 曲线规则：小于 7 天使用原始点并按 5 分钟补点；7 至 30 天使用小时聚合；30 天及以上使用日聚合；秒级查询只允许受控窗口。
- 基础设施：数十 TB 磁盘、数百 GB 内存。生产基线要求至少 3 个 BE；若只有一台物理机，只能按单副本降级部署，不能宣称高可用。
- 不使用接口传入的表名、列名或任意 SQL 片段。`menuType`、`levelType` 必须映射到服务器管理的固定配置。

## 3. 集群与数据链路

### 3.1 推荐拓扑

```text
                    +-------------------------+
                    |  Tarsier API Service     |
                    | mapping / route / fill   |
                    +------------+------------+
                                 |
                      +----------+----------+
                      |                     |
               +------+-------+      +------+-------+
               | Redis        |      | Doris FE x3  |
               | hot cache    |      +------+-------+
               +--------------+             |
                    +------------------------+-----------------------+
                    |                        |                       |
                +---+---+                +---+---+               +---+---+
                | BE-1  |                | BE-2  |               | BE-3  |
                | SSD   |                | SSD   |               | SSD   |
                | HDD   |                | HDD   |               | HDD   |
                +---+---+                +---+---+               +---+---+
                    ^                        ^                       ^
                    +----------- Kafka / ingest service ------------+
```

- FE：3 节点，1 个 Master 和 2 个 Follower，提供元数据高可用。
- BE：至少 3 节点，原始和聚合事实表使用 3 副本；维表可按数据重要性采用 3 副本。
- SSD：最近 30 天原始分区、当前状态、5 分钟聚合、维表和高频小时/天聚合。
- HDD：第 31 至第 365 天原始分区。若现场 Doris 版本和对象存储经过验证，可改为远端对象存储冷却。
- 内存：为 BE 的查询执行、Page Cache、Compaction 和元数据预留空间；Redis 只存热点，不能作为历史数据存储。

### 3.2 写入与派生关系

```text
采集报文
  -> 原始变化点 fact_telemetry_raw / fact_telemetry_ext_raw
  -> 当前状态 fact_current_state
  -> agg_object_5m -> agg_object_1h -> agg_object_1d
  -> agg_global_5m -> agg_global_1h -> agg_global_1d
  -> 事件/作业 fact_event / fact_work_order
```

原始变化点是历史事实的唯一来源。当前状态和聚合表是派生数据，可以从原始分区重建；任何迁移、补录或修正必须同时重算受影响的聚合桶并失效相应缓存。

## 4. 查询驱动的数据模型

### 4.1 逻辑表和访问路径

| 表 | 用途 | 分区 | 有效排序前缀 | 读取方 |
|---|---|---|---|---|
| `dim_object` | 对象、厂站、层级和父子关系 | 无 | `object_id` | 所有接口 |
| `dim_metric` | 指标单位、类型、聚合与补点语义 | 无 | `metric_code` | 路由与响应 |
| `cfg_curve_mapping` | 菜单和层级到系列的白名单映射 | 无 | `menu_type, level_type` | Tarsier 服务 |
| `fact_telemetry_raw` | 高频且稳定指标的原始变化点宽表 | 日 | `event_date, object_id, event_time, source_seq` | 短对象曲线、秒级详情 |
| `fact_telemetry_ext_raw` | 扩展/低频指标窄表 | 日 | `event_date, object_id, metric_code, event_time, source_seq` | 扩展对象曲线 |
| `fact_current_state` | 每对象每指标最新值 | 无 | `object_id, metric_code` | 当前地图、列表 |
| `agg_object_5m/1h/1d` | 单对象曲线与历史状态 | 日/月 | `event_date, object_id, metric_code, bucket_time` | 对象和站内曲线 |
| `agg_global_5m/1h/1d` | 全网指标曲线 | 日/月 | `event_date, metric_code, bucket_time` | 地图全网曲线 |
| `fact_event` | 告警、状态变化、缺陷等事件 | 日 | `event_date, object_id, event_time` | 事件/状态分页 |
| `fact_work_order` | 作业情况 | 月 | `work_month, station_id, start_time` | 作业分页 |

`event_date` 位于排序键第一位是 Doris 日分区模型的实现约束。请求总是带时间范围，Doris 先裁剪到有限日分区；在每个命中分区内，`object_id`、`metric_code` 和时间成为实际的扫描前缀。

### 4.2 对象与指标维表

```sql
CREATE TABLE dim_object (
  object_id BIGINT NOT NULL,
  object_code VARCHAR(128) NOT NULL,
  object_name VARCHAR(256) NOT NULL,
  level_type VARCHAR(32) NOT NULL,
  station_id BIGINT NULL,
  parent_object_id BIGINT NULL,
  voltage_level VARCHAR(32) NULL,
  enabled TINYINT NOT NULL,
  version BIGINT NOT NULL,
  updated_at DATETIME NOT NULL
)
UNIQUE KEY(object_id)
DISTRIBUTED BY HASH(object_id) BUCKETS 3
PROPERTIES (
  "replication_allocation" = "tag.location.default: 3",
  "enable_unique_key_merge_on_write" = "true"
);

CREATE TABLE dim_metric (
  metric_code VARCHAR(64) NOT NULL,
  metric_name VARCHAR(128) NOT NULL,
  unit VARCHAR(32) NOT NULL,
  value_kind VARCHAR(16) NOT NULL,
  fill_policy VARCHAR(16) NOT NULL,
  aggregation_policy VARCHAR(32) NOT NULL,
  source_kind VARCHAR(16) NOT NULL,
  source_field VARCHAR(64) NULL,
  enabled TINYINT NOT NULL,
  version BIGINT NOT NULL
)
UNIQUE KEY(metric_code)
DISTRIBUTED BY HASH(metric_code) BUCKETS 3
PROPERTIES (
  "replication_allocation" = "tag.location.default: 3",
  "enable_unique_key_merge_on_write" = "true"
);
```

`value_kind` 至少区分 `GAUGE`、`COUNTER`、`STATE`。连续量使用前向补点和 min/max/last；电度使用差值语义；开关状态使用 last-value 语义，不得按数值插值。

### 4.3 受控映射配置

```sql
CREATE TABLE cfg_curve_mapping (
  menu_type VARCHAR(64) NOT NULL,
  level_type VARCHAR(32) NOT NULL,
  series_code VARCHAR(64) NOT NULL,
  metric_code VARCHAR(64) NOT NULL,
  object_scope VARCHAR(16) NOT NULL,
  source_kind VARCHAR(16) NOT NULL,
  display_order SMALLINT NOT NULL,
  enabled TINYINT NOT NULL,
  version BIGINT NOT NULL
)
UNIQUE KEY(menu_type, level_type, series_code)
DISTRIBUTED BY HASH(menu_type) BUCKETS 3
PROPERTIES (
  "replication_allocation" = "tag.location.default: 3",
  "enable_unique_key_merge_on_write" = "true"
);
```

`object_scope` 只允许以下固定值：`GLOBAL`、`SELF`、`STATION_CHILDREN`。例如，地图全网功率映射为 `GLOBAL`，输电线路负载率映射为 `SELF`，变电站下所有主变负载率映射为 `STATION_CHILDREN`。服务查询此表后只从已发布的枚举中选择 SQL 模板。

### 4.4 原始变化点表

稳定、同报文到达的电压、电流、功率、电度等指标放入宽表，避免把一份采集报文拆成多行后无谓放大记录数。宽表仍是列式存储，曲线查询只读取目标指标列。

```sql
CREATE TABLE fact_telemetry_raw (
  event_date DATE NOT NULL,
  object_id BIGINT NOT NULL,
  station_id BIGINT NULL,
  level_type VARCHAR(32) NOT NULL,
  event_time DATETIME(3) NOT NULL,
  source_seq BIGINT NOT NULL,
  quality TINYINT NOT NULL,
  ua DOUBLE NULL,
  ub DOUBLE NULL,
  uc DOUBLE NULL,
  ia DOUBLE NULL,
  ib DOUBLE NULL,
  ic DOUBLE NULL,
  active_power DOUBLE NULL,
  reactive_power DOUBLE NULL,
  power_factor DOUBLE NULL,
  frequency DOUBLE NULL,
  load_rate DOUBLE NULL,
  positive_active_energy DOUBLE NULL,
  positive_reactive_energy DOUBLE NULL,
  reverse_active_energy DOUBLE NULL,
  reverse_reactive_energy DOUBLE NULL,
  tap_position DOUBLE NULL,
  partial_discharge DOUBLE NULL,
  wireless_temperature DOUBLE NULL,
  ingest_time DATETIME(3) NOT NULL
)
DUPLICATE KEY(event_date, object_id, event_time, source_seq)
PARTITION BY RANGE(event_date) ()
DISTRIBUTED BY HASH(object_id) BUCKETS 6
PROPERTIES (
  "replication_allocation" = "tag.location.default: 3",
  "compression" = "ZSTD"
);
```

本文以 3 个 BE、6 个 Hash 桶为生产基线，使每个 BE 承担 2 个桶。若节点数增加，或单日压缩后数据量导致单桶长期低于 1 GB 或超过 10 GB，实施变更必须同步调整为 BE 数量的整数倍，并在建表前记录调整原因。

扩展/低频指标使用窄表：

```sql
CREATE TABLE fact_telemetry_ext_raw (
  event_date DATE NOT NULL,
  object_id BIGINT NOT NULL,
  metric_code VARCHAR(64) NOT NULL,
  event_time DATETIME(3) NOT NULL,
  source_seq BIGINT NOT NULL,
  value_double DOUBLE NULL,
  value_text VARCHAR(256) NULL,
  quality TINYINT NOT NULL,
  ingest_time DATETIME(3) NOT NULL
)
DUPLICATE KEY(event_date, object_id, metric_code, event_time, source_seq)
PARTITION BY RANGE(event_date) ()
DISTRIBUTED BY HASH(object_id) BUCKETS 6
PROPERTIES (
  "replication_allocation" = "tag.location.default: 3",
  "compression" = "ZSTD"
);
```

`source_seq` 使同一对象、同一时刻的多个来源记录可共存；不可用唯一键静默覆盖历史变化点。

### 4.5 当前状态与聚合表

```sql
CREATE TABLE fact_current_state (
  object_id BIGINT NOT NULL,
  metric_code VARCHAR(64) NOT NULL,
  source_time DATETIME(3) NOT NULL,
  source_seq BIGINT NOT NULL,
  state_sequence BIGINT NOT NULL,
  value_double DOUBLE NULL,
  value_text VARCHAR(256) NULL,
  quality TINYINT NOT NULL,
  version BIGINT NOT NULL,
  updated_at DATETIME(3) NOT NULL
)
UNIQUE KEY(object_id, metric_code)
DISTRIBUTED BY HASH(object_id) BUCKETS 6
PROPERTIES (
  "replication_allocation" = "tag.location.default: 3",
  "enable_unique_key_merge_on_write" = "true",
  "function_column.sequence_col" = "state_sequence"
);

CREATE TABLE agg_object_5m (
  event_date DATE NOT NULL,
  object_id BIGINT NOT NULL,
  metric_code VARCHAR(64) NOT NULL,
  bucket_time DATETIME NOT NULL,
  first_time DATETIME(3) NULL,
  first_value DOUBLE NULL,
  last_time DATETIME(3) NULL,
  last_value DOUBLE NULL,
  min_time DATETIME(3) NULL,
  min_value DOUBLE NULL,
  max_time DATETIME(3) NULL,
  max_value DOUBLE NULL,
  sample_count BIGINT NOT NULL,
  aggregate_version BIGINT NOT NULL
)
UNIQUE KEY(event_date, object_id, metric_code, bucket_time)
PARTITION BY RANGE(event_date) ()
DISTRIBUTED BY HASH(object_id) BUCKETS 6
PROPERTIES (
  "replication_allocation" = "tag.location.default: 3",
  "enable_unique_key_merge_on_write" = "true",
  "function_column.sequence_col" = "aggregate_version",
  "compression" = "ZSTD"
);
```

`agg_object_1h` 和 `agg_object_1d` 采用同一列定义但粒度不同。`agg_global_*` 的主键改为 `(event_date, metric_code, bucket_time)`，只保存全网已定义的指标。全网曲线只能读取 `agg_global_*`，不得从对象聚合或原始表即时汇总。

`state_sequence` 必须由接入层根据源事件时间和源序号生成单调可比较值；同一对象指标的迟到记录序列更小，不得覆盖较新的 `fact_current_state`。部署前需核验现场 Doris 版本支持 `function_column.sequence_col`；若不支持，接入层必须先过滤旧序列，再执行状态表写入。

`aggregate_version` 必须在每次桶重算时单调递增；同一序列机制应用于小时、天和全网聚合表。这样较早启动的补录任务不能在较晚完成后覆盖已发布的新聚合桶。

## 5. 数据生命周期：写入、迁移、归档与删除

### 5.1 分区状态机

```text
OPEN (D0-D2, SSD, 允许迟到)
  -> SEALED (完成迟到窗口和聚合核对)
  -> WARM (D31-D365, HDD 或对象存储)
  -> BACKED_UP (备份和校验完成)
  -> DROPPED (超过 365 天，执行 DROP PARTITION)
```

- `OPEN`：当天及迟到窗口内的日分区。原始数据、当前状态和相关聚合均可更新。
- `SEALED`：迟到窗口结束，核对原始行数、时间边界、聚合桶完整性；正常接口只读。
- `WARM`：通过 Doris 分区存储策略把已封闭日分区迁到 HDD 或远端存储。若版本不支持，迁入同构温表并登记路由元数据。
- `BACKED_UP`：对超过一年分区生成可恢复备份，记录对象路径、快照 ID、行数、最早/最晚时间、校验时间与执行人。
- `DROPPED`：只有 `BACKED_UP` 成功后才允许 `DROP PARTITION`。不对时序事实表执行无范围逐行 `DELETE`。

### 5.2 热温迁移规则

优先方案是同一逻辑表的分区级存储策略：接口始终查询一个表，Doris 负责冷热介质。前提是现场版本已经验证分区冷却、对象存储权限和远端读取恢复流程。

兼容方案是同构的 `*_hot`、`*_warm` 物理表：

1. 将封闭日分区从热表复制到温表临时分区。
2. 校验行数、最早/最晚事件时间、对象数、指标数和每个聚合桶的 `sample_count`。
3. 原子发布温分区路由；跨冷热边界的时间范围才使用 `UNION ALL` 合并。
4. 保留热源分区至观察期结束后才删除。
5. 若目标校验失败，撤销路由发布，热源分区继续提供查询。

### 5.3 迟到与补录

迟到窗口必须由实施方按上游特性配置，例如 D+2。窗口内的记录重算受影响的 5 分钟、小时、天聚合桶，并失效相应缓存。窗口外数据不得直接写入已删除或已迁移分区；必须走有审计记录的补录流程，重建目标日分区/桶，校验后再发布。

## 6. Tarsier 请求路由

### 6.1 通用处理顺序

```text
1. 校验时间、时区、pageSize、levelType 和 menuType
2. 从本地缓存/Redis 读取 cfg_curve_mapping 和 dim_metric
3. 解析 object_scope，必要时从 dim_object 得到有限对象集合
4. 按时间跨度和精度选择固定 SQL 模板
5. 先查询 startTime 前的有效值，再查询窗口数据
6. 服务端生成标准时间点、补点、排序和响应单位
7. 写入允许的缓存或返回结果
```

所有 SQL 参数绑定对象 ID、指标、时间和分页值。配置只选择预定义模板和字段枚举，绝不将客户端内容拼进表名、列名、`ORDER BY` 或排序方向。

### 6.2 曲线路由矩阵

| 场景 | 数据源 | 查询约束 | 服务职责 |
|---|---|---|---|
| 对象曲线，小于 7 天 | 原始宽/窄表 | 对象、指标、日期分区、时间范围 | 读取前置有效值；返回原始变化点并按 5 分钟补点 |
| 对象曲线，7-30 天 | `agg_object_1h` | 对象、指标、小时桶 | 读取小时首/末/极值，补齐桶边界 |
| 对象曲线，30 天及以上 | `agg_object_1d` | 对象、指标、日桶 | 返回日极值包络和末值 |
| 全网功率/频率 | `agg_global_*` | 指标、桶时间 | 不扫描对象明细或原始表 |
| 当前地图/列表 | `fact_current_state + dim_object` | 当前版本、对象范围 | 组装名称、电压等级、状态 |
| 历史指针地图/列表 | `agg_object_5m + dim_object` | 有限对象集合、最近桶 | 取指针前最近末值 |
| 事件/作业列表 | `fact_event` / `fact_work_order` | 日期分区、对象范围、分页 | 过滤、排序、游标/页码 |
| 秒级详情 | 原始宽/窄表 | 单对象、配置的最大窗口/点数 | 读取前置有效值并逐秒补点 |

PDF 中的“窗口仅返回最大值和最小值”与示例的多个原始变化点不一致。本文固定为：短周期返回原始变化点加边界补点，长周期返回极值包络。接口响应须返回 `granularity`，调用方据此展示。

### 6.3 SQL 模板示例

对象指标短周期读取：

```sql
SELECT event_time, load_rate, source_seq
FROM fact_telemetry_raw
WHERE event_date >= :start_date
  AND event_date <= :end_date
  AND object_id = :object_id
  AND event_time >= :start_time
  AND event_time <= :end_time
  AND load_rate IS NOT NULL
ORDER BY event_time, source_seq
LIMIT :max_raw_points;
```

前置有效值读取：

```sql
SELECT event_time, load_rate, source_seq
FROM fact_telemetry_raw
WHERE event_date >= :lookback_date
  AND event_date <= :start_date
  AND object_id = :object_id
  AND event_time < :start_time
  AND load_rate IS NOT NULL
ORDER BY event_time DESC, source_seq DESC
LIMIT 1;
```

对象小时聚合读取：

```sql
SELECT bucket_time, first_time, first_value, last_time, last_value,
       min_time, min_value, max_time, max_value
FROM agg_object_1h
WHERE event_date >= :start_date
  AND event_date <= :end_date
  AND object_id = :object_id
  AND metric_code = :metric_code
  AND bucket_time >= :start_time
  AND bucket_time <= :end_time
ORDER BY bucket_time
LIMIT :max_buckets;
```

全网日曲线读取：

```sql
SELECT bucket_time, min_value, max_value, last_value
FROM agg_global_1d
WHERE event_date >= :start_date
  AND event_date <= :end_date
  AND metric_code = :metric_code
ORDER BY bucket_time
LIMIT :max_buckets;
```

真实的字段名称由服务器发布的指标枚举选择，不由请求参数指定。扩展指标使用窄表模板，区别仅是 `metric_code` 条件和 `value_double` 列。

## 7. 缓存设计与一致性

| 缓存对象 | 介质 | 一致性 | 禁止项 |
|---|---|---|---|
| 对象树、指标定义、映射配置 | 本地 Caffeine + Redis | 配置发布事件主动失效；版本号校验 | 不依赖纯 TTL 更新配置 |
| 当前状态、地图榜单 | Redis | 遥测更新按对象/指标删除或推进版本；短 TTL 仅兜底 | 不缓存超过数据版本的状态 |
| 小时/天聚合固定窗口 | Redis | 聚合桶更新后失效；Key 含版本 | 不缓存任意动态时间范围 |
| Doris 远端数据/页缓存 | Doris Page Cache | 由 Doris 管理 | 不作为接口正确性的唯一机制 |

建议缓存键：

```text
cfg:curve:{mapping_version}:{menu_type}:{level_type}
state:{object_id}:{metric_code}:{state_version}
dashboard:{scope_hash}:{metric_code}:{granularity}:{start}:{end}:{timezone}:{aggregate_version}
```

不缓存以下请求：任意原始历史曲线、秒级曲线、任意大分页、包含未封闭分区的大范围动态查询。这些键基数高、命中率低，且会挤占 Redis 内存。

## 8. 容量与实施前置条件

容量按以下公式规划，而非只按磁盘标称容量规划：

```text
一年物理容量 =
  50 亿 x 实测压缩后字节/记录 x 副本数
  + 原始宽/窄表索引和元数据
  + 当前状态、对象聚合、全网聚合、事件表
  + Compaction、导入、查询临时空间和系统预留
```

实施前必须确认：

1. Doris 主版本、存储策略能力和对象存储兼容性。
2. 物理节点数、每个 BE 的 SSD/HDD 容量、网络和挂载点。
3. 原始数据是多指标采集报文还是一行一指标，以及实际压缩后字节数。
4. 对象数量、每对象指标数量、站内子对象最大数量和事件增长量。
5. 上游迟到数据的最大时间边界。
6. 秒级接口允许的最大时间窗口和返回点数。
7. 归档存储的保留年限、恢复责任人和恢复流程。

## 9. 实施顺序与回退

1. 建立 Doris 集群、冷热介质和备份存储，并确认版本支持路径。
2. 部署维表和映射配置，审核每个 `menuType + levelType` 的可用系列。
3. 部署原始、当前状态、对象聚合、全网聚合和事件表。
4. 导入历史日分区，逐日生成聚合并核对时间边界、行数和桶完整性。
5. 在 Tarsier 中按“对象、全网、状态、事件、秒级”路径接入固定 SQL 模板。
6. 启用缓存失效事件、分区迁移、归档和删除台账。
7. 上线后以数据质量、分区状态、Compaction、缓存失效和备份可恢复性为日常运维项。

回退原则：新查询路径异常时回退到既有数据源或上一版路由配置；不得通过删除原始分区回退。迁移失败时保持源分区可读并撤回目标路由；删除失败时保留已归档分区，不重试逐行删除。

## 10. 不在本次范围内

- 不交付 Tarsier 接口实现、Doris 建表脚本、ETL 作业、Kafka Topic、Redis 客户端或运维自动化脚本。
- 不定义压测方案、QPS、P95/P99 或压测结论。
- 不将一年以上归档数据纳入实时接口 SLA。
- 不支持用户在请求中输入表名、字段名、SQL、无界秒级窗口或无界分页。
