# Nginx 日志触发拓扑图资源同步方案

## 1. 背景

当前 A 系统需要在 B 系统保存拓扑图资源后尽快拉取最新数据，但前提是 B 系统不做任何代码改造。由于 B 不主动发送事件，A 无法严格实时感知保存动作，只能从 B 请求链路的外部信号中观察变化。

已知 B 的保存接口为：

```text
/thing-api/topo/eam/esDiagram/saveOrUpdateDiagramComponent
```

请求体中包含 `diagramId`：

```json
{
  "diagramId": "887c6df24830c9e4",
  "modifyTime": 20260519140156,
  "ADD": [],
  "UPDATE": []
}
```

目标是在 Nginx 作为网关的前提下，通过监听 Nginx access log 识别该保存请求，并把 `diagramId` 作为 `topoId` 发送给另一个服务：

```text
POST /projectScene/offlineTopo/sync
```

## 2. 总体链路

```text
用户在 B 系统保存拓扑图
  ↓
请求经过 Nginx
  ↓
Nginx 处理完成后写入专用 access log
  ↓
监听组件读取新增日志
  ↓
匹配目标 URI、POST 方法、2xx 状态码
  ↓
解析 request_body.diagramId
  ↓
调用 /projectScene/offlineTopo/sync，body 为 {"topoId":"diagramId"}
```

推荐保留一个低频定时任务作为兜底，例如每 10 或 30 分钟按更新时间做一次增量校验，用于修复日志漏读、监听服务停机、目标服务短暂不可用等异常。

## 3. Nginx 配置

### 3.1 专用 JSON 日志

不要监听总 `access.log`。Nginx 同时代理静态资源时，总日志会频繁变化，且会引入大量无关请求。建议只给目标保存接口单独写一份 JSON 日志。

```nginx
log_format topo_sync_json escape=json
  '{'
  '"time":"$time_iso8601",'
  '"request_id":"$request_id",'
  '"method":"$request_method",'
  '"uri":"$uri",'
  '"request_uri":"$request_uri",'
  '"status":$status,'
  '"request_time":$request_time,'
  '"request_body":"$request_body"'
  '}';

location = /thing-api/topo/eam/esDiagram/saveOrUpdateDiagramComponent {
    client_body_buffer_size 256k;
    client_body_in_single_buffer on;

    access_log /uinnova/nginx/nginx/logs/topo_save_or_update.log topo_sync_json;
    proxy_pass http://b_backend;
}
```

### 3.2 配置说明

1. `access_log` 默认在请求处理完成后写入，因此可以结合 `status` 判断保存接口是否成功。
2. `escape=json` 用于避免日志中的 JSON 字符串破坏外层 JSON 格式。
3. `$request_body` 只有在请求体被 Nginx 读取到内存 buffer 中时才可靠。
4. `client_body_buffer_size` 需要结合实际请求体大小设置，示例使用 `256k`。
5. `client_body_in_single_buffer on` 用于尽量保证 `$request_body` 可用。

## 4. 方案一：Vector 监听日志并触发服务

### 4.1 适用场景

适合希望少写代码、快速验证、并希望由成熟日志组件处理断点续读、日志轮转、缓冲和重试的场景。

链路：

```text
Nginx 专用日志
  ↓
Vector file source
  ↓
解析 JSON 日志
  ↓
解析 request_body
  ↓
过滤目标请求
  ↓
HTTP sink 调用 /projectScene/offlineTopo/sync
```

### 4.2 安装 Vector

Ubuntu 或 Debian：

```bash
bash -c "$(curl -L https://setup.vector.dev)"
sudo apt-get install vector
sudo systemctl enable --now vector
```

CentOS 或 RHEL：

```bash
bash -c "$(curl -L https://setup.vector.dev)"
sudo yum install vector
sudo systemctl enable --now vector
```

### 4.3 Vector 配置

配置文件示例：`/etc/vector/vector.toml`

