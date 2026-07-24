# AffinityRoute：Java 服务发现与客户端负载均衡实现方案

AffinityRoute 是面向 Java 应用的开源服务发现、客户端负载均衡和统一管理控制台。系统面向云瞰调用 Topo、森大屏等产品的场景，以逻辑服务名替代固定 `IP + 端口 + URL`，在调用方 JVM 内完成 ID 亲和选址、故障转移、超时、重试和本地隔离。

方案基线：

- JDK 17 起步，同时验证 JDK 21；后续 LTS版本进入兼容矩阵后继续支持。
- Spring Boot 3.5.0 起步；3.5.x作为首发基线，更高版本通过兼容矩阵逐线验证。
- Maven 多模块工程。
- 三节点注册中心，使用 Apache Ratis 提供 Raft 共识。
- REST负责注册和快照，SSE负责目录增量通知。
- Vue 3 + TypeScript + Vite 管理控制台。
- 单客户环境目标容量：200 个服务、2,000 个实例。

## 1. 背景

### 1.1 现状

云瞰当前通过固定 `IP + 端口 + 请求路径` 访问 Topo、森大屏等产品。例如：

```text
http://10.100.30.239:8180/projectScene/offlineTopo/sync
```

这种调用方式存在以下问题：

1. 一个实例故障后，云瞰不能自动切换到其他实例。
2. 扩容实例不能自动分担流量。
3. IP 或端口变化时，需要修改云瞰配置并重启或重新发布。
4. 同一业务 ID 可能在不同实例之间随机漂移，破坏本地缓存或状态亲和。
5. 超时、重试、并发和故障隔离散落在各业务代码中，难以统一治理。
6. 运维无法从一个入口看到服务目录、SDK Client 状态、实例流量和故障原因。

### 1.2 系统定位

本方案建设一个独立的服务目录控制面和一套 Java SDK。Topo、森大屏等 Provider 通过 `ProviderClient` 注册，云瞰等 Consumer 通过 `DiscoveryClient` 获取目录，并由 `LoadBalancerClient` 或 `ServiceHttpClient` 在本 JVM 选址。本系统不增加业务流量代理：注册中心只提供控制面目录，SDK 选出实例后直接访问目标服务。

## 2. 目标

### 2.1 功能目标

1. 使用 `namespace + group + serviceName` 标识逻辑服务。
2. 支持应用自动注册的临时实例，以及兼容旧系统的静态实例。
3. 相同 affinity ID 稳定命中相同实例。
4. 主实例故障时，相同 affinity ID 稳定切换到同一个备用实例。
5. 实例恢复并通过观察期后，新的请求自动迁回原归属。
6. 无 affinity ID 时使用加权最少并发策略。
7. SDK同时提供自动注册、目录查询、简单选址、受治理选址和完整 HTTP 调用。
8. 注册中心全部不可达时，SDK继续使用最近有效快照调用仍可达实例。
9. 提供统一控制台，管理服务、实例、Client、权限、审批、审计和运行观测。

### 2.2 高可用目标

1. 三节点注册中心允许一个节点故障。
2. Leader 故障后，目标 10 秒内恢复目录写入。
3. 当前 SDK遇到实例连接失败时立即在本 JVM 切换备用实例。
4. 全局实例状态变化目标 3 秒内推送到在线 Consumer。
5. 注册中心失去多数派时停止目录写入，避免脑裂。
6. 注册中心不可达不应直接中断已有业务调用。

### 2.3 非目标

首版不实现：

- 通用配置中心。
- 多 Raft 分片和跨地域多活。
- 服务网格或独立业务流量代理。
- 非 Java SDK。
- gRPC、自定义 TCP协议或异步 HTTP API。
- 自动扩缩容和复杂灰度编排。

## 3. 总体架构

### 3.1 逻辑架构

```text
Topo / 森大屏 Provider
  └─ ProviderClient
       └─ REST 注册、续约、注销
                    │
                    ▼
       ┌───────────────────────────────┐
       │ Registry Server A / B / C     │
       │                               │
       │ Spring Boot 3.5               │
       │ REST + SSE + Console API      │
       │ Service Catalog + Lease       │
       │ Apache Ratis / Raft           │
       └───────────────────────────────┘
                    │
                    │ REST 全量 + SSE 增量
                    ▼
云瞰 Consumer JVM
  ├─ DiscoveryClient：内存/磁盘服务快照
  ├─ LoadBalancerClient：亲和选址和并发许可
  └─ ServiceHttpClient：超时、重试、隔离和 HTTP 调用
                    │
                    └─────────── 业务流量直达选中实例

浏览器
  └─ VIP / Nginx / Kubernetes Service
       └─ 任意 Registry 节点
            ├─ console-web 静态资源
            ├─ console-api
            └─ Prometheus Query 代理
```

### 3.2 功能架构

```text
接入层
├── ProviderClient：注册、续约、注销
├── DiscoveryClient：快照、增量同步、本地恢复
├── LoadBalancerClient：亲和选址、并发许可
└── ServiceHttpClient：超时、重试、隔离、HTTP 调用

核心能力层
├── Service Catalog：namespace/group/service/instance
├── Weighted HRW：ID 亲和和确定性备用序列
├── Least Concurrency：无亲和请求选址
├── Lease + Health：临时实例存活和恢复观察
└── Local Resilience：deadline、bulkhead、本地隔离

管理与运维层
├── Console API + Vue Console
├── RBAC + 审批 + 审计
└── Micrometer + Prometheus + 告警
```

### 3.3 控制面与数据面

注册中心属于控制面，采用 CP：

- 注册、注销、权重、静态实例、健康状态和权限变更必须经 Raft多数派提交。
- 失去多数派时拒绝写入，不允许少数派形成另一份服务目录。

业务调用属于数据面，采用 AP：

- 请求线程只读取 SDK 内存快照，不同步查询注册中心。
- 注册中心失联时保留最近有效快照。
- SDK根据真实请求结果维护当前 JVM 的本地隔离状态。

### 3.4 故障边界

| 故障 | 系统行为 | 业务影响 |
| --- | --- | --- |
| 一个 Registry 节点故障 | 剩余多数派继续服务 | 已有调用不中断 |
| Registry Leader 故障 | 重新选举；Provider/SDK切换节点 | 短时不能写目录，调用继续 |
| 失去 Raft多数派 | 拒绝注册和管理写入 | 已有快照调用继续 |
| 三个 Registry 全部失联 | SDK使用内存或磁盘快照 | 不能发现新实例，但可调用旧实例 |
| 一个业务实例故障 | SDK立即本地隔离，随后全局标记 DOWN | 首次请求失败或安全重试 |
| 所有实例不可用 | 返回结构化 `NoAvailableInstanceException` | 当前逻辑服务调用失败 |

### 3.5 部署架构

```text
                                 授权业务网络
                                        │
                          VIP / Nginx / Kubernetes Service
                         ┌───────┼───────┐
                         ▼       ▼       ▼
                  Registry-01 Registry-02 Registry-03
                  REST/SSE/UI REST/SSE/UI REST/SSE/UI
                         │       │       │
                         └── Raft / mTLS ──┘
                           各节点独立数据盘
                                 │
                    可选 Prometheus 监控网络

Provider JVM ───── HTTPS 注册/续约 ─────▲
Consumer JVM ───── HTTPS 快照/SSE ───────▲
Consumer JVM ───── HTTPS 业务请求 ───────► Provider JVM
```

生产环境的三个 Registry 节点必须分布在不同故障域，Raft 通信端口只允许节点间互访。前端静态资源由每个 Registry 节点携带，不需要独立前端服务器。

## 4. 代码架构

### 4.1 开源项目命名

| 项目 | 固定名称 |
| --- | --- |
| 项目品牌 | `AffinityRoute` |
| GitHub仓库 | `lvdaxianer/affinity-route` |
| GitHub地址 | `https://github.com/lvdaxianer/affinity-route` |
| GitHub Description | `Java-first service discovery and client-side load balancing with affinity routing, weighted balancing, deterministic failover, and resilient HTTP calls.` |
| 所属域名 | `lvdaxianerplus.cc` |
| Maven GroupId | `cc.lvdaxianerplus.affinityroute` |
| Java根包 | `cc.lvdaxianerplus.affinityroute` |
| Spring配置前缀 | `affinityroute` |
| Linux配置目录 | `/etc/affinityroute` |
| Linux数据目录 | `/var/lib/affinityroute` |
| systemd服务名 | `affinityroute-registry` |
| 指标前缀 | `affinityroute_` |

Java包名按域名反写，因此必须使用 `cc.lvdaxianerplus.affinityroute`，禁止使用 `lvdaxianerplus.cc.affinityroute`。发布到 Maven Central 时，所有公开构件统一使用上述 GroupId，ArtifactId统一使用 `affinityroute-` 前缀。首次发布前需要在 Central Portal 通过 `lvdaxianerplus.cc` 的 DNS记录验证 `cc.lvdaxianerplus` namespace所有权。

### 4.2 工程目录

实际产品代码建议建立独立 Maven reactor：

```text
affinity-route/
├── pom.xml
├── .mvn/
│   └── maven.config
├── affinityroute-bom/
├── sdk-api/
├── sdk-bundle/
├── registry-protocol/
├── registry-ratis/
├── registry-server/
├── registry-client/
├── lb-core/
├── lb-http-client/
├── registry-static/
├── lb-spring-boot-starter/
├── console-api/
├── observability-prometheus/
├── console-web/
├── examples/
│   ├── provider-example/
│   ├── consumer-example/
│   └── migration-example/
├── architecture-tests/
├── system-tests/
├── performance-tests/
└── distribution/
```

### 4.3 模块坐标与职责

