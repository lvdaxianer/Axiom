# Elasticsearch Chart 全文件注释设计

## 目标

为 `Elasticsearch离线三节点集群/chart` 下每个源文件增加中文说明，使交付和后续维护人员能够快速理解文件职责、关键配置、安全边界与测试意图，同时保证 Helm 渲染结果和 Elasticsearch 运行行为不变。

## 范围

覆盖 Chart 元数据、默认与客户 values、JSON Schema、全部 Helm 模板、Bats 测试、Python 结构化断言及测试 fixture。生成缓存、Chart 压缩包和其他二进制交付物不在范围内。

## 注释策略

### YAML 与 Helm 模板

每个文件顶部说明该文件创建的资源或承担的职责。对集群引导、Secret 复用、证书 SAN、NFS 数据隔离、MetalLB 保留注解、NetworkPolicy、快照 Hook、失败处理及数据保留等非显然逻辑增加就近中文注释。显然的 Kubernetes 字段不逐行复述。

Helm 控制语句优先使用不会进入渲染清单的模板注释；需要交付给运维查看的运行约束使用 YAML 注释。注释不得包含密码、私钥、真实客户地址或登录信息。

### Values 与 Schema

`values.yaml`、客户示例和测试 fixture 按配置分组说明用途、允许值以及需要客户替换的内容。`values.schema.json` 保持严格 JSON，不使用非法的 `//` 或 `#` 注释，而是在对象和关键属性上增加标准 JSON Schema `description`。

### Python 与 Bats

Python 文件保留模块说明和完整函数文档，补充常量组及复杂结构化断言的意图。Bats 文件说明测试套件用途、公共辅助函数以及每个场景的前置条件和结果。已有准确注释不重复堆叠。

## 质量边界

- 注释统一使用中文，产品名、API、字段名和命令保持原文。
- 注释解释为什么存在约束以及失败后的影响，不复述代码字面含义。
- 不修改资源名称、默认值、schema 约束、Hook 行为、测试断言或文件拆分。
- 每个 Chart 源文件必须具有可识别的文件职责说明；JSON Schema 以顶层 `description` 作为等价文件说明。
- 新增说明不得包含真实服务器凭据、仓库凭据、Elasticsearch 密码或证书材料。

## 验证

先增加注释覆盖审计，验证每个文件都存在相应的文件说明，并确认 JSON Schema 使用合法 `description`。随后执行全部 Bats 测试、`helm lint --strict`、两次关键 values 渲染、Python 静态检查、JSON 解析和敏感信息扫描。比较注释前后的结构化 Helm 输出，确认资源语义没有漂移。

## 交付结果

完成后，Chart 目录内每个源文件都能在文件本身说明用途；复杂安全和数据生命周期逻辑具有就近说明；运维人员无需依赖外部上下文即可理解安装参数与风险边界。
