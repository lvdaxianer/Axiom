## ADDED Requirements

### Requirement: Granularity-based timeline routing
The system SHALL route a timeline request by time span: raw change points with 5-minute fill for spans shorter than 7 days, hourly aggregation for spans from 7 days up to 30 days, and daily aggregation for spans of 30 days or longer.

#### Scenario: Short object timeline
- **WHEN** an object curve requests a span shorter than 7 days
- **THEN** the service SHALL read only that object's raw partitions plus the configured lookback range.

#### Scenario: Long global timeline
- **WHEN** a map-level curve requests a span of 30 days or longer
- **THEN** the service SHALL read the daily global aggregation table.

### Requirement: Server-side fill semantics
The service SHALL own standard-point generation and forward-fill behavior. It MUST read the most recent valid value before the requested start time within the configured lookback boundary before filling missing points.

#### Scenario: Fillable start point
- **WHEN** no raw value exists at the requested start time and a valid preceding value exists inside the lookback boundary
- **THEN** the service SHALL use that preceding value to fill the first standard point.

#### Scenario: Unfillable start point
- **WHEN** no valid preceding value exists inside the lookback boundary
- **THEN** the service SHALL omit or represent the unfillable point according to the documented response contract without inventing a value.

### Requirement: Restricted second-level detail
The system SHALL permit second-level data only for one resolved object and only inside a server-configured maximum span and maximum point count.

#### Scenario: Oversized second-level request
- **WHEN** a second-level request exceeds the configured span or point limit
- **THEN** the service SHALL reject it without issuing a raw telemetry scan.

### Requirement: Historical state lookup
The system SHALL use object aggregation bucket end values for a historical state pointer and SHALL use raw history only when the request explicitly requires configured second-level precision.

#### Scenario: Historical map pointer
- **WHEN** a map or list request contains a historical time pointer
- **THEN** the service SHALL resolve the latest eligible aggregate bucket value for each allowed object metric.