最终可复制配置也单独放在：[vector配置-final.toml](./references/vector配置-final.toml)。

```toml
data_dir = "/var/lib/vector"

[sources.topo_nginx_log]
type = "file"
include = ["/uinnova/nginx/nginx/logs/topo_save_or_update.log"]
read_from = "end"

[transforms.parse_nginx_log]
type = "remap"
inputs = ["topo_nginx_log"]
source = '''
. = parse_json!(.message)
'''

[transforms.extract_topo_event]
type = "remap"
inputs = ["parse_nginx_log"]
source = '''
method = string(.method) ?? ""
uri = string(.uri) ?? ""
status = to_int(.status) ?? 0
request_body = string(.request_body) ?? ""

body = parse_json(request_body) ?? {}
topo_id = string(body.diagramId) ?? ""

.method_text = method
.uri_text = uri
.status_code = status
.topo_id = topo_id

.is_valid_topo_save = method == "POST" &&
  ends_with(uri, "/thing-api/topo/eam/esDiagram/saveOrUpdateDiagramComponent") &&
  status >= 200 &&
  status < 300 &&
  topo_id != ""
'''

[transforms.only_valid_topo_save]
type = "filter"
inputs = ["extract_topo_event"]
condition = '''
bool(.is_valid_topo_save) ?? false
'''

# 组装成后端需要的单个 JSON 对象：
# {"topoId":"xxx"}
#
# 这里使用 text 编码发送 .message，而不是 http sink 的 json 编码。
# Vector 0.33.1 的 http sink 使用 json 编码时会按批次发送 JSON 数组，
# 即使 max_events = 1，Spring 端接收单个 DTO 时也会报 START_ARRAY。
[transforms.prepare_listener_event]
type = "remap"
inputs = ["only_valid_topo_save"]
source = '''
topo_id = string!(.topo_id)
. = {}
.message = "{\"topoId\":\"" + topo_id + "\"}"
.topoId = topo_id
'''

# 调试用：命中目标保存请求时打印 topoId。
# 确认稳定后可以删除这个 sink。
[sinks.debug_matched_events]
type = "console"
inputs = ["prepare_listener_event"]
encoding.codec = "json"

[sinks.topo_listener]
type = "http"
inputs = ["prepare_listener_event"]
uri = "http://10.100.30.239:8180/projectScene/offlineTopo/sync"
method = "post"

# 这里不是鉴权，只是告诉 Spring 请求体是 JSON。
[sinks.topo_listener.headers]
Content-Type = "application/json"

[sinks.topo_listener.healthcheck]
enabled = false

# 使用 text，发送 .message 字段内容，避免 Vector 自动包成 JSON 数组。
[sinks.topo_listener.encoding]
codec = "text"

[sinks.topo_listener.batch]
max_events = 1
timeout_secs = 1

[sinks.topo_listener.buffer]
type = "disk"
max_size = 268435488
when_full = "block"
```

### 4.4 验证命令

```bash
sudo vector validate /etc/vector/vector.toml
sudo systemctl restart vector
sudo systemctl status vector
journalctl -u vector -f
```

### 4.5 权限要求

Vector 进程需要具备读取 `/uinnova/nginx/nginx/logs/topo_save_or_update.log` 以及进入 `/uinnova/nginx/nginx/logs` 目录的权限。可以通过日志文件所属组、ACL 或专用日志目录解决。

### 4.6 日志查看与后台运行

如果使用 systemd 安装 Vector，推荐后台运行：

```bash
sudo systemctl enable vector
sudo systemctl restart vector
sudo systemctl status vector
```

查看 Vector 实时日志：

```bash
journalctl -u vector -f
```

查看最近 200 行日志：

```bash
journalctl -u vector -n 200 --no-pager
```

## 5. 方案二：Docker 镜像 + Helm 部署到 Kubernetes

### 5.1 适用场景

