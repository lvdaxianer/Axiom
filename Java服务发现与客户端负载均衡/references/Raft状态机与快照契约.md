# AffinityRoute Raft 状态机与快照契约

本文档是 `affinityroute-registry-ratis` 的编码级契约，固定可复制状态、命令、原子边界、Ratis 适配、快照、恢复和故障测试。实现不得在 Controller 或 Leader 本地内存中另建一份持久权威状态。

## 1. 核心不变量

1. 只有已经 Raft 多数派提交并在 Leader 本地 apply 完成的命令可返回成功。
2. 同一日志序列在所有节点生成相同资源、版本、事件和 CommandResult。
3. 状态机 apply 不读取系统时钟、随机数、网络、DNS、环境变量或节点本地配置。
4. 状态机不执行 HTTP、健康探测、文件备份上传、日志轮转或审计导出等外部副作用。
5. `resourceVersion` 按资源独立从 1 递增；`directoryRevision` 按 ServiceKey 独立从 1 递增；`appliedIndex` 使用 Raft 全局日志 index。
6. 命令、命令结果、目录变更事件和审计事件在同一 apply 临界区原子可见。
7. 任何不可识别的 command schemaVersion 都必须使节点拒绝加入集群，不能跳过日志。

## 2. 代码目录和职责

```text
registry-ratis/src/main/java/cc/lvdaxianerplus/affinityroute/registry/ratis/
├── catalog/
│   ├── CatalogState.java
│   ├── CatalogStateMachine.java
│   ├── CommandApplier.java
│   ├── AuthorizationGuard.java
│   ├── ResourceVersionGuard.java
│   ├── CommandDeduplicator.java
│   ├── CatalogEventStore.java
│   └── model/
├── command/
│   ├── CommandEnvelope.java
│   ├── RegistryCommand.java
│   ├── RegistrationCommands.java
│   ├── InstanceCommands.java
│   ├── SecurityCommands.java
│   └── MaintenanceCommands.java
├── consensus/
│   ├── ConsensusStore.java
│   ├── RatisConsensusStore.java
│   ├── LeaderLocator.java
│   └── ReadBarrier.java
├── codec/
│   ├── CommandCodec.java
│   ├── CanonicalCommandHasher.java
│   └── StateSnapshotCodec.java
└── snapshot/
    ├── SnapshotManifest.java
    ├── SnapshotWriter.java
    ├── SnapshotLoader.java
    └── SnapshotMigrator.java
```

`registry-server` 只能通过 `ConsensusStore` 读写持久状态，不得依赖 Ratis 具体类。

## 3. 可复制状态

```java
final class CatalogState {
    private final NavigableMap<ServiceKey, ServiceRecord> services;
    private final NavigableMap<InstanceKey, InstanceRecord> instances;
    private final NavigableMap<String, IdentityRecord> identities;
    private final NavigableMap<GrantKey, PermissionGrant> grants;
    private final NavigableMap<String, ApprovalRecord> approvals;
    private final NavigableMap<String, CommandResultRecord> commandResults;
    private final NavigableMap<ServiceKey, Long> directoryRevisions;
    private final NavigableMap<ServiceKey, EventWindow> catalogEvents;
    private final NavigableMap<Long, AuditEventRecord> auditEvents;
    private ExpirationWatermark expirationWatermark;
}
```

### 3.1 目录资源

```java
record ServiceKey(String namespace, String group, String serviceName)
        implements Comparable<ServiceKey> {}

record ServiceRecord(
        ServiceKey key,
        long resourceVersion,
        long createdAtEpochMillis,
        long updatedAtEpochMillis
) {}

record InstanceKey(ServiceKey service, String instanceId)
        implements Comparable<InstanceKey> {}

record InstanceRecord(
        InstanceKey key,
        URI baseUri,
        int weight,
        String cluster,
        SortedMap<String, String> metadata,
        String healthPath,
        HealthStatus healthStatus,
        InstanceLifecycle lifecycle,
        boolean enabled,
        String registrationId,
        SessionVerifier sessionVerifier,
        long resourceVersion,
        long createdAtEpochMillis,
        long updatedAtEpochMillis
) {}

record SessionVerifier(
        String algorithm,
        String keyId,
        byte[] digest
) {}
```

