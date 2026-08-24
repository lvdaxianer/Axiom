# 时间序列读压测方案 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 2TB 物理磁盘的单机 Doris 环境中，建立支撑现有时间轴/状态/事件接口的数据模型，离线造数并用并发 1、3、5 验证只读接口性能。

**Architecture:** 原始层保留业务形态的变化时序数据，状态层保存对象最新值，查询层按对象和全网两类访问路径提供 5 分钟、小时和天汇总，事件单独存储。数据离线装载并控制业务表在 1.4～1.6TB，独立压测客户端按固定场景读取接口并采集延迟、扫描和资源指标。

**Tech Stack:** Apache Doris 3.x、HTTP/REST 接口、批量 Parquet/CSV 装载、独立压测客户端、Doris Query Profile。

---

## Scope and Safety

- 2TB 是物理磁盘容量，不将业务数据跑到满盘；业务表目标为 1.4～1.6TB。
- 不统计写入吞吐；数据装载完成、Compaction 稳定后才开始读压测。
- 若需要验证接近满盘的行为，使用独立 `capacity_fill` 表，不能混入业务接口查询。
- 单机测试使用 1 FE + 1 BE、单副本；这不是高可用验证。

## Task 1: Freeze contracts and hardware assumptions

**Files:**
- Create: `docs/time-series-read-benchmark/01-assumptions.md`
- Create: `docs/time-series-read-benchmark/01-interface-contract.md`

- [ ] Confirm Doris version, 256-core host memory, disk type, mount path, and external benchmark-client host.
- [ ] Record the physical-disk safety rule, target data usage, timezone, time interval inclusivity, empty-value behavior, and provisional P95 objectives.
- [ ] Normalize `/api/dix/lineChartData`, `/api/dix/eventData`, `lineChartDataIsolated`, and `eventDataIsolated` request/response examples.
- [ ] Freeze whitelist mappings for `menuType` and `levelType`; reject unknown mappings before SQL construction.

## Task 2: Create the Doris data model

**Files:**
- Create: `docs/time-series-read-benchmark/02-schema-design.md`
- Create: `sql/time-series-read-benchmark/create_dimensions.sql`
- Create: `sql/time-series-read-benchmark/create_facts.sql`
- Create: `sql/time-series-read-benchmark/create_rollups.sql`

- [ ] Define `dim_object`, `dim_metric`, and `metric_mapping` with globally unique object IDs and numeric metric codes.
- [ ] Define `fact_telemetry_raw` as Duplicate Key history partitioned by `event_date`, distributed by object ID, and ordered for object/metric/time queries.
- [ ] Define `fact_current_state` as Unique Key `(object_id, metric_code)` for map and list endpoints.
- [ ] Define object-oriented and global-oriented 5-minute, hourly, and daily rollups; document sequence-aware handling for first/last values.
- [ ] Define `fact_event` for alarm, homework, defect, and status interval queries.
- [ ] Add only query-justified Bloom/inverted indexes; do not add broad indexes to the raw table.

## Task 3: Build deterministic data fixtures

**Files:**
- Create: `docs/time-series-read-benchmark/03-data-generation.md`
- Create: `tools/time-series-read-benchmark/generate_fixture`
- Create: `tools/time-series-read-benchmark/fixture.yaml`

- [ ] Generate object hierarchy, metrics, change-only telemetry, duplicate timestamps, late records, missing ranges, and event intervals from a fixed seed.
- [ ] Keep numeric values and repeated dimensions realistic for Doris compression; do not add fake payload columns to business tables.
- [ ] Produce a calibration batch and measure actual bytes per row after Doris compaction.
- [ ] Calculate the next batch size from observed storage usage and stop business tables at 1.4～1.6TB.
- [ ] Define an optional separate `capacity_fill` table for near-full-disk testing.

## Task 4: Offline load and validation

**Files:**
- Create: `docs/time-series-read-benchmark/04-load-runbook.md`
- Create: `tools/time-series-read-benchmark/load_fixture`
- Create: `tools/time-series-read-benchmark/validate_fixture`

- [ ] Bulk-load dimensions, raw facts, current state, rollups, and events outside the read benchmark.
- [ ] Wait for Compaction stability and record Doris table size, filesystem usage, partition counts, tablet distribution, and available free space.
- [ ] Validate row counts, date coverage, object/metric cardinality, checksums, and random API-equivalent samples.
- [ ] Fail the run if the filesystem safety threshold is exceeded or if raw and rollup samples disagree.

## Task 5: Run read-only API benchmark

**Files:**
- Create: `docs/time-series-read-benchmark/05-read-benchmark.md`
- Create: `tools/time-series-read-benchmark/benchmark_api`
- Create: `tools/time-series-read-benchmark/scenarios.yaml`

- [ ] Run current-state, single-object 1-hour/7-day/30-day/1-year, global timeline, second-level popup, and event scenarios.
- [ ] For each scenario run concurrency 1, 3, and 5; warm up for 30 seconds, sample for 60 seconds, and repeat three times.
- [ ] Randomize object, metric, level, and time range; execute separate cold-cache and warm-cache runs.
- [ ] Record P50/P95/P99, QPS, errors, timeouts, scanned rows/bytes, CPU, memory, disk read bandwidth, and Doris Query Profile.

## Task 6: Produce the evidence report

**Files:**
- Create: `docs/time-series-read-benchmark/06-results-report.md`

- [ ] Compare every scenario and concurrency level with the frozen response objectives.
- [ ] Attribute bottlenecks to partition pruning, sort-key locality, rollup routing, memory, or disk reads.
- [ ] Record completed and unfinished tasks, residual risks, and whether the single-node result is suitable only for capacity/read validation or for a production deployment.

## Verification Commands

```bash
openspec validate time-series-read-benchmark --strict
git worktree list --porcelain
git branch --show-current
git status --short
```

Expected result: OpenSpec validation passes, the active branch is `features/时间序列读压测方案`, and the plan/worktree contains only the intended planning documents and scaffolding.
