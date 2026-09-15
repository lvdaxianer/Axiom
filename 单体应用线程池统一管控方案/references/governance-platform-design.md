# 总控平台设计

## 1. 定位

总控平台是线程池统一管控方案的**只读观测层**，职责是：

- 收集各应用实例的线程池指标。
- 聚合集群视角数据。
- 提供可视化看板和告警。
- 支持容量分析和历史趋势查询。

总控**不干预**子控运行：

- 不修改线程池参数。
- 不调度线程。
- 不持有业务状态。

## 2. 总控不部署时的替代方案

总控可以不作为独立服务部署，但必须保留其设计，便于未来快速启用。替代方案：

| 阶段 | 做法 |
|---|---|
| 初期 | 子控输出结构化日志，通过现有日志平台（ELK/Loki）手动查询。 |
| 中期 | 在日志平台中配置聚合报表和告警规则。 |
| 后期 | 部署总控平台，统一拉取、聚合、展示。 |

## 3. 总控核心模块

```text
GovernancePlatform
    ├── InstanceRegistry
    │       └── 管理子控实例列表（IP、端口、环境）
    ├── CursorStore
    │       └── 本地文件持久化每个实例已确认的采集游标
    ├── MetricsCollector
    │       └── 定时轮询各实例 HTTP 接口
    ├── MetricsAggregator
    │       └── 按实例、按线程池名称聚合指标
    ├── Dashboard
    │       └── 可视化展示
    └── AlertManager
            └── 根据规则触发告警
```

## 4. 实例列表配置

总控通过配置文件或环境变量维护子控实例列表：

```yaml
governance:
  instances:
    - name: app-01
      host: 192.168.1.101
      port: 8080
      env: prod
    - name: app-02
      host: 192.168.1.102
      port: 8080
      env: prod
    - name: app-03
      host: 192.168.1.103
      port: 8080
      env: prod

  collect:
    interval-seconds: 30
    timeout-seconds: 5
```

实例扩缩容时，更新该配置即可。

## 5. Cursor 持久化与补拉语义

时间戳不是可靠的断点：多个线程池可在同一毫秒采样，分页也可能在同一采样批次中截断。
子控必须为每条指标记录生成实例内单调递增、不可由客户端构造的 `cursor`。总控本地文件仅记录
**已经完整处理**的 cursor：

```yaml
# /data/governance/cursors.yaml
cursors:
  app-01: "c:01HZZR9Q0T:8192"
  app-02: "c:01HZZR9Q2B:4121"
  app-03: "c:01HZZR9Q3Y:2050"
```

- 每次响应携带 `nextCursor` 和 `hasMore`。总控必须持续翻页，直到
  `hasMore=false` 后才能原子提交 `nextCursor`。
- 单页请求失败、解析失败或下游写入失败时，不推进持久化 cursor；允许幂等地重复处理已收到的页。
- 环形缓冲区必须声明保留时间和最大记录数。cursor 已过期时子控返回明确的 `CURSOR_EXPIRED`
  错误及 `oldestCursor`，总控记录观测缺口、触发告警并改用当前快照恢复。
- 本地 cursor 文件仅适合单实例总控；若总控需要高可用，必须放入具备原子 compare-and-set
  语义的共享存储。

## 6. 拉取流程

```text
定时任务启动（每 30 秒）
    ↓
读取实例列表
    ↓
读取 cursors.yaml
    ↓
对每个实例：
    GET /admin/thread-pool/metrics?cursor={cursor}&limit={limit}
    ↓
子控返回 cursor 之后的一页指标、nextCursor 和 hasMore
    ↓
hasMore=true 时继续拉取；全部分页成功后原子更新 cursor
    ↓
将指标送入 Aggregator
    ↓
定时刷新 Dashboard 和告警检查
```

## 7. 子控接口定义

### 7.1 查询指标

```http
GET /admin/thread-pool/metrics?cursor={cursor}&limit={limit}
```

请求参数：

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `cursor` | string | 否 | 上一次已完整处理的 cursor；首次采集为空。 |
| `limit` | int | 否 | 单次返回最大条数，默认 1000 |

响应：

