# OCR语义聚类落地实施计划

本文档补充 `OCR语义聚类Markdown生成` 方案的可执行细节，包括数据结构、接口、Prompt、任务状态和验收指标。

## 1. 数据结构

### 1.1 OCR 原始块

```json
{
  "doc_id": "doc_001",
  "page": 12,
  "block_id": "p12_b03",
  "text": "退\n款\n多\n久\n到\n账？",
  "bbox": [120, 340, 720, 388],
  "confidence": 0.91
}
```

### 1.2 清洗后 Chunk

```json
{
  "chunk_id": "doc_001_p12_c004",
  "doc_id": "doc_001",
  "page_range": [12, 12],
  "text": "退款多久到账？",
  "source_blocks": ["p12_b03"],
  "token_count": 12,
  "ocr_confidence": 0.91
}
```

### 1.3 Cluster Card

```json
{
  "cluster_id": "cluster_023",
  "title": "退款到账时间",
  "summary": "用户集中询问退款处理周期、到账时间和未到账处理方式。",
  "representative_examples": [
    "退款多久到账？",
    "退款什么时候到账？",
    "超过7天没收到退款怎么办？"
  ],
  "chunk_ids": [
    "doc_001_p12_c004",
    "doc_001_p18_c009"
  ],
  "confidence": 0.86,
  "needs_review": false
}
```

## 2. 存储设计

第一版可以使用 PostgreSQL + pgvector 统一承载，也可以拆分为关系型数据库和独立向量库。

| 表或索引 | 用途 |
| --- | --- |
| `ocr_blocks` | 保存 OCR 原始块、页码、坐标和置信度 |
| `text_chunks` | 保存清洗切块后的文本 |
| `chunk_embeddings` | 保存 chunk 向量和 embedding 模型版本 |
| `local_clusters` | 保存批内聚类结果 |
| `cluster_cards` | 保存 LLM 生成的标题、摘要和代表样本 |
| `global_clusters` | 保存跨批次合并后的最终主题 |
| `review_items` | 保存待人工复核内容 |
| `markdown_exports` | 保存最终 Markdown 版本和导出记录 |

## 3. 候选问题抽取

候选抽取先用规则，再用模型复核。

规则命中条件：

- 包含 `如何`、`怎么`、`是否`、`为什么`、`能不能`、`多久`、`哪里`、`怎么办`。
- 包含 `？` 或 `?`。
- 以 `Q:`、`问：`、`问题：` 开头。
- 长度处于合理区间，且 OCR 置信度不低于阈值。

输出类型建议分为：

| 类型 | 说明 |
| --- | --- |
| `question` | 明确的问题 |
| `answer` | 疑似答案或解释 |
| `statement` | 陈述性知识点 |
| `noise` | 页眉、页脚、页码、乱码 |
| `uncertain` | 需要人工复核 |

## 4. LLM Prompt 模板

### 4.1 聚类命名 Prompt

```text
你是文档结构化助手。
下面是一组来自 OCR 文档的相似问题片段。
请完成：
1. 判断这些片段是否属于同一主题。
2. 如果属于同一主题，生成简洁的 Markdown 标题。
3. 生成主题摘要。
4. 如果混入不同主题，请拆分为多个主题。
5. 不要编造原文不存在的信息。

输出 JSON：
{
  "is_coherent": true,
  "title": "...",
  "summary": "...",
  "items": [
    {
      "text": "...",
      "chunk_id": "...",
      "page": 1
    }
  ],
  "split_suggestions": []
}
```

### 4.2 跨批次合并 Prompt

```text
下面多个主题来自不同批次。
请判断它们是否应该合并为同一个 Markdown 标题。
如果可以合并，请给出统一标题和原因。
如果不应合并，请返回保留拆分的理由。

输出 JSON：
{
  "merge": true,
  "merged_title": "...",
  "reason": "...",
  "cluster_ids": []
}
```

## 5. 推荐接口

### 5.1 创建解析任务

```http
POST /api/ocr-clustering/jobs
Content-Type: application/json

{
  "doc_id": "doc_001",
  "ocr_result_uri": "s3://bucket/doc_001/ocr.json",
  "options": {
    "language": "zh-CN",
    "min_ocr_confidence": 0.75,
    "auto_publish": false
  }
}
```

### 5.2 查询任务状态

```http
GET /api/ocr-clustering/jobs/job_001
```

### 5.3 导出 Markdown

```http
GET /api/ocr-clustering/jobs/job_001/markdown
```

## 6. Markdown 输出样例

```markdown
# OCR 文档语义聚类结果

## 退款到账与退回渠道

摘要：用户集中询问退款到账时间、退回路径和未到账处理。

- 退款多久到账？（来源：第 12 页）
- 退款会退到哪里？（来源：第 18 页）
- 超过 7 天没收到退款怎么办？（来源：第 21 页）

## 需要人工确认的问题

- 退订之后还会...（来源：第 33 页，原因：OCR 文本缺失）
```

## 7. 任务状态机

```text
created
  -> ocr_loaded
  -> cleaned
  -> chunked
  -> embedded
  -> clustered
  -> summarized
  -> merged
  -> rendered
  -> reviewed
  -> published
```

失败状态：

```text
failed_cleaning
failed_embedding
failed_clustering
failed_llm_summary
failed_rendering
```

每个失败状态都需要记录：

- 当前文档 ID。
- 当前批次 ID。
- 失败模块。
- 错误信息。
- 可重试次数。
- 输入数据引用。

## 8. 验收清单

- OCR 噪声清洗后，页眉页脚、页码和重复水印被去除。
- 单个 chunk 不超过设定 token 上限。
- 同义问题能进入同一簇。
- 发票、退款、登录等不同主题不会混杂。
- LLM 生成的标题简短、准确、无编造。
- Markdown 中标题、摘要、问题列表和来源完整。
- OCR 缺失和混杂簇进入人工复核区。
- 单文档失败后可以按批次重试。