| 模块目录 | Maven ArtifactId | Java包 | 职责 |
| --- | --- | --- | --- |
| 根工程 | `affinityroute-parent` | 不适用 | Reactor父工程和插件管理 |
| `affinityroute-bom` | `affinityroute-bom` | 不适用 | 对外依赖版本清单 |
| `sdk-api` | `affinityroute-sdk-api` | `cc.lvdaxianerplus.affinityroute.api` | 对业务公开的 Client、模型和异常 |
| `sdk-bundle` | `affinityroute-sdk` | 不适用 | 普通 Java应用的一站式依赖聚合 |
| `registry-protocol` | `affinityroute-registry-protocol` | `cc.lvdaxianerplus.affinityroute.protocol` | REST/SSE wire DTO、命令和错误码 |
| `registry-ratis` | `affinityroute-registry-ratis` | `cc.lvdaxianerplus.affinityroute.registry.ratis` | 状态机、快照和 Ratis适配 |
| `registry-server` | `affinityroute-registry-server` | `cc.lvdaxianerplus.affinityroute.registry.server` | 注册、租约、健康、REST/SSE和安全 |
| `registry-client` | `affinityroute-registry-client` | `cc.lvdaxianerplus.affinityroute.client` | Provider注册和 Consumer目录同步 |
| `lb-core` | `affinityroute-loadbalancer-core` | `cc.lvdaxianerplus.affinityroute.loadbalancer` | 加权 HRW、最少并发和候选计划 |
| `lb-http-client` | `affinityroute-http-client` | `cc.lvdaxianerplus.affinityroute.http` | deadline、重试、隔离和 HTTP调用 |
| `registry-static` | `affinityroute-static-discovery` | `cc.lvdaxianerplus.affinityroute.staticdiscovery` | 固定 URL映射为 `DiscoveryClient` |
| `lb-spring-boot-starter` | `affinityroute-spring-boot-starter` | `cc.lvdaxianerplus.affinityroute.starter` | Spring Boot自动配置和生命周期组装 |
| `console-api` | `affinityroute-console-api` | `cc.lvdaxianerplus.affinityroute.console` | 控制台 API、RBAC、审批和 Client目录 |
| `observability-prometheus` | `affinityroute-observability-prometheus` | `cc.lvdaxianerplus.affinityroute.observability.prometheus` | Prometheus Query适配和降级 |
| `console-web` | `affinityroute-console-web` | 不适用 | Vue 3管理控制台 |
| `distribution` | `affinityroute-distribution` | 不适用 | 离线包、脚本、证书、systemd和文档 |

`cc.lvdaxianerplus.affinityroute.api` 及其子包是唯一承诺语义化版本兼容的公共 Java API。其他模块包默认属于实现边界，业务代码不得直接依赖 `internal` 子包。不同 Artifact不得声明同一个 Java package，避免 split package；公共类型移动或改名必须通过 Revapi或 japicmp兼容门禁。

### 4.4 依赖方向

```text
sdk-api                           registry-protocol
   ↑                                ↑          ↑
   ├── registry-client ─────────────┘          │
   ├── lb-core                              registry-ratis
   ├── registry-static                        ↑
   └── lb-http-client                     registry-server
             ↑                                  ↑
      lb-spring-boot-starter               console-api
                                                ↑
                                          console-web
```

必须使用 ArchUnit 或模块构建测试保证：

- `sdk-api` 不依赖 Spring、Ratis、HTTP引擎或 `registry-protocol`。
- `registry-client` 不实现负载算法。
- `lb-core` 不访问网络和磁盘。
- `registry-server` 不依赖 Consumer 负载均衡实现。
- `console-web` 不直接调用 Prometheus、Raft或内部管理对象。

### 4.5 编码约束

实现阶段统一遵守以下约束：

- 新增 Java/TypeScript/Vue类和公共方法使用中文文档注释，并按项目规范填写作者标识 `lvdaxianer@yeah.net`。
- Java方法控制在 20 行内，普通类和前端单文件控制在 350 行内；Controller控制在 100 行内。
- 4 个以上参数使用 request/config record，不使用长参数列表。
- 可能缺失的 Java返回值使用 `Optional`，TypeScript显式使用 `T | undefined`，禁止返回未声明的 null。
- 状态、失败类型、事件类型和阈值使用枚举或具名常量，不散落魔法数字/字符串。
- 循环中禁止远程请求、数据库访问和逐条控制面写入；使用批量 API或先拉取后内存处理。
- 所有自定义线程池必须具名、有界、隔离、可监控并有明确拒绝策略。
- 外部输入在 API边界验证；URL、排序字段、标签和 PromQL参数使用白名单。
- 异常转换保留 cause，不捕获 `Throwable` 或宽泛 `Exception` 后静默吞掉。
- Vue Route Page保持薄层，feature组件职责单一，Props Down / Events Up，副作用放入 composable。

### 4.6 公共包结构

```text
sdk-api/src/main/java/cc/lvdaxianerplus/affinityroute/api/
├── client/
│   ├── ProviderClient.java
│   ├── DiscoveryClient.java
│   ├── LoadBalancerClient.java
│   ├── ServiceHttpClient.java
│   ├── RegistrationHandle.java
│   └── SelectionLease.java
├── model/
│   ├── ClientScope.java
│   ├── ServiceName.java
│   ├── ServiceInstance.java
│   ├── ServiceSnapshot.java
│   ├── SelectedInstance.java
│   ├── SnapshotSource.java
│   └── AffinityKey.java
├── request/
│   ├── ProviderRegistration.java
│   ├── ProviderInstanceOptions.java
│   ├── SelectionRequest.java
│   └── ServiceRequest.java
├── response/
│   ├── DiscoveryStatus.java
│   ├── RegistrationState.java
│   └── ServiceResponse.java
├── body/
│   ├── BodyHandler.java
│   ├── BodyHandlers.java
│   └── BodyCodec.java
└── error/
    ├── DiscoveryUnavailableException.java
    ├── NoAvailableInstanceException.java
    ├── OverloadedException.java
    ├── TimeoutBudgetExceededException.java
    ├── IndeterminateWriteException.java
    └── ClientClosedException.java
```

### 4.7 技术选型与版本策略

| 领域 | 选型 | 约束 |
| --- | --- | --- |
| Java | JDK 17+，首发验证 17和21 | 编译目标保持 17，不使用 21 专属 API |
| 后端 | Spring Boot 3.5.0+ | 3.5.x为首发基线；更高版本通过兼容矩阵后声明支持 |
| 共识 | Apache Ratis | 只通过 `ConsensusStore` 适配层进入业务代码 |
| HTTP | Apache HttpClient 5 | 统一连接池、TLS、deadline 和连接回收 |
| 指标 | Micrometer + Prometheus | SDK 与 Registry 使用同一指标命名规则 |
| 前端 | Vue 3、TypeScript、Vite、Element Plus | Composition API、严格 TypeScript |
| 测试 | JUnit 5、AssertJ、Testcontainers、Toxiproxy、Vitest、Playwright | 单元、组件、系统和故障测试分层执行 |

父 POM 必须通过 dependencyManagement 锁定直接依赖和插件版本，并使用 Maven Enforcer 禁止依赖收敛冲突、低于 JDK 17 的构建环境和动态版本。前端必须提交 lockfile 并在 CI 使用 `npm ci`。

### 4.8 为什么不直接使用 Nacos

Nacos是成熟的动态服务发现、配置管理和服务治理平台，官方提供服务注册、健康检查、权重路由、管理界面及主流微服务生态集成。如果需求只是“把固定 IP改成可动态发现的实例列表”，直接部署 Nacos的交付风险和长期维护成本都更低，不应为了自研而自研。

本项目需要评估三条路线：

| 路线 | 优点 | 代价 | 适用条件 |
| --- | --- | --- | --- |
| 直接使用 Nacos | 产品成熟、社区活跃、功能完整、运维经验多 | ID亲和、确定性备用序列、调用级 deadline/重试/隔离仍需自研 SDK | 已有 Nacos平台，或只需要标准注册发现 |
| Nacos作为目录后端，复用 AffinityRoute SDK | 快速获得成熟控制面，同时保留亲和路由和 HTTP治理 | 需要维护 Nacos语义适配、版本兼容和两套管理视图 | 客户环境允许部署 Nacos，团队接受其运维模型 |
| Ratis原生最小 Registry | 数据模型、一致性契约、离线包和控制台完全可控；只实现本项目所需能力 | 共识、安全、升级、备份、故障恢复都由项目承担，研发和验证成本最高 | 需要单一离线发行包、精确一致性语义和端到端统一治理 |

AffinityRoute首版选择第三条路线，理由不是 Nacos无法完成服务发现，而是以下差异需要形成一个可独立验证的整体：

1. ID亲和使用加权 Rendezvous Hash，并要求主实例故障后得到稳定的备用序列。
2. 一次业务调用固定一个目录 revision，重试、并发许可、本地隔离和结果反馈属于同一个 SDK调用模型。
3. 控制面只保留服务目录、权限、审批和观测，不引入通用配置中心等额外产品能力。
4. 交付物需要在离线客户环境中形成单一版本、单一控制台和可重复的故障验收。
5. 持久目录、Leader内存租约、SDK缓存和本地隔离分别声明一致性级别，不能用“最终会同步”代替契约。

这仍然属于有条件的自研决策，而不是不可逆绑定。公共 `ProviderClient`、`DiscoveryClient` 和 `LoadBalancerClient` 不暴露 Ratis类型；`registry-client` 通过 `RegistrationTransport`、`CatalogTransport` 适配控制面。若采用第二条路线，可增加 `affinityroute-nacos-adapter`，但不改变负载算法和业务调用 API。

原生 Registry有以下退出条件，任一条件在首个生产版本前无法满足，就停止扩大自研范围，优先切换为 Nacos后端或其他成熟注册中心：

