# AffinityRoute Java 公共 API 契约

本文档是 `affinityroute-sdk-api` 和 `affinityroute-spring-boot-starter` 的编码级契约。实现者可按本文档直接建立 Java 类、校验规则和契约测试，不得在实现模块里重新定义公共语义。

## 1. 版本和依赖边界

| 项目 | 契约 |
| --- | --- |
| Maven GroupId | `cc.lvdaxianerplus.affinityroute` |
| API ArtifactId | `affinityroute-sdk-api` |
| Bundle ArtifactId | `affinityroute-sdk` |
| Starter ArtifactId | `affinityroute-spring-boot-starter` |
| Java 基线 | JDK 17，`--release 17` |
| Spring Boot 基线 | 3.5.x；只有 Starter 可依赖 Spring |
| 公共包 | `cc.lvdaxianerplus.affinityroute.api` 及其子包 |
| 兼容性 | 公共类使用 Revapi 或 japicmp 执行二进制兼容门禁 |

`sdk-api` 只允许依赖 JDK。它不得引用 Spring、Jackson、Apache HttpClient、Ratis、Micrometer 或 Registry wire DTO。

## 2. 通用编码约束

1. 公共值对象使用不可变 `record`，集合在构造器中使用 `List.copyOf` 或 `Map.copyOf` 防御性复制。
2. 所有公共参数默认非 `null`；可缺省返回值使用 `Optional<T>`，可缺省请求字段由 Builder 的空方法表示。
3. 校验失败抛出 `IllegalArgumentException`，错误消息包含字段名但不包含 secret、token、affinity key 原文或请求 Body。
4. 时间使用 `Instant`，耗时使用 `Duration`，计时实现使用单调时钟。
5. Client 实现必须线程安全；Builder、`SelectionLease` 和 `RegistrationHandle` 不承诺线程安全。
6. `close()` 必须幂等。Client 关闭后再调用业务方法统一抛出 `ClientClosedException`。
7. 公共 API 不暴露可变数组、实现线程池、HTTP 引擎对象或 Registry 传输对象。

## 3. 公共目录与文件职责

```text
sdk-api/src/main/java/cc/lvdaxianerplus/affinityroute/api/
├── client/
│   ├── ProviderClient.java
│   ├── RegistrationHandle.java
│   ├── DiscoveryClient.java
│   ├── LoadBalancerClient.java
│   ├── SelectionLease.java
│   └── ServiceHttpClient.java
├── model/
│   ├── ClientScope.java
│   ├── ServiceName.java
│   ├── AffinityKey.java
│   ├── ServiceInstance.java
│   ├── ServiceSnapshot.java
│   ├── SelectedInstance.java
│   ├── InstanceLifecycle.java
│   ├── HealthStatus.java
│   └── SnapshotSource.java
├── request/
│   ├── ProviderRegistration.java
│   ├── ProviderInstanceOptions.java
│   ├── SelectionRequest.java
│   ├── ServiceRequest.java
│   ├── ServiceRequestBuilder.java
│   ├── HttpMethod.java
│   └── RequestBody.java
├── response/
│   ├── ServiceResponse.java
│   ├── DiscoveryStatus.java
│   ├── RegistrationState.java
│   ├── RegistrationFailure.java
│   ├── AttemptSummary.java
│   └── FailureType.java
├── body/
│   ├── BodyHandler.java
│   ├── BodyHandlers.java
│   ├── BodyCodec.java
│   └── ResponseBody.java
└── error/
    ├── AffinityRouteException.java
    ├── DiscoveryUnavailableException.java
    ├── NoAvailableInstanceException.java
    ├── OverloadedException.java
    ├── TimeoutBudgetExceededException.java
    ├── IndeterminateWriteException.java
    ├── RemoteServiceException.java
    ├── ResponseTooLargeException.java
    └── ClientClosedException.java
```

## 4. 值对象契约

### 4.1 ClientScope 和 ServiceName

