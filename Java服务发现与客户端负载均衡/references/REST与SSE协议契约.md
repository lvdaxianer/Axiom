# AffinityRoute REST 与 SSE 协议契约

本文档固定 Registry Server 与 Java SDK 之间的 HTTP 语义。字段结构的机器可读权威来源是 [OpenAPI 3.1 契约](./openapi.yaml)；本文档负责 OpenAPI 无法完整表达的幂等、一致性、SSE 时序、安全和恢复规则。

## 1. 协议基线

| 项目 | 契约 |
| --- | --- |
| 协议 | HTTPS，HTTP/1.1 和 HTTP/2 |
| REST 格式 | `application/json; charset=utf-8` |
| SSE 格式 | `text/event-stream; charset=utf-8` |
| API 主版本 | `/api/v1` |
| 时间 | RFC 3339 UTC，例如 `2026-07-24T10:30:15Z` |
| ID | ULID 字符串，或按端点指定的高熵 token |
| 整数版本 | JSON number，范围 `0..9_007_199_254_740_991` |
| 字段命名 | JSON 使用 lowerCamelCase，Header 使用 HTTP-Title-Case |
| 压缩 | REST 允许 gzip；SSE 默认禁止代理缓冲和压缩 |

所有客户端请求必须设置 `User-Agent: affinityroute-java/<version>`。Server 必须返回 `X-AffinityRoute-Node-Id`和 `X-AffinityRoute-Schema-Version`，SDK 将未支持的主 schema 版本视为不可重试协议错误。

## 2. 通用 Header 和请求分类

### 2.1 Header

| Header | 适用范围 | 规则 |
| --- | --- | --- |
| `Authorization` | 除 token 端点外 | `Bearer <access-token>` |
| `X-Request-Id` | 全部请求 | ULID；缺失时 Server 生成，响应必须回显 |
| `X-Command-Id` | 持久状态写 | ULID；作为 Raft 命令幂等键 |
| `If-Match` | 修改已存在资源 | 双引号包围的十进制 resourceVersion，例如 `"7"` |
| `X-Registration-Session` | 注册、续约、注销 | Provider SDK 生成的 256 bit base64url 无 padding token |
| `Last-Event-ID` | SSE 重连 | 该 ServiceKey 最后已应用的 directoryRevision |

### 2.2 持久命令与软状态写

以下操作必须携带 `X-Command-Id`并进入 Raft：

- 注册、注销实例。
- 创建或修改静态实例。
- 修改权重或全局健康状态。
- 身份、权限、审批和安全配置变更。

以下操作是 Leader 内存软状态，不使用 `X-Command-Id`，使用 session/sequence 去重：

- Provider 租约续期。
- SDK Client 在线心跳。

软状态端点若收到 `X-Command-Id` 可忽略该 Header，但不得伪装为 Raft 幂等保证。

## 3. 幂等与并发契约

1. Server 先生成 RFC 8785 规范 JSON 请求描述符，再计算 `requestDigest = SHA-256(UTF8(canonicalCommandRequest))`。描述符必须包含 method、canonical path、规范 query、principalId、规范 Body，以及影响命令语义的 `If-Match` 和 session verifier（不是 token 原文）。Authorization、Request ID、网络地址和原始 session token 不进入摘要。不得使用无长度边界的字符串拼接。
2. 去重窗口内，相同 commandId 和相同 digest 返回原 HTTP 状态、业务 Body、resourceVersion、directoryRevision 和 minimumReadIndex。
3. 相同 commandId 但 digest 不同返回 HTTP 409 `COMMAND_ID_CONFLICT`，不执行新命令。
4. `If-Match` 缺失返回 HTTP 428 `PRECONDITION_REQUIRED`；版本不匹配返回 HTTP 412 `RESOURCE_VERSION_CONFLICT`。
5. Server 在确认命令是否提交前断开连接时，SDK 只能用原 commandId 和完全相同请求重试。
6. 幂等保证期通过 `X-AffinityRoute-Deduplication-Window-Seconds` 响应 Header 公开。

## 4. 认证和令牌

### 4.1 POST /api/v1/auth/tokens

