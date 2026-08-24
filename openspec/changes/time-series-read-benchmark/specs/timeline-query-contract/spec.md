## ADDED Requirements

### Requirement: Unified timeline curve contract
`/api/dix/lineChartData` MUST accept `menuType`, `startTime`, `endTime`, and `levelConfig`, and MUST return metric name, unit, selected granularity, timezone, and ordered points.

#### Scenario: Granularity routing
- **WHEN** span is less than 7 days
- **THEN** the service reads or produces 5-minute points.

#### Scenario: Hour granularity routing
- **WHEN** span is at least 7 days and less than 30 days
- **THEN** the service reads or produces hourly points.

#### Scenario: Daily granularity routing
- **WHEN** span is at least 30 days
- **THEN** the service reads or produces daily points aligned to natural-day boundaries.

### Requirement: Timeline event contract
`/api/dix/eventData` and `eventDataIsolated` MUST return interval events with event ID, object ID, type, level, start time, end time, status, and content.

#### Scenario: Event interval filtering
- **WHEN** an event overlaps the requested time interval
- **THEN** the event is returned once with its original start and end times.

### Requirement: Isolated second-level curve contract
`lineChartDataIsolated` MUST return one point per second for the selected event window and MUST enforce a maximum time span and maximum point count.

#### Scenario: Second-level forward fill
- **WHEN** a second has no source value and a prior valid value exists within the configured lookback window
- **THEN** the missing second uses the prior value.

### Requirement: Query safety and response consistency
Timeline endpoints MUST use whitelist mappings, timezone-aware timestamps, numeric values plus units, and consistent error envelopes.

#### Scenario: Invalid mapping input
- **WHEN** `menuType` or `levelType` is not present in the whitelist
- **THEN** the endpoint returns a validation error without constructing dynamic SQL.

#### Scenario: Empty source range
- **WHEN** no valid source value exists within the configured lookback window
- **THEN** the endpoint omits the unfillable point or returns the documented null representation consistently.
