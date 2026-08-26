## Purpose

Define cache scope and invalidation behavior for telemetry configuration, current state, and aggregate query results.

## Requirements

### Requirement: Configuration cache invalidation
The system SHALL cache object hierarchy, metric definitions, and mapping configuration only with explicit invalidation on configuration publication.

#### Scenario: Mapping configuration update
- **WHEN** an administrator publishes a changed menu-to-metric mapping
- **THEN** the service SHALL invalidate the affected local and Redis configuration cache entries before accepting requests using that mapping.

### Requirement: Current and aggregate result cache consistency
The system SHALL use data version or update-event invalidation for cached current state and aggregate responses. A finite TTL MAY be used as a fallback but MUST NOT be the only correctness mechanism.

#### Scenario: Current state update
- **WHEN** a telemetry update changes an object's current state
- **THEN** the system SHALL invalidate or advance the version of the affected current-state cache key.

### Requirement: Raw detail cache exclusion
The system MUST NOT cache arbitrary raw historical curves, second-level detail curves, or unbounded event pages as general Redis result entries.

#### Scenario: Second-level curve request
- **WHEN** a second-level detail request is accepted
- **THEN** the service SHALL use its controlled raw query path rather than creating a general-purpose Redis result cache entry.
