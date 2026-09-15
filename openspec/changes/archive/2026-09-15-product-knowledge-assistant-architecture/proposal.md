## Why

企业产品文档通常分散、篇幅不一且表述存在同义差异，单纯依靠关键词或将全文直接交给大模型会导致召回遗漏、跨文档规则缺失和答案不可控。需要一套可由 Codex 或 Claude 加工文档、由 Java 服务稳定检索并通过浏览器插件提供单轮流式问答的独立产品架构。

## What Changes

- 定义由总控、生产者和检查者三种 Skill 组成的知识加工 General Loop。
- 定义 Markdown 配套知识包、概念、本体关系和关系证据的统一契约。
- 定义 Java Spring Boot、SQLite、Qdrant 与 OpenAI 兼容网关组成的单租户后端架构。
- 定义“语义召回、本体推理、LLM 重排序、证据回答”的检索链路和 SSE 接口。
- 定义浏览器插件边界、手动目录导入、故障处理、观测与验收方案。

## Capabilities

### New Capabilities

- `knowledge-processing-loop`: 将指定路径下的产品 Markdown 逐份加工为可信知识包的三角色 Skill 协作能力。
- `ontology-backed-retrieval`: 使用向量召回、SQLite 本体关系扩展和 LLM 重排序生成有证据的单轮回答。
- `browser-assistant-delivery`: 通过浏览器插件和 SSE 向用户展示流式答案与文档、章节来源的交付能力。
- `knowledge-import-and-indexing`: 从可信目录手动导入知识包、同步 SQLite 与 Qdrant 的能力。

### Modified Capabilities

- 无。

## Impact

- 新增“产品知识本体问答助手”方案目录和根目录索引项。
- 新增三个可执行 Skill 及共享协议的设计契约，运行在 Codex 或 Claude 中，不依赖线上后端。
- 后续实现将引入 Spring Boot、SQLite、Qdrant、OpenAI 兼容模型网关和浏览器扩展工程，但本次仅产出架构与验收方案。