```java
package cc.lvdaxianerplus.affinityroute.api.model;

public record ClientScope(String namespace, String group) {
    public ClientScope {
        namespace = ApiValues.requireName("namespace", namespace, 1, 63);
        group = ApiValues.requireName("group", group, 1, 63);
    }

    public static ClientScope of(String namespace, String group) {
        return new ClientScope(namespace, group);
    }
}

public record ServiceName(ClientScope scope, String value) {
    public ServiceName {
        scope = Objects.requireNonNull(scope, "scope");
        value = ApiValues.requireName("serviceName", value, 1, 128);
    }

    public static ServiceName of(ClientScope scope, String value) {
        return new ServiceName(scope, value);
    }

    public String canonicalValue() {
        return scope.namespace() + "/" + scope.group() + "/" + value;
    }
}
```

名称必须匹配 `[a-zA-Z0-9][a-zA-Z0-9._-]*`，禁止首尾空格、`/`、`..` 和控制字符。`canonicalValue()` 只用于诊断和确定性算法，网络路径中各段仍需独立 URL encode。`ApiValues` 为 package-private 校验工具，不属于公共 API。

### 4.2 AffinityKey

```java
public record AffinityKey(String value) {
    public AffinityKey {
        value = ApiValues.requireAffinityKey(value);
    }

    @Override
    public String toString() {
        return "AffinityKey[redacted]";
    }
}
```

`value` 按 Unicode NFC 归一化，UTF-8 长度为 1–256 字节，不自动 trim。空白、控制字符和超限值必须拒绝。`equals/hashCode` 使用归一化后的原值，日志、指标和 `toString()` 均不得输出原值。

### 4.3 ServiceInstance

```java
public record ServiceInstance(
        ServiceName service,
        String instanceId,
        URI baseUri,
        int weight,
        String cluster,
        Map<String, String> metadata,
        HealthStatus healthStatus,
        InstanceLifecycle lifecycle,
        long resourceVersion
) {
    public ServiceInstance {
        service = Objects.requireNonNull(service, "service");
        instanceId = ApiValues.requireName("instanceId", instanceId, 1, 128);
        baseUri = ApiValues.requireBaseUri(baseUri);
        weight = ApiValues.requireRange("weight", weight, 1, 10_000);
        cluster = ApiValues.requireName("cluster", cluster, 1, 63);
        metadata = ApiValues.copyMetadata(metadata);
        healthStatus = Objects.requireNonNull(healthStatus, "healthStatus");
        lifecycle = Objects.requireNonNull(lifecycle, "lifecycle");
        if (resourceVersion < 1) {
            throw new IllegalArgumentException("resourceVersion must be positive");
        }
    }
}
```

`baseUri` 只允许 `http` 或 `https`，必须含 host 和显式端口，禁止 user-info、query、fragment，path 必须为空或 `/`。metadata 最多 32 项，key 长 1–64，value UTF-8 长度最多 256 字节，键不得以 `affinityroute.` 开头。

```java
public enum HealthStatus { UP, SUSPECT, DOWN, RECOVERING }
public enum InstanceLifecycle { EPHEMERAL, STATIC }
public enum SnapshotSource { LIVE, MEMORY_CACHE, DISK_CACHE, STATIC }
```

### 4.4 ServiceSnapshot

```java
public record ServiceSnapshot(
        ServiceName service,
        long revision,
        Instant createdAt,
        SnapshotSource source,
        List<ServiceInstance> instances
) {
    public ServiceSnapshot {
        service = Objects.requireNonNull(service, "service");
        if (revision < 0) {
            throw new IllegalArgumentException("revision must not be negative");
        }
        createdAt = Objects.requireNonNull(createdAt, "createdAt");
        source = Objects.requireNonNull(source, "source");
        instances = List.copyOf(instances);
        if (instances.stream().anyMatch(item -> !item.service().equals(service))) {
            throw new IllegalArgumentException("instances must belong to service");
        }
    }
}
```

revision `0` 只表示已知空目录，不表示“未初始化”。未获得任何可用快照时，`DiscoveryClient.snapshot` 抛出 `DiscoveryUnavailableException`。

## 5. ProviderClient

