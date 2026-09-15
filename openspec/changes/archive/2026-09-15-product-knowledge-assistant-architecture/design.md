## Context

本变更定义一个独立、单租户的企业产品知识助手。产品资料经 Codex 或 Claude 中的三角色 Skill Loop 处理后，形成可信 Markdown 与知识包文件对；Java 服务再将其导入 SQLite 和 Qdrant，为浏览器插件提供单轮 SSE 问答。系统必须支持中文自然语言、跨文档规则和同名文档替换，同时避免将向量索引误当作事实来源。

## Goals / Non-Goals

**Goals:**

- 将产品 Markdown 加工为可验证的章节、概念、关系和证据。
- 使用语义召回与有界本体推理补足跨文档规则，再通过 LLM 重排序控制上下文。
- 用 Spring Boot、SQLite、Qdrant 和 OpenAI 兼容网关交付可恢复、可观测的单轮流式问答。
- 让可信目录成为后端唯一的外部知识输入，且只由 Checker PASS 的产物进入。

**Non-Goals:**

- 不建设多租户、SSO、用户权限过滤或多轮会话记忆。
- 不建设人工审核后台、OCR 解析服务、图数据库、RDF/OWL 推理引擎或自动目录监听。
- 不允许模型把未检索到的常识写成产品事实。

## Decisions

### 三角色 Skill General Loop

选择总控、生产者、检查者三个独立 Skill。总控负责输入、顺序调度、循环、哈希核验、成功输出和总计；生产者负责完整知识包；检查者独立给出 PASS/FAIL/ERROR。相比让单个 Agent 自审，这一结构将事实抽取与审查分离；相比先建设后端任务队列，它可直接在 Codex 或 Claude 中运行。

### Markdown Sidecar 知识包

选择 `A.md + A.knowledge.json`，而不是将结构嵌入 Frontmatter 或仅保存 JSON。Markdown 保留原始可读产品资料，JSON 提供稳定 ID、关系和证据；两者的 SHA-256 绑定防止校验结果误用于已变更原文。

### SQLite 为事实源，Qdrant 为派生索引

SQLite 保存文档、章节、概念、关系和关系证据，保证替换、删除和关系有效性可以事务化处理。Qdrant 仅保存章节向量和最少 payload，允许以 SQLite 全量重建。选择 Qdrant 而非 ChromaDB，是因为其过滤与 Java 服务集成更适合长期后端；不使用 SQLite 向量扩展以避免混合事实事务和向量索引职责。

### 有界图谱推理而非自由式 LLM 推理

选择 Java `OntologyReasoner` 在 SQLite 边表上遍历，不让 LLM 自由扩展知识。仅自动走强关系，最多四跳、八个概念、三份关联文档；三、四跳结果仍必须经过重排序才能进入答案上下文。该策略在保留跨文档能力的同时限制发散与 token 成本。

### 两次聊天模型调用

选择先用小上下文进行 JSON 重排序，再用完整精选证据进行 SSE 回答。Embedding 单独通过 OpenAI 兼容 `/embeddings` 接口调用。相比让最终模型直接检索并回答，分层流程更可观察、更可控制，也能避免将 20 至 30 个候选正文全部发送给模型。

### 手动导入和最终一致的索引同步

第一期选择内部管理资源 `POST /api/admin/knowledge-imports` 手动导入，而非文件监听。接口只接受内部运维身份或部署侧服务密钥，以 `source_key + content_hash` 幂等；SQLite 事务先提交，Qdrant 失败只形成可重试任务，不回滚事实数据。问答服务在索引未就绪时明确提示，避免旧向量与新事实混答。

## Risks / Trade-offs

- [概念命名受目录顺序影响] → 文件按稳定字典序处理，必要时使用数字前缀表达依赖顺序；Checker 以重复概念错误阻止漂移。
- [四跳推理扩大候选集] → 限制强关系、概念数、文档数，并将远距离候选交由重排序筛选。
- [云模型或 Qdrant 不可用] → 明确降级为无知识或索引更新状态，保留可重试同步任务，不生成无依据答案。
- [模型更换导致向量不兼容] → 新建 Qdrant collection、从 SQLite 全量重建、完成后切换 collection 配置。
- [Checker 持续失败] → 最大五轮后失败退出，保持旧可信知识包不变并提供最终结构化报告。

## Migration Plan

1. 创建可信知识目录和三 Skill 共享协议。
2. 用样本文档运行 General Loop，产出首批知识包。
3. 部署 SQLite 和 Qdrant，实施手动导入与全量建索引。
4. 实施检索、推理、重排序和 SSE API，使用固定问题集验证。
5. 部署浏览器插件并灰度验证单轮问答。
6. 回滚时切换到上一个可信目录快照或 SQLite 备份；Qdrant 可清空后从 SQLite 重建。

## Open Questions

- 部署环境中实际可用的中文多语言 embedding 模型、维度和网关限流参数需在实施前确认。
- 浏览器插件的固定客户端密钥放置与内网反向代理策略需在部署时确认。