请求：

```json
{
  "clientId": "yunkan",
  "clientSecret": "<client-secret>"
}
```

成功返回 HTTP 200：

```json
{
  "tokenType": "Bearer",
  "accessToken": "<access-token>",
  "expiresInSeconds": 900
}
```

JWT 固定使用 ES256，必须包含 `iss`、`sub`、`aud=affinityroute-registry`、`iat`、`exp`、`jti`、`clientId` 和 `scopeVersion`。Server 只接受当前或下一个 `kid`，令牌 TTL 默认 15 分钟，不提供 refresh token。密钥轮换期必须大于最大 token TTL 与时钟偏差之和。

失败响应不得区分 clientId 不存在与 secret 错误，统一返回 HTTP 401 `INVALID_CLIENT_CREDENTIALS`。

## 5. Provider 注册和租约

### 5.1 POST /api/v1/registrations

必需 Header：`Authorization`、`X-Request-Id`、`X-Command-Id`、`X-Registration-Session`。session token 由 Provider SDK 预生成，Server 使用集群 session key 计算 HMAC-SHA-256，只将 `keyId + verifier` 进入 Raft 状态，响应不回传 token。比较 verifier 必须使用 constant-time API；密钥轮换期可验证当前和上一 `keyId`，旧 key 的保留时间必须覆盖最长注册租约和 Leader 宽限期。

请求：

```json
{
  "service": {
    "namespace": "customer-a-prod",
    "group": "DEFAULT_GROUP",
    "serviceName": "topo-service"
  },
  "instanceId": "topo-node-01",
  "baseUri": "https://topo-01.example.internal:8180",
  "weight": 100,
  "cluster": "default",
  "metadata": {
    "version": "2026.07"
  },
  "healthPath": "/actuator/health/readiness"
}
```

首次提交成功返回 HTTP 201，幂等重放保留原始 201：

```json
{
  "registrationId": "reg-01J3M7V01Q8XF3M3S8AJQB6R8A",
  "instance": {
    "instanceId": "topo-node-01",
    "baseUri": "https://topo-01.example.internal:8180",
    "weight": 100,
    "cluster": "default",
    "metadata": {
      "version": "2026.07"
    },
    "healthStatus": "UP",
    "lifecycle": "EPHEMERAL",
    "resourceVersion": 1
  },
  "directoryRevision": 1024,
  "minimumReadIndex": 2987,
  "leaseExpiresAt": "2026-07-24T10:30:15Z"
}
```

`instanceId` 已存在且不属于当前 session 时返回 HTTP 409 `INSTANCE_ALREADY_REGISTERED`。断线恢复必须使用原 session token；丢失 token 时只能等待租约过期或由管理员强制清理。

### 5.2 PUT /api/v1/registrations/{instanceId}/lease

必需 Header：`Authorization`、`X-Request-Id`、`X-Registration-Session`。

```json
{
  "sequence": 42
}
```

`sequence` 必须在同一 session 内严格递增。小于等于已处理值的重复续约返回当前租约，不缩短已有到期时间；跳号允许。成功返回 HTTP 200：

```json
{
  "sequence": 42,
  "leaseExpiresAt": "2026-07-24T10:30:20Z",
  "leaderEpoch": 18
}
```

续约只更新 Leader 内存，不递增 resourceVersion 或 directoryRevision。请求到达 Follower 时返回 HTTP 307 和受信任的集群 Leader `Location`，SDK 只允许跟随预配置 Registry 端点集合内的重定向。

### 5.3 DELETE /api/v1/registrations/{instanceId}

必需 Header：`Authorization`、`X-Request-Id`、`X-Command-Id`、`X-Registration-Session`。成功返回 HTTP 200 和提交元数据：

```json
{
  "resourceId": "topo-node-01",
  "directoryRevision": 1025,
  "minimumReadIndex": 2991
}
```

相同 commandId 重放保留原结果。另一 commandId 再次删除已不存在实例返回 HTTP 404 `INSTANCE_NOT_FOUND`。

## 6. Consumer 目录和心跳

### 6.1 GET /api/v1/catalog/.../snapshot

