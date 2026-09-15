# 可执行 Skill 模板

以下四个目录可直接复制到 Codex 或 Claude 的 Skills 根目录。`knowledge-loop-protocol` 是共享规则，后三个是执行角色。

## 1. `knowledge-loop-protocol/SKILL.md`

```md
---
name: knowledge-loop-protocol
description: 共享产品知识加工的文件、JSON、概念、本体关系和判定协议。
---

# Knowledge Loop Protocol

使用 `knowledge-package.schema.json` 和 `checker-verdict.schema.json` 作为唯一结构化契约。

- 可信目录中的每份知识必须由 `A.md` 和 `A.knowledge.json` 配对组成。
- SHA-256 基于 Markdown 原始 UTF-8 内容计算，格式为 `sha256:<64位小写十六进制>`。
- 概念类型仅为 `feature`、`action`、`entity`、`state`、`rule`、`exception`、`role`。
- 关系类型仅为 `parent_of`、`has_part`、`creates`、`requires`、`governed_by`、`exception_of`、`overrides`、`related_to`。
- 关系 quote 必须逐字出现在同一知识包所指 section.content 中。
- `canonicalAliases` 必须来自原文；`queryAliases` 可是无新增事实的口语同义表达。
```

## 2. `knowledge-producer/SKILL.md`

```md
---
name: knowledge-producer
description: 从产品 Markdown 生成或修复完整知识包候选。
---

# Knowledge Producer

先读取 `knowledge-loop-protocol`。你接收 source、sourceHash、graphContext、previousKnowledge 和可选 checkerVerdict。

create 模式：按 Markdown 标题生成可独立回答的 sections；抽取 concepts、aliases 和带原文 quote 的 relations；优先复用 graphContext 中等价 conceptId。

repair 模式：逐项修复 checkerVerdict 中所有 severity=error 的问题；输出完整 candidate，不输出补丁。

禁止：使用原文外产品事实；将别的文档作为当前文档证据；发明关系类型；写入可信目录。

输出：candidate.json 和 `CANDIDATE_READY` 结果，包含 sourceHash、candidateHash、candidatePath、resolvedIssueIds。
```

## 3. `knowledge-checker/SKILL.md`

```md
---
name: knowledge-checker
description: 独立核验产品 Markdown 与候选知识包，返回 PASS、FAIL 或 ERROR。
---

# Knowledge Checker

先读取 `knowledge-loop-protocol`。只读取 source、candidate、graphContext、previousKnowledge；不要读取 Producer 的推理过程。

按以下顺序检查：source key/hash；章节内容、摘要、标题和行锚点；概念复用与类型；关系白名单、方向、两端和 quote；旧关系的 retain/retire 影响；JSON Schema。

PASS：输出 sourceHash、candidateHash 和 checkedCounts。
FAIL：输出每个阻塞问题的 issueId、code、candidatePath、message、requiredAction。
ERROR：仅用于不可读输入、协议版本不支持等 Producer 无法推断修复的问题。

不要修改 candidate，不要发布知识包，不要放宽无证据事实。
```

## 4. `knowledge-orchestrator/SKILL.md`

```md
---
name: knowledge-orchestrator
description: 调度 Producer 与 Checker，将指定 Markdown 文件或目录加工为可信产品知识包。
---

# Knowledge Orchestrator

先读取 `knowledge-loop-protocol`。输入为一个 .md 文件、包含 .md 的目录，或显式 remove 请求。可信输出目录为系统固定配置。

目录输入：递归发现 Markdown，按文件名字典序逐一处理。每份文件处理时，从可信目录聚合 graphContext；更新 A.md 时排除旧 A.knowledge.json，但把它作为 previousKnowledge。

单份文档循环：
1. 计算 sourceHash。
2. 调用同一个 Producer Agent 的 create 或 repair 模式。
3. 调用独立 Checker Agent。
4. PASS 且 sourceHash、candidateHash、Schema 均一致时，原子写入 A.md 与 A.knowledge.json 到可信目录。
5. FAIL 时把 verdict 原样交回同一个 Producer，最多五轮。
6. ERROR、文件变化或超过五轮时失败退出，保留旧可信包。

总控不得改写候选内容或 Checker 结论。输出总计：成功/失败文件、轮次、sections、concepts、relations 和失败原因。
```

## 5. 文件引用

复制 Skill 时，将[知识包 Schema](./knowledge-package.schema.json)与[判定 Schema](./checker-verdict.schema.json)放到共享协议 Skill 可读取的位置，并在三个执行 Skill 中引用该路径。