```java
public interface ProviderClient extends AutoCloseable {
    RegistrationHandle register(ProviderRegistration registration);

    @Override
    void close();
}

public record ProviderRegistration(
        ServiceName service,
        String instanceId,
        URI baseUri,
        ProviderInstanceOptions options
) {
    public ProviderRegistration {
        service = Objects.requireNonNull(service, "service");
        instanceId = ApiValues.requireName("instanceId", instanceId, 1, 128);
        baseUri = ApiValues.requireBaseUri(baseUri);
        options = Objects.requireNonNull(options, "options");
    }
}

public record ProviderInstanceOptions(
        int weight,
        String cluster,
        Map<String, String> metadata,
        String healthPath
) {
    public ProviderInstanceOptions {
        weight = ApiValues.requireRange("weight", weight, 1, 10_000);
        cluster = ApiValues.requireName("cluster", cluster, 1, 63);
        metadata = ApiValues.copyMetadata(metadata);
        healthPath = ApiValues.requireHealthPath(healthPath);
    }

    public static ProviderInstanceOptions defaults() {
        return new ProviderInstanceOptions(
                100, "default", Map.of(), "/actuator/health/readiness");
    }
}
```

`healthPath` 必须以 `/` 开头，长度 1–200，禁止 scheme、host、query、fragment 和 `..` 路径段。

```java
public interface RegistrationHandle extends AutoCloseable {
    ServiceInstance registeredInstance();
    RegistrationState state();
    Optional<RegistrationFailure> lastFailure();

    @Override
    void close();
}

public enum RegistrationState {
    REGISTERING, REGISTERED, DEGRADED, CLOSING, CLOSED, FAILED
}

public record RegistrationFailure(
        String code,
        String message,
        boolean retryable,
        Instant occurredAt
) {}
```

1. `register()` 必须在首次 Registry 响应成功后才返回；超时、鉴权失败或终止失败直接抛异常，不返回半初始化 handle。
2. SDK 在请求前使用 CSPRNG 生成 256 bit session token，只将 token 放入请求 Header 和当前 JVM 内存，不写日志和磁盘。
3. `registeredInstance()` 在 handle 生命周期内返回最后一次 Registry 确认的不可变实例。
4. `close()` 先停止续约，再在最多 `provider.shutdown-timeout` 内尝试注销。超时后本地仍进入 `CLOSED`，Registry 依靠租约回收。
5. `lastFailure()` 只暴露脱敏分类，不暴露 token、session 或响应 Body。

## 6. DiscoveryClient

```java
public interface DiscoveryClient extends AutoCloseable {
    ServiceSnapshot snapshot(ServiceName service);
    List<ServiceInstance> instances(ServiceName service);
    DiscoveryStatus status();

    @Override
    void close();
}

public record DiscoveryStatus(
        boolean connected,
        Optional<URI> connectedEndpoint,
        Optional<Instant> lastSuccessfulSyncAt,
        Map<ServiceName, Long> revisions,
        Optional<String> lastFailureCode
) {
    public DiscoveryStatus {
        connectedEndpoint = Objects.requireNonNull(
                connectedEndpoint, "connectedEndpoint");
        lastSuccessfulSyncAt = Objects.requireNonNull(
                lastSuccessfulSyncAt, "lastSuccessfulSyncAt");
        revisions = Map.copyOf(revisions);
        lastFailureCode = Objects.requireNonNull(
                lastFailureCode, "lastFailureCode");
    }
}
```

1. `snapshot()` 和 `instances()` 只读当前原子快照，不在业务线程访问网络或磁盘。
2. `instances()` 等价于 `snapshot(service).instances()`，返回不可变 List。
3. 只有 revision 更大的合法快照可替换当前快照；相同 revision 且校验和不同属于协议错误，必须拒绝并重新选择 Registry 节点。
4. `status()` 为诊断快照，返回数据不保证与随后的 `snapshot()` 处于同一时刻。

## 7. LoadBalancerClient

```java
public interface LoadBalancerClient {
    SelectedInstance select(SelectionRequest request);
    SelectionLease acquire(SelectionRequest request);
}

public record SelectionRequest(
        ServiceName service,
        Optional<AffinityKey> affinityKey,
        Set<String> excludedInstanceIds
) {
    public SelectionRequest {
        service = Objects.requireNonNull(service, "service");
        affinityKey = Objects.requireNonNull(affinityKey, "affinityKey");
        excludedInstanceIds = Set.copyOf(excludedInstanceIds);
    }

    public static SelectionRequest affinity(
            ServiceName service,
            AffinityKey affinityKey
    ) {
        return new SelectionRequest(service, Optional.of(affinityKey), Set.of());
    }
}
```