`ServiceRecord` 在首个实例创建时隐式创建，实例全部删除后仍保留空 ServiceRecord，首版不自动删除服务。`sessionVerifier` 仅对 EPHEMERAL 实例存在，固定为 `HMAC-SHA-256`的 `keyId + 32-byte digest`；快照与日志中不得存储 session token 原文。三节点必须部署相同 keyring，轮换期同时保留当前和上一 `keyId`；续约比较使用 constant-time API。所有内部 byte array record 必须防御性复制并覆盖数组的 `equals/hashCode`。

### 3.2 安全与审批资源

```java
record IdentityRecord(
        String identityId,
        String clientId,
        CredentialVerifier credentialVerifier,
        boolean enabled,
        long scopeVersion,
        long resourceVersion
) {}

record PermissionGrant(
        GrantKey key,
        Set<Action> actions,
        ServicePattern servicePattern,
        long resourceVersion
) {}

record ApprovalRecord(
        String approvalId,
        ApprovalAction action,
        byte[] canonicalPayload,
        ApprovalStatus status,
        String requesterId,
        Optional<String> approverId,
        long expiresAtEpochMillis,
        long resourceVersion
) {}
```

凭证只存 Argon2id 或等效强哈希参数与结果。身份 secret 创建或轮换时的明文只能由 `console-api` 在命令提交前生成并显示一次，不进入状态机。

### 3.3 命令结果和事件

```java
record CommandResultRecord(
        String commandId,
        byte[] requestDigest,
        CommandStatus status,
        byte[] canonicalResult,
        long appliedTerm,
        long appliedIndex,
        long retainedUntilEpochMillis
) {}

record CatalogEventRecord(
        ServiceKey service,
        long revision,
        CatalogEventType type,
        String resourceId,
        Optional<InstanceRecord> instance,
        long appliedIndex
) {}

record AuditEventRecord(
        long auditSequence,
        String commandId,
        String principalId,
        Action action,
        String resourceKey,
        CommandStatus status,
        long submittedAtEpochMillis,
        long appliedTerm,
        long appliedIndex
) {}
```

`canonicalResult` 是版本化内部 Result DTO 的规范 JSON，不是 HTTP Response，不包含 access token、session token 或 secret。API 层由该 Result 稳定重建原 HTTP 状态和 Body。

## 4. 命令封装和编码

```java
record CommandEnvelope(
        int schemaVersion,
        String clusterId,
        String commandId,
        String principalId,
        Action requiredAction,
        ServicePattern authorizationScope,
        byte[] requestDigest,
        long submittedAtEpochMillis,
        RegistryCommand command
) {}

sealed interface RegistryCommand permits
        RegisterEphemeralInstance,
        DeregisterEphemeralInstance,
        CreateStaticInstance,
        PatchInstance,
        ChangeInstanceHealth,
        UpsertIdentity,
        RotateIdentityCredential,
        UpsertPermissionGrant,
        CreateApproval,
        DecideApproval,
        ExpireCommandResults {}
```

1. Command 使用显式 `type` 和 `schemaVersion` 的 JSON 编码，不使用 Java 默认序列化。
2. JSON 规范化遵循 RFC 8785；Map key 排序，整数不使用指数形式，禁止 NaN/Infinity。
3. `requestDigest` 由 API 层对 RFC 8785 规范请求描述符计算；描述符包含 method、canonical path/query、principalId、规范 Body、`If-Match` 和 session verifier 等全部语义输入，不包含 token 原文。状态机从 envelope 和 command 重建同一描述符并对比，禁止无边界字符串拼接。
4. `submittedAtEpochMillis` 是审计展示值，不参与命令排序、版本号和租约计算。
5. 命令大小默认上限 1 MiB，批量命令最多 500 个子操作且总字节数仍受 1 MiB 限制。
6. `schemaVersion` 只增不减。滚动升级期间新版本进程在确认集群全部节点支持前，只能写入旧 `schemaVersion` 的命令；节点读到不支持的 `schemaVersion` 必须失败并拒绝启动，不得跳过或降级解析。

## 5. 确定性 apply 顺序

```java
CommandResultRecord apply(
        CommandEnvelope envelope,
        long term,
        long index
) {
    validateEnvelope(envelope);
    Optional<CommandResultRecord> existing = findCommandResult(envelope.commandId());
    if (existing.isPresent()) {
        return requireSameDigest(existing.get(), envelope.requestDigest());
    }
    ValidationDecision decision = authorizeAndValidate(envelope);
    Mutation mutation = decision.accepted()
            ? prepareAcceptedMutation(envelope, term, index)
            : prepareRejectedMutation(envelope, decision, term, index);
    mutation.applyAtomically(state);
    return mutation.commandResult();
}
```

