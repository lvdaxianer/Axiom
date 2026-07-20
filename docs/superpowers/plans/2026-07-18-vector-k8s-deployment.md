# Vector K8s Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a Vector container image and Helm chart that can run the topo-sync listener on Kubernetes with host-persisted config and state.

**Architecture:** Package Vector `0.33.1` as a thin runtime image with a bootstrap entrypoint. Deploy it with a dedicated Helm chart that mounts `/data/uinnova/apps/vector` and the host Nginx log directory, then validate the rendered manifests and ARM64 container runtime behavior.

**Tech Stack:** Docker, Vector 0.33.1, Helm, Kubernetes YAML, shell validation commands.

---

### Task 1: Add the container runtime assets

**Files:**
- Create: `/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/container/Dockerfile`
- Create: `/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/container/entrypoint.sh`
- Create: `/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/container/.dockerignore`

- [ ] **Step 1: Write the failing test**

```bash
test -f "/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/container/Dockerfile"
```

Expected: FAIL because the container assets do not exist yet.

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
test -f "/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/container/Dockerfile"
```

Expected: exit code 1.

- [ ] **Step 3: Write the minimal implementation**

Create:

- a Dockerfile based on Vector `0.33.1` for ARM64-compatible builds
- an entrypoint script that bootstraps `/host-vector/config/vector.toml` if missing and then starts Vector with the host config
- a `.dockerignore` that keeps the build context focused on runtime files

- [ ] **Step 4: Run the test to verify it passes**

Run:

```bash
test -f "/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/container/Dockerfile" && \
test -f "/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/container/entrypoint.sh" && \
test -f "/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/container/.dockerignore"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add \
  "/Users/lvdaxianer/workspace/my/project/Axiom/docs/superpowers/specs/2026-07-18-vector-k8s-design.md" \
  "/Users/lvdaxianer/workspace/my/project/Axiom/docs/superpowers/plans/2026-07-18-vector-k8s-deployment.md" \
  "/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/container/Dockerfile" \
  "/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/container/entrypoint.sh" \
  "/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/container/.dockerignore"
git commit -m "feat: add vector container runtime assets"
```

### Task 2: Add the Helm chart and default Vector config template

**Files:**
- Create: `/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/chart/vector-topo-sync/Chart.yaml`
- Create: `/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/chart/vector-topo-sync/values.yaml`
- Create: `/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/chart/vector-topo-sync/templates/_helpers.tpl`
- Create: `/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/chart/vector-topo-sync/templates/configmap.yaml`
- Create: `/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/chart/vector-topo-sync/templates/deployment.yaml`
- Create: `/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/chart/vector-topo-sync/templates/NOTES.txt`

- [ ] **Step 1: Write the failing test**

```bash
helm template vector-topo-sync "/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/chart/vector-topo-sync"
```

Expected: FAIL because the chart does not exist yet.

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
helm template vector-topo-sync "/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/chart/vector-topo-sync"
```

Expected: chart path error.

- [ ] **Step 3: Write the minimal implementation**

Create a Helm chart that:

- renders a single `Deployment` with `Recreate` strategy
- mounts `/data/uinnova/apps/vector` as `/host-vector`
- mounts `/uinnova/nginx/nginx/logs` as `/host-nginx-logs` read-only
- injects a default `vector.toml` template through a ConfigMap
- supports private registry image values and optional `imagePullSecrets`
- runs in namespace `uino` when installed with `helm upgrade --install ... -n uino`

- [ ] **Step 4: Run the test to verify it passes**

Run:

```bash
helm template vector-topo-sync "/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/chart/vector-topo-sync" >/tmp/vector-topo-sync-rendered.yaml
test -s /tmp/vector-topo-sync-rendered.yaml
```

Expected: PASS and rendered YAML is non-empty.

- [ ] **Step 5: Commit**

```bash
git add "/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/chart/vector-topo-sync"
git commit -m "feat: add vector helm deployment chart"
```

### Task 3: Document usage and validate Docker plus Helm behavior

**Files:**
- Modify: `/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/README.md`

- [ ] **Step 1: Write the failing test**

```bash
rg -n "私有仓库|Helm|/data/uinnova/apps/vector|docker build" "/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/README.md"
```

Expected: FAIL because the Kubernetes container deployment guide is not documented yet.

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
rg -n "私有仓库|Helm|/data/uinnova/apps/vector|docker build" "/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/README.md"
```

Expected: exit code 1 or no matching deployment guidance for this containerized path.

- [ ] **Step 3: Write the minimal implementation**

Update the README with:

- image build, tag, and push commands for a private registry
- host directory preparation instructions
- Helm install and upgrade examples for namespace `uino`
- host config editing notes and ARM64 validation notes

- [ ] **Step 4: Run the test to verify it passes**

Run:

```bash
rg -n "私有仓库|Helm|/data/uinnova/apps/vector|docker build" "/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/README.md"
```

Expected: PASS with matching lines.

- [ ] **Step 5: Commit**

```bash
git add "/Users/lvdaxianer/workspace/my/project/Axiom/Nginx日志触发拓扑图资源同步/README.md"
git commit -m "docs: add vector container deployment guide"
```
