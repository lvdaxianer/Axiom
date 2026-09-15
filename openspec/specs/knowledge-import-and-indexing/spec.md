# knowledge-import-and-indexing Specification

## Purpose
TBD - created by archiving change product-knowledge-assistant-architecture. Update Purpose after archive.
## Requirements
### Requirement: Import SHALL consume only complete trusted file pairs
The Java import endpoint SHALL be an internal administrative resource and SHALL read a Markdown file and its same-name knowledge package from one configured trusted directory. It SHALL reject missing pairs, source-key mismatches, source-hash mismatches, schema-invalid packages, and unsafe source keys (absolute paths, traversal segments, separators, or non-Markdown names). It SHALL use the source key and source hash as an idempotency scope.

#### Scenario: A pair is missing its sidecar package
- **WHEN** an authorized internal operator imports `A.md` and `A.knowledge.json` is absent
- **THEN** the endpoint SHALL reject the import without changing SQLite or Qdrant

### Requirement: Import SHALL atomically replace source-owned SQLite data
For one source key, import SHALL replace its sections, section-concept mappings, and relation evidence in a SQLite transaction while preserving facts and evidence owned by other documents. A relation SHALL remain active while at least one current evidence row supports it.

#### Scenario: A replacement drops one of two relation evidences
- **WHEN** document A removes evidence for a relation that document B still supports
- **THEN** the import SHALL remove only A's evidence and SHALL keep the relation active

### Requirement: Vector synchronization SHALL be asynchronous and recoverable
After SQLite commits, import SHALL enqueue deletion of old points and upsert of new section points in Qdrant. Qdrant synchronization failure SHALL leave SQLite committed, record a retryable index job, and return an index-pending result.

#### Scenario: Qdrant is temporarily unavailable
- **WHEN** SQLite import commits but Qdrant cannot accept a point upsert
- **THEN** the endpoint SHALL return `IMPORTED_WITH_INDEX_PENDING` and SHALL record a retryable synchronization job

### Requirement: Removal SHALL be explicit
The knowledge workflow SHALL not infer deletion merely because a source is absent from an input directory. Removing a trusted package SHALL require an explicit remove operation and SHALL remove its source-owned SQLite data and Qdrant points during import synchronization.

#### Scenario: A partial directory is processed
- **WHEN** an operator processes a directory that does not include an existing trusted source
- **THEN** the workflow SHALL retain the omitted source unchanged