```java
public record SelectedInstance(
        ServiceInstance instance,
        long directoryRevision,
        int candidateIndex
) {}

public interface SelectionLease extends AutoCloseable {
    SelectedInstance selection();
    void recordSuccess(Duration latency);
    void recordFailure(FailureType type, Duration latency);

    @Override
    void close();
}

public enum FailureType {
    CONNECT_FAILURE,
    CONNECT_TIMEOUT,
    RESPONSE_TIMEOUT,
    REMOTE_5XX,
    REMOTE_429,
    PROTOCOL_ERROR,
    CANCELLED
}
```

`select()` 不占用并发许可，仅用于旧代码迁移。`acquire()` 在返回前必须成功获得选中实例的并发许可；超时抛 `OverloadedException`。首次 `recordSuccess/recordFailure` 生效，再次调用抛 `IllegalStateException`。未记录结果的 `close()` 按 `CANCELLED` 记录且仅释放一次许可。

## 8. ServiceHttpClient

### 8.1 请求类型

```java
public enum HttpMethod {
    GET, HEAD, OPTIONS, POST, PUT, PATCH, DELETE
}

public sealed interface RequestBody
        permits RequestBody.Empty, RequestBody.Bytes, RequestBody.Text {
    record Empty() implements RequestBody {}
    record Bytes(byte[] value, String contentType) implements RequestBody {
        public Bytes {
            Objects.requireNonNull(value, "value");
            value = Arrays.copyOf(value, value.length);
            contentType = ApiValues.requireContentType(contentType);
        }

        @Override
        public byte[] value() {
            return Arrays.copyOf(value, value.length);
        }

        @Override
        public boolean equals(Object candidate) {
            return this == candidate
                    || candidate instanceof Bytes other
                    && Arrays.equals(value, other.value)
                    && contentType.equals(other.contentType);
        }

        @Override
        public int hashCode() {
            return 31 * Arrays.hashCode(value) + contentType.hashCode();
        }
    }
    record Text(String value, String contentType, Charset charset)
            implements RequestBody {
        public Text {
            value = Objects.requireNonNull(value, "value");
            contentType = ApiValues.requireContentType(contentType);
            charset = Objects.requireNonNull(charset, "charset");
        }
    }
}
```

`RequestBody.Bytes` 必须使用 `Arrays.equals/Arrays.hashCode` 覆盖 record 默认的数组引用比较，并保持构造和 getter 的双向防御性复制。

`sdk-api` 不内置 JSON 序列化依赖。`BodyCodec` 是 JDK-only SPI，`sdk-bundle` 提供 Jackson 实现；`ServiceRequestBuilder.jsonBody(Object, BodyCodec)` 必须立即编码为不可变 `RequestBody`，不得保留可变业务对象。纯 API 用户也可直接使用 UTF-8 `RequestBody.Text` 或 `RequestBody.Bytes`。

```java
public record ServiceRequest(
        ServiceName service,
        HttpMethod method,
        String path,
        Map<String, List<String>> query,
        Map<String, List<String>> headers,
        RequestBody body,
        Optional<AffinityKey> affinityKey,
        Optional<String> idempotencyKey,
        Duration timeout
) {
    public static ServiceRequestBuilder builder(
            ServiceName service,
            HttpMethod method,
            String path
    ) {
        return new ServiceRequestBuilder(service, method, path);
    }

    public static ServiceRequestBuilder post(ServiceName service, String path) {
        return builder(service, HttpMethod.POST, path);
    }
}
```

Builder 校验规则：

1. `path` 必须以 `/` 开头且长度不超过 2,048，禁止 scheme、authority、fragment、NUL、反斜杠和解码后的 `.`/`..` 路径段。
2. query 必须通过 Builder 的 `query(name, value)` 添加，不允许直接把 `?` 拼入 path。
3. Header 名符合 RFC 9110 token；禁止业务方设置 `Host`、`Content-Length`、`Connection`、`Transfer-Encoding` 和 `X-AffinityRoute-*`。
4. `timeout` 必须大于 0 且不超过配置的 `http.maximum-timeout`。
5. `idempotencyKey` 长度 16–128，只允许 `[A-Za-z0-9._:-]`；不得写入普通 INFO 日志。
6. GET、HEAD 和 OPTIONS 不允许非空 Body。