- 无法通过单节点故障、Leader切换、少数派拒写和崩溃恢复测试。
- 无法证明已确认写入在单节点故障后不丢失，或线性读可能返回旧值。
- 200个服务、2,000个实例和目标 Client规模下无法达到容量门禁。
- 安全审查、依赖升级、备份恢复或离线运维成本超过团队长期承受能力。
- 项目维护者不足以持续负责 Ratis兼容、安全修复和跨版本升级。

因此，本方案的核心差异是 AffinityRoute SDK和亲和路由语义；原生 Registry是默认控制面实现，不是项目必须永久维护的唯一后端。

## 5. SDK Client 实现

### 5.1 ProviderClient

Provider 使用该接口注册自身：

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
) {}

public record ProviderInstanceOptions(
        int weight,
        String cluster,
        Map<String, String> metadata,
        String healthPath
) {}
```

`register` 返回一个独立注册会话：

```java
public interface RegistrationHandle extends AutoCloseable {
    ServiceInstance registeredInstance();
    RegistrationState state();
    Optional<RegistrationFailure> lastFailure();

    @Override
    void close();
}
```

实现规则：

1. 注册请求携带稳定 `commandId`，网络重试不得重复创建实例。
2. 注册成功后保存 sessionId，共享调度器默认每 5 秒续约。
3. 连接非 Leader 时，根据 Leader提示重试。
4. 单个 `RegistrationHandle.close()` 只注销对应实例。
5. `ProviderClient.close()` 停止新注册并关闭所有 handle。
6. 注册中心失联时 handle 进入 `DEGRADED`，恢复后重新续约或注册。
7. Spring Starter 在 `WebServerInitializedEvent` 后获取真实端口并自动注册。

### 5.2 DiscoveryClient

```java
public interface DiscoveryClient extends AutoCloseable {
    ServiceSnapshot snapshot(ServiceName service);
    List<ServiceInstance> instances(ServiceName service);
    DiscoveryStatus status();

    @Override
    void close();
}
```

```java
public record ServiceSnapshot(
        ServiceName service,
        long revision,
        Instant createdAt,
        SnapshotSource source,
        List<ServiceInstance> instances
) {}
```

`SnapshotSource` 包括：

- `LIVE`：已与注册中心在线同步。
- `MEMORY_CACHE`：当前进程内最近有效数据。
- `DISK_CACHE`：冷启动从磁盘恢复。
- `STATIC`：固定 URL配置。

同步流程：

```text
读取并校验磁盘快照
  → 发布初始内存目录
  → REST 拉取最新全量目录
  → 原子替换 AtomicReference<ServiceCatalog>
  → 从 revision 建立 SSE订阅
  → 连续应用增量事件
  → 版本间隙时重新拉取全量
  → 低频 revision 对账
```

磁盘快照必须包含 `schemaVersion`、`revision`、生成时间和校验和。写入使用临时文件加原子 rename；写入队列容量为 1，只保留最新 revision。

### 5.3 LoadBalancerClient

```java
public interface LoadBalancerClient {
    SelectedInstance select(SelectionRequest request);
    SelectionLease acquire(SelectionRequest request);
}
```

`select()` 只返回地址，适合旧代码兼容；`acquire()` 同时管理实例并发许可和调用结果：

```java
try (SelectionLease lease = loadBalancerClient.acquire(request)) {
    URI target = lease.instance().baseUri().resolve(relativePath);
    long startedAt = System.nanoTime();

    try {
        existingHttpClient.execute(target);
        lease.recordSuccess(Duration.ofNanos(System.nanoTime() - startedAt));
    } catch (ConnectException ex) {
        lease.recordFailure(
                FailureType.CONNECT_FAILURE,
                Duration.ofNanos(System.nanoTime() - startedAt));
        throw ex;
    }
}
```

`SelectionLease.close()` 必须幂等释放并发许可。未记录结果时按 `CANCELLED` 处理，不得误记成功。

### 5.4 ServiceHttpClient

新业务优先使用完整调用 API：

```java
public interface ServiceHttpClient extends AutoCloseable {
    <T> ServiceResponse<T> execute(
            ServiceRequest request,
            BodyHandler<T> bodyHandler
    );

    @Override
    void close();
}
```

云瞰同步示例：

```java
SyncResult result = serviceHttpClient.execute(
        ServiceRequest.post(
                        ServiceName.of("topo-service"),
                        "/projectScene/offlineTopo/sync")
                .affinityKey(topoId)
                .jsonBody(Map.of("topoId", topoId))
                .idempotencyKey(syncTaskId)
                .timeout(Duration.ofSeconds(5))
                .build(),
        BodyHandlers.json(SyncResult.class)
).body();
```

内部调用链：

```text
DefaultServiceHttpClient.execute
  → DiscoveryClient.snapshot
  → CandidateFilter：全局健康 + 本地隔离
  → CandidatePlanner：主选 + 确定性备用
  → RetryCoordinator：deadline + 幂等性
  → AttemptExecutor：bulkhead + half-open许可
  → Transport：Apache HttpClient 5
  → ResultClassifier
  → LocalEjectionRegistry
  → CallObservation
```

`DefaultServiceHttpClient` 只负责编排，不实现哈希、网络或健康算法：

```java
final class DefaultServiceHttpClient implements ServiceHttpClient {
    private final CandidatePlanner candidatePlanner;
    private final RetryCoordinator retryCoordinator;
    private final AttemptExecutor attemptExecutor;
    private final CallObservationFactory observations;

    @Override
    public <T> ServiceResponse<T> execute(
            ServiceRequest request,
            BodyHandler<T> bodyHandler
    ) {
        CallContext call = CallContext.start(request);
        CandidatePlan candidates = candidatePlanner.plan(call);

        try (CallObservation observation = observations.open(call)) {
            return retryCoordinator.execute(
                    call,
                    candidates,
                    attempt -> attemptExecutor.execute(
                            attempt, bodyHandler, observation));
        }
    }
}
```

### 5.5 亲和算法

有 affinity ID 时使用加权 Rendezvous Hash。对每个候选实例计算：

```text
u = uniformHash(serviceKey + affinityKey + instanceId), u ∈ (0, 1)
score = -ln(u) / weight
```

按 score 从小到大排序：

- 第一名是主实例。
- 后续实例是确定性备用序列。
- 相同目录和 ID 的顺序稳定。
- 权重越大，获得的 ID比例越高。
- 节点变化时只迁移必要 ID。

无 affinity ID 时计算：

```text
score = (activeRequests + 1) / weight
```

选择 score 最低实例，平局时稳定轮转。

亲和键获取顺序：

1. 业务显式传入。
2. 按路由规则从 Header 提取。
3. 从 Path参数提取。
4. 从 Query参数提取。
5. 从 JSON Body的 JSON Pointer提取。
6. 未获取时使用无亲和策略。

### 5.6 超时与重试

每次逻辑调用只创建一个 deadline。以下时间共同消耗总预算：

- 等待连接池。
- 建立连接。
- 等待响应。
- 退避。
- 所有重试。

重试规则：

| 请求 | 默认策略 |
| --- | --- |
| `GET/HEAD/OPTIONS` | 允许有限重试 |
| `POST/PUT/PATCH/DELETE` | 默认不重试 |
| 带幂等键的写请求 | 可按配置重试 |
| 收到明确业务响应 | 默认不重试 |
| 连接失败/连接超时 | 可切换确定性备用 |

请求可能已经到达服务端但响应丢失时，非幂等写请求返回 `IndeterminateWriteException`，不得自动重复提交。

### 5.7 本地隔离与并发控制

SDK按 instanceId 维护本 JVM 状态：

```text
CLOSED
  └─ 连续失败达到阈值 → OPEN
OPEN
  └─ 冷却期结束 → HALF_OPEN
HALF_OPEN
  ├─ 探测成功 → CLOSED
  └─ 探测失败 → OPEN
```

每个实例配置：

- 最大活跃并发。
- 连接池等待上限。
- 连续失败阈值。
- 隔离冷却时间。
- half-open 探测并发。

所有候选都达到并发上限时返回 `OverloadedException`，不得创建无界队列。

### 5.8 线程与资源模型

每个 Spring ApplicationContext 默认只有：

- 一个 `DiscoveryClient`。
- 一个 `LoadBalancerClient`。
- 一个 `ServiceHttpClient`。
- 一个共享 HTTP连接池。
- 一个串行目录事件执行器。
- 一个 Provider续约调度器。
- 一个目录revision对账调度器。
- 一个容量为 1 的快照写入器。

不同职责使用独立的自定义线程池或调度器，不能共享工作队列。所有执行器必须配置：

- 能表达业务用途的线程名，例如 `discovery-sse-event-%d`、`discovery-provider-renewal-%d`、`discovery-reconcile-%d` 和 `discovery-snapshot-writer-%d`。
- 明确的核心/最大线程数、有界队列、拒绝策略和关闭等待时间。
- 任务开始、成功、失败和拒绝指标；异常日志带 `[服务发现]` 业务标识。
- 慢任务和队列长度指标，禁止无超时阻塞或无限 sleep重试。

禁止按服务、请求或 RegistrationHandle 创建线程池。请求线程读取一次不可变快照，不访问注册中心和磁盘。

### 5.9 调用日志

`ServiceHttpClient` 对每次服务间调用记录可诊断且脱敏的结构化日志：

- DEBUG请求日志：requestId、逻辑服务、相对 path、方法、脱敏 Header、Query和受大小限制的脱敏 Body。
- DEBUG响应日志：requestId、instanceId、状态码、耗时和受大小限制的脱敏响应体。
- WARN失败日志：失败分类、attempt、目录revision、异常链和安全请求上下文。
- 所有日志使用 `[服务间调用]` 业务标识和参数化占位符。
- `Authorization`、Cookie、secret、token、幂等键、原始 affinity ID和业务敏感字段必须由统一 `LogSanitizer` 脱敏。
- 日志 Body达到配置上限时截断并记录 `truncated=true`；流式、文件和二进制 Body只记录长度、类型和摘要。
- 生产环境默认关闭完整 Body DEBUG日志，启用时仍必须执行脱敏和大小限制。

### 5.10 SDK 发布与 Spring Boot 接入

SDK的 BOM、普通 Java聚合依赖和 Starter发布到 Maven Central，Registry与离线发行包发布到 GitHub Releases。首个开发版本使用以下坐标，稳定发布时只替换版本号：

```xml
<dependencyManagement>
  <dependencies>
    <dependency>
      <groupId>cc.lvdaxianerplus.affinityroute</groupId>
      <artifactId>affinityroute-bom</artifactId>
      <version>1.0.0-SNAPSHOT</version>
      <type>pom</type>
      <scope>import</scope>
    </dependency>
  </dependencies>