适合现场环境通过私有仓库统一发版，并且希望在 Kubernetes 中运行 Vector，同时把运行配置和 checkpoint 数据持久化到宿主机的场景。

本方案默认：

- 命名空间：`uino`
- 宿主机持久化目录：`/data/uinnova/apps/vector`
- 宿主机 Nginx 日志文件：`/data/uinnova/apps/nginx/logs/sync_topo.log`

目录约定：

```text
/data/uinnova/apps/vector
├── config
│   └── vector.toml
└── data
```

### 5.2 镜像结构

仓库新增了以下交付物：

- 容器目录：`Nginx日志触发拓扑图资源同步/container`
- Helm Chart：`Nginx日志触发拓扑图资源同步/chart/vector-topo-sync`

镜像本身不把业务配置写死在镜像内，只做两件事：

1. 首次启动时，如果宿主机 `/data/uinnova/apps/vector/config/vector.toml` 不存在，就从 Chart 下发的默认模板复制一份到宿主机。
2. 之后始终以宿主机上的 `vector.toml` 启动，便于现场直接修改配置。

### 5.3 构建并推送到私有仓库

示例：

```bash
cd Nginx日志触发拓扑图资源同步/container

docker build \
  --platform linux/arm64 \
  -t registry.example.com/uino/vector-topo-sync:0.33.1 \
  .

docker push registry.example.com/uino/vector-topo-sync:0.33.1
```

说明：

- `vector-topo-sync:0.33.1` 是正式建议推送到私有仓库的镜像 tag。
- `vector-topo-sync:0.33.1-test` 只是开发验证阶段在测试机上临时使用的本地 tag，不是最终交付名称。
- 当前 Dockerfile 会在构建镜像阶段下载 Vector 官方二进制，因此镜像应在可联网的构建环境中生成，然后推送到客户私有仓库。
- 客户现场如果是离线环境，Pod 启动时不会再下载任何外网资源；运行时只会做本地目录创建、默认配置复制和 Vector 进程启动。

如果私有仓库需要先登录：

```bash
docker login registry.example.com
```

### 5.4 准备宿主机目录

在 Kubernetes 节点上执行：

```bash
mkdir -p /data/uinnova/apps/vector/config
mkdir -p /data/uinnova/apps/vector/data
mkdir -p /data/uinnova/apps/nginx/logs
touch /data/uinnova/apps/nginx/logs/sync_topo.log
```

如果你希望先手工准备配置文件，也可以直接放置：

```bash
vi /data/uinnova/apps/vector/config/vector.toml
```

如果不手工创建，Pod 首次启动时会自动生成一份默认配置。

离线环境说明：

- 客户环境离线时，只需要保证 Kubernetes 节点能够从私有仓库拉取已经构建好的镜像。
- 容器启动时不会执行 `curl`、`apt-get`、`apk add` 等下载动作。
- 启动流程只有三步：挂载宿主机目录、必要时生成 `/data/uinnova/apps/vector/config/vector.toml`、执行 `vector --config`。

### 5.5 使用 Helm 安装

示例安装命令：

```bash
helm upgrade --install vector-topo-sync \
  ./Nginx日志触发拓扑图资源同步/chart/vector-topo-sync \
  -n uino \
  --create-namespace \
  --set image.repository=registry.example.com/uino/vector-topo-sync \
  --set image.tag=0.33.1 \
  --set vector.sink.uri=http://10.100.30.239:8180/projectScene/offlineTopo/sync
```

如果私有仓库需要 `imagePullSecrets`：

```bash
helm upgrade --install vector-topo-sync \
  ./Nginx日志触发拓扑图资源同步/chart/vector-topo-sync \
  -n uino \
  --create-namespace \
  --set image.repository=registry.example.com/uino/vector-topo-sync \
  --set image.tag=0.33.1 \
  --set image.pullSecrets[0]=registry-secret \
  --set vector.sink.uri=http://10.100.30.239:8180/projectScene/offlineTopo/sync
```

