# Elasticsearch Chart 逐行中文注释 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 Elasticsearch Chart 的全部部署配置和模板有效行增加中文逐行说明。

**Architecture:** 普通 YAML 使用行尾 `# 行说明：`，Helm 模板使用渲染时不输出的 `{{/* 行说明： */}}`，从而保持生成资源不变。严格 JSON Schema 通过为每个配置属性补充中文 `description` 实现等价逐项说明。

**Tech Stack:** Helm 3、Kubernetes YAML、JSON Schema Draft 2020-12、Bats、Python 3

---

### Task 1: 部署文件逐行注释

**Task boundary:**
- Agent: `elasticsearch-chart-line-comments-agent`（主代理直接执行）
- Owned responsibility: Chart 元数据、values、测试 fixture、全部 Helm 模板、Schema 和注释覆盖测试
- Allowed files: `Elasticsearch离线三节点集群/chart/**`、本计划文件
- Out of scope: Kubernetes 资源行为、默认值、Schema 约束、既有业务断言、OpenSpec、其他工作区改动
- Dependencies: 已提交的 Chart 和注释覆盖测试
- Dispatch fallback: 所有文件共享同一逐行标记及渲染一致性约束，并行修改会产生重叠与冲突
- Focused verification: `bats Elasticsearch离线三节点集群/chart/tests/comment_test.bats`
- Broader verification: 全量 Bats、Helm strict lint/template、结构化渲染对比、Ruff、Python/JSON 检查
- Handoff evidence: RED/GREEN 输出、逐行缺失数、结构化行为对比、review 和提交哈希

- [x] **Step 1: 扩展逐行覆盖测试并确认 RED**

  检查每个有效 YAML/Helm 源码行都带中文行说明，递归检查 Schema 每个配置属性都有中文 `description`。

- [x] **Step 2: 为部署文件增加逐行中文说明并确认 GREEN**

  注释解释字段用途、约束和失败影响；Helm 行内注释不得进入渲染结果。

- [x] **Step 3: 执行全量验证、审查和行为对比**

  全量测试、lint、双 values 渲染、静态检查和修改前后结构化资源必须通过。

- [x] **Step 4: 创建原子提交**

  仅提交本任务文件，使用中文完整 Conventional Commit、正文和 `Refs:` footer。
