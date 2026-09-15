## Why

产品架构已经定义知识加工、后端和浏览器插件，但尚未固化实际仓库结构和 Java 构件命名。没有这一约定时，后续初始化容易出现项目目录、Maven 坐标和包名不一致的问题。

## What Changes

- 将产品仓库名称和顶层工程结构固定为 `ProjectIQ/backend`、`ProjectIQ/skills` 与 `ProjectIQ/plugins`。
- 将后端 Maven 构件固定为 `io.github.lvdaxianer.dinghai:knowledge-assistant`。
- 将 Java 根包固定为 `io.github.lvdaxianer.dinghai.projectiq`，并记录后端业务模块边界。
- 在架构方案中说明 `skills`、浏览器扩展 `plugins` 与后端的职责和依赖方向。

## Capabilities

### New Capabilities

- `projectiq-engineering-layout`: 定义 ProjectIQ 仓库、后端构件、Java 包名和子工程边界的稳定约定。

### Modified Capabilities

无。

## Impact

影响产品知识助手架构文档、工程初始化模板与后续后端、Skill、浏览器扩展的代码落点；不新增运行时 API、数据库或外部依赖。
