## 1. Contract and assumptions

- [ ] 1.1 Confirm Doris version, memory, disk type, mount path, and whether 2TB means physical capacity or business-table usage; record the decision in the benchmark runbook.
- [ ] 1.2 Freeze the timeline boundary rule as `<7d = 5m`, `7d<=span<30d = 1h`, and `span>=30d = 1d`, including timezone and interval inclusivity.
- [ ] 1.3 Freeze target response objectives for current-state, timeline, event, and second-level popup endpoints before collecting pass/fail results.

## 2. Data model and Doris schema

- [ ] 2.1 Define `dim_object`, `dim_metric`, and `metric_mapping` fields, keys, object hierarchy, units, value types, fill policies, and aggregation policies.
- [ ] 2.2 Define `fact_telemetry_raw` as the retained history model with event-date partitions, object/time/source-sequence duplicate keys, and object-hash distribution.
- [ ] 2.3 Define `fact_current_state` as the latest-value unique-key model and document update ordering for late and duplicate records.
- [ ] 2.4 Define object-oriented and global-oriented `fact_metric_5m`, `fact_metric_1h`, and `fact_metric_1d` rollups with query-aligned sort-key prefixes.
- [ ] 2.5 Define `fact_event` for alarm, homework, defect, and status intervals, including overlap filtering and event identity.
- [ ] 2.6 Produce and review executable DDL plus partition/bucket sizing for the single-BE test environment; keep `replication_num=1` for the isolated benchmark.

## 3. Interface documentation

- [ ] 3.1 Normalize request and response schemas for `/api/dix/lineChartData`, `/api/dix/eventData`, `lineChartDataIsolated`, and `eventDataIsolated`.
- [ ] 3.2 Document metric and level whitelist mapping, numeric value plus unit representation, timezone, empty-value behavior, and error envelope.
- [ ] 3.3 Document query routing from span to 5-minute/hour/day tables and the maximum range/point limits for second-level queries.
- [ ] 3.4 Add concrete request/response examples for map, substation, transmission-line, transformer, bay/bus/GIS/other levels.

## 4. Dataset generation and offline load

- [ ] 4.1 Implement deterministic fixture generation with a seed, configurable object hierarchy, metric distribution, date range, change-point density, late records, duplicate timestamps, and event counts.
- [ ] 4.2 Generate a calibration batch, bulk-load it outside the read benchmark, measure Doris compression and filesystem usage, and calculate the next batch size from observed bytes per row.
- [ ] 4.3 Load production-shaped business data until the business tables occupy 1.4-1.6TB, then wait for compaction and validate row counts, partitions, checksums, and random samples.
- [ ] 4.4 Create an optional isolated `capacity_fill` table for near-full-disk experiments; exclude it from all business endpoint queries and stop before filesystem safety thresholds.

## 5. Read benchmark harness

- [ ] 5.1 Build an external benchmark client with randomized object, metric, level, and time-range parameters and separate cold-cache and warm-cache modes.
- [ ] 5.2 Implement scenarios for current state, 1-hour/7-day/30-day/1-year timelines, global timelines, second-level popup curves, and event lists.
- [ ] 5.3 Execute concurrency levels 1, 3, and 5 with 30 seconds warm-up, 60 seconds sampling, and three repetitions per scenario.
- [ ] 5.4 Capture P50/P95/P99, QPS, errors, timeouts, scanned rows/bytes, CPU, memory, disk read bandwidth, and Doris Query Profile.

## 6. Review and reporting

- [ ] 6.1 Compare measured results with the frozen response objectives and identify partition, sort-key, aggregation, or disk-read bottlenecks.
- [ ] 6.2 Produce the interface contract, schema/DDL, generation configuration, load evidence, benchmark matrix, and final results report.
- [ ] 6.3 Run the plan-implementation consistency review and record completed and unfinished tasks before any production implementation begins.