</dependencyManagement>

```

普通 Java应用增加：

```xml
<dependency>
  <groupId>cc.lvdaxianerplus.affinityroute</groupId>
  <artifactId>affinityroute-sdk</artifactId>
</dependency>
```

Spring Boot应用改用 Starter，不再重复声明 `affinityroute-sdk`：

```xml
<dependency>
  <groupId>cc.lvdaxianerplus.affinityroute</groupId>
  <artifactId>affinityroute-spring-boot-starter</artifactId>
</dependency>
```

Starter通过 `@ConfigurationProperties(prefix = "affinityroute")` 绑定配置，并在条件满足时提供四个公共 Client Bean。业务方自定义同类型 Bean 时，自动配置使用 `@ConditionalOnMissingBean` 退让。生命周期顺序固定为：

```text
创建 HTTP连接池
  → 恢复磁盘快照
  → 启动 Discovery同步
  → 创建 LoadBalancerClient
  → 创建 ServiceHttpClient
  → WebServer就绪后注册 Provider

应用停止
  → 停止接收新调用
  → 注销 Provider并等待确认
  → 停止 SSE和后台任务
  → 刷新最终快照
  → 关闭 HTTP连接池
```

不使用 Spring Boot 的应用由 `affinityroute-sdk` 聚合 `sdk-api`、`registry-client`、`lb-core` 和 `lb-http-client`，并通过 `DiscoveryClients.builder()` 显式组装；两种接入方式必须复用相同实现，不能维护两套行为。

## 6. 注册中心实现

### 6.1 服务目录模型

```text
ServiceKey
├── namespace
├── group
└── serviceName

ServiceInstance
├── instanceId
├── scheme
├── host
├── port
├── weight
├── cluster
├── metadata
├── healthPath
└── lifecycle: EPHEMERAL | STATIC
```

同一 ServiceKey 内：

- `instanceId` 必须唯一。
- `scheme + host + port` 不允许被不同 instanceId 重复注册。
- 权重必须为正数并有上限。
- 实例只注册基础地址，业务请求路径不进入目录。

### 6.2 Raft 状态机

必须经多数派提交的命令：

- 创建或更新服务定义。
- 注册、更新和注销实例。
- 管理静态实例。
- 修改权重和全局健康状态。
- 管理身份、权限和审批。

每个命令携带 commandId。状态机保存有限去重窗口，相同 commandId 返回原结果，不重复产生事件。

每个改变可见目录的命令只递增受影响 `ServiceKey` 的 `directoryRevision`；Raft `appliedIndex` 表示集群全局已应用位置。这避免其他服务的变更在当前服务事件流中被误判为缺口。一条命令若原子影响多个 `ServiceKey`，状态机分别递增其版本并生成各自事件。状态机不得读取系统时钟、访问网络或执行磁盘之外的副作用，保证所有节点确定性回放。

### 6.3 数据一致性模型

系统不对所有数据笼统宣称“强一致”。不同数据按业务风险选择不同一致性级别：

| 数据类别 | 权威位置 | 一致性级别 | 故障时行为 |
| --- | --- | --- | --- |
| 服务定义、静态实例、已提交临时实例、权重、全局健康状态 | Raft状态机 | `LINEARIZABLE`写；管理读默认`LINEARIZABLE` | 失去多数派拒绝写和线性读 |
| 身份、权限、审批、审计索引 | Raft状态机 | `LINEARIZABLE`写；鉴权读不得落后于已确认权限变更 | 失去多数派拒绝安全敏感变更 |
| Provider租约、SDK Client在线心跳 | Leader内存 | `LEADER_LOCAL`，不承诺跨Leader瞬时一致 | Leader切换后进入宽限期并等待重新上报 |
| SDK服务目录 | Consumer内存和磁盘快照 | `MONOTONIC`单调读、最终追上已提交目录 | 控制面失联时保留最后有效 revision |
| SDK本地隔离、活跃并发 | 单个 Consumer JVM | `PROCESS_LOCAL` | 不向其他 JVM伪装成全局状态 |

#### 6.3.1 写入提交与确认

所有持久控制面写入只接受 Leader执行，Follower内部转发或返回 Leader提示。Leader追加日志前先完成令牌签名、请求结构和静态范围检查；对可变 RBAC状态的授权判定与业务命令一起在状态机中按日志顺序复核，防止已提交的撤权与并发写入穿透。写入时序固定为：

```text
校验身份与命令格式
  → Leader追加 Raft日志
  → 多数派将日志持久化并提交
  → 各节点按相同顺序应用确定性状态机
  → 状态机内统一检查可变权限、commandId 和 If-Match
  → 状态机确定性生成并原子保存 resourceVersion、directoryRevision、事件和命令结果
  → Leader等待本地应用完成并返回已保存结果
