## ADDED Requirements

### Requirement: Trusted knowledge packages SHALL carry sections, concepts, relations, and evidence
Each published Markdown file SHALL have a same-name `.knowledge.json` sidecar. The package SHALL identify the source file and SHA-256 hash, stable document and section identifiers, concepts and aliases, relation claims, and source evidence for every relation.

#### Scenario: A package declares a relation
- **WHEN** a package declares a relation between two concepts
- **THEN** the relation SHALL include a permitted relation type, a section identifier from the same document, and a quote that occurs in that section content

### Requirement: The backend SHALL treat SQLite as the authoritative knowledge store
The backend SHALL store documents, sections, concepts, aliases, relations, and relation evidence in SQLite. It SHALL treat Qdrant only as a rebuildable semantic retrieval index and SHALL hydrate every answer candidate from SQLite before use.

#### Scenario: A stale vector remains after an update
- **WHEN** Qdrant returns a point for a section that is no longer current in SQLite
- **THEN** the backend SHALL discard the point and SHALL not use its content in an answer

### Requirement: The retrieval pipeline SHALL combine semantic recall, bounded ontology expansion, and reranking
For a question, the backend SHALL create an embedding, retrieve the top 20 to 30 candidate sections from Qdrant, collect their concepts, traverse only strong ontology relations for at most four hops, and rerank the resulting candidate summaries with an LLM. It SHALL send no more than six sections from no more than three documents to the answer model.

#### Scenario: A question requires a billing rule linked from an exception
- **WHEN** semantic recall matches an invitation-link exception and the graph connects it through strong relations to a seat billing rule
- **THEN** the pipeline SHALL include the billing rule as a reranking candidate and SHALL include it in answer context only when reranking selects it

### Requirement: Ontology traversal SHALL preserve current evidence semantics
The backend SHALL permit only `parent_of`, `has_part`, `creates`, `requires`, `governed_by`, `exception_of`, `overrides`, and `related_to` relation types. Automatic traversal SHALL use only `creates`, `requires`, `governed_by`, `exception_of`, and `overrides`; `related_to` SHALL not automatically enter answer context.

#### Scenario: An unrelated weak relationship exists
- **WHEN** a concept is connected only through `related_to`
- **THEN** the reasoner SHALL not automatically add that concept's sections to the answer context