### 5.5.1 现场最终命令

下面这组命令是当前确认后的现场执行版本，默认宿主机持久化目录为 `/data/uinnova/apps/vector`。

1. 准备宿主机目录：

```bash
mkdir -p /data/uinnova/apps/vector/config
mkdir -p /data/uinnova/apps/vector/data
mkdir -p /data/uinnova/apps/nginx/logs
touch /data/uinnova/apps/nginx/logs/sync_topo.log
```

2. 构建并推送 ARM64 镜像到私有仓库：

```bash
cd Nginx日志触发拓扑图资源同步/container

docker build \
  --platform linux/arm64 \
  -t registry.example.com/uino/vector-topo-sync:0.33.1 \
  .

docker push registry.example.com/uino/vector-topo-sync:0.33.1
```

3. 安装或升级 Helm 发布：

```bash
helm upgrade --install vector-topo-sync \
  ./Nginx日志触发拓扑图资源同步/chart/vector-topo-sync \
  -n uino \
  --create-namespace \
  --set image.repository=registry.example.com/uino/vector-topo-sync \
  --set image.tag=0.33.1 \
  --set vector.sink.uri=http://10.100.30.239:8180/projectScene/offlineTopo/sync
```

4. 如果私有仓库需要拉取密钥，先创建 secret：

```bash
kubectl create secret docker-registry registry-secret \
  -n uino \
  --docker-server=registry.example.com \
  --docker-username='<用户名>' \
  --docker-password='<密码>' \
  --docker-email='<邮箱>'
```

5. 带私有仓库拉取密钥的 Helm 安装命令：

```bash
helm upgrade --install vector-topo-sync \
  ./Nginx日志触发拓扑图资源同步/chart/vector-topo-sync \
  -n uino \
  --create-namespace \
  --set image.repository=registry.example.com/uino/vector-topo-sync \
  --set image.tag=0.33.1 \
  --set image.pullSecrets[0]=registry-secret \
  --set vector.sink.uri=http://10.100.30.239:8180/projectScene/offlineTopo/sync
```

### 5.6 配置暴露与持久化说明

该 Chart 会把以下路径挂载到 Pod：

- `/data/uinnova/apps/vector` -> 容器内 `/host-vector`
- `/data/uinnova/apps/nginx/logs/sync_topo.log` -> 容器内 `/host-nginx-log/input.log`

默认模板生成后的实际配置文件位置是：

```bash
/data/uinnova/apps/vector/config/vector.toml
```

运行中的 checkpoint、磁盘 buffer 数据位于：

```bash
/data/uinnova/apps/vector/data
```

如果你希望像 `217` 环境那样继续沿用“从 `request_body.diagramId` 提取值、再发送 `{"topoId":"..."}`”这套逻辑，默认 values 已经保持一致；只是容器化场景下默认监听的共享日志文件改成了 `/data/uinnova/apps/nginx/logs/sync_topo.log`。

如果现场要改监听规则或请求映射，直接调整以下 values 即可：

- `hostPaths.nginxLogFile`：宿主机上的完整日志文件路径，必须包含文件名
- `vector.source.requestMethod`：只匹配哪种入口请求方法
- `vector.source.requestPath`：只匹配哪个入口 URI
- `vector.source.successStatus.min` / `vector.source.successStatus.max`：只接收哪段状态码
- `vector.extract.requestBodyField`：从 `request_body` 里提取哪个字段，例如 `diagramId`
- `vector.extract.targetField`：发送给下游时 JSON body 使用哪个字段名，例如 `topoId`
- `vector.sink.method`：发给下游时使用什么 HTTP method
- `vector.sink.uri`：发给哪个下游地址

例如，下面这组默认值就对应当前 `217` 环境的行为：

