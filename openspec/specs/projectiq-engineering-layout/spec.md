# projectiq-engineering-layout Specification

## Purpose
TBD - created by archiving change projectiq-engineering-layout. Update Purpose after archive.
## Requirements
### Requirement: ProjectIQ SHALL separate its three executable concerns
The implementation repository SHALL be named `ProjectIQ` and SHALL contain sibling `backend/`, `skills/`, and `plugins/` directories. `backend/` SHALL own the Java service, `skills/` SHALL own the Codex or Claude knowledge-processing Skills, and `plugins/` SHALL own browser-extension delivery. Neither Skill nor browser-extension source SHALL require a direct source-code dependency on the backend.

#### Scenario: A developer initializes the product repository
- **WHEN** a developer creates the ProjectIQ implementation repository
- **THEN** the repository layout SHALL provide `ProjectIQ/backend`, `ProjectIQ/skills`, and `ProjectIQ/plugins` as separate top-level engineering boundaries

### Requirement: Backend SHALL use the approved Maven coordinates and root package
The backend Maven module SHALL use group ID `io.github.lvdaxianer.dinghai`, artifact ID `knowledge-assistant`, and Java root package `io.github.lvdaxianer.dinghai.projectiq`. The artifact name SHALL describe the deployable knowledge assistant even though the enclosing product repository is named ProjectIQ.

#### Scenario: A developer creates the Spring Boot application
- **WHEN** the developer creates the backend application entry point
- **THEN** it SHALL be located under `io.github.lvdaxianer.dinghai.projectiq` and the backend POM SHALL identify the artifact as `knowledge-assistant`

### Requirement: Backend packages SHALL preserve capability boundaries
The backend root package SHALL organize product code by `knowledge`, `retrieval`, `chat`, `integration`, `config`, and `shared` capabilities. A capability that needs internal layering SHALL place its API, application, domain, infrastructure, and repository code below that capability rather than placing all application controllers, services, or mappers in one global package.

#### Scenario: A new ontology import use case is added
- **WHEN** a developer implements a knowledge-import use case
- **THEN** its API, application logic and persistence implementation SHALL reside below the `knowledge` capability boundary