```

HTTP成功只能在该命令日志达到 Raft `commitIndex` 且 Leader本地 `appliedIndex`已越过该命令 index后返回。`If-Match`、幂等判定和版本号分配不能只在 Leader追加日志前执行，否则并发命令会绕过状态机的顺序化保证。版本号必须由已应用状态和当前日志 index确定性推导，不依赖 Leader本地时钟或随机数。

客户端超时不等于写入失败：使用相同 `X-Command-Id` 和相同规范化请求摘要重试时，必须得到第一次命令的结果，不得重复产生实例、revision或审计事件。相同 `commandId` 携带不同摘要时返回 HTTP 409和 `COMMAND_ID_CONFLICT`，不得执行新请求或伪装成成功。

去重记录按数量和时间双重有界保留，服务端必须公开最小去重保证期和容量。状态机不直接读时钟：Leader定期提交带单调截止值的 `ExpireCommandResults`命令，各节点按同一截止值清理，并通过配置的最小日志 index保留距离防止时钟跃变提前破坏窗口。超出窗口后不再承诺原结果可重放，业务方不得将其当作无限期业务幂等。未提交日志可以在 Leader切换时丢弃；已经向客户端确认的提交不得因单节点故障丢失。

单条 Raft命令是最小原子边界。注册实例、建立会话、递增资源版本和产生目录事件必须在同一次状态机应用中完成，不能先返回实例成功再异步补事件。首版不提供跨多个独立命令的通用事务；批量操作必须封装成一个有上限的批量命令，整体校验后一次提交，失败时不产生部分结果。

`registrationId`和审计事件 ID可在状态机中由 `clusterId + logIndex + commandType + ordinal` 确定性派生。具有凭证属性的 `sessionId` 必须由 Leader使用 CSPRNG预生成并作为完整命令载荷进入 Raft，所有节点仅持久化强哈希。任何预生成 ID都必须在状态机内校验唯一性，不得由各节点在应用日志时自行生成随机值。

#### 6.3.2 读取语义

API显式区分两种持久读：

- `consistency=LINEARIZABLE`：Leader先执行 Raft `ReadIndex` 或等价的多数派确认，等待本地 `appliedIndex` 达到该 read index后读取。管理写后的查询、鉴权、审批和路由诊断默认使用此模式。
- `consistency=STALE`：Follower可以读取本地已应用快照，响应携带 `servedBy`、`term`、`appliedIndex` 和 `directoryRevision`。只允许用于总览、监控和可容忍旧值的列表。

API不提供含义模糊的“强一致布尔开关”。如果节点不能完成 `LINEARIZABLE`读，返回 HTTP 503和 `CONSISTENCY_UNAVAILABLE`，不得静默降级为旧值。写响应返回 `minimumReadIndex`，客户端可在后续读请求中传入同名查询参数获得 read-after-write；服务端只有在 `appliedIndex >= minimumReadIndex` 时才能返回，超过请求 deadline则按一致性不可用处理。

#### 6.3.3 Revision与并发写

系统维护两个不同版本号：

- `resourceVersion`：单个服务、实例、身份或审批资源每次修改递增，用于乐观并发控制。
- `directoryRevision`：每个 `ServiceKey` 独立维护；影响该服务可见路由目录的已提交变更递增，用于该服务快照和事件排序。全局提交位置使用 `appliedIndex`，不用 `directoryRevision` 兼任。

修改已有资源必须同时使用稳定 `commandId` 和 `resourceVersion + If-Match`。版本不匹配返回 HTTP 412和 `RESOURCE_VERSION_CONFLICT`，响应给出当前版本但不自动覆盖。删除与更新竞争时按 Raft提交顺序决定结果；后提交命令必须针对最新资源重新校验。

#### 6.3.4 SDK单调目录与事件收敛

每个 `ServiceSnapshot` 是某个 `ServiceKey + directoryRevision`下的不可变完整视图。SDK按 `ServiceKey` 使用 compare-and-set仅接受更大的 revision，禁止从 1024回退到 1023。SSE订阅必须限定一个 `ServiceKey`，其事件必须满足 `event.revision == localRevision + 1`：

- 等于下一版本：在串行事件执行器中应用并原子发布新快照。
- 小于等于当前版本：视为重复事件并幂等忽略。
- 大于下一版本：视为事件缺口，暂停增量应用并重新拉取全量。
- 全量快照小于本地 revision：拒绝替换并切换其他 Registry节点。

一次 `ServiceHttpClient`调用只读取一次快照并固定其 revision；同一次调用的备用选择不会在重试中切换到另一版目录。新请求可以看到更新后的 revision。磁盘快照只保存校验通过的最后有效视图，临时文件 `fsync`后原子 rename；快照损坏、schema不兼容或 revision回退时隔离文件，不覆盖内存目录。

#### 6.3.5 租约、时钟和恢复边界

租约和 Client心跳是软状态，不进入每次 Raft日志，以避免高频写放大。这意味着它们不具备 `LINEARIZABLE`语义：

- Leader使用单调时钟计算本任期内的超时，不把不同节点墙上时钟直接比较。
- Leader切换后，新 Leader不能把未重建的租约立即判死；进入 `leader-grace-period`并等待 Provider携带 sessionId续约。
- 宽限期结束仍未续约的实例，通过一个 Raft命令转为 `SUSPECT/DOWN`，该可见状态变化才递增 `directoryRevision`。
- SDK本地隔离只影响当前进程选址，不能直接写成全局 DOWN；Registry健康状态仍以租约和主动探测为准。

Raft日志和状态机快照是 Registry权威恢复来源。快照必须包含最后包含的 term/index、schemaVersion和校验和；安装快照后继续重放后续日志。备份只能在已应用 index上生成，并记录集群ID和成员信息；恢复演练必须证明 revision不回退、commandId去重窗口仍有效且旧集群不能同时对外写入。

### 6.4 租约

- Provider默认每 5 秒续约。
- 约 15 秒未续约进入 `SUSPECT`。
- 高频心跳仅更新 Leader内存，不写入 Raft日志。
- 首次注册、注销和可见健康变化写入 Raft。
- Leader切换后为全部已提交临时实例提供至少一个租约周期的宽限期。
- 旧 sessionId 不能续约新的注册会话。

### 6.5 健康状态

```text
UP → SUSPECT → DOWN → RECOVERING → UP
```

判断信号：

1. Provider租约。
2. Registry主动 readiness 探测。
3. SDK调用结果形成的本地隔离。

本地隔离不能直接覆盖全局状态。实例恢复后默认连续健康 30 秒才从 `RECOVERING` 转为 `UP`。

### 6.6 REST 与 SSE

主要 API：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `POST` | `/api/v1/auth/tokens` | 使用 Client身份兑换短期令牌 |
| `POST` | `/api/v1/registrations` | 注册临时实例 |
| `PUT` | `/api/v1/registrations/{instanceId}/lease` | 续约 |
| `DELETE` | `/api/v1/registrations/{instanceId}` | 注销 |
| `GET` | `/api/v1/catalog/namespaces/{namespace}/groups/{group}/services/{serviceName}/snapshot` | 获取作用域内全量快照 |
| `GET` | `/api/v1/catalog/events?namespace={namespace}&group={group}&serviceName={serviceName}` | 按单个 `ServiceKey` 订阅 SSE目录事件 |
| `PUT` | `/api/v1/clients/{clientInstanceId}/heartbeat` | 上报 SDK Client轻量状态 |
| `POST` | `/api/v1/admin/static-instances` | 创建静态实例 |
| `PATCH` | `/api/v1/admin/instances/{instanceId}` | 权重或上下线 |

除令牌接口外，调用方必须携带 `Authorization: Bearer <access-token>` 和 `X-Request-Id`；所有写接口还必须携带稳定的 `X-Command-Id`。修改已有资源时使用 `If-Match: <resource-version>` 防止覆盖并发变更。注册请求示例：

持久读接口统一接受 `consistency=LINEARIZABLE|STALE`和可选的 `minimumReadIndex=<long>`。未指定时，管理、鉴权和路由诊断使用 `LINEARIZABLE`，只读监控总览可显式使用 `STALE`。所有持久读响应均返回以下元数据，让调用方能判断数据来源和新旧：

| 字段 | 含义 |
| --- | --- |
| `servedBy` | 实际服务节点 ID |
| `term` | 响应时节点已知 Raft term |
| `appliedIndex` | 已应用到本地状态机的最大日志 index |
| `directoryRevision` | 该响应所属的可见目录版本 |
| `consistency` | 实际执行的 `LINEARIZABLE`或 `STALE`，不允许暗中降级 |

统一错误码至少包含 `CONSISTENCY_UNAVAILABLE`、`RESOURCE_VERSION_CONFLICT`、`COMMAND_ID_CONFLICT`和 `CATALOG_REVISION_GAP`。前三者分别映射 HTTP 503、HTTP 412和 HTTP 409；资源版本冲突响应必须携带当前 `resourceVersion`，但不返回可被误用为成功的更新结果。

注册请求示例：

```http
POST /api/v1/registrations HTTP/1.1
Authorization: Bearer <access-token>
X-Request-Id: 01J3M7ST8Y0P3J2G86KX8G5R3P
X-Command-Id: 01J3M7T8F70NDNHD7CJHWP7W4Q
Content-Type: application/json

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

```json
{
  "registrationId": "reg-01J3M7V01Q8XF3M3S8AJQB6R8A",
  "sessionId": "ses-01J3M7V4Q1VVR6A26GQBS9RHQX",
  "instanceId": "topo-node-01",
  "directoryRevision": 1024,
  "resourceVersion": 1,
  "minimumReadIndex": 2987,
  "leaseExpiresAt": "2026-07-24T10:30:15Z"
}
```

快照响应必须返回完整作用域、revision 和不可变实例列表：

```json
{
  "schemaVersion": 1,
  "consistency": "LINEARIZABLE",
  "servedBy": "registry-1",
  "term": 42,
  "appliedIndex": 2987,
  "directoryRevision": 1024,
  "service": {
    "namespace": "customer-a-prod",
    "group": "DEFAULT_GROUP",
    "serviceName": "topo-service"
  },
  "generatedAt": "2026-07-24T10:30:00Z",
  "instances": [
    {
      "instanceId": "topo-node-01",
      "baseUri": "https://topo-01.example.internal:8180",
      "weight": 100,
      "cluster": "default",
      "healthStatus": "UP",
      "lifecycle": "EPHEMERAL",
      "resourceVersion": 7
    }
  ]
}
```

所有失败响应使用统一错误结构，HTTP状态码表达协议语义，`code` 表达稳定业务分类：

```json
{
  "requestId": "01J3M7ST8Y0P3J2G86KX8G5R3P",
  "code": "CATALOG_REVISION_GAP",
  "message": "目录事件已过期，请重新拉取全量快照",
  "retryable": true,
  "details": {
    "minimumAvailableRevision": 1010
  }
}
```

SSE事件只包含版本化变更，一条连接只订阅一个完整 `ServiceKey`。Consumer携带该 `ServiceKey` 最后应用的 `directoryRevision` 作为 `Last-Event-ID` 重连；事件历史已清理或 revision不连续时，服务端返回 `CATALOG_REVISION_GAP`，SDK立即重新拉取该服务全量快照。

### 6.7 安全

- 节点间使用 mTLS。
- Provider、Consumer和控制台 API使用 TLS。
- `clientId + secret` 兑换短期令牌。
- secret仅保存强哈希。
- 访问令牌使用短期签名 JWT；三个节点挂载同一套令牌签名材料，任一节点都能本地验签。
- 控制台会话使用集群共享密钥签名并加密的 Cookie，不在单节点内存保存登录态。
- 权限绑定 namespace、group、服务模式和操作。
- 支持当前/下一密钥重叠轮换。
- 注册、注销、静态实例、权重、身份和权限操作全部审计。

权限动作：

```text
REGISTER
DISCOVER
VIEW
OPERATE
SECURITY_ADMIN
SYSTEM_ADMIN
```

## 7. 统一控制台实现

### 7.1 技术栈

```text
Vue 3 + TypeScript + Vite
Vue Router
Pinia
TanStack Query
Element Plus
ECharts
Axios + Zod
Vitest + Vue Test Utils
Playwright
```

所有 SFC 使用 Composition API 和 `<script setup lang="ts">`。Route Page只负责组合 feature，不承载完整业务逻辑。

### 7.2 前端目录

```text
console-web/src/
├── app/
│   ├── App.vue
│   ├── router.ts
│   ├── query-client.ts
│   └── permissions.ts
├── layouts/
│   ├── ConsoleLayout.vue
│   └── AuthLayout.vue
├── pages/
│   ├── LoginPage.vue
│   ├── OverviewPage.vue
│   ├── ServicesPage.vue
│   ├── ServiceDetailPage.vue
│   ├── ClientsPage.vue
│   ├── ClientDetailPage.vue
│   ├── RouteDiagnosticsPage.vue
│   ├── ClusterPage.vue
│   ├── IdentitiesPage.vue
│   ├── ApprovalsPage.vue
│   ├── AuditPage.vue
│   └── SettingsPage.vue
├── features/
│   ├── auth/
│   ├── overview/
│   ├── service-catalog/
│   ├── instance-management/
│   ├── client-observability/
│   ├── route-diagnostics/
│   ├── cluster-health/
│   ├── identity-access/
│   ├── approvals/
│   ├── audit/
│   └── settings/
├── shared/
│   ├── api/
│   ├── components/
│   ├── composables/
│   ├── charts/
│   ├── validation/
│   ├── types/
│   └── utils/
└── tests/
```

### 7.3 页面

