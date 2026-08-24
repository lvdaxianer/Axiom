## ADDED Requirements

### Requirement: Layered telemetry data model
系统 SHALL provide object and metric dimensions, raw telemetry history, latest state, time-bucket rollups, event history, and mapping configuration as separate logical tables.

#### Scenario: Object hierarchy lookup
- **WHEN** a request contains `levelType` and `levelId`
- **THEN** the service resolves the object and its parent station/device relationship from `dim_object` without scanning raw telemetry history.

#### Scenario: Latest state lookup
- **WHEN** a map or list endpoint requests the current value of an object metric
- **THEN** the query reads `fact_current_state` keyed by `object_id` and `metric_code`.

#### Scenario: Historical point retention
- **WHEN** two source records share an object, metric, and timestamp but have different source sequence values
- **THEN** `fact_telemetry_raw` retains both records and does not silently overwrite either one.

### Requirement: Partition and sort strategy
Raw and rollup tables MUST be partitioned by event date and MUST expose sort-key prefixes that match their supported query path.

#### Scenario: Object timeline pruning
- **WHEN** a timeline query supplies object, metric, start time, and end time
- **THEN** the query prunes date partitions and scans rows ordered by `object_id`, `metric_code`, and time.

#### Scenario: Global timeline pruning
- **WHEN** a whole-network query supplies metric and time range without an object ID
- **THEN** the query uses a global rollup ordered by `metric_code`, bucket time, and object ID instead of scanning object-detail raw rows.

### Requirement: Metric semantics metadata
Each metric MUST declare unit, value type, fill policy, and aggregation policy in `dim_metric`.

#### Scenario: Counter metric
- **WHEN** an electricity meter metric is queried over an interval
- **THEN** the service applies counter-delta semantics and does not treat it as a gauge max/min metric.

#### Scenario: Discrete state metric
- **WHEN** a switch position or status metric is queried
- **THEN** the service uses forward-fill/last-value semantics and does not interpolate numeric values.