```yaml
vector:
  source:
    requestMethod: POST
    requestPath: /thing-api/topo/eam/esDiagram/saveOrUpdateDiagramComponent
    successStatus:
      min: 200
      max: 299
hostPaths:
  nginxLogFile: /data/uinnova/apps/nginx/logs/sync_topo.log
  extract:
    requestBodyField: diagramId
    targetField: topoId
  sink:
    method: post
    uri: http://10.100.30.239:8180/projectScene/offlineTopo/sync
```

如果现场修改了宿主机配置文件，执行一次重启即可：

```bash
kubectl rollout restart deployment/vector-topo-sync -n uino
```

### 5.7 查看运行日志

查看 Pod 日志：

```bash
kubectl logs -n uino deploy/vector-topo-sync -f
```

查看渲染结果是否正确：

```bash
helm template vector-topo-sync \
  ./Nginx日志触发拓扑图资源同步/chart/vector-topo-sync
```

### 5.8 ARM64 / 麒麟现场说明

现场主机如果是 ARM64 架构，例如麒麟 V10 ARM 服务器，构建镜像时请明确指定：

```bash
--platform linux/arm64
```

只要现场 Kubernetes 节点可拉取该 ARM64 镜像，这套 Chart 不依赖发行版特性，麒麟 V10 与 Ubuntu ARM64 场景都可以使用。

临时前台调试时使用：

```bash
vector --config /etc/vector/vector.toml
```

如果需要看更详细的 Vector 内部日志，可以临时使用：

```bash
vector --config /etc/vector/vector.toml --verbose
```

`--verbose` 会输出大量 checkpoint、throughput、utilization 日志，只建议排障时短时间使用。

如果没有 systemd，也可以用 `nohup` 临时后台运行：

```bash
nohup vector --config /etc/vector/vector.toml > /var/log/vector.log 2>&1 &
```

查看 `nohup` 方式的日志：

```bash
tail -f /var/log/vector.log
```

停止 `nohup` 方式启动的 Vector：

```bash
ps -ef | grep vector
kill <pid>
```

## 5. 方案二：Java 自研日志监听服务

### 5.1 适用场景

适合希望所有逻辑都纳入 Java 服务体系，并统一接入现有配置中心、监控、告警、任务表和重试机制的场景。

链路：

```text
Nginx 专用日志
  ↓
Java tail 服务
  ↓
增量读取新增行
  ↓
解析日志 JSON
  ↓
解析 request_body.diagramId
  ↓
异步调用 /projectScene/offlineTopo/sync
```

### 5.2 核心处理逻辑

```java
void handleLine(String line) {
    NginxLog log = objectMapper.readValue(line, NginxLog.class);

    if (!"POST".equals(log.method())) {
        return;
    }

    if (!log.uri().endsWith("/thing-api/topo/eam/esDiagram/saveOrUpdateDiagramComponent")) {
        return;
    }

    if (log.status() < 200 || log.status() >= 300) {
        return;
    }

    JsonNode body = objectMapper.readTree(log.requestBody());
    String diagramId = body.path("diagramId").asText(null);

    if (diagramId == null || diagramId.isBlank()) {
        return;
    }

    listenerClient.post("/projectScene/offlineTopo/sync", Map.of("topoId", diagramId));
}
```

### 5.3 文件监听建议

Java 服务不要反复扫描完整日志文件，应维护 offset 增量读取。

```text
启动时读取本地 offset
  ↓
打开 /uinnova/nginx/nginx/logs/topo_save_or_update.log
  ↓
seek 到上次 offset
  ↓
读取新增行
  ↓
逐行解析并生成触发任务
  ↓
处理成功后持久化 offset
```

offset 文件示例：

```json
{
  "path": "/uinnova/nginx/nginx/logs/topo_save_or_update.log",
  "inode": "123456",
  "offset": 987654321
}
```

### 5.4 必须处理的边界