| 路由 | 页面 |
| --- | --- |
| `/auth/login` | 内置账户登录 |
| `/overview` | 服务、实例、Client和集群总览 |
| `/services` | 服务目录 |
| `/services/:serviceKey` | 实例、权重、健康和流量详情 |
| `/clients` | SDK Client在线目录 |
| `/clients/:clientInstanceId` | 快照、连接和本地隔离详情 |
| `/route-diagnostics` | 只读路由模拟 |
| `/cluster` | Leader、term、提交和副本状态 |
| `/identities` | 身份、权限和密钥轮换 |
| `/approvals` | 待审批和我的申请 |
| `/audit` | 控制面审计 |
| `/settings` | namespace、group和默认策略 |

### 7.4 状态管理

Pinia只保存：

- 当前登录用户。
- 当前 namespace/group作用域。
- 菜单和显示偏好。

TanStack Query管理：

- 服务、实例和Client。
- 集群、身份、审批和审计。
- Prometheus指标。
- 请求状态、缓存、轮询和失效刷新。

页面首次进入通过 REST 获取完整数据。SSE只推送资源失效事件，前端根据 queryKey精准刷新，不直接把 SSE payload当作最终业务对象。

### 7.5 SDK Client 在线目录

SDK默认每 15 秒上报轻量心跳：

```json
{
  "clientInstanceId": "yunkan-node-01",
  "applicationName": "yunkan",
  "sdkVersion": "<sdk-version>",
  "javaVersion": "17",
  "namespace": "customer-a-prod",
  "group": "DEFAULT_GROUP",
  "snapshotRevision": 1024,
  "snapshotAgeSeconds": 3,
  "registryConnectionState": "CONNECTED",
  "localEjections": [
    {
      "instanceId": "topo-node-01",
      "reason": "CONNECT_FAILURE",
      "until": "2026-07-24T10:30:00Z"
    }
  ]
}
```

心跳只更新 Leader内存，不写 Raft。只在 `ONLINE/OFFLINE` 等可见状态变化时发布事件。不得上传请求体、业务响应、原始 affinity ID或敏感 Header。

任意 Registry节点收到 Client心跳时都内部转发给 Leader；Leader不可用时返回可重试错误，SDK按端点列表切换。Client列表、Client详情和带 `clientInstanceId` 的路由诊断属于 Leader内存视图，Follower必须代理到 Leader，不得用本地空数据冒充成功结果。

### 7.6 Prometheus

支持两种模式：

1. 连接客户已有 Prometheus。
2. 离线包提供可选 Prometheus部署。

浏览器不直接访问 Prometheus。`observability-prometheus` 负责：

- Query API代理。
- 查询模板和标签白名单。
- 超时、短缓存和并发限制。
- Prometheus未配置或不可用时的明确降级。

Prometheus不可用时，服务管理、实例操作和Client在线状态仍可使用，历史图表显示“指标服务不可用”。

### 7.7 路由诊断

诊断 API只模拟，不发送真实业务请求：

```http
POST /console/api/v1/route-simulations
```

```json
{
  "serviceName": "topo-service",
  "affinityKey": "887c6df24830c9e4",
  "clientInstanceId": "yunkan-node-01"
}
```

返回快照 revision、脱敏 affinity hash、候选排序、权重及排除原因。原 affinity key只在请求内存中使用，不落库、不写日志、不进入 URL和浏览器持久存储。

### 7.8 登录、权限与审批

首版提供内置管理员账户和可扩展认证 SPI：

- 密码使用强哈希。
- 首次登录强制修改初始密码。
- 后续可接 OAuth2/OIDC。
- 页面和 API同时校验 RBAC，不能只依赖前端隐藏按钮。
- 登录会话使用 `Secure + HttpOnly + SameSite=Lax` Cookie，访问令牌不写入 localStorage或 sessionStorage。
- 所有修改请求校验 CSRF Token和 Origin，登录、改密和密钥轮换接口单独限流。
- 连续登录失败触发渐进延迟和临时锁定，认证失败分支记录不含密码/令牌的 WARN审计日志。
- 响应设置严格 CSP、`frame-ancestors 'none'`、`X-Content-Type-Options: nosniff` 和合理的 Referrer Policy。
- 前端默认转义用户输入，禁止使用未净化的 `v-html`；后端对所有分页、排序、过滤、PromQL模板参数和相对路径执行白名单校验。

角色：

- `VIEWER`
- `OPERATOR`
- `SECURITY_ADMIN`
- `SYSTEM_ADMIN`

普通权重调整等操作要求二次确认。批量下线、身份删除和权限提升要求双人审批：申请人与审批人不能相同，审批绑定资源版本，资源变化后原申请失效。

### 7.9 控制台高可用与交付

- `console-web` 独立开发和测试。
- 构建产物复制到 `registry-server` 静态资源目录。
- 三个 Registry节点携带相同前端资源。
- 浏览器通过 VIP、Nginx或 Kubernetes Service访问任意节点。
- 服务目录、身份、审批和审计等持久读请求使用当前节点已提交状态。
- Client在线目录和其他 Leader内存视图由 Follower内部转交 Leader；无 Leader时返回明确降级状态。
- 写请求由 Follower内部转交 Leader。
- SSE断开后浏览器自动重连到可用节点。
- 首版只交付 `zh-CN`，所有文案按 i18n key组织。

## 8. API 与配置

### 8.1 控制台 API

| 方法 | 路径 | 权限 |
| --- | --- | --- |
| `POST` | `/console/api/v1/auth/login` | 匿名 |
| `POST` | `/console/api/v1/auth/logout` | 已登录 |
| `GET` | `/console/api/v1/overview` | VIEWER |
| `GET` | `/console/api/v1/services` | VIEWER |
| `GET` | `/console/api/v1/services/{serviceKey}` | VIEWER |
| `PATCH` | `/console/api/v1/instances/{instanceId}` | OPERATOR |
| `GET` | `/console/api/v1/clients` | VIEWER |
| `GET` | `/console/api/v1/clients/{clientInstanceId}` | VIEWER |
| `POST` | `/console/api/v1/route-simulations` | VIEWER |
| `GET` | `/console/api/v1/cluster` | VIEWER |
| `GET/POST` | `/console/api/v1/identities` | SECURITY_ADMIN |
| `POST` | `/console/api/v1/identities/{id}/rotate-secret` | SECURITY_ADMIN |
| `GET/POST` | `/console/api/v1/approvals` | 按动作判断 |
| `POST` | `/console/api/v1/approvals/{id}/approve` | 对应审批角色 |
| `GET` | `/console/api/v1/audit-events` | SECURITY_ADMIN |
| `GET` | `/console/api/v1/events` | VIEWER |

所有列表 API使用游标分页，过滤字段白名单，排序字段白名单。所有写请求支持 requestId和幂等命令 ID。

### 8.2 配置文件

可复制示例：

1. [Registry Server 配置](./references/registry-server.example.yaml)
2. [SDK Client 配置](./references/sdk-client.example.yaml)
3. [Prometheus 告警规则](./references/prometheus-alerts.example.yaml)

敏感配置必须通过环境变量、挂载文件或密钥系统提供，不允许直接写入 YAML。

### 8.3 协议版本

REST路径使用主版本 `/api/v1`。JSON增加字段必须向后兼容；删除或改变字段语义需要提升主版本。SSE事件包含：

```json
{
  "schemaVersion": 1,
  "revision": 1024,
  "type": "INSTANCE_HEALTH_CHANGED",
  "serviceKey": "customer-a-prod/DEFAULT_GROUP/topo-service",
  "resourceId": "topo-node-01"
}
```

公共 `sdk-api` 使用 Revapi或 japicmp建立二进制兼容门禁。

## 9. 部署步骤

### 9.1 前置条件

- 三个互相可达的稳定节点。
- 每个节点有独立持久磁盘和稳定 nodeId。
- 时钟同步。
- 为节点间、Client和控制台准备 DNS或稳定地址。
- JDK 17或 JDK 21。
- 可选 Prometheus。

### 9.2 部署资源规划

以下规格以单客户环境 200 个服务、2,000 个实例、目录变更低于每秒 20 次、在线 SDK Client不超过 500 个为初始假设，最终规格必须以 10.5 容量测试结果校准。

单机模式只用于研发和演示，不提供 Raft多数派和节点故障容忍：

| 节点 | 机器规格 | 组件部署 | 实例数量 | 资源备注 |
| --- | --- | --- | --- | --- |
| dev-01 | 4 vCPU、8 GiB内存、50 GiB SSD | Registry、Console、可选 Prometheus | Registry 1、Console内嵌 1 | JVM初始 2 GiB、最大 4 GiB；数据和指标使用不同目录 |

生产高可用模式：

| 节点组 | 机器规格 | 节点数量 | 组件部署 | 实例数量 | 资源备注 |
| --- | --- | --- | --- | --- | --- |
| registry | 每节点 4 vCPU、8 GiB内存、100 GiB SSD | 3 | Registry、内嵌 Console | 每节点 1 | 每节点独立故障域和数据盘；JVM初始 2 GiB、最大 4 GiB |
| access | 每节点 2 vCPU、2 GiB内存、20 GiB磁盘 | 2 | Nginx或等价四层/七层入口 | 每节点 1 | 健康检查 `/actuator/health/readiness`，不保存会话状态 |
| metrics | 4 vCPU、8 GiB内存、按保留期配置 SSD | 1 或复用现有集群 | Prometheus | 1 | 可选组件；不影响注册和发现主链路 |

生产环境至少预留 30% CPU、内存和磁盘空间。Raft数据盘不得与高吞吐业务日志共用；磁盘使用率达到 70% 告警，达到 85% 前必须扩容或执行已验证的快照清理。

### 9.3 建议端口

| 端口 | 用途 | 暴露范围 |
| --- | --- | --- |
| `9443` | REST、SSE和控制台 HTTPS | 授权业务网络 |
| `9858` | Ratis节点通信 | 仅三个 Registry节点 |
| `9090` | 可选 Prometheus | 仅 Registry/运维网络 |

