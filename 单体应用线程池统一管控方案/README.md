# 单体应用线程池统一管控方案

## 1. 背景

单体应用内部存在大量线程池时，容易出现以下问题：

- 各业务自行创建线程池，参数各异，管理混乱。
- 单个线程池的 `max-size` 被限制，但 JVM 内线程池总数不受控，导致整体线程数爆炸。
- 高优先级业务和低优先级业务争抢线程，核心链路可能被非核心任务挤占。
- 缺乏统一观测手段，问题排查依赖逐个实例登录查看日志。

本方案面向**集群部署的单体应用**，在每个 JVM 内部署自治的线程池治理模块（子控），并通过一个轻量总控平台聚合各实例指标，实现统一管控与可观测。

## 2. 目标

- 统一 JVM 内部所有线程池的创建、命名、配置和监控。
- 保证每个线程池都有保底线程，避免被完全饿死。
- 超出保底部分的线程资源按业务权重分配。
- 限制受管业务线程池的 worker 总预算，避免业务异步任务挤占 JVM 资源。
- 总控只做统计展示与告警，不干预子控运行。

## 3. 总体架构

```text
┌─────────────────────────────┐
│          总控平台             │
│  聚合展示 / 告警 / 容量分析    │
│  不干涉子控运行               │
└─────────────────────────────┘
              ↑
    子控暴露 HTTP 接口，增量返回指标
              ↑
┌─────────┬─────────┬─────────┐
│ App-01  │ App-02  │ App-03  │
│  子控    │  子控    │  子控    │
│ 内存存   │ 内存存   │ 内存存   │
│ 指标     │ 指标     │ 指标     │
└─────────┴─────────┴─────────┘
```

### 3.1 子控层

子控嵌入在每个应用实例内部，是实际治理线程池的地方：

```text
ThreadPoolGovernor（子控入口）
    ├── QuotaManager（配额计算）
    │       └── 根据 min / max / weight 计算每个池的实际 max
    ├── PoolRegistry（注册表）
    │       └── 管理所有线程池，禁止重名和私自创建
    ├── ThreadPoolFactory（工厂）
    │       └── 统一创建线程池
    ├── RuntimeGuard（运行时保护）
    │       └── 监控 JVM 总线程水位，必要时拦截低优先级任务
    └── MetricsReporter（指标上报）
            └── 内存环形缓冲区 + HTTP 增量查询接口
```

### 3.2 总控层

总控是一个独立的只读平台：

- 配置各实例子控的 IP 列表。
- 定时增量拉取各实例的线程池指标。
- 本地文件持久化每个实例已确认的 cursor。
- 聚合集群视角的总线程数、队列堆积、拒绝次数等。
- 提供可视化看板和告警。

总控不修改子控配置，不调度线程，不需要独立数据库。

详见 [总控平台设计](./references/governance-platform-design.md)。

## 4. 核心设计

### 4.1 配额模型

#### 4.1.1 资源边界与不变量

`managed-worker-budget` 不是 JVM 的总线程上限，而是**受管业务 worker 预算**：仅覆盖由
`ThreadPoolGovernor` 创建的执行线程。Tomcat/Netty、GC/JIT、JDK 运行时、定时任务和
三方库线程均属于非受管线程，必须在容量规划中单独预留余量。

子控必须同时满足下列不变量：

1. `sum(各池 actualMax) <= managed-worker-budget`。
2. 每项任务在实际开始运行前必须持有一个全局 worker 许可；任务结束（包括异常）后在
   `finally` 中释放。许可数量等于 `managed-worker-budget`，用于消除“先检查、后提交”
   的并发竞态。
3. 许可耗尽时不得创建额外 worker；任务应依据其可靠性分类进入有界队列、拒绝或持久化
   重试流程。
4. JVM 实际线程数仅作为水位和告警指标，不作为可以严格保证的硬上限。

容量规划应先确定容器线程、JVM/框架线程、定时任务和三方 SDK 的预留，再以可承受的
进程线程数减去该余量得到 `managed-worker-budget`。当进程线程水位异常时，RuntimeGuard
只能进一步收紧低优先级任务准入，不能突破上述预算。

每个线程池配置三个关键参数：