实际实现不得直接修改多个 Map 后再发现后续校验失败。`prepareAcceptedMutation` 必须完成全部版本和事件计算，返回不可变 mutation；`applyAtomically` 在单线程状态机中一次更新。

权限、If-Match、资源不存在等预期业务失败也是已提交命令的确定性结果。`prepareRejectedMutation` 只写入 CommandResult 和失败审计事件，不修改业务资源、resourceVersion 或 directoryRevision。只有 command schema 无法解析、clusterId 不一致、digest 不可重算和状态不变量破坏才作为节点级致命错误。

幂等查询先于当前权限检查：原命令成功后即使 principal 被撤权，使用同 digest 的重放仍返回原结果，但不产生新副作用。不同 digest 始终返回 `COMMAND_ID_CONFLICT`。

## 6. 命令效果表

| 命令 | 前置条件 | 资源版本 | 目录 revision | 事件 |
| --- | --- | --- | --- | --- |
| `RegisterEphemeralInstance` | instanceId 未被其他 session 占用 | 实例从 1 开始 | +1 | `INSTANCE_REGISTERED` |
| `DeregisterEphemeralInstance` | 实例存在且 session hash 匹配 | 删除前不额外递增 | +1 | `INSTANCE_DEREGISTERED` |
| `CreateStaticInstance` | instanceId 未存在 | 实例从 1 开始 | +1 | `INSTANCE_REGISTERED` |
| `PatchInstance` | If-Match 匹配 | 实例 +1 | +1 | `INSTANCE_UPDATED` 或 `INSTANCE_HEALTH_CHANGED` |
| `ChangeInstanceHealth` | 合法状态迁移 | 实例 +1 | +1 | `INSTANCE_HEALTH_CHANGED` |
| `UpsertIdentity` | clientId 唯一，If-Match 匹配或新建 | 身份从 1/+1 | 不变 | 无目录事件 |
| `UpsertPermissionGrant` | 身份存在，If-Match 匹配 | grant 从 1/+1，identity.scopeVersion +1 | 不变 | 无目录事件 |
| `CreateApproval` | payload 可规范化 | approval 从 1 | 不变 | 无目录事件 |
| `DecideApproval` | PENDING、未过期、不能自批 | approval +1；通过时业务变更同命令原子应用 | 按 payload | 按 payload |
| `ExpireCommandResults` | cutoff 单调且满足最小 index 保留距离 | 不变 | 不变 | 无 |

批准操作不得先把 Approval 设为 APPROVED 后再另发业务命令。`DecideApproval` 必须携带原规范 payload，在一次 apply 内完成审批状态和目标资源变更。

## 7. 版本、ID 和过期生成

### 7.1 版本

- 新资源 `resourceVersion=1`，合法更新使用 `Math.addExact(current, 1)`。溢出属于不可恢复内部错误，节点必须停止 apply 并报警。
- 新 ServiceKey 的第一个可见变更产生 `directoryRevision=1`。一条命令只对每个受影响 ServiceKey 递增一次，即使同时改变多个实例。
- `minimumReadIndex` 就是命令的 applied Raft index，不单独生成计数器。

### 7.2 ID

`registrationId`、`approvalId` 和 `auditSequence` 由状态机使用 `clusterId + term + index + commandType + ordinal` 的 SHA-256 前 128 bit 确定性派生，文本使用 Crockford Base32 和类型前缀。该 ID 不承诺按时间排序，列表顺序使用 appliedIndex。

session token、client secret 和令牌私钥不使用确定性 ID 方法；它们在状态机外使用 CSPRNG 生成。session token 只把 HMAC verifier 放入 command，client secret 只把 Argon2id verifier 放入 command，令牌私钥不进入状态机。

### 7.3 去重过期

`ExpireCommandResults` 包含 `expireBeforeEpochMillis` 和 `retainAfterIndex`。状态机先将时间截止值与已保存 watermark 取 max，再仅删除同时满足以下条件的结果：

```text
retainedUntilEpochMillis < effectiveCutoff
AND appliedIndex < retainAfterIndex
```

Leader 默认每 60 秒提交一次过期命令；最小保证期 24 小时，最少保留最近 100,000 个 applied index 范围的结果。两个条件必须同时满足，避免时钟跳变提前清理。

## 8. Catalog 事件窗口