1. 服务重启后从上次 offset 继续读取，避免重复触发或漏触发。
2. 日志轮转时识别 inode 变化，重新打开新文件。
3. `copytruncate` 场景下识别文件大小小于已记录 offset，重置 offset。
4. 读取到末尾半行时先缓存，不处理不完整 JSON。
5. 监听线程只负责读日志和投递任务，不直接执行耗时同步。
6. `/projectScene/offlineTopo/sync` 调用失败时需要重试或落任务表。
7. 同一个 `diagramId` 短时间内多次保存时，建议合并触发，避免频繁拉取。

### 5.5 推荐内部结构

```text
LogTailer
  - 维护文件句柄、inode、offset、半行缓存

LogParser
  - 解析 Nginx JSON 日志
  - 解析 request_body
  - 提取 diagramId

TriggerDispatcher
  - 去重和合并
  - 投递到本地队列、MQ 或任务表

ListenerClient
  - 调用 /projectScene/offlineTopo/sync
  - 处理超时、重试、失败日志
```

## 6. 两种方案对比

| 维度 | Vector 方案 | Java 自研方案 |
| --- | --- | --- |
| 开发成本 | 低 | 中 |
| 运维组件 | 需要部署 Vector | 无额外日志组件 |
| 日志轮转处理 | Vector 内置处理 | 需要自行实现 |
| 断点续读 | Vector 内置 checkpoint | 需要自行实现 |
| 业务逻辑灵活性 | 中 | 高 |
| 可靠重试 | 依赖 Vector buffer 和 HTTP 重试配置 | 可接入任务表或 MQ |
| 推荐用途 | 快速验证和轻量生产 | 深度集成现有 Java 体系 |

推荐先使用 Vector 方案验证链路。如果后续需要复杂去重、任务状态、人工补偿、统一告警，再把触发逻辑收敛到 Java 服务或让 Vector 先写入 MQ，由 Java 消费。

## 7. 性能与安全注意事项

### 7.1 性能

1. 不要监听总 `access.log`，只监听专用日志文件。
2. 不要定时 `grep` 全文件，只能增量读取新增日志。
3. 监听组件命中日志后应异步触发，避免同步阻塞。
4. 如果保存请求频繁，按 `diagramId` 做短时间合并。
5. Nginx 日志需要配置 logrotate，避免磁盘持续增长。

### 7.2 安全

1. `$request_body` 会把完整请求体写入磁盘日志，可能包含敏感信息。
2. 本接口当前请求体包含图形节点数据，日志体积可能较大。
3. 日志文件权限需要收紧，只允许 Nginx、监听服务和运维账号读取。
4. 不建议把 access log 长期保留过久，可以单独设置较短保留周期。
5. 如果后续 body 中出现 token、密码、手机号等敏感字段，应改为在网关层只提取 `diagramId`，不要落完整 body。

## 8. 验收标准

1. 访问保存接口后，`/uinnova/nginx/nginx/logs/topo_save_or_update.log` 中出现一条 JSON 日志。
2. 日志中的 `uri` 以后缀匹配 `/thing-api/topo/eam/esDiagram/saveOrUpdateDiagramComponent`。
3. 日志中的 `status` 为 `2xx` 时才触发。
4. 监听组件能从 `request_body` 提取 `diagramId=887c6df24830c9e4`。
5. 目标服务收到请求：`POST /projectScene/offlineTopo/sync`，请求体为 `{"topoId":"887c6df24830c9e4"}`。
6. Nginx 日志轮转后，监听链路仍能继续工作。
7. 监听服务或目标服务短暂重启后，不出现大面积漏触发。

## 9. 推荐落地顺序

1. 先在测试环境给目标接口配置专用 Nginx JSON 日志。
2. 用手动请求验证 `$request_body` 中能看到 `diagramId`。
3. 部署 Vector，配置读取专用日志并调用测试服务。
4. 验证成功请求触发、失败请求不触发。
5. 验证日志轮转、服务重启和目标服务短暂不可用场景。
6. 若 Vector 方案满足要求，进入生产灰度。
7. 若需要复杂任务管理，再设计 Java 自研监听或 Java 消费 MQ 的版本。