端口可配置，但同一部署的配置必须一致。

### 9.4 构建

```bash
cd affinity-route
mvn -T1C clean verify
cd console-web
npm ci
npm run typecheck
npm run test
npm run build
cd ..
mvn -pl distribution -am package -Poffline
```

构建流程必须把 `console-web/dist` 复制进 `registry-server` 发行资源，并生成包含所有 Maven/npm依赖的离线包。

### 9.5 初始化证书与身份

```bash
./distribution/bin/init-pki.sh \
  --output ./runtime/pki \
  --nodes registry-01,registry-02,registry-03

./distribution/bin/init-admin.sh \
  --output ./runtime/secrets/admin-initial-password

./distribution/bin/init-cluster-secrets.sh \
  --token-key ./runtime/secrets/token-signing.key \
  --token-certificate ./runtime/pki/token-signing.crt \
  --session-key ./runtime/secrets/session-signing.key
```

脚本只将初始密码和集群签名材料写入权限受限文件，不打印到标准输出。三个 Registry节点必须安全分发同一套令牌和会话签名材料；首次登录后必须修改密码。

### 9.6 三节点配置

每个节点复制参考配置，并修改：

- `node-id`
- `advertised-address`
- `data-directory`
- 证书文件路径

三个节点的 peers列表必须完全一致。

### 9.7 启动顺序

```bash
./distribution/bin/preflight.sh --config /etc/affinityroute/registry.yaml
systemctl enable affinityroute-registry@registry-01
systemctl start affinityroute-registry@registry-01
```

三个节点均启动后检查：

```bash
curl --cacert /etc/affinityroute/pki/ca.crt \
  https://registry.example.internal:9443/actuator/health
```

确认：

- 一个 Leader、两个 Follower。
- Raft Group成员一致。
- 三个磁盘目录可写。
- 节点证书身份匹配。
- 控制台能通过统一入口访问。

### 9.8 接入顺序

1. 先把现有固定 URL作为静态实例录入。
2. 云瞰引入 Starter并启用影子选址，只比较、不切流量。
3. 选择一个幂等读接口切换到 `LoadBalancerClient`。
4. 观察流量、失败和快照状态。
5. 新代码切换到 `ServiceHttpClient`。
6. 写接口确认服务端幂等后再启用重试。
7. Topo、森大屏接入 ProviderClient后移除对应静态实例。

## 10. 验证方式

### 10.1 单元测试

- 加权 HRW相同 ID稳定性。
- 权重 1:3 统计分布。
- 节点变化最小迁移。
- 确定性备用顺序。
- 加权最少并发和异常释放。
- deadline不能被重试重置。
- 非幂等写请求不重试。
- SelectionLease幂等关闭。
- 快照校验和、原子写入和损坏隔离。
- 状态机 commandId去重返回原结果，且不重复递增 revision。
- 相同 commandId更换请求载荷返回 HTTP 409和 `COMMAND_ID_CONFLICT`，不执行任何新变更。
- 两个并发 `If-Match` 更新只有一个成功，另一个返回 HTTP 412和 `RESOURCE_VERSION_CONFLICT`。
- SSE重复、缺口、乱序事件和全量快照回退均不得使 SDK revision回退。

### 10.2 组件测试

- 三节点 Ratis启动、选举和快照恢复。
- 已确认写入在任意单节点故障后仍可读取，剩余多数派可继续提交。
- 失去多数派拒绝写入。
- `LINEARIZABLE`读不返回已确认写入之前的旧值，无法确认多数派时返回 `CONSISTENCY_UNAVAILABLE`。
- `STALE`读允许返回旧值，但必须暴露 `servedBy`、`term`、`appliedIndex`和 `directoryRevision`。
- Leader切换租约宽限期。
- Leader租约重建和快照恢复后 `directoryRevision`不回退。
- REST/SSE鉴权、重连和事件缺口回退。
- ClientScope禁止跨 namespace。
- Spring Starter Bean覆盖和关闭顺序。

### 10.3 前端测试

- Vitest测试 composable、权限判断和 Zod校验。
- Vue Test Utils测试表格、表单、审批和错误状态。
- Playwright覆盖登录、服务查看、权重调整、审批、Client详情和路由诊断。
- 验证 Prometheus不可用时页面降级。
- 验证密钥只在创建或轮换时显示一次。

### 10.4 故障注入

使用 Testcontainers和 Toxiproxy覆盖：

1. 终止 Follower。
2. 终止 Leader。
3. 隔离一个节点形成少数派。
4. 断开 Consumer与三个 Registry的网络。
5. 注入业务实例连接失败、延迟和超时。
6. 损坏磁盘快照。
7. 快速反复恢复业务实例。

### 10.5 容量测试

固定记录测试环境和阈值，至少覆盖：

- 200 个服务。
- 2,000 个实例。
- 目标 Consumer数量。
- 目录快照大小和拉取延迟。
- SSE扇出和推送 P95/P99。
- SDK选址吞吐和内存。
- 主动健康探测峰值。
- Prometheus查询并发。

### 10.6 发布验收

```bash
mvn -T1C verify
npm --prefix console-web run typecheck
npm --prefix console-web run test
npm --prefix console-web run build
mvn -pl system-tests verify
mvn -pl performance-tests verify -Ptarget-scale
./distribution/bin/run-acceptance.sh
```

必须通过：

- Leader目标 10 秒内恢复写入。
- 当前 SDK连接失败后立即选择备用实例。
- 全局 DOWN目标 3 秒内推送。
- Registry全失联时快照调用继续。
- 同一 ID路由稳定。
- 权重分布在预设统计误差范围内。
- 离线环境安装不访问互联网。

## 11. 风险与边界

| 风险 | 缓解方式 |
| --- | --- |
| Leader内存租约在切换时丢失 | 新 Leader宽限期，Provider抖动重续 |
| 旧快照包含已下线实例 | SDK本地隔离、快照年龄告警、恢复后revision对账 |
| 写请求重试导致重复业务 | 默认禁止，必须显式幂等或幂等键 |
| SSE丢事件造成目录失真 | revision连续性校验、全量回退、低频对账 |
| 恢复实例导致大量 ID迁回 | RECOVERING观察期和客户端抖动 |
| 三节点只能容忍一个节点故障 | 明确故障域、磁盘和告警要求 |
| 主动探测形成流量尖峰 | 分片调度、抖动和有界执行器 |
| 控制台误操作 | RBAC、二次确认、双人审批和审计 |
| affinity ID泄露 | 只在内存计算，日志和响应仅保存不可逆哈希 |
| Prometheus不可用 | 管理功能保持可用，历史图表明确降级 |
| Ratis升级影响业务 | `ConsensusStore` 隔离依赖并锁定验证版本 |
| 线性读增加延迟，且失去多数派时不可用 | 仅在需要的路径默认线性读，监控总览显式使用带元数据的 `STALE`读，分别监控延迟和拒绝率 |
| commandId去重窗口过期后重试可能重复执行 | 公开去重保留时长和容量，SDK在窗口内完成重试，核心业务另设长期业务幂等键 |
| 备份恢复后旧集群与新集群同时写入造成分裂 | 恢复前隔离旧集群、校验 clusterId、换发访问入口和凭证，以单一写入集群为验收门禁 |
| 原生 Registry的共识、安全与升级维护超出团队能力 | 设置可量化退出条件，保留 Registry transport适配边界，门禁失败时切换成熟目录后端 |

## 12. 排障方式

| 现象 | 重点检查 | 处理方式 |
| --- | --- | --- |
| Provider注册失败 | TLS、令牌、Leader、REGISTER权限 | 查看结构化错误码和审计 |
| 实例频繁上下线 | 心跳延迟、主动探测、时钟、恢复观察期 | 调整阈值前先定位网络或服务抖动 |
| SDK一直使用磁盘快照 | Registry连接、SSE、令牌、revision | 检查 `DiscoveryStatus` 和重连指标 |
| 同一 ID路由不稳定 | instanceId、权重、目录revision、key规范化 | 比较路由诊断候选序列 |
| 请求大量重试 | 实例连接、超时预算、可重试状态码 | 检查 attempt指标和本地隔离 |
| 所有请求 Overloaded | 每实例并发、连接池、下游容量 | 扩容或调整经过压测的上限 |
| Registry不可写 | Raft多数派、节点网络、磁盘 | 恢复至少两个节点，不在少数派强写 |
| 控制台无历史图表 | Prometheus地址、权限、查询超时 | 管理功能可继续使用 |
| SSE反复断开 | 代理超时、TLS、节点切换 | 调整长连接代理配置并观察重连 |
| 快照损坏 | 校验和、磁盘空间和原子 rename支持 | 隔离损坏文件并在线拉全量 |

建议重点指标：

```text
affinityroute_registry_raft_writable
affinityroute_registry_raft_commit_latency_seconds
affinityroute_registry_raft_log_lag_entries
affinityroute_registry_catalog_revision
affinityroute_registry_sse_connections
affinityroute_registry_sse_delivery_latency_seconds
affinityroute_registry_sse_delivery_latency_seconds_bucket
affinityroute_client_connected
affinityroute_client_snapshot_age_seconds
affinityroute_lb_requests_total
affinityroute_lb_request_duration_seconds
affinityroute_lb_retries_total
affinityroute_lb_local_ejections
affinityroute_lb_no_available_instance_total
```

## 13. 实施计划

每项任务必须先写失败测试，再实现最小通过代码，并形成独立提交。

实施时按下表确定写入范围和验证入口；一个任务只允许修改“主要文件”列出的模块，公共契约变更必须先回到 T01：

