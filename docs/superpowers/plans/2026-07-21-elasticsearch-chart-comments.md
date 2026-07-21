# Elasticsearch Chart 全文件注释 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 Elasticsearch 离线三节点集群 Chart 的全部源文件补充可维护的中文职责说明，同时保持 Helm 渲染结果和运行行为不变。

**Architecture:** 使用一个 Bats 覆盖审计约束每个非 JSON 文件必须具有中文文件职责注释，并约束 JSON Schema 使用合法的 `description`。随后仅增加注释或 Schema 描述字段，通过去除注释与 `description` 后的结构化对比、现有测试和 lint 证明没有行为漂移。

**Tech Stack:** Helm 3、Kubernetes YAML、JSON Schema Draft 2020-12、Bats、Python 3

---

### Task 1: Chart 全文件中文注释

**Task boundary:**
- Agent: `elasticsearch-chart-comments-agent`（由主代理直接执行）
- Owned responsibility: Chart 全部 21 个现有源文件、注释覆盖测试及本计划文件
- Allowed files: `Elasticsearch离线三节点集群/chart/**`、`docs/superpowers/plans/2026-07-21-elasticsearch-chart-comments.md`
- Out of scope: Kubernetes 资源行为、默认参数、Schema 约束、测试断言、OpenSpec、根级 README、其他工作区改动
- Dependencies: 已批准的注释设计 `docs/superpowers/specs/2026-07-21-elasticsearch-chart-comments-design.md`
- Dispatch fallback: 文件间共享同一注释契约且修改范围高度重叠，并行代理会引入冲突；当前会话由主代理单线程执行
- Focused verification: `bats Elasticsearch离线三节点集群/chart/tests/comment_test.bats`
- Broader verification: 全量 Bats、Helm strict lint/template、Python 编译与 Ruff、JSON 解析、结构化渲染对比、敏感信息扫描、`git diff --check`
- Handoff evidence: RED/GREEN 输出、全量验证输出、逐项代码审查记录和原子提交哈希

**Files:**
- Create: `Elasticsearch离线三节点集群/chart/tests/comment_test.bats`
- Create: `Elasticsearch离线三节点集群/chart/tests/assert_comments.py`
- Modify: `Elasticsearch离线三节点集群/chart/Chart.yaml`
- Modify: `Elasticsearch离线三节点集群/chart/values.yaml`
- Modify: `Elasticsearch离线三节点集群/chart/values.customer.example.yaml`
- Modify: `Elasticsearch离线三节点集群/chart/values.schema.json`
- Modify: `Elasticsearch离线三节点集群/chart/templates/_helpers.tpl`
- Modify: `Elasticsearch离线三节点集群/chart/templates/configmap.yaml`
- Modify: `Elasticsearch离线三节点集群/chart/templates/credentials-secret.yaml`
- Modify: `Elasticsearch离线三节点集群/chart/templates/headless-service.yaml`
- Modify: `Elasticsearch离线三节点集群/chart/templates/http-service.yaml`
- Modify: `Elasticsearch离线三节点集群/chart/templates/networkpolicy.yaml`
- Modify: `Elasticsearch离线三节点集群/chart/templates/pdb.yaml`
- Modify: `Elasticsearch离线三节点集群/chart/templates/snapshot-job.yaml`
- Modify: `Elasticsearch离线三节点集群/chart/templates/statefulset.yaml`
- Modify: `Elasticsearch离线三节点集群/chart/templates/tls-secret.yaml`
- Modify: `Elasticsearch离线三节点集群/chart/tests/assert_access.py`
- Modify: `Elasticsearch离线三节点集群/chart/tests/assert_common.py`
- Modify: `Elasticsearch离线三节点集群/chart/tests/assert_render.py`
- Modify: `Elasticsearch离线三节点集群/chart/tests/assert_snapshot.py`
- Modify: `Elasticsearch离线三节点集群/chart/tests/fixtures/valid-values.yaml`
- Modify: `Elasticsearch离线三节点集群/chart/tests/render_test.bats`
- Modify: `Elasticsearch离线三节点集群/chart/tests/snapshot_test.bats`

- [x] **Step 1: 写入失败的注释覆盖测试**

  新增 Bats 测试：枚举 Chart 源文件，要求非 JSON 文件前 12 行包含中文和“文件说明”，要求 `values.schema.json` 顶层以及一级属性都包含非空中文 `description`，并用 Python 标准库解析 JSON 以禁止非法注释。

- [x] **Step 2: 运行测试并确认 RED**

  Run: `bats Elasticsearch离线三节点集群/chart/tests/comment_test.bats`

  Expected: FAIL，指出现有源文件缺少统一的中文文件职责说明或 Schema 描述。

- [x] **Step 3: 增加最小注释实现**

  为 YAML、Helm、Bats、Python 文件增加统一的文件职责说明；为复杂的 Secret 复用、证书 SAN、集群引导、NFS 目录隔离、MetalLB、NetworkPolicy、快照 Hook 和失败保留逻辑增加就近中文说明。JSON Schema 只增加标准 `description` 字段，不加入 `#` 或 `//`。

- [x] **Step 4: 运行测试并确认 GREEN**

  Run: `bats Elasticsearch离线三节点集群/chart/tests/comment_test.bats`

  Expected: PASS，所有 Chart 文件均通过注释覆盖与 JSON 合法性检查。

- [x] **Step 5: 执行广泛验证与行为对比**

  Run: `bats Elasticsearch离线三节点集群/chart/tests/*.bats`

  Run: `helm lint --strict Elasticsearch离线三节点集群/chart -f Elasticsearch离线三节点集群/chart/tests/fixtures/valid-values.yaml`

  Run: `helm template es Elasticsearch离线三节点集群/chart -n uino -f Elasticsearch离线三节点集群/chart/tests/fixtures/valid-values.yaml`

  Run: `ruff check Elasticsearch离线三节点集群/chart/tests/*.py`

  Run: `PYTHONPYCACHEPREFIX=/tmp/axiom-pycache python3 -m py_compile Elasticsearch离线三节点集群/chart/tests/*.py`

  Run: `python3 -m json.tool Elasticsearch离线三节点集群/chart/values.schema.json >/dev/null`

  Run: `git diff --check`

  Expected: 全部命令成功；去除 YAML 注释与 Schema `description` 后，修改前后的结构化结果一致；扫描结果不包含真实凭据。

- [x] **Step 6: 审计、复验并提交**

  逐项对照设计、计划和 canonical `code-review-spec` 审查完整 diff，修复发现的问题并重跑 Step 4、Step 5。仅暂存本任务允许文件，使用中文完整 Conventional Commit（正文和 `Refs:` footer）创建一个原子提交。