查询参数：

| 参数 | 默认 | 语义 |
| --- | --- | --- |
| `consistency` | `LINEARIZABLE` | `LINEARIZABLE` 或 `STALE` |
| `minimumReadIndex` | 无 | 返回前本地 appliedIndex 必须不小于该值 |

响应必须同时包含 `servedBy`、`term`、`appliedIndex`、`directoryRevision` 和实际 `consistency`。空服务返回 HTTP 200 和空 instances，不返回 404。

`LINEARIZABLE` 在 deadline 内无法完成 ReadIndex 或等待应用时返回 HTTP 503 `CONSISTENCY_UNAVAILABLE`，不降级。`STALE` 可由 Follower 返回，但 `appliedIndex` 和 revision 必须是真实本地值。

### 6.2 GET /api/v1/catalog/events

查询参数 `namespace`、`group`、`serviceName` 全部必填，一条连接只订阅一个 ServiceKey。该端点只接受 `Accept: text/event-stream`。

建连前检测到 revision 过期时返回 HTTP 409 JSON `CATALOG_REVISION_GAP`。建连后检测到缓冲溢出、缺口或节点退出时，发送 `catalog-control` 事件后关闭连接，SDK 必须拉取全量：

```text
event: catalog-control
data: {"schemaVersion":1,"type":"SNAPSHOT_REQUIRED","reason":"BUFFER_OVERFLOW"}

```

SSE 数据事件格式：

```text
id: 1025
event: catalog-change
data: {"schemaVersion":1,"revision":1025,"type":"INSTANCE_UPDATED","serviceKey":{"namespace":"customer-a-prod","group":"DEFAULT_GROUP","serviceName":"topo-service"},"resourceId":"topo-node-01","instance":{"instanceId":"topo-node-01","baseUri":"https://topo-01.example.internal:8180","weight":200,"cluster":"default","metadata":{},"healthStatus":"UP","lifecycle":"EPHEMERAL","resourceVersion":8}}

```

Server 每 15 秒发送 `:heartbeat\n\n` 注释。代理必须禁止响应缓冲。每个 subscriber 拥有有界队列，队列满时不阻塞 Raft 应用线程，而是发送控制事件或直接断开。

### 6.3 PUT /api/v1/clients/{clientInstanceId}/heartbeat

请求包含递增 sequence、SDK 版本、应用名、已知服务 revision、本地隔离数量和脱敏运行状态。该端点只更新 Leader 内存，返回 HTTP 202，Body 包含 `acceptedSequence` 和 `leaderEpoch`。

Client 心跳不上报 affinity key、业务 URL、请求 Body、token、Cookie 或业务 Header。

## 7. 管理写端点

### 7.1 POST /api/v1/admin/static-instances

创建静态实例，必须携带 `X-Command-Id`。成功返回 HTTP 201。`lifecycle` 由 Server 固定为 `STATIC`，请求不允许伪造。

### 7.2 PATCH /api/v1/admin/instances/{instanceId}

只接受 JSON Merge Patch 子集，必须携带 `X-Command-Id` 和 `If-Match`。允许字段仅为 `weight`、`enabled`、`metadata`，未知字段返回 HTTP 400 `UNKNOWN_PATCH_FIELD`。

`enabled=false` 将全局健康状态设为 `DOWN`，`enabled=true` 将状态设为 `RECOVERING`，不可直接跳到 `UP`。成功返回 HTTP 200，Body 包含更新后 instance、directoryRevision 和 minimumReadIndex。

## 8. 统一错误契约

```json
{
  "requestId": "01J3M7ST8Y0P3J2G86KX8G5R3P",
  "code": "RESOURCE_VERSION_CONFLICT",
  "message": "resource version does not match",
  "retryable": false,
  "details": {
    "currentResourceVersion": 8
  }
}
```