| 任务 | 主要文件 | 首个失败测试 | 聚焦验证命令 |
| --- | --- | --- | --- |
| T01 工程与契约 | `pom.xml`、`sdk-api/src/main/java/cc/lvdaxianerplus/affinityroute/api/**`、`registry-protocol/src/main/java/cc/lvdaxianerplus/affinityroute/protocol/**` | `architecture-tests/src/test/java/cc/lvdaxianerplus/affinityroute/architecture/ModuleDependencyTest.java` | `mvn -pl architecture-tests -am test` |
| T02 负载算法 | `lb-core/src/main/java/cc/lvdaxianerplus/affinityroute/loadbalancer/**` | `lb-core/src/test/java/cc/lvdaxianerplus/affinityroute/loadbalancer/WeightedRendezvousHashTest.java`、`WeightedLeastConcurrencyTest.java` | `mvn -pl lb-core -am test` |
| T03 目录状态机 | `registry-ratis/src/main/java/cc/lvdaxianerplus/affinityroute/registry/ratis/catalog/**` | `CatalogStateMachineTest`先覆盖 commandId原结果、If-Match竞争和revision确定性 | `mvn -pl registry-ratis -am test` |
| T04 Ratis适配 | `registry-ratis/src/main/java/cc/lvdaxianerplus/affinityroute/registry/ratis/consensus/**` | `ThreeNodeConsensusTest`先覆盖已确认写不丢失、ReadIndex线性读和快照恢复 | `mvn -pl registry-ratis -am verify` |
| T05 注册与健康 | `registry-server/src/main/java/cc/lvdaxianerplus/affinityroute/registry/server/registration/**`、`health/**` | `LeaseLifecycleTest`先覆盖 Leader切换宽限期、会话重建和可见健康版本 | `mvn -pl registry-server -am test` |
| T06 REST/SSE与安全 | `registry-server/src/main/java/cc/lvdaxianerplus/affinityroute/registry/server/api/**`、`security/**`、`events/**` | `RegistryContractTest`先覆盖读一致性参数、响应元数据、412/503错误和SSE缺口 | `mvn -pl registry-server -am verify` |
| T07 Provider与Discovery | `registry-client/src/main/java/cc/lvdaxianerplus/affinityroute/client/**` | `DiscoveryRecoveryTest`先覆盖重复/乱序/缺口事件、快照回退拒绝和磁盘恢复 | `mvn -pl registry-client -am verify` |
| T08 HTTP治理 | `lb-http-client/src/main/java/cc/lvdaxianerplus/affinityroute/http/**` | `lb-http-client/src/test/java/cc/lvdaxianerplus/affinityroute/http/RetryDeadlineTest.java`、`LocalEjectionTest.java` | `mvn -pl lb-http-client -am verify` |
| T09 Starter与迁移 | `lb-spring-boot-starter/src/**`、`registry-static/src/**`、`examples/**` | `lb-spring-boot-starter/src/test/java/cc/lvdaxianerplus/affinityroute/starter/AffinityRouteAutoConfigurationTest.java` | `mvn -pl lb-spring-boot-starter,examples -am verify` |
| T10 控制台后端 | `console-api/src/**`、`observability-prometheus/src/**` | `console-api/src/test/java/cc/lvdaxianerplus/affinityroute/console/ApprovalWorkflowTest.java` | `mvn -pl console-api,observability-prometheus -am verify` |
| T11 控制台前端 | `console-web/src/**`、`console-web/tests/**` | `console-web/src/features/service-catalog/ServicesTable.spec.ts`、`console-web/tests/critical-flow.spec.ts` | `npm --prefix console-web run typecheck && npm --prefix console-web run test && npm --prefix console-web run test:e2e` |
| T12 发行与验收 | `distribution/**`、`system-tests/**`、`performance-tests/**` | `RegistryFailoverTest`先覆盖单节点故障后确认写可读、线性读不倒退和备份恢复防分裂 | `mvn -pl system-tests,performance-tests,distribution -am verify -Ptarget-scale,offline` |

每个任务的固定执行顺序为：新增单一行为测试并确认按预期失败，完成最小实现，运行聚焦命令，再运行 `mvn -T1C verify`；涉及前端时追加 typecheck、Vitest、构建和 Playwright。随后核对本节交付标准、执行完整 diff审查并提交。任何公共 API、wire schema、配置键或指标名变更都必须同步兼容性测试和示例配置。

### 13.1 工程与公共契约

1. 建立 Maven reactor、BOM、JDK 17/21 CI和模块依赖测试。
2. 定义 `registry-protocol` wire DTO、错误码和 schemaVersion。
3. 定义 `sdk-api` 四类 Client、不可变模型、异常和二进制兼容门禁。

交付标准：空模块全量构建通过，ArchUnit证明公共 API不依赖实现技术。

### 13.2 负载均衡核心

1. 实现加权 Rendezvous Hash及性质测试。
2. 实现确定性备用序列和恢复迁回。
3. 实现加权最少并发和 `SelectionLease`。
4. 实现亲和键提取 SPI。

交付标准：相同 ID稳定、权重分布和节点变化迁移率通过自动化阈值。

### 13.3 目录状态机与 Raft

1. 实现确定性目录状态机、commandId去重、If-Match并发控制和原子revision。
2. 实现状态机快照和恢复。
3. 通过 `ConsensusStore` 接入三节点 Ratis并实现 `ReadIndex`线性读。
4. 验证 Follower写引导、确认写故障后不丢失、少数派拒写、线性读和节点追平。

交付标准：三节点故障集成测试通过，无外部数据库。

### 13.4 注册、租约和健康

1. 实现临时/静态实例应用服务。
2. 实现 Leader内存租约和切换宽限期。
3. 实现主动 readiness探测。
4. 实现 `UP/SUSPECT/DOWN/RECOVERING` 状态机。

交付标准：租约、探测和恢复场景使用虚拟时钟稳定测试。

### 13.5 REST、SSE与安全

1. 实现应用身份、令牌、权限和密钥轮换。
2. 实现注册、续约、注销和快照 REST API。
3. 实现 `LINEARIZABLE|STALE`读参数、minimumReadIndex、元数据和统一一致性错误。
4. 实现有界 SSE事件窗口和版本缺口处理。
5. 实现审计和 Micrometer指标。

交付标准：契约、鉴权、慢 Consumer和断线恢复集成测试通过。

### 13.6 Provider与Discovery Client

1. 实现 `DefaultProviderClient` 和 `RegistrationHandle`。
2. 实现 `DefaultDiscoveryClient`、全量拉取和 SSE订阅。
3. 实现不可变内存目录、单调revision、事件缺口回退和原子磁盘快照。
4. 实现端点切换、退避、抖动和关闭语义。

交付标准：WireMock集成测试覆盖 Leader切换、失联和快照恢复。

### 13.7 HTTP调用治理

1. 实现 `DefaultLoadBalancerClient` 和并发许可。
2. 实现 `DefaultServiceHttpClient`、安全目标解析和 HttpClient 5 Transport。
3. 实现 deadline、幂等性和确定性重试。
4. 实现本地隔离、half-open和 bulkhead。
5. 实现指标、安全日志和异常映射。

交付标准：一次调用固定 revision，非幂等写不重复，所有资源可关闭。

### 13.8 Spring Boot Starter与迁移

1. 实现 Consumer自动配置和 Bean覆盖点。
2. 实现 Provider实际端口自动注册和优雅下线。
3. 实现静态 DiscoveryClient和影子选址。
4. 提供 Provider、Consumer和迁移示例。

交付标准：Spring Boot 3.5.x、JDK 17/21示例端到端通过。

### 13.9 统一控制台

1. 实现内置登录、RBAC和认证 SPI。
2. 实现服务、实例、Client、集群、身份和审计 API。
3. 实现 Client心跳在线目录。
4. 实现审批工作流和资源版本检查。
5. 实现 Prometheus查询适配。
6. 实现 Vue应用壳、权限路由和 TanStack Query基础设施。
7. 实现全部页面和错误/空/加载状态。
8. 实现只读路由诊断。
9. 完成 Vitest、组件测试和 Playwright核心流程。

交付标准：所有页面在 Prometheus正常和不可用两种模式下均有正确状态。

### 13.10 离线部署与发布

1. 制作三节点离线包、systemd、证书和预检脚本。
2. 提供可选 Prometheus离线部署。
3. 执行三节点故障、实例故障和快照损坏测试。
4. 执行已确认写不丢失、线性读不倒退、幂等重试和SSE收敛系统测试。
5. 执行 200 服务/2,000 实例容量测试。
6. 完成备份恢复、防分裂、升级回滚和云瞰影子迁移演练。

交付标准：同一发布候选通过全量构建、故障、容量、离线安装和回滚门禁。

## 14. 后续演进

完成首版后可按真实业务压力演进：

1. 增加 OAuth2/OIDC企业身份适配器。
2. 增加异步和响应式 Java调用 API，但保持同步 API兼容。
3. 增加更多 Transport实现。
4. 增加多 Raft Group分片，前提是单 Group容量数据证明需要。
5. 增加跨地域只读目录副本和明确的故障切换策略。
6. 增加非 Java SDK，并复用同一协议兼容测试。
7. 增加基于审批的灰度权重计划和定时变更。

## 15. 参考资料

- [Nacos官方介绍](https://nacos.io/docs/latest/what-is-nacos/)
- [Nacos GitHub仓库](https://github.com/alibaba/nacos)
- [Registry Server 配置示例](./references/registry-server.example.yaml)
- [SDK Client 配置示例](./references/sdk-client.example.yaml)
- [Prometheus 告警规则示例](./references/prometheus-alerts.example.yaml)

正式开发前需要在依赖兼容任务中锁定 Spring Boot 3.5.x、Apache Ratis、Apache HttpClient 5、Vue和构建插件的具体补丁版本，并将版本写入父 BOM和兼容矩阵。不要在未经验证的情况下使用浮动版本。
