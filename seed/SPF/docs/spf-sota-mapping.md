---
id: SPF.DOC.SOTA-MAPPING
name: SPF ↔ SOTA Mapping
status: draft
created: 2026-02-13
---

# SPF ↔ SOTA Mapping

> Correspondence table: SPF slots and the SOTA practices that fill them.
> Source: Pack DP `06-sota/DP.SOTA.*` + SPF.SPEC.003

## Positioning

| Level | What | Role |
|-------|------|------|
| FPF | Meta-principles of correct thinking | First principles |
| SPF | Core domain specification | Second principles |
| SOTA | Best practices from industry | SPF slot fillers |
| DDD | Method for extracting and engineering the core | SPF operationalization |

> SPF defines SLOTS. SOTA fills slots with METHODS. DDD is the bridge between them.

## Mapping: SPF slot → SOTA practice

| SPF slot | SOTA practice | ID | What it provides |
|----------|---------------|----|-----------------|
| Bounded Context | DDD Strategic | DP.SOTA.001 | Context Mapping, ACL, Published Language |
| Vocabulary (Kinds, terms) | DDD (Ubiquitous Language) | DP.SOTA.001 | UL permeates everywhere: code, UI, docs, tickets |
| Invariants / second principles | DSL→DSLM | DP.SOTA.010 | Machine-checkable domain rules |
| Boundary Statements | Open API Specs | DP.SOTA.003 | OpenAPI + AsyncAPI + CloudEvents |
| Multi-View representations | Multi-Representation Arch | DP.SOTA.012 | viewOf, compositionViewOf, projectionView |
| Projection into Downstream | Multi-Representation Arch | DP.SOTA.012 | Pack → multiple views |
| Context integration | Coupling Model | DP.SOTA.011 | knowledge/distance/volatility coupling |
| Evidence / Assurance | DDD + Open Specs | DP.SOTA.001/003 | Domain tests + contract testing |
| Model evolution | DDD Strategic | DP.SOTA.001 | Refactoring toward deeper insight |
| Policy/mechanism separation | Context Engineering | DP.SOTA.002 | Write/Select/Compress/Isolate |

## Mapping: SPF Layer → SOTA method (Pack Architecture)

| SPF Layer | SOTA method | What it does |
|-----------|-------------|-------------|
| Layer 0 (manifest) | llms.txt, MemGPT/Letta (core) | Machine-readable index, always-in-context |
| Layer 0 (summary) | Contextual Chunking | Retrieval without reading the full file |
| Layer 1 (MAP, indices) | RAPTOR, MemGPT/Letta (recall) | Hierarchical navigation |
| Layer 2 (entity cards) | MemGPT/Letta (archival) | Point load by ID |
| Cross-entity links | LightRAG | Typed `related:` = graph for traversal |
| Semantic search | Hybrid Retrieval | Vector (summary) + exact (ID-codes) |

## Mapping: Operational cycle → SOTA practice

| Operation | SOTA practice | ID | How it is applied |
|-----------|---------------|----|------------------|
| Pack creation | DDD Strategic | DP.SOTA.001 | BC identification, UL extraction |
| Knowledge extraction | AI-Accelerated OE | DP.SOTA.007 | LLM first pass, human validates |
| Capture (during work) | Real-Time KM | DP.SOTA.008 | At checkpoints, not after session |
| Agent design | Agentic Development | DP.SOTA.006 | BC + IPO + contracts |
| Agent context | Context Engineering | DP.SOTA.002 | Write/Select/Compress/Isolate |
| Agent organization | AI-Native Org | DP.SOTA.005 | Each agent = org unit with accountability |
| Coupling assessment | Coupling Model | DP.SOTA.011 | 3 dimensions: knowledge/distance/volatility |
| Retrieval | GraphRAG | DP.SOTA.004 | Vector + graph traversal |
| Digital Twin | KB Digital Twins | DP.SOTA.009 | Pack + data + agents |

## What is NOT applicable (with rationale)

| Practice | Why not SOTA / not applicable |
|----------|-------------------------------|
| Tactical DDD (Entity, VO, Aggregate) | OOP-specific, not universal beyond Java/C# (DP.D.017) |
| Formal domain specifications (academic) | Not mainstream; replaced by ontologies + KG |
| Full GraphRAG (Microsoft) | Excessive for structured Pack; LightRAG is sufficient |
| Static `_index.md` | Become outdated; replaced by auto-MAP |
| Subfolders by entity type | Solves human problem, not AI |

---

*Edition: 2026-02 | Update when SOTA practices in Pack DP change*