```json
{
  "serverTime": 1694750460000,
  "nextCursor": "c:01HZZR9Q0T:8192",
  "hasMore": false,
  "oldestCursor": "c:01HZZR8K3A:1",
  "metrics": [
    {
      "cursor": "c:01HZZR9Q0T:8192",
      "timestamp": 1694750400000,
      "instance": "app-01",
      "name": "order-create-h",
      "active": 8,
      "poolSize": 16,
      "queueSize": 12,
      "queueCapacity": 200,
      "completed": 49980,
      "rejected": 0,
      "waitTimeMs": 15,
      "execTimeMs": 45,
      "weight": 10,
      "actualMax": 32,
      "managedWorkerBudget": 64
    }
  ]
}
```

当请求中的 cursor 早于子控环形缓冲区的保留窗口时，接口返回 `409 Conflict`：

```json
{
  "code": "CURSOR_EXPIRED",
  "message": "The requested cursor is older than the retained metrics window.",
  "oldestCursor": "c:01HZZR8K3A:1"
}
```

### 7.2 查询实例下所有线程池快照

```http
GET /admin/thread-pools/snapshot
```

返回当前时刻所有线程池的最新状态。

## 8. 聚合逻辑

### 8.1 集群聚合

```text
集群活跃线程总数 = sum(active) by instance
集群队列堆积总数 = sum(queueSize) by instance
集群拒绝总数   = sum(rejected) by instance
集群实际 max   = sum(actualMax) by instance
```

### 8.2 单池聚合

```text
order-create-h 集群活跃 = sum(active) where name = order-create-h
order-create-h 集群队列 = sum(queueSize) where name = order-create-h
```

### 8.3 利用率

```text
单实例利用率 = sum(active) / sum(actualMax)
单池利用率   = active / actualMax
```

## 9. 看板设计

建议展示以下面板：

| 面板 | 指标 |
|---|---|
| 集群总览 | 受管 worker 总活跃数、受管 worker 预算、总队列堆积、按原因的拒绝数 |
| 线程池排行 | 按队列使用率、拒绝数、活跃线程排序 |
| 实例对比 | 各实例同名线程池的活跃数和队列数对比 |
| 耗时趋势 | waitTimeMs / execTimeMs / totalTimeMs 趋势 |
| 配额分布 | 各池 actualMax / configuredMax / weight |

## 10. 告警规则

| 告警级别 | 条件 |
|---|---|
| P0 | `PERSIST_FOR_RETRY` 任务无法持久化，或死信数在 1 分钟内增加 |
| P1 | `FAIL_FAST` 或 `BEST_EFFORT_DROP` 拒绝数在 1 分钟内增加 |
| P1 | 某实例 `queueSize / queueCapacity > 0.8` 持续 2 分钟 |
| P1 | 某池 `waitTimeMs` 持续升高 |
| P2 | 集群总活跃线程超过设计容量的 80% |
| P2 | 某实例线程池利用率持续超过 90% |

## 11. 部署方式

### 方式一：独立轻量服务（推荐后期使用）

部署一个独立的总控服务，不依赖数据库：

- 配置文件或服务发现管理实例列表。
- 单实例部署时以本地文件持久化 cursor；高可用时使用共享 cursor 存储。
- 仅做实时聚合；历史趋势、告警状态和容量分析写入已有 Prometheus 等时序后端。
- 提供 Web 看板。

### 方式二：脚本/定时任务（临时方案）

用脚本定时拉取各实例指标，生成报告或发送告警邮件：

```bash
#!/bin/bash
for host in app-01 app-02 app-03; do
  curl -s "https://${host}:8080/admin/thread-pool/metrics?cursor=$(cat cursors/${host})"
done
```

### 方式三：复用现有平台（推荐初期使用）

- 子控暴露受认证保护的 Micrometer/Prometheus 指标。
- 复用 Prometheus/Grafana 做聚合、持久化趋势和告警。
- 结构化日志只记录低频的配置变更、拒绝摘要和异常，不作为高频时序指标通道。

## 12. 安全要求

子控管理接口必须限制访问：

- 全链路 TLS；优先使用 mTLS，或使用部署系统注入、可轮换的服务身份凭据。
- 在网关和应用层都校验调用方身份与最小权限；IP 白名单只能作为附加控制。
- 对查询端点限流、限制 `limit` 上限，并记录访问审计日志。
- 禁止暴露到公网；错误响应不得泄露内部拓扑、凭据或栈信息。

## 13. 后续演进

| 阶段 | 内容 |
|---|---|
| 初期 | 子控输出日志，复用现有日志平台查询。 |
| 中期 | 部署独立总控服务，定时拉取并展示。 |
| 后期 | 增加配置建议、容量预测、自动告警升级。 |