`ServiceRequest` 的 public canonical constructor 与 Builder 必须共用同一个 package-private `ServiceRequestValidator`；不允许通过直接 `new ServiceRequest(...)` 绕过上述校验和 collection 防御性复制。

### 8.2 执行与响应

```java
public interface ServiceHttpClient extends AutoCloseable {
    <T> ServiceResponse<T> execute(
            ServiceRequest request,
            BodyHandler<T> bodyHandler
    );

    @Override
    void close();
}

@FunctionalInterface
public interface BodyHandler<T> {
    T handle(ResponseBody body) throws IOException;
}

public interface BodyCodec {
    RequestBody encode(Object value);
    <T> T decode(ResponseBody body, Class<T> targetType) throws IOException;
}

public interface ResponseBody extends AutoCloseable {
    Optional<String> contentType();
    OptionalLong contentLength();
    InputStream stream();

    @Override
    void close();
}
```

```java
public record ServiceResponse<T>(
        int statusCode,
        Map<String, List<String>> headers,
        T body,
        SelectedInstance selectedInstance,
        Duration duration,
        List<AttemptSummary> attempts
) {
    public ServiceResponse {
        headers = ApiValues.copyHeaders(headers);
        attempts = List.copyOf(attempts);
    }
}

public record AttemptSummary(
        String instanceId,
        int candidateIndex,
        OptionalInt statusCode,
        Optional<FailureType> failureType,
        Duration duration
) {}
```

`BodyHandler` 在请求线程中执行，只被调用一次。处理完成或抛出异常后，Transport 必须关闭 `ResponseBody`。未知 `Content-Type` 和 `Content-Length` 分别用 `Optional.empty()` 和 `OptionalLong.empty()` 表示，不使用 `null` 或 `-1`。默认 `BodyHandlers` 提供 `discarding()`、`ofByteArray(maxBytes)`、`ofString(maxBytes, charset)` 和 `json(targetType, codec)`；超限抛 `ResponseTooLargeException` 并不复用未排空的连接。

`execute()` 对任意 HTTP 状态码均返回 `ServiceResponse`，仅对无法得到完整 HTTP 响应的传输、解码、超时和选址失败抛异常。若业务需要 4xx/5xx 自动抛异常，由上层包装器实现，不改变底层契约。

## 9. 异常层次

```text
RuntimeException
└── AffinityRouteException
    ├── DiscoveryUnavailableException
    ├── NoAvailableInstanceException
    ├── OverloadedException
    ├── TimeoutBudgetExceededException
    ├── IndeterminateWriteException
    ├── RemoteServiceException
    ├── ResponseTooLargeException
    └── ClientClosedException
```

```java
public abstract class AffinityRouteException extends RuntimeException {
    private final String code;
    private final boolean retryable;

    protected AffinityRouteException(
            String code,
            String message,
            boolean retryable,
            Throwable cause
    ) {
        super(message, cause);
        this.code = Objects.requireNonNull(code, "code");
        this.retryable = retryable;
    }

    public final String code() { return code; }
    public final boolean retryable() { return retryable; }
}
```

| 异常 | 使用场景 | retryable |
| --- | --- | --- |
| `DiscoveryUnavailableException` | 从未获得可用目录 | `true` |
| `NoAvailableInstanceException` | 快照为空或候选全部不可用 | `true` |
| `OverloadedException` | 并发许可在预算内不可用 | `true` |
| `TimeoutBudgetExceededException` | 整体 deadline 耗尽 | `true` |
| `IndeterminateWriteException` | 非幂等写可能已到达但未得到响应 | `false` |
| `RemoteServiceException` | 传输或协议异常，保留 cause | 按分类 |
| `ResponseTooLargeException` | 响应超过上限 | `false` |
| `ClientClosedException` | Client 已关闭 | `false` |

异常 message 可包含 serviceName、instanceId、attempt 和脱敏错误分类，不得包含 affinity key、Authorization、Cookie、session token、secret 和 Body。

## 10. Starter 装配契约

### 10.1 Bean 名称和条件

