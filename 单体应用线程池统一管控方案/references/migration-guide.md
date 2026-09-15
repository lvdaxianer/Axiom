# 线程池迁移指南

## 迁移原则

1. 新线程池必须通过子控创建。
2. 旧线程池逐个改造，不一次性全改。
3. 全部迁移完成后，代码规范中禁止直接创建线程池。

## 迁移步骤

### 第一步：接入子控

在项目中引入 `ThreadPoolGovernor` 模块，配置 `application.yml`：

```yaml
thread-pools:
  global:
    managed-worker-budget: 64
  pools:
    order-create-h:
      min: 1
      max: 16
      weight: 10
      priority: HIGH
      reliability: FAIL_FAST
      queue-size: 200
```

### 第二步：改造单个线程池

以订单模块为例，替换旧代码：

```java
// 改造前
private final ThreadPoolExecutor orderPool = new ThreadPoolExecutor(
    4, 16, 60, TimeUnit.SECONDS,
    new LinkedBlockingQueue<>(200)
);

// 改造后
private final Executor orderPool;

public OrderService(ThreadPoolGovernor governor) {
    this.orderPool = governor.executor("order-create-h");
}
```

### 第三步：验证指标

启动应用后，检查日志：

```text
thread_pool_stats name=order-create-h active=0 poolSize=1 queue=0/200 rejected=0
```

确认线程池已按子控配置创建。

### 第四步：批量迁移

按业务域逐个迁移，建议顺序：

1. 非核心、低优先级模块（如报表、消息推送）
2. 中等优先级模块（如库存同步）
3. 核心高优先级模块（如订单创建、支付回调）

### 第五步：禁止直接创建

在代码审查中增加规则：

- 禁止 `new ThreadPoolExecutor(...)`
- 禁止 `Executors.newFixedThreadPool(...)` 等工厂方法
- 禁止未显式指定执行器的 `CompletableFuture.*Async(...)`
- 审查 Spring `@Async`、`@Scheduled`、消息消费者和三方 SDK 的执行器来源
- 所有受管执行器必须通过 `ThreadPoolGovernor.register` 或
  `ThreadPoolGovernor.executor` 获取；业务代码不得持有原始 `ThreadPoolExecutor`

## 回滚策略

迁移过程中若出现问题：

1. 迁移前盘点所有执行器来源、任务的幂等键、可靠性分类、调用入口和业务所有者。
2. 为每个业务域建立独立开关，使该域可在旧执行器与受控执行器之间切换；开关变更必须审计。
3. 先在预发验证，再灰度到少量生产实例。重点验证全局许可、拒绝语义、MDC/traceId、指标 cursor 和优雅关闭。
4. 回退时停止向新执行器接收任务，等待或持久化其在途任务；切回旧执行器后核对重试/死信记录，防止重复执行。
5. 不保留被注释的旧线程池代码。回退依据是受版本控制的开关、配置和发布制品。
