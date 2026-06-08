# GraphRAG 落地实施计划

**日期**: 2026-06-08  
**状态**: 草案  
**目标**: 将 GraphRAG 复用方案拆解为可逐步交付的工程任务。

---

## 1. 总体交付路径

```text
P0 基础 RAG
 -> P1 实体关系抽取
 -> P2 Local GraphRAG
 -> P3 Community GraphRAG
 -> P4 运营与质量增强
```

每个阶段都应能独立上线和验证，不要求一次性完成完整 GraphRAG。

---

## 2. P0 基础 RAG

### 2.1 目标

建立最小可用知识检索能力，为后续实体图谱索引提供基础数据。

### 2.2 数据表

```text
documents
text_units
text_unit_embeddings
```

### 2.3 任务

- 文档入库
- Markdown 切块
- 生成 text_units
- 生成 text_unit embedding
- 实现 basic_search
- 输出证据包

### 2.4 验收标准

- 给定问题能召回相关 text_units
- 回答中能返回引用来源
- 能记录召回耗时、召回数量、token 消耗

---

## 3. P1 实体关系抽取

### 3.1 目标

将 text_units 转换为实体和关系，形成基础知识图谱。

### 3.2 数据表

```text
raw_entities
raw_relationships
entities
relationships
entity_embeddings
```

### 3.3 任务

- 定义实体类型配置
- 定义关系抽取 JSON Schema
- 实现主抽取 prompt
- 实现继续抽取 prompt
- 实现 JSON repair
- 实现 schema 校验
- 实现 orphan relationship 过滤
- 实现实体合并
- 实现关系合并
- 生成 entity embedding

### 3.4 验收标准

- 单个 text_unit 能生成合法实体关系 JSON
- parse 失败可进入 repair
- 关系端点必须存在于实体集合中
- 合并后实体具有 `text_unit_ids` 和 `frequency`
- 合并后关系具有 `text_unit_ids` 和 `weight`

---

## 4. P2 Local GraphRAG

### 4.1 目标

实现实体优先检索：用户问题先匹配实体，再扩展关系和证据文本。

### 4.2 查询流程

```text
query
 -> entity embedding search
 -> matched entities
 -> related relationships
 -> related text_units
 -> structured context
 -> answer
```

### 4.3 任务

- 实现 query embedding
- 实现 entity similarity search
- 实现 include / exclude entity_names
- 根据实体查找一跳关系
- 根据实体和关系查找 text_units
- 组织 entities / relationships / text_units 上下文
- 实现 token budget 分配
- 返回候选证据和实际入 prompt 证据

### 4.4 验收标准

- 问具体实体时能命中实体
- 回答能引用实体相关 text_units
- 关系信息能进入回答上下文
- 上下文不会超过最大 token 预算

---

## 5. P3 Community GraphRAG

### 5.1 目标

支持跨文档主题、趋势和全局问题。

### 5.2 数据表

```text
communities
community_reports
```

### 5.3 任务

- 基于 relationships 构建图
- 实现社区发现
- 生成 communities
- 聚合 community 的 entity_ids、relationship_ids、text_unit_ids
- 为每个 community 构建报告上下文
- 生成 community_report
- 实现 global_search map-reduce

### 5.4 验收标准

- 能生成社区层级
- 每个 community 能追溯实体、关系和原文证据
- 能对全局问题生成基于社区报告的答案
- map 阶段能输出带分数的要点
- reduce 阶段能过滤低分要点并生成最终回答

---

## 6. P4 运营与质量增强

### 6.1 目标

提升长期运行质量和可维护性。

### 6.2 任务

- 抽取质量指标
- 实体关系人工校正
- 黑白名单实体
- 同义词和 canonical_name 维护
- 增量索引
- 索引版本管理
- 回答引用质量评估
- 用户反馈闭环

### 6.3 验收标准

- 可以查看抽取成功率和失败原因
- 可以人工修正错误实体和关系
- 可以按知识库版本回滚索引
- 可以根据用户反馈定位低质量知识或低质量抽取

---

## 7. 推荐模块边界

```text
knowledge_indexing
- text_unit_builder
- graph_extractor
- graph_merger
- entity_embedding_builder
- community_builder
- community_report_builder

knowledge_retrieval
- basic_search
- local_search
- global_search
- context_builder
- evidence_builder

knowledge_quality
- extraction_metrics
- retrieval_metrics
- feedback_analyzer
```

---

## 8. 第一版最小任务清单

第一版建议只做到 P1 + P2 的最小闭环：

```text
1. text_units 已存在或可复用 OCR Markdown 切块
2. 实现实体关系 JSON 抽取
3. 实现实体关系合并
4. 实现 entity embedding
5. 实现 local_search
6. Hermes retrieval_skill 增加 local_graph_rag 模式
```

---

## 9. 不建议第一版做的内容

- 多级社区层级
- DRIFT Search
- Prompt Tuning 全流程
- 多存储后端适配
- 复杂增量更新
- 自动实体消歧大模型工作流

这些能力可以后续补齐，第一版应优先验证实体优先检索是否明显优于普通 RAG。

---

## 10. 一句话定义

GraphRAG 落地应先实现 Entity-First Local Search，把普通 RAG 从 chunk 相似度检索升级为实体图谱检索；社区报告和全局 Map-Reduce 应作为第二阶段增强。