| 参数 | 含义 |
|---|---|
| `min` | 保底线程数，任何情况下不被压缩 |
| `max` | 业务期望的最大线程数 |
| `weight` | 可分配资源时的权重 |

`weight` 只用于弹性容量分配，**不得**作为优先级或任务重要性的代理。每个线程池还必须配置
`priority: HIGH | MEDIUM | LOW`，由 RuntimeGuard 在过载状态下执行差异化准入。

配额计算规则：

```text
可分配资源 = managed-worker-budget - sum(各池 min)

各池额外分配 = 可分配资源 × (本池 weight / 总 weight)
各池实际 max = min + 额外分配
             （不超过业务配置的 max）
```

示例：

```yaml
global:
  managed-worker-budget: 64

pools:
  order-create-h:
    min: 1
    max: 32
    weight: 10
    priority: HIGH
    reliability: FAIL_FAST
  inventory-sync-m:
    min: 1
    max: 16
    weight: 5
    priority: MEDIUM
    reliability: PERSIST_FOR_RETRY
  message-push-l:
    min: 1
    max: 8
    weight: 2
    priority: LOW
    reliability: BEST_EFFORT_DROP
```

计算过程：

```text
sum(min) = 1 + 1 + 1 = 3
可分配资源 = 64 - 3 = 61
totalWeight = 10 + 5 + 2 = 17

order 额外分配 = 61 × 10 / 17 ≈ 35
order 实际 max = min(1 + 35, 32) = 32

inventory 额外分配 = 61 × 5 / 17 ≈ 17
inventory 实际 max = min(1 + 17, 16) = 16

message 额外分配 = 61 × 2 / 17 ≈ 7
message 实际 max = 1 + 7 = 8
```

多余的可分配资源按权重重新分配，直到分完或被各池上限卡住。

### 4.2 新池加入时的重新分配

当有新线程池注册时，子控会重新计算所有池的实际 max，并更新现有池的 `maximumPoolSize`：

```text
1. 新池加入
2. sum(min) 增加
3. 可分配资源减少
4. 按新权重重新切分
5. 更新所有池的实际 max
```

### 4.3 运行时任务提交流程

```text
业务调用 governor.executor(name).submit(task)
        ↓
受控执行器包装任务并透传 MDC / traceId
        ↓
RuntimeGuard 根据 priority、可靠性分类、全局许可和 JVM 水位执行准入
        ↓
  正常 → 进入线程池
  受管预算耗尽 → 按可靠性策略排队、快速失败或持久化重试
  JVM 高水位 → 优先收紧 LOW，再收紧 MEDIUM；HIGH 仅保留其明确配置的保底能力
        ↓
ThreadPoolExecutor 执行
        ↓
当前线程 < core → 创建线程
  当前线程 ≥ core，队列未满 → 排队
  队列满，当前线程 < 实际 max → 创建线程
  队列满，当前线程 = 实际 max → 执行拒绝策略
```

业务代码不得获得原始 `ThreadPoolExecutor`，否则可绕过准入、任务包装和埋点。子控只暴露
受控的 `Executor` 或 `ExecutorService` 门面；其包装器负责全局许可、计时、指标和 MDC
上下文传播。Spring `@Async`、`CompletableFuture` 的默认执行器、定时任务和三方 SDK
线程池也必须在迁移盘点中被显式处理。

#### 4.3.1 任务可靠性与拒绝语义

每个池必须声明 `reliability`，拒绝策略由该属性决定，而不是直接暴露 JDK 的
`DiscardPolicy` 或 `DiscardOldestPolicy`：

| 分类 | 适用任务 | 预算或队列耗尽时的行为 |
|---|---|---|
| `FAIL_FAST` | 同步请求可明确返回过载的非关键派生操作 | 返回稳定的过载错误；调用方可退避重试。不得使用 caller-runs 阻塞入口线程。 |
| `PERSIST_FOR_RETRY` | 支付回调、库存同步、必须送达的通知等 | 原子写入可恢复的重试记录或消息系统，记录幂等键、失败原因和重试状态；超过阈值进入死信或人工处置。 |
| `BEST_EFFORT_DROP` | 明确允许丢失的刷新、预取、非关键分析 | 丢弃前递增专用指标并写受控告警；配置需注明业务所有者和可接受损失。 |