1. 每个 ServiceKey 维护按 revision 排序的环形事件窗口，默认最多 10,000 条。
2. 事件在状态机 apply 时产生并进入可复制状态，SSE 线程只读事件，不自行生成 revision。
3. 超出保留数量时删除最旧事件，但不改变当前 directoryRevision。
4. 快照必须包含当前事件窗口，Leader 切换后 SDK 可继续用 Last-Event-ID 重连。
5. 请求 revision 小于 `oldestRevision - 1` 时返回 `CATALOG_REVISION_GAP`。

## 9. ConsensusStore 和 Ratis 映射

```java
interface ConsensusStore extends AutoCloseable {
    CompletionStage<CommandResult> submit(CommandEnvelope command);
    <T> CompletionStage<ConsistentRead<T>> read(
            ReadConsistency consistency,
            OptionalLong minimumReadIndex,
            Function<CatalogView, T> reader
    );
    ConsensusStatus status();
    Optional<URI> leaderEndpoint();
    @Override void close();
}
```

| ConsensusStore 行为 | Ratis 映射 |
| --- | --- |
| `submit` | Leader `RaftClientRequest.writeRequest` 或等价 API |
| 命令成功 | transaction committed 且 StateMachine future 完成 |
| `LINEARIZABLE` read | Leader ReadIndex/线性读屏障，等待 local appliedIndex 达到 read index |
| `STALE` read | 直接读节点本地不可变 CatalogView |
| Leader 提示 | Ratis leaderId 通过受信任 nodeId 映射到配置 endpoint |
| 快照触发 | applied entries 达阈值或管理员调用本地维护操作 |

`reader` 只能在状态机公布的不可变 `CatalogView` 上执行，不得持有 apply 锁执行序列化、网络写入或长时间计算。

### 9.1 集群初始化

- 首版只支持配置文件固定的 1 节点开发集群或 3 节点生产集群。
- `cluster-id`、`raft-group-id` 和 peers 必须在三节点完全一致。
- 数据目录已存在 cluster metadata 时，配置不一致必须拒绝启动。
- 首版不提供在线 membership API。替换节点按发行手册逐节点执行，不允许一次替换多数派。

## 10. 快照格式

### 10.1 文件布局

```text
snapshot-<term>-<index>/
├── manifest.json
└── state.json
```

`state.json` 是 UTF-8 RFC 8785 规范 JSON，包含第 3 节的全部可复制状态。数组按稳定主键排序；byte[] 使用 base64url 无 padding。

```json
{
  "snapshotSchemaVersion": 1,
  "clusterId": "affinityroute-prod-a",
  "raftGroupId": "6f9169b0-98c6-4f6e-a326-4741bcec7f18",
  "lastIncludedTerm": 42,
  "lastIncludedIndex": 2987,
  "stateFile": "state.json",
  "stateLength": 582304,
  "stateSha256": "6d0f...64-hex-characters",
  "createdAt": "2026-07-24T10:30:00Z"
}
```

`createdAt` 由快照写入器在状态机 apply 之外生成，不参与 state checksum 或恢复结果。

### 10.2 写入顺序

1. 捕获指定 appliedIndex 的不可变 CatalogState view。
2. 在数据目录内创建 `snapshot-<term>-<index>.tmp-<random>`。
3. 写入 `state.json`，计算 SHA-256，对文件执行 `FileChannel.force(true)`。
4. 写入 `manifest.json`并 force。
5. fsync 临时目录，再在同文件系统原子 rename 为最终目录。
6. fsync 父目录，最后通知 Ratis 快照可用。

写入失败仅删除当次临时目录，不删除上一有效快照。

### 10.3 加载和迁移

1. 先校验目录名、manifest schema、clusterId、groupId、文件长度和 SHA-256，再解析 state。
2. 只允许 `currentSchema` 和 `currentSchema - 1` 直接加载；更旧版本必须经过离线逐版迁移工具。
3. 迁移是纯函数 `oldState -> newState`，不读时钟和网络；迁移后重新写入新快照，不覆盖原文件。
4. 损坏快照移动到 `quarantine/`并记录脱敏原因，节点尝试上一快照和后续日志；无法恢复时拒绝启动。

## 11. Leader 软状态和租约恢复

```java
record LeaseKey(ServiceKey service, String instanceId) {}
record LeaseRecord(
        byte[] sessionHash,
        long highestSequence,
        long expiresAtNanos,
        long leaderEpoch
) {}
```

