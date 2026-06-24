# Final Product Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade the final product HTML so it clearly shows platform capabilities, orchestration design, and technology selection.

**Architecture:** Keep the page as a single static HTML artifact. Strengthen the information architecture with a function map, a node-detail panel, and a clearer technical explanation section. Use lightweight vanilla JavaScript to keep the click interactions simple and self-contained.

**Tech Stack:** Static HTML, CSS, vanilla JavaScript.

---

### Task 1: Make the prototype explain the product and orchestration layer

**Files:**
- Modify: `/Users/lvdaxianer/workspace/my/project/Axiom/.superpowers/brainstorm/82558-1782311229/content/final-product.html`

- [ ] **Step 1: Write the failing test**

```bash
node <<'NODE'
const fs = require('fs');
const html = fs.readFileSync('/Users/lvdaxianer/workspace/my/project/Axiom/.superpowers/brainstorm/82558-1782311229/content/final-product.html', 'utf8');
const required = ['功能地图', '编排怎么做', 'React Flow', 'FastAPI', '日志与监控', '智能体广场'];
const missing = required.filter(text => !html.includes(text));
if (missing.length) {
  console.error('Missing:', missing.join(', '));
  process.exit(1);
}
NODE
```

Expected: FAIL because at least one of the new explanation phrases is absent.

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
node <<'NODE'
const fs = require('fs');
const html = fs.readFileSync('/Users/lvdaxianer/workspace/my/project/Axiom/.superpowers/brainstorm/82558-1782311229/content/final-product.html', 'utf8');
const required = ['功能地图', '编排怎么做', 'React Flow', 'FastAPI', '日志与监控', '智能体广场'];
const missing = required.filter(text => !html.includes(text));
if (missing.length) {
  console.error('Missing:', missing.join(', '));
  process.exit(1);
}
NODE
```

Expected: exit code 1 with a missing-text error.

- [ ] **Step 3: Write the minimal implementation**

Update `/Users/lvdaxianer/workspace/my/project/Axiom/.superpowers/brainstorm/82558-1782311229/content/final-product.html` so the system page contains:

- a `功能地图` section with six cards for 文档审核、知识库治理、智能体编排、模型管理、日志与监控、智能体广场
- a `编排怎么做` explanation block that states the page uses fixed business nodes, React Flow for visual editing, and FastAPI + Celery for DSL execution
- a technical page section that explicitly lists React Flow, FastAPI, Redis + Celery, PostgreSQL + NAS, pgvector, and the model gateway
- node copy that explains each module in one sentence so the UI is readable without clicking every node

- [ ] **Step 4: Run the test to verify it passes**

Run:

```bash
node <<'NODE'
const fs = require('fs');
const html = fs.readFileSync('/Users/lvdaxianer/workspace/my/project/Axiom/.superpowers/brainstorm/82558-1782311229/content/final-product.html', 'utf8');
const required = ['功能地图', '编排怎么做', 'React Flow', 'FastAPI', '日志与监控', '智能体广场'];
const missing = required.filter(text => !html.includes(text));
if (missing.length) {
  console.error('Missing:', missing.join(', '));
  process.exit(1);
}
NODE
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add /Users/lvdaxianer/workspace/my/project/Axiom/docs/superpowers/specs/2026-06-25-final-product-page-design.md /Users/lvdaxianer/workspace/my/project/Axiom/docs/superpowers/plans/2026-06-25-final-product-page.md /Users/lvdaxianer/workspace/my/project/Axiom/.superpowers/brainstorm/82558-1782311229/content/final-product.html
git commit -m "feat: improve product page explanation"
```
