## Purpose

Define Doris physical access paths for object timelines, whole-network curves, current state, and controlled metric mapping.

## Requirements

### Requirement: Object-oriented raw telemetry access path
The system SHALL retain raw change points in a daily partitioned fact table ordered by object, metric, event time, and source sequence. The raw access path MUST support exact single-object timeline and second-level detail queries without overwriting records that share a timestamp.

#### Scenario: Duplicate timestamp from source
- **WHEN** two telemetry records have the same object, metric, and event time but different source sequences
- **THEN** the raw fact table SHALL retain both records.

### Requirement: Separate object and global aggregation access paths
The system SHALL maintain separate object aggregation tables and global aggregation tables for 5-minute, hourly, and daily granularity. Global curve queries MUST NOT scan the raw object telemetry table.

#### Scenario: Whole-network curve
- **WHEN** a map-level power or frequency curve is requested
- **THEN** the query SHALL use the corresponding global aggregation table ordered by metric and bucket time.

#### Scenario: Device curve
- **WHEN** a query supplies an object ID, metric, and time range beyond the raw-detail range
- **THEN** the query SHALL use the object aggregation table ordered by object, metric, and bucket time.

### Requirement: Current state is separate from history
The system SHALL store the latest value of each object metric in a current-state table keyed by object and metric. Current map and list queries MUST read this table instead of locating latest values by scanning raw history.

#### Scenario: Current map state
- **WHEN** a map or list request has no historical time pointer
- **THEN** the service SHALL read the current-state table and object dimension.

### Requirement: Controlled metric and object mapping
The system SHALL resolve `menuType` and `levelType` through a server-owned mapping that specifies allowed metrics, units, source type, and object scope. Request input MUST NOT be interpolated as a table name or column name.

#### Scenario: Invalid mapping
- **WHEN** a request supplies a menu or level combination not present in the mapping
- **THEN** the service SHALL reject the request before executing telemetry SQL.
