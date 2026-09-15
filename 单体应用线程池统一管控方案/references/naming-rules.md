# 线程池命名规则

## 格式

```text
{业务域}-{用途}-{优先级标识}
```

## 分段说明

| 分段 | 含义 | 示例 |
|---|---|---|
| `业务域` | 业务模块或系统域 | `order`、`inventory`、`payment`、`message`、`report` |
| `用途` | 任务类型或操作 | `create`、`sync`、`push`、`export`、`callback`、`handle`、`batch` |
| `优先级标识` | 单字母，表示业务重要性 | `h` High、`m` Medium、`l` Low |

## 规范

1. 全小写，使用 `-` 连接。
2. 禁止使用无意义命名，如 `pool1`、`executor2`、`myPool`、`thread-pool-a`。
3. 一个 JVM 内线程池名称必须唯一。
4. 名称长度控制在 50 字符以内。
5. 业务域和用途使用英文单词，避免拼音或缩写。

## 示例

| 场景 | 命名 |
|---|---|
| 订单创建异步处理 | `order-create-h` |
| 库存同步 | `inventory-sync-m` |
| 消息推送 | `message-push-l` |
| 报表导出 | `report-export-l` |
| 支付回调 | `payment-callback-h` |
| 日志批量写入 | `log-batch-l` |
| 用户数据同步 | `user-sync-m` |

## 线程名

线程池创建的线程也应带有业务含义，便于日志排查：

```text
order-create-h-pool-1
order-create-h-pool-2
inventory-sync-m-pool-1
```

避免使用 JDK 默认命名 `pool-1-thread-1`。