| HTTP | code | retryable | 语义 |
| --- | --- | --- | --- |
| 400 | `VALIDATION_FAILED` | false | 输入非法，details 仅包含字段与脱敏原因 |
| 400 | `UNKNOWN_PATCH_FIELD` | false | Patch 存在非白名单字段 |
| 401 | `INVALID_CLIENT_CREDENTIALS` | false | token 换取凭证无效 |
| 401 | `INVALID_ACCESS_TOKEN` | true | token 过期、签名或 audience 无效 |
| 403 | `PERMISSION_DENIED` | false | 当前身份无权执行动作 |
| 404 | `SERVICE_NOT_FOUND` | false | 管理语义下服务不存在 |
| 404 | `INSTANCE_NOT_FOUND` | false | 实例不存在 |
| 409 | `COMMAND_ID_CONFLICT` | false | commandId 被不同请求复用 |
| 409 | `INSTANCE_ALREADY_REGISTERED` | true | instanceId 已属于其他 session |
| 409 | `CATALOG_REVISION_GAP` | true | 增量起点已不可用 |
| 412 | `RESOURCE_VERSION_CONFLICT` | false | If-Match 与当前版本不一致 |
| 428 | `PRECONDITION_REQUIRED` | false | 要求 If-Match 但未提供 |
| 429 | `RATE_LIMITED` | true | 鉴权或管理 API 限流 |
| 503 | `NOT_LEADER` | true | 需要 Leader，details 可包含受信任 leaderEndpoint |
| 503 | `CONSISTENCY_UNAVAILABLE` | true | 线性读无法完成 |
| 503 | `CLUSTER_NOT_WRITABLE` | true | 失去 Raft 多数派 |
| 503 | `SERVER_OVERLOADED` | true | 有界队列或并发许可耗尽 |

`message` 用于运维阅读，SDK 业务分支只能依赖 `code`。details 不得包含堆栈、类名、磁盘路径、token、session token、secret 或完整请求。

## 9. 超时、重试和限流

1. REST 请求的 SDK deadline 为总预算，连接、TLS、重定向、退避和重试共享该预算。
2. SDK 只对连接失败、HTTP 307/503 的明确可重试错误以及 429 且存在合法 `Retry-After` 时重试。
3. 持久写只能使用原 commandId 重试；续约和心跳只能使用原 sequence 重试。
4. Server 对 token 端点按 clientId 和网络源限流，对管理写按 principalId 限流，不对租约使用会阻断正常续约的全局限流器。

## 10. 兼容性和协议测试

### 10.1 演进规则

- 同一 `/api/v1` 内可新增可选响应字段和新错误码，客户端必须忽略未知响应字段。
- 不可新增必填请求字段、改变字段含义、改变默认一致性或复用已发布错误码。
- SSE 未知 `type` 不得跳过后继 revision；SDK 必须停止增量并拉取全量。
- OpenAPI 变更必须运行 breaking-change diff，并在 `registry-protocol` 中运行 JSON 兼容性测试。

### 10.2 必须自动化的场景

| 测试 | 断言 |
| --- | --- |
| `RegistrationIdempotencyContractTest` | 同 commandId+同 Body 返回完全相同结果 |
| `CommandConflictContractTest` | 同 commandId+不同 Body 返回 409 |
| `ResourceVersionContractTest` | 两个同 If-Match 并发 Patch 仅一个成功 |
| `LeaseSequenceContractTest` | 重放 sequence 不缩短租约，不改变 revision |
| `LinearizableReadContractTest` | minimumReadIndex 达到前不返回旧快照 |
| `StaleReadMetadataContractTest` | STALE 响应暴露真实节点与 index |
| `SseReconnectContractTest` | 重复忽略、缺口拉全量、控制事件关闭 |
| `UnknownFieldCompatibilityTest` | 新增响应字段不破坏旧 SDK |
| `SecurityRedactionContractTest` | 所有错误不含凭证和内部路径 |

## 11. 与实施任务的映射

- T01 从 `openapi.yaml` 生成或手写 wire DTO，并用 OpenAPI 检查防止漂移。
- T05 实现注册 session、续约 sequence 和租约语义。
- T06 实现本文档的 REST、SSE、鉴权、错误和限流契约。
- T07 实现严格遵守重定向白名单、幂等和 SSE 收敛规则的 Registry Client。
- T12 在真实三节点故障测试中重用全部协议契约测试。
