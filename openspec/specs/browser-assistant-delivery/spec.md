# browser-assistant-delivery Specification

## Purpose
TBD - created by archiving change product-knowledge-assistant-architecture. Update Purpose after archive.
## Requirements
### Requirement: The browser assistant SHALL provide single-turn streaming answers
The browser extension SHALL submit one question to the Java backend and SHALL render Server-Sent Events without persisting multi-turn conversation state in the first release.

#### Scenario: The answer model streams normally
- **WHEN** the backend has selected evidence and the answer model produces output
- **THEN** the extension SHALL append `delta` events, display source document and section names from the final `sources` event, and finish on `done`

### Requirement: The answer model SHALL be evidence constrained
The backend SHALL instruct the answer model to answer only from selected source sections and to state that the product material does not cover the question when evidence is insufficient. The model SHALL not be invoked for no-knowledge and no-relevant-knowledge outcomes.

#### Scenario: No material supports a question
- **WHEN** recall and reranking produce no answerable section
- **THEN** the backend SHALL return a no-knowledge outcome and SHALL not generate an unsupported answer

### Requirement: The extension SHALL receive stable error events
The streaming API SHALL emit an `error` event with a machine-readable code and user-safe message for answer generation failures. It SHALL distinguish no knowledge, knowledge updating, no relevant knowledge, and answer failure outcomes.

#### Scenario: The model gateway times out
- **WHEN** the configured answer timeout elapses before the stream completes
- **THEN** the backend SHALL terminate the stream with an `answer_failed` error event and the extension SHALL show a retry-safe message
