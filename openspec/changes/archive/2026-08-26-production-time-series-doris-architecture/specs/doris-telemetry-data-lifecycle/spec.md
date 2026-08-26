## ADDED Requirements

### Requirement: Online telemetry retention and tiering
The system SHALL retain raw telemetry change points online for 365 days using daily date partitions. Partitions from the most recent 30 days MUST use the hot storage medium; partitions from day 31 through day 365 MUST use the configured warm storage medium or the validated remote storage policy.

#### Scenario: Hot range query
- **WHEN** an API requests telemetry wholly inside the most recent 30 days
- **THEN** its data source SHALL be the hot daily partitions without application-level migration routing.

#### Scenario: Warm range query
- **WHEN** an API requests telemetry wholly between day 31 and day 365
- **THEN** its data source SHALL be the warm partitions or the configured warm logical table.

### Requirement: Verified partition migration and deletion
The system SHALL migrate and delete telemetry only at daily partition granularity. A partition MUST be backed up and its row count, time range, and backup location verified before its deletion is eligible.

#### Scenario: Expired partition
- **WHEN** a daily raw partition exceeds 365 days of online retention
- **THEN** the lifecycle job SHALL record successful backup verification before dropping that partition.

#### Scenario: Failed migration verification
- **WHEN** the target partition verification fails during a hot-to-warm migration
- **THEN** the source partition SHALL remain queryable and the lifecycle job SHALL not delete it.

### Requirement: Late telemetry correction boundary
The system MUST define a configurable late-arrival boundary for each daily partition. Records within the boundary SHALL update the raw and affected aggregate buckets; records outside it SHALL use an auditable backfill process.

#### Scenario: Late record inside boundary
- **WHEN** a record arrives for an open historical partition inside the configured boundary
- **THEN** the system SHALL persist it and refresh each affected aggregate bucket.

#### Scenario: Late record outside boundary
- **WHEN** a record arrives for a closed or migrated partition outside the configured boundary
- **THEN** the system SHALL not silently overwrite historical aggregates and SHALL route it to the backfill process.
