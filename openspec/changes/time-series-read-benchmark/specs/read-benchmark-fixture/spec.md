## ADDED Requirements

### Requirement: Reproducible benchmark dataset
The data generator MUST accept a seed and configuration for object counts, metric counts, date range, change-point density, late records, duplicate timestamps, and event counts.

#### Scenario: Repeated generation
- **WHEN** the generator runs twice with the same seed and configuration
- **THEN** it produces equivalent rows, distributions, and validation checksums.

### Requirement: Safe 2TB capacity target
Business tables MUST stop at 1.4～1.6TB on a 2TB physical disk, leaving space for system files, indexes, compaction, and query temporary data.

#### Scenario: Capacity calibration
- **WHEN** a calibration batch is loaded
- **THEN** the plan measures actual Doris table size and filesystem usage before calculating the next batch size.

#### Scenario: Near-full-disk test
- **WHEN** near-full-disk behavior is required
- **THEN** remaining space is filled in a separate `capacity_fill` table that is excluded from business endpoint queries.

### Requirement: Read-only concurrency benchmark
The benchmark MUST test concurrency levels 1, 3, and 5 for current-state, object timeline, global timeline, second-level popup, and event queries.

#### Scenario: Per-level sampling
- **WHEN** one concurrency level is executed
- **THEN** the runner performs 30 seconds of warm-up, 60 seconds of sampling, and three repetitions.

#### Scenario: Result evidence
- **WHEN** a repetition completes
- **THEN** the report records P50/P95/P99 latency, QPS, error and timeout counts, scanned rows/bytes, CPU, memory, and disk read bandwidth.

### Requirement: Cache-aware result validation
The benchmark MUST support separate cold-cache and warm-cache runs and MUST randomize object, metric, and time-range parameters.

#### Scenario: Cache isolation
- **WHEN** a cold-cache run is requested
- **THEN** the runner records the cache state and does not reuse a fixed result set as the performance conclusion.
