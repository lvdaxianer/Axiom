## Context

现有方案描述了离线 Skill、Java 后端和浏览器插件的职责，但没有规定它们在实际产品仓库中的落点。`ProjectIQ` 是产品仓库名；后端发布构件仍使用“知识助手”的业务名称，避免将仓库名和 Maven 构件名混为一谈。

## Goals / Non-Goals

**Goals:**

- 固定三类工程的顶层目录和依赖方向。
- 固定 Java 根包和 Maven 坐标，使后续代码、配置和部署脚本可预测。
- 让架构文档与 OpenSpec 规格成为工程初始化的唯一命名依据。

**Non-Goals:**

- 不在本变更中初始化 Spring Boot、浏览器扩展或实际 Skill 文件。
- 不创建 Maven 多模块聚合工程，不改变已有知识处理、检索和 SSE 契约。

## Decisions

### ProjectIQ 使用单仓库三子工程布局

采用 `ProjectIQ/backend`、`ProjectIQ/skills`、`ProjectIQ/plugins`，并在根目录保留运行时知识目录与部署文件。这样 Skill 可被 Codex 或 Claude 单独加载，浏览器扩展可用自己的 Node 工具链构建，后端保持 Maven 生命周期；不采用将三者塞进同一个 Maven 多模块工程的方式。

### 后端构件与 Java 包名分别表达发布能力和产品归属

Maven 使用 `io.github.lvdaxianer.dinghai:knowledge-assistant`，Java 根包使用 `io.github.lvdaxianer.dinghai.projectiq`。构件名面向制品仓库和部署，包名面向产品代码边界；因此不使用过于宽泛的 `io.github.lvdaxianer.dinghai.*` 作为业务类直接根目录。

### 后端按业务能力分包

在根包下按 `knowledge`、`retrieval`、`chat`、`integration`、`config` 与 `shared` 分组。模块内部可采用 `api`、`application`、`domain`、`infrastructure`、`repository` 的轻量分层；不以全局 `controller/service/mapper` 作为唯一组织方式。

## Risks / Trade-offs

- [`ProjectIQ` 与 `knowledge-assistant` 名称不同] → 在根 README 和后端 `pom.xml` 同时说明二者分别是产品仓库名和后端构件名。
- [目录规划先于代码] → 以 OpenSpec 场景和文档链接校验锁定约定，实际初始化时再补充构建验证。