`caller-runs` 仅允许在已证明不会阻塞 HTTP、MQ 消费或调度入口的内部低频场景使用。所有拒绝、
持久化失败和降级都必须按池、原因和可靠性分类计数。

### 4.4 命名规则

格式：

```text
{业务域}-{用途}-{优先级标识}
```

| 分段 | 说明 | 示例 |
|---|---|---|
| 业务域 | 业务模块 | `order`、`inventory`、`payment` |
| 用途 | 任务类型 | `create`、`sync`、`push`、`export`、`callback` |
| 优先级标识 | 单字母 | `h` High、`m` Medium、`l` Low |

命名规范：

- 全小写，用 `-` 连接。
- 禁止 `pool1`、`executor2` 等无意义命名。
- 一个 JVM 内名称唯一。
- 长度控制在 50 字符以内。

示例：

```text
order-create-h
inventory-sync-m
message-push-l
payment-callback-h
report-export-l
```

线程名也应带有业务含义，便于日志排查：

```text
order-create-h-pool-1
order-create-h-pool-2
```

### 4.5 埋点指标

子控需要采集以下指标：

| 类别 | 指标 | 说明 |
|---|---|---|
| 基础信息 | `name` | 线程池名称 |
| | `timestamp` | 采样时间戳 |
| | `instance` | 实例标识 |
| 容量状态 | `min` | 保底线程数 |
| | `configuredMax` | 业务配置的最大线程数 |
| | `actualMax` | 子控计算后的实际最大线程数 |
| | `coreSize` | 线程池当前 coreSize |
| | `maxSize` | 线程池当前 maximumPoolSize |
| 运行状态 | `active` | 当前活跃线程数 |
| | `poolSize` | 当前线程池大小 |
| | `idle` | 空闲线程数 |
| | `queueSize` | 当前队列堆积数 |
| | `queueCapacity` | 队列总容量 |
| | `queueRemaining` | 队列剩余容量 |
| 任务统计 | `submitted` | 累计提交任务数 |
| | `completed` | 累计完成任务数 |
| | `rejected` | 累计拒绝任务数 |
| | `failed` | 累计执行失败数 |
| 耗时指标 | `waitTimeMs` | 任务平均等待时间 |
| | `maxWaitTimeMs` | 任务最大等待时间 |
| | `execTimeMs` | 任务平均执行时间 |
| | `maxExecTimeMs` | 任务最大执行时间 |
| | `totalTimeMs` | 任务平均总耗时 |
| 配额信息 | `weight` | 该池权重 |
| | `managedWorkerBudget` | 当前实例的受管业务 worker 预算 |

采集方式：包装任务提交过程，在任务开始执行和完成时记录时间戳，计算等待耗时和执行耗时。采用周期内聚合统计，而非记录每条任务原始数据。

## 5. 核心配置

详见 [references/thread-pools-config.yaml](./references/thread-pools-config.yaml)。

```yaml
thread-pools:
  global:
    # 仅受管业务 worker 预算；JVM 非受管线程需在容量规划中另行预留
    managed-worker-budget: 64
    # 进程可承受线程数，包含受管和非受管线程；用于解释 high-water-mark
    process-thread-capacity: 192
    high-water-mark: 0.8
    metrics-sample-interval-seconds: 30
    metrics-retain-count-per-pool: 2000 # 仅作为短时 cursor 补拉缓冲

  defaults:
    queue-size: 100
    keep-alive-seconds: 60
  pools:
    order-create-h:
      min: 1
      max: 32
      weight: 10
      priority: HIGH
      reliability: FAIL_FAST
      queue-size: 200

    inventory-sync-m:
      min: 1
      max: 16
      weight: 5
      priority: MEDIUM
      reliability: PERSIST_FOR_RETRY
      queue-size: 50

    message-push-l:
      min: 1
      max: 8
      weight: 2
      priority: LOW
      reliability: BEST_EFFORT_DROP
      business-owner: message
      queue-size: 20
```

## 6. 部署步骤

### 6.1 集成子控

1. 将子控模块引入单体应用。
2. 在 `application.yml` 中配置线程池参数。
3. 业务代码统一通过 `ThreadPoolGovernor` 获取线程池，禁止直接 `new ThreadPoolExecutor`。
4. 启动时子控自动创建线程池并校验配额。

### 6.2 部署总控