LeaseTable 只存在当前 Leader 内存，`expiresAtNanos` 基于该 Leader 的单调时钟。Leader 获得领导权时：

1. 从 CatalogState 枚举 EPHEMERAL 实例，创建状态为 WAITING_FOR_RENEWAL 的租约占位。
2. 所有占位的到期点设为 `nowNanos + leaderGracePeriod`，不沿用旧 Leader 墙上时间。
3. Provider 携带正确 session token 续约后建立新 LeaseRecord，`leaderEpoch` 使用当前 Raft term。
4. 宽限期结束未续约的实例由 Leader 提交 `ChangeInstanceHealth(SUSPECT)`，可见变更仍经 Raft。

主动探测与租约调度使用独立有界执行器。它们不在状态机 apply 线程中执行。

## 12. 备份、恢复和防分裂

1. 备份只能复制已完成快照目录和必要的后续 Ratis 日志，不直接复制正在写入的数据文件。
2. 备份 manifest 记录 sourceClusterId、groupId、lastIncludedIndex、发行版本、schemaVersion 和全部 checksum。
3. 恢复必须在隔离网络中完成；新集群预检通过后生成新的 deploymentId，换发节点证书、token signing key 和客户端入口。
4. 旧集群必须保持停机或网络隔离，不允许两个从同一备份恢复的集群同时对外写入。
5. 恢复验收必须比对状态 checksum、每个 ServiceKey revision、commandId 去重结果和身份 scopeVersion。

## 13. 错误分类

| 内部错误 | 对外映射 | 处理 |
| --- | --- | --- |
| `NotLeaderException` | 307 或 503 `NOT_LEADER` | 提供受信任 Leader 提示 |
| `NoMajorityException` | 503 `CLUSTER_NOT_WRITABLE` | 不尝试本地强写 |
| `CommandDigestConflictException` | 409 `COMMAND_ID_CONFLICT` | 保留原结果 |
| `ResourceVersionConflictException` | 412 `RESOURCE_VERSION_CONFLICT` | 回传当前版本 |
| `AuthorizationRejectedException` | 403 `PERMISSION_DENIED` | 写入失败审计结果 |
| `UnsupportedStateSchemaException` | 节点拒绝启动 | 不允许跳过日志 |
| `CorruptSnapshotException` | 节点不健康 | 隔离快照并从其他节点恢复 |
| `StateMachineInvariantViolation` | 节点立即退出 apply | ERROR 报警，不继续提供读写 |

## 14. 必须先写的测试

### 14.1 状态机单元测试

| 测试 | 断言 |
| --- | --- |
| `DeterministicReplayTest` | 同一命令字节序列在两个空状态机产生相同 state checksum |
| `CommandDeduplicationTest` | 同 commandId+digest 返回同 Result，不增加 revision/事件 |
| `CommandDigestConflictTest` | 同 commandId+不同 digest 不修改状态 |
| `ConcurrentIfMatchTest` | 相同版本的两个命令按日志顺序一成一败 |
| `PerServiceRevisionTest` | 服务 A 变更不改变服务 B revision |
| `ApprovalAtomicityTest` | 批准状态与目标变更同时可见或同时失败 |
| `ExpirationWatermarkTest` | 时钟回退/跳进不突破最小 index 保留距离 |
| `EventWindowTest` | 事件连续、截断边界和缺口判定正确 |

### 14.2 快照测试

- 状态写入、加载、再写入的 checksum 一致。
- 损坏 state、manifest、checksum、clusterId 和 groupId 均被拒绝。
- 写入中断不影响上一有效快照。
- schema N-1 迁移到 N 后保持资源、revision、去重结果和事件。

### 14.3 三节点集成测试

- 成功响应的命令在 Leader 和任意 Follower 终止后仍可线性读取。
- 少数派不返回写成功，网络恢复后无分叉状态。
- Leader 切换后 commandId 重放、SSE 事件窗口和 minimumReadIndex 仍有效。
- 安装快照后 revision 不回退，并可继续应用后续日志。
- 新 Leader 宽限期内不将未重建租约的实例误判为 DOWN。

## 15. 与实施任务的映射

- T03 实现第 3–8 节的状态、命令、版本、去重和事件窗口。
- T04 实现第 9–10 节的 Ratis 适配、ReadIndex、快照和恢复。
- T05 实现第 11 节的 Leader 租约和健康命令。
- T10 实现身份、权限、审批和审计的命令封装。
- T12 执行第 12 和 14.3 节的备份、恢复、防分裂和故障测试。
