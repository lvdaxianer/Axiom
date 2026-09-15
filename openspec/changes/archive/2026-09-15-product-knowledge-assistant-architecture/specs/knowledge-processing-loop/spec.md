## ADDED Requirements

### Requirement: General Loop SHALL process one Markdown file through independent producer and checker roles
The system SHALL define `knowledge-orchestrator`, `knowledge-producer`, and `knowledge-checker` Skills. The orchestrator SHALL pass immutable source content, the current graph context, and a complete candidate package between the roles. The producer and checker SHALL not directly publish or modify each other's artifacts.

#### Scenario: A valid source file is processed
- **WHEN** an operator invokes the orchestrator with a Markdown file path
- **THEN** the orchestrator SHALL invoke the producer, invoke the checker on the complete candidate, and publish only after a PASS verdict

### Requirement: General Loop SHALL repair failed candidates using structured checker feedback
The checker SHALL return PASS, FAIL, or ERROR. A FAIL verdict SHALL identify every blocking issue with an issue ID, code, candidate path, message, and required action. The orchestrator SHALL invoke the producer in repair mode with that verdict and SHALL submit a new complete candidate for independent checking.

#### Scenario: The checker rejects a relation without evidence
- **WHEN** the checker returns a FAIL verdict containing an unsupported relation issue
- **THEN** the orchestrator SHALL pass that issue to the producer and SHALL not write the candidate into the trusted knowledge directory

### Requirement: General Loop SHALL have deterministic success and failure exits
The orchestrator SHALL succeed only when the checker returns PASS and the source hash, candidate hash, and package schema still match the checked artifacts. The orchestrator SHALL fail without publishing when the checker returns ERROR, the source changes during processing, or the configured maximum of five rounds is reached.

#### Scenario: Maximum repair rounds are exhausted
- **WHEN** a candidate remains FAIL after five producer-checker rounds
- **THEN** the orchestrator SHALL return a failed run summary with the final verdict and SHALL not replace the existing trusted package

### Requirement: Directory processing SHALL be sequential and graph-aware
The orchestrator SHALL accept either a Markdown file or a directory. For a directory, it SHALL process Markdown files in deterministic lexical order, one at a time. Each successful package SHALL become graph context for later files in the same run.

#### Scenario: A later document reuses a prior concept
- **WHEN** the second file in a directory names a concept already published by the first file
- **THEN** the producer SHALL receive the existing concept identifier in graph context and SHALL reuse it when the concepts are equivalent
