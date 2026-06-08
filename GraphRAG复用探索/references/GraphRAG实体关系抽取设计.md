# GraphRAG 实体关系抽取设计

**日期**: 2026-06-08  
**状态**: 草案  
**目标**: 定义智能问答平台中实体、关系、证据的抽取结构、提示词模板、校验规则和合并策略。

---

## 1. 抽取目标

对每个 `text_unit` 进行局部知识图谱抽取，得到：

- 实体列表
- 实体关系列表
- 支撑证据
- 来源 text_unit

之后再将所有局部结果合并为全局实体表和关系表。

```text
text_unit
 -> raw_entities / raw_relationships
 -> merged_entities / merged_relationships
 -> entity_embeddings
 -> local_search
```

---

## 2. GraphRAG 原版做法

GraphRAG 原版使用自定义 tuple 文本协议，而不是 JSON。

实体格式：

```text
("entity"<|><entity_name><|><entity_type><|><entity_description>)
```

关系格式：

```text
("relationship"<|><source_entity><|><target_entity><|><relationship_description><|><relationship_strength>)
```

记录分隔符：

```text
##
```

完成标记：

```text
<|COMPLETE|>
```

原版优点是简单、节省 token；缺点是解析脆弱，不适合复杂校验。智能问答平台建议保留其抽取思想，但输出格式升级为 JSON Schema。

---

## 3. 推荐实体类型

第一版建议使用通用实体类型：

```text
PERSON
ORG
LOCATION
EVENT
CONCEPT
PRODUCT
SYSTEM
POLICY
PROCESS
DOCUMENT
METRIC
OTHER
```

后续可以按知识库领域配置实体类型。例如运维知识库可增加：

```text
SERVICE
HOST
CLUSTER
DATABASE
MIDDLEWARE
ALERT
LOG_SOURCE
CONFIG
```

---

## 4. LLM 输出结构

### 4.1 ExtractGraphResult

```json
{
  "entities": [
    {
      "name": "string",
      "canonical_name": "string",
      "type": "PERSON | ORG | LOCATION | EVENT | CONCEPT | PRODUCT | SYSTEM | POLICY | PROCESS | DOCUMENT | METRIC | OTHER",
      "description": "string",
      "evidence": "string"
    }
  ],
  "relationships": [
    {
      "source": "string",
      "target": "string",
      "type": "string",
      "description": "string",
      "weight": 1,
      "evidence": "string"
    }
  ]
}
```

### 4.2 字段说明

```text
entities[].name
- 原文中的实体名称

entities[].canonical_name
- 规范化名称，用于跨 chunk 合并实体

entities[].type
- 实体类型，只能来自配置列表

entities[].description
- 实体在当前 text_unit 中的属性、职责、行为或上下文说明

entities[].evidence
- 支撑该实体抽取的原文短句

relationships[].source
- 关系源实体 canonical_name

relationships[].target
- 关系目标实体 canonical_name

relationships[].type
- 关系类型，例如 depends_on、belongs_to、causes、mentions、uses、owns

relationships[].description
- 为什么这两个实体有关

relationships[].weight
- 关系强度，1 到 10

relationships[].evidence
- 支撑该关系的原文短句
```

---

## 5. 主抽取提示词

```text
你是一个知识图谱抽取器。请从给定文本中抽取实体和实体之间的明确关系。

要求：
1. 只抽取文本中明确出现或可直接推出的信息，不要猜测。
2. 实体类型只能从以下列表选择：
{entity_types}
3. 实体 name 保留原文名称。
4. 实体 canonical_name 使用统一、简洁、可合并的名称。
5. 关系必须发生在已抽取实体之间。
6. relationship.weight 使用 1-10，越强越高。
7. evidence 必须摘取能支持该实体或关系的原文短句。
8. 如果没有实体或关系，返回空数组。
9. 输出必须是合法 JSON，不要输出解释性文字，不要使用 Markdown 代码块。

输出格式：
{
  "entities": [
    {
      "name": "...",
      "canonical_name": "...",
      "type": "...",
      "description": "...",
      "evidence": "..."
    }
  ],
  "relationships": [
    {
      "source": "...",
      "target": "...",
      "type": "...",
      "description": "...",
      "weight": 1,
      "evidence": "..."
    }
  ]
}

文本：
{text}
```

---

## 6. 继续抽取提示词