1. 部署总控平台（独立服务、脚本或复用现有日志/监控系统均可）。
2. 在总控中配置所有应用实例的 IP 和端口。
3. 总控定时调用子控接口增量拉取指标。
4. 配置看板和告警规则。

### 6.3 迁移现有线程池

1. 新线程池必须通过子控创建。
2. 逐个将现有线程池改造为子控管理。
3. 全部迁移完成后，代码规范中禁止直接创建线程池。

## 7. 验证方式

### 7.1 启动校验

- 配置错误时应用启动失败，日志提示具体原因。
- 校验项包括：命名规范、`min ≤ max`、`weight > 0`、
  `sum(min) ≤ managed-worker-budget`、队列容量有界、`priority` 和
  `reliability` 均已声明，以及 `BEST_EFFORT_DROP` 已注明业务所有者。

### 7.2 功能验证

- 新线程池注册时，子控正确计算实际 max。
- 新池加入后，现有弹性池的实际 max 按权重重新分配。
- 并发提交下，任何时刻实际运行的受管 worker 都不会超过
  `managed-worker-budget`，异常任务也会释放许可。
- JVM 高水位时，LOW 和 MEDIUM 池按定义收紧，HIGH 池仍只享有其已配置的保底能力。
- 三种 `reliability` 分类的拒绝、重试/死信和允许丢弃行为均可验证。
- 包装后的异步任务保持 MDC / traceId，且指标和拒绝原因归属正确。
- 优雅关闭时，停止接收新任务，等待正在执行的任务到达明确超时；超时后的可恢复任务被持久化。

### 7.3 总控验证

- 总控使用 cursor 分页拉取各实例增量指标；同一采样时刻、分页中断和总控重启均不丢失或跳过指标。
- 集群总线程数、队列堆积、拒绝次数聚合正确。
- cursor 持久化后，总控重启能从断点续拉。

## 8. 风险与边界

| 场景 | 说明 |
|---|---|
| `sum(min) > managed-worker-budget` | 启动失败，提示配置不合理，需减少保底线程或提高受管 worker 预算。 |
| 全为固定大小池 | 若所有池 `min == max` 且总和达到上限，新池只能被拒绝。 |
| 总控挂掉 | 子控自治不受影响；恢复后从持久化 cursor 分页补拉。若 cursor 过期，记录缺口并以当前快照恢复观测。 |
| 实例扩缩容 | 总控 IP 列表需人工更新。 |
| 队列容量不可热改 | 如需变更队列容量，只能创建新池并迁移任务。 |
| 核心与 max 绑定 | 若某池 `min` 接近 `max`，可分配空间小，弹性差。 |

## 9. 排障方式

### 9.1 队列堆积

- 观察 `queueSize / queueCapacity`。
- 若 `waitTimeMs` 同步升高，说明线程不足，考虑提高权重或扩容实例。
- 若 `execTimeMs` 升高，说明任务执行慢，排查下游依赖。

### 9.2 拒绝数增加

- 查看 `rejected` 指标。
- 确认是否因 `actualMax` 被压缩导致。
- 检查是否因 JVM 总线程达到高水位触发保护。

### 9.3 某实例线程数异常

- 通过总控对比各实例同名线程池的 `active` 和 `poolSize`。
- 定位负载不均的实例，检查该实例业务流量是否异常。

## 10. 后续演进

| 阶段 | 内容 |
|---|---|
| 第一阶段 | 子控落地，统一创建和管理线程池。 |
| 第二阶段 | 总控接入，实现集群视角监控和告警。 |
| 第三阶段 | 根据线上数据优化权重和各池参数。 |
| 第四阶段（可选） | 引入轻量配置刷新机制，支持不停机调整参数。 |

## 11. 参考资料

- [JDK ThreadPoolExecutor 文档](https://docs.oracle.com/en/java/javase/17/docs/api/java.base/java/util/concurrent/ThreadPoolExecutor.html)
- [references/thread-pools-config.yaml](./references/thread-pools-config.yaml)
- [references/metrics-api-response.json](./references/metrics-api-response.json)
- [references/naming-rules.md](./references/naming-rules.md)
- [references/migration-guide.md](./references/migration-guide.md)
- [references/governance-platform-design.md](./references/governance-platform-design.md)
