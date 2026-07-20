# Elasticsearch 7.10.2 ARM64 离线三节点集群实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` task-by-task. The main agent owns task selection, merge review, verification, OpenSpec markers, canonical review and commits.

**Goal:** 交付一个可在麒麟 V10 ARM64 离线 Kubernetes 环境中安装的三节点 Elasticsearch 7.10.2 Helm Chart。

**Architecture:** 原生 StatefulSet 管理三个混合角色节点，共享 NFS hostPath 按 Pod 隔离数据，独立 NFS volume 保存快照，MetalLB LoadBalancer 暴露固定 TLS 地址。Chart 使用 Helm Secret 生成/复用、NetworkPolicy、PDB 和 bootstrap Hook Job 管理安全与初始化。

**Tech Stack:** Helm 4、Kubernetes YAML、Elasticsearch 7.10.2、Bats、PyYAML、OpenSpec。

## 1. Chart 契约与三节点核心集群

- [x] 1.1 以测试先行方式实现 Chart schema、helpers、三节点 StatefulSet、Headless Service、Elasticsearch 配置、可复用 Secret、共享 NFS 独立数据目录和 PDB

**Task boundary and agent dispatch**

| Field | Value |
| --- | --- |
| Module agent | `elasticsearch-core-chart-agent` |
| Owned responsibility | 建立可渲染的 Chart 契约和不依赖公网的三节点核心集群 |
| Allowed files | `Elasticsearch离线三节点集群/chart/Chart.yaml`, `values.yaml`, `values.schema.json`, `templates/_helpers.tpl`, `templates/configmap.yaml`, `templates/headless-service.yaml`, `templates/credentials-secret.yaml`, `templates/tls-secret.yaml`, `templates/statefulset.yaml`, `templates/pdb.yaml`, `tests/render_test.bats`, `tests/assert_render.py`, `tests/fixtures/valid-values.yaml` |
| Out of scope | MetalLB HTTP Service、NetworkPolicy、快照 Hook、README、远程镜像操作、OpenSpec 文件 |
| Dependencies | 已批准的 proposal、design 和三个 capability specs |
| Focused verification | `bats Elasticsearch离线三节点集群/chart/tests/render_test.bats --filter 'core cluster'` |
| Broader verification | `helm lint Elasticsearch离线三节点集群/chart -f Elasticsearch离线三节点集群/chart/tests/fixtures/valid-values.yaml && helm template es-cluster Elasticsearch离线三节点集群/chart -n uino -f Elasticsearch离线三节点集群/chart/tests/fixtures/valid-values.yaml >/tmp/es-rendered.yaml` |
| Handoff evidence | RED 失败原因、GREEN 输出、渲染资源清单、所有触及文件列表 |

Implementation sequence:

1. 在 Bats 中先增加 `core cluster` 测试；测试调用 `helm template`，再由 `assert_render.py` 使用 `yaml.safe_load_all` 断言 StatefulSet 副本数为 3、角色完整、Headless Service、PDB、强制反亲和、hostPath、`subPathExpr`、TLS/认证配置和私有 digest 镜像。
2. 运行 focused verification，预期因 Chart 或资源尚不存在而失败，记录 RED 输出。
3. 创建 `Chart.yaml`、严格的 `values.schema.json` 和 `values.yaml`。测试 fixture 使用 `registry.internal.example/uino/elasticsearch:7.10.2-arm64-hardened@sha256:1111111111111111111111111111111111111111111111111111111111111111`、`192.0.2.50` 固定 IP和 `192.0.2.60:/exports/es-snapshots`。
4. 实现 helpers、ConfigMap、Headless Service、Secret、StatefulSet 和 PDB。密码与 TLS 在首次安装生成，后续通过 `lookup` 复用；数据根目录固定为 `/data/uinnova/apps/es`，Pod 仅挂载自身子目录。
5. 重新运行 focused verification，预期所有 `core cluster` 测试通过。
6. 运行 broader verification，完成计划一致性审计与 canonical `code-review-spec`，修复后再次执行 focused 和 broader verification。
7. 主 agent 将任务 1.1 标记完成，并用 `✨ feat(es): 建立离线三节点集群核心` 创建包含 OpenSpec 初始资产的原子提交。

## 2. MetalLB 固定 IP 与网络访问控制

- [ ] 2.1 以测试先行方式实现固定 IP LoadBalancer Service、MetalLB legacy annotations、来源 CIDR、可选共享键和只允许授权流量的 NetworkPolicy