GraphRAG 原版有 `gleaning` 机制：第一次抽完后，让模型继续补充遗漏实体和关系。

推荐保留一轮继续抽取。

```text
你刚才可能遗漏了部分实体或关系。请基于同一段文本继续补充遗漏项。

要求：
1. 只补充遗漏项，不要重复已有实体和关系。
2. 仍然只抽取文本中明确出现或可直接推出的信息。
3. 仍然使用相同 JSON 格式。
4. 如果没有遗漏项，返回：
{
  "entities": [],
  "relationships": []
}

已抽取结果：
{previous_result}

文本：
{text}
```

---

## 7. 是否继续提示词

如果后续希望支持多轮 gleaning，可以加入是否继续判断。

```text
根据原文和当前已抽取结果，是否仍有明显遗漏的实体或关系？

只回答一个字符：
Y 表示仍有遗漏
N 表示没有明显遗漏

当前结果：
{current_result}

文本：
{text}
```

第一版建议 `max_gleanings = 1`，避免抽取成本膨胀。

---

## 8. 抽取流程

```text
for each text_unit:
  1. 调用主抽取提示词
  2. JSON parse
  3. schema 校验
  4. 如果 parse 或 schema 失败，执行 repair
  5. 执行 0-1 次继续抽取
  6. 合并主结果与补充结果
  7. 清洗 canonical_name
  8. 丢弃 source / target 不存在的 relationship
  9. 写入 raw_entities / raw_relationships
```

---

## 9. 修复提示词

当模型输出不是合法 JSON 时，使用 repair prompt。

```text
下面内容应该是实体关系抽取结果，但不是合法 JSON。
请修复为合法 JSON，并保持原有信息，不要新增信息。

合法结构必须为：
{
  "entities": [],
  "relationships": []
}

待修复内容：
{invalid_output}
```

---

## 10. 校验规则

### 10.1 实体校验

- `canonical_name` 不能为空
- `type` 必须属于配置实体类型
- `description` 不能为空
- `evidence` 不能为空
- 同一个 text_unit 内 `canonical_name + type` 去重

### 10.2 关系校验

- `source` 和 `target` 不能为空
- `source` 和 `target` 必须能匹配已抽取实体
- `source` 不能等于 `target`
- `weight` 必须在 1 到 10 之间
- `description` 不能为空
- `evidence` 不能为空
- 同一个 text_unit 内 `source + target + type` 去重

---

## 11. 合并策略

### 11.1 合并实体

按以下键合并：

```text
canonical_name + type
```

合并后字段：

```text
title = canonical_name
type = type
description = descriptions 去重后合并
text_unit_ids = 来源 text_unit 去重
frequency = 出现次数
evidence = evidence 去重列表
```

### 11.2 合并关系

按以下键合并：

```text
source + target + type
```

合并后字段：

```text
source = source
target = target
type = type
description = descriptions 去重后合并
weight = weight 求和或平均
text_unit_ids = 来源 text_unit 去重
evidence = evidence 去重列表
```

第一版建议 `weight` 求和，因为出现次数越多，关系越重要。

---

## 12. 存储表

### 12.1 raw_entities

```text
raw_entities
- id
- text_unit_id
- document_id
- name
- canonical_name
- type
- description
- evidence
- created_at
```

### 12.2 raw_relationships

```text
raw_relationships
- id
- text_unit_id
- document_id
- source
- target
- type
- description
- weight
- evidence
- created_at
```

### 12.3 entities

```text
entities
- id
- title
- type
- description
- text_unit_ids
- frequency
- evidence
- rank
- created_at
- updated_at
```

### 12.4 relationships

```text
relationships
- id
- source
- target
- type
- description
- weight
- text_unit_ids
- evidence
- rank
- created_at
- updated_at
```

---

## 13. 质量控制

建议记录以下指标：

```text
extract_success_rate
json_parse_failure_count
schema_validation_failure_count
empty_result_count
entity_count_per_text_unit
relationship_count_per_text_unit
orphan_relationship_count
gleaning_added_entity_count
gleaning_added_relationship_count
```

这些指标用于判断 prompt 是否适合当前知识库。

---

## 14. 一句话定义

实体关系抽取的目标是把每个 text_unit 转换为可合并的小型知识图谱，并通过校验、去重和合并形成全局实体关系索引，为 Local GraphRAG 提供结构化检索入口。