| Bean 名 | 类型 | 创建条件 | 退让条件 |
| --- | --- | --- | --- |
| `affinityRouteDiscoveryClient` | `DiscoveryClient` | `affinityroute.enabled=true` | 存在任意 `DiscoveryClient` Bean |
| `affinityRouteLoadBalancerClient` | `LoadBalancerClient` | 存在 `DiscoveryClient` | 存在任意 `LoadBalancerClient` Bean |
| `affinityRouteServiceHttpClient` | `ServiceHttpClient` | 存在 `LoadBalancerClient` | 存在任意 `ServiceHttpClient` Bean |
| `affinityRouteProviderClient` | `ProviderClient` | `affinityroute.provider.enabled=true` | 存在任意 `ProviderClient` Bean |

自动配置使用 `@ConditionalOnMissingBean(type)`，不以 Bean 名作为退让判断。注册顺序为 Discovery → LoadBalancer → HTTP → Provider，关闭顺序反向执行。

### 10.2 配置属性

| 属性 | Java 类型 | 默认值 | 校验 |
| --- | --- | --- | --- |
| `affinityroute.enabled` | `boolean` | `true` | 无 |
| `scope.namespace` | `String` | 无 | 启用时必填，1–63 |
| `scope.group` | `String` | `DEFAULT_GROUP` | 1–63 |
| `registry.endpoints` | `List<URI>` | 无 | 静态目录以外必填，1–10 个 HTTPS URI |
| `registry.client-id` | `String` | 无 | Registry 模式必填 |
| `registry.secret-file` | `Path` | 无 | 必须存在、可读、非目录 |
| `registry.connect-timeout` | `Duration` | `2s` | `100ms..30s` |
| `registry.request-timeout` | `Duration` | `5s` | `connect-timeout..60s` |
| `snapshot.path` | `Path` | `${java.io.tmpdir}/affinityroute/catalog.snapshot` | 父目录可写 |
| `snapshot.reconciliation-interval` | `Duration` | `60s` | `5s..1h` |
| `provider.enabled` | `boolean` | `false` | 无 |
| `provider.shutdown-timeout` | `Duration` | `5s` | `0..30s` |
| `load-balancer.local-ejection.consecutive-failures` | `int` | `3` | `1..100` |
| `load-balancer.local-ejection.cooldown` | `Duration` | `20s` | `1s..10m` |
| `http.total-timeout` | `Duration` | `5s` | `100ms..5m` |
| `http.maximum-timeout` | `Duration` | `30s` | 不小于 `total-timeout` |
| `http.max-attempts` | `int` | `2` | `1..5` |
| `http.retryable-statuses` | `Set<Integer>` | 空 | 只允许 429、500–599 |
| `http.minimum-attempt-budget` | `Duration` | `50ms` | `1ms..total-timeout` |
| `http.max-concurrency-per-instance` | `int` | `100` | `1..10000` |
| `http.acquire-timeout` | `Duration` | `100ms` | `0..total-timeout` |
| `http.max-response-bytes` | `DataSize` | `10MB` | `1KB..100MB` |

其他线程池和连接池属性以 [SDK Client 配置示例](./sdk-client.example.yaml) 为完整键集。所有 `@ConfigurationProperties` 类使用 `@Validated`，不允许未知属性静默生效；旧键兼容必须显式声明 deprecated alias 和移除版本。

## 11. 必须先写的契约测试

| 测试类 | 必须覆盖 |
| --- | --- |
| `ApiValueValidationTest` | 名称边界、URI 白名单、metadata 上限、AffinityKey 脱敏 |
| `ServiceSnapshotTest` | 防御性复制、跨服务实例拒绝、revision 0 语义 |
| `ServiceRequestBuilderTest` | path traversal、保留 Header、超时、写请求幂等键 |
| `SelectionLeaseContractTest` | 双重记录拒绝、close 幂等、未记录按 CANCELLED |
| `ClientLifecycleContractTest` | Client 关闭顺序和关闭后统一异常 |
| `BodyHandlerContractTest` | 单次调用、超限中止、连接释放 |
| `AutoConfigurationTest` | 默认 Bean、用户 Bean 退让、配置校验、关闭顺序 |

## 12. 与实施任务的映射

- T01 建立本文档列出的 `sdk-api` 类和契约测试。
- T07 实现 Provider/Discovery 线程安全、快照和生命周期语义。
- T08 实现 SelectionLease、ServiceRequest、BodyHandler 和异常映射。
- T09 实现 Starter Bean、属性校验和关闭顺序。

本契约变更时，必须同步公共 API 兼容性基线、示例代码、Starter metadata 和对应契约测试。