**Task boundary and agent dispatch**

| Field | Value |
| --- | --- |
| Module agent | `elasticsearch-access-agent` |
| Owned responsibility | 实现外部 HTTPS `9200` 固定 IP 暴露和 Pod 网络访问边界 |
| Allowed files | `Elasticsearch离线三节点集群/chart/values.yaml`, `values.schema.json`, `templates/http-service.yaml`, `templates/networkpolicy.yaml`, `tests/render_test.bats`, `tests/assert_render.py`, `tests/fixtures/valid-values.yaml` |
| Out of scope | StatefulSet 数据与启动逻辑、Secret 内容、快照、README、远程镜像、OpenSpec 规格 |
| Dependencies | Task 1.1 已提交 |
| Focused verification | `bats Elasticsearch离线三节点集群/chart/tests/render_test.bats --filter 'secure access'` |
| Broader verification | `bats Elasticsearch离线三节点集群/chart/tests/render_test.bats && helm lint Elasticsearch离线三节点集群/chart -f Elasticsearch离线三节点集群/chart/tests/fixtures/valid-values.yaml` |
| Handoff evidence | RED/GREEN 输出、Service 与 NetworkPolicy 结构化断言结果、触及文件列表 |

Implementation sequence:

1. 先添加 `secure access` Bats/PyYAML 断言，覆盖 `type: LoadBalancer`、固定 IP、`first-pool`、`loadBalancerIPs`、`layer2`、来源 CIDR、不暴露 `9300` 和仅同集群 Pod 可进入 `9300`。
2. 增加两个负面用例：固定 IP 为空时渲染失败；`allowSharedIP=false` 时不得出现注解，显式启用时必须使用 `sharedIPKey` 而不是 `"true"`。
3. 运行 focused verification，预期因 HTTP Service 与 NetworkPolicy 尚不存在而失败。
4. 扩展 values/schema 并实现 `http-service.yaml` 和 `networkpolicy.yaml`；合并 `service.annotations`，但禁止覆盖固定 IP、地址池和共享键的安全默认逻辑。
5. 运行 focused verification，预期通过；再运行 broader verification。
6. 完成计划一致性审计与 canonical `code-review-spec`，修复后重复验证。
7. 主 agent 标记任务 2.1 完成，并用 `✨ feat(es): 增加固定IP安全访问` 创建原子提交。

## 3. NFS 快照仓库与 SLM 初始化

- [ ] 3.1 以测试先行方式实现独立 NFS 快照挂载、`path.repo`、仓库注册与验证、SLM 策略和失败可观测的 Helm Hook Job

**Task boundary and agent dispatch**

| Field | Value |
| --- | --- |
| Module agent | `elasticsearch-snapshot-agent` |
| Owned responsibility | 实现快照配置、挂载、初始化 API 调用和保留策略 |
| Allowed files | `Elasticsearch离线三节点集群/chart/values.yaml`, `values.schema.json`, `templates/configmap.yaml`, `templates/statefulset.yaml`, `templates/snapshot-job.yaml`, `tests/render_test.bats`, `tests/assert_render.py`, `tests/fixtures/valid-values.yaml` |
| Out of scope | 数据 hostPath 模型、HTTP Service、NetworkPolicy、证书生成、README、远程镜像、OpenSpec 规格 |
| Dependencies | Tasks 1.1 和 2.1 已提交 |
| Focused verification | `bats Elasticsearch离线三节点集群/chart/tests/render_test.bats --filter 'snapshot'` |
| Broader verification | `bats Elasticsearch离线三节点集群/chart/tests/render_test.bats && helm lint Elasticsearch离线三节点集群/chart -f Elasticsearch离线三节点集群/chart/tests/fixtures/valid-values.yaml && helm template es-cluster Elasticsearch离线三节点集群/chart -n uino -f Elasticsearch离线三节点集群/chart/tests/fixtures/valid-values.yaml >/tmp/es-rendered.yaml` |
| Handoff evidence | RED/GREEN 输出、快照 Job API 请求断言、NFS/path.repo 断言、触及文件列表 |

Implementation sequence:

1. 先添加 `snapshot` 结构化断言，覆盖 NFS server/export、三个 ES Pod 的统一 mountPath、`path.repo`、Hook annotations、digest 固定镜像、Secret 认证挂载和有界重试。
2. 添加仓库 `PUT /_snapshot/<name>`、`POST /_snapshot/<name>/_verify`、`PUT /_slm/policy/<name>` 的请求体断言，以及 API 失败时非零退出的脚本断言。
3. 添加负面用例：`snapshot.enabled=true` 且任一必要字段为空时模板渲染必须失败。
4. 运行 focused verification，预期因快照 volume、配置或 Job 缺失而失败。
5. 扩展 values/schema，修改 ConfigMap/StatefulSet，并创建 post-install/post-upgrade `snapshot-job.yaml`。Job 复用加固 Elasticsearch 镜像，不引入第二个公共镜像。
6. 运行 focused verification 和 broader verification，完成计划一致性审计与 canonical `code-review-spec`，修复后重复验证。
7. 主 agent 标记任务 3.1 完成，并用 `✨ feat(es): 配置NFS快照与保留策略` 创建原子提交。

## 4. 离线镜像准备、交付文档与 Chart 打包

- [ ] 4.1 在授权 ARM64 服务器准备并核验加固镜像，完成客户 values 示例、安装验收文档、根索引和可重复 Chart 包

**Task boundary and agent dispatch**

| Field | Value |
| --- | --- |
| Module agent | `elasticsearch-delivery-main` |
| Owned responsibility | 远程镜像准备、无敏感信息的交付证据、部署/回滚/快照恢复文档和 Chart 打包 |
| Allowed files | `Elasticsearch离线三节点集群/README.md`, `Elasticsearch离线三节点集群/chart/values.customer.example.yaml`, `Elasticsearch离线三节点集群/chart/tests/delivery_test.bats`, `Elasticsearch离线三节点集群/references/镜像交付清单.md`, `README.md`；远程服务器仅允许 Docker 镜像拉取、加固、扫描/检查和导出操作 |
| Out of scope | 保存服务器登录凭据、私有仓库凭据、私钥或镜像 tar 到 Git；修改 Chart 运行模板；修改用户已有的无关文件 |
| Dependencies | Tasks 1.1、2.1、3.1 已提交；客户授权的远程服务器可访问官方镜像仓库 |
| Focused verification | `bats Elasticsearch离线三节点集群/chart/tests/delivery_test.bats` |
| Broader verification | `bats Elasticsearch离线三节点集群/chart/tests/*.bats && helm lint Elasticsearch离线三节点集群/chart -f Elasticsearch离线三节点集群/chart/tests/fixtures/valid-values.yaml && rm -rf /tmp/es-chart-package && mkdir -p /tmp/es-chart-package && helm package Elasticsearch离线三节点集群/chart --destination /tmp/es-chart-package` |
| Handoff evidence | ARM64 inspect 输出、加固镜像 digest、Log4j 检查、安全扫描结果或扫描工具不可用说明、Chart 包路径与 SHA-256、无凭据扫描结果 |

Direct execution fallback: 该任务涉及用户提供的远程服务器凭据和外部 Docker 状态，不能将敏感凭据传递给子 agent；主 agent 直接执行，凭据只用于交互式连接且不写入文件、命令参数、Git 或报告。

Implementation sequence:

1. 先编写 `delivery_test.bats`，断言客户 values 示例不包含真实凭据、README 覆盖离线安装/升级/回滚/卸载/固定 IP/NFS/快照恢复，根 README 包含方案索引，交付清单包含架构与 digest 字段。
2. 运行 focused verification，预期因客户 values、索引和交付清单尚不存在而失败。
3. 通过交互式 SSH 在授权服务器上确认 `uname -m`、Docker 可用性和磁盘空间；拉取官方 `linux/arm64` 7.10.2 镜像，删除所有 `log4j-core` 中的 `JndiLookup`，构建加固镜像并核验该类已不存在。
4. 执行镜像架构 inspect、安全扫描（服务器有可用扫描器时）和 digest 记录；推送已配置的客户私有仓库，若仓库信息未提供则导出 tar 保存在远程服务器并记录绝对路径及 SHA-256，不下载到本地 Git 工作树。
5. 使用文档占位示例值 `192.0.2.50`、`192.0.2.60` 和 `registry.internal.example` 创建客户 values 示例；实际客户 IP、NFS 和仓库值仅在部署时覆盖。
6. 完善 README、镜像交付清单和根索引，运行 focused 与 broader verification，并对打包结果执行 `shasum -a 256 /tmp/es-chart-package/*.tgz`。
7. 完成计划一致性审计、canonical `code-review-spec` 和敏感信息扫描，修复后重复全部验证。
8. 主 agent 标记任务 4.1 完成，并用 `📚 docs(es): 完善离线交付与验收说明` 创建原子提交。
