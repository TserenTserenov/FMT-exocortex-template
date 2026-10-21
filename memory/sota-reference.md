---
description: IWE operational memory file
domains:
- reference
horizon: warm
name: sota-reference
originSessionId: 9a0e726a-951e-4408-9e02-94d7eeffbf74
owner: user
schema_version: 1
status: active
type: reference
valid_from: 2026-03-14
---
# SOTA Practices (Operational Reference)

> **Source:** Pack DP (`06-sota/DP.SOTA.*`) + SPF.SPEC.003
> **Edition:** 2026-02 | **Update:** when a new SOTA practice appears or an existing one becomes obsolete

## Priority Three (ALWAYS apply)

| # | Practice | Rule for Claude |
|---|----------|-----------------|
| 1 | **Context Engineering** (DP.SOTA.002) | Write/Select/Compress/Isolate. Every line in CLAUDE.md is a token. Remove what is unnecessary. |
| 2 | **DDD Strategic** (DP.SOTA.001) | BC = Pack scope. UL = ontology.md. Context Map = typed `related:`. |
| 3 | **Coupling Model** (DP.SOTA.011) | Evaluate connections across 3 dimensions: knowledge (how much A knows about B), distance (how far apart), volatility (how often the contract changes). |

## Conditional (apply when triggered)

| # | Practice | Trigger | Rule |
|---|----------|---------|------|
| 4 | **Quantum-Like Modeling Lens** (DP.SOTA.020 / FPF C.26*) | Probe-coupled state change, order effects, incompatibility, false composition, cross-context evidence transfer | Exhaust the classical toolset first. QL-lite activates only with 5 safeguards (DP.METHOD.050 §4): responsible / representation failure / weak inference / action / exit criterion. The lens is representational, not physical quantum. |

## Full Table: Platform SOTA (Pack DP)

| ID | Practice | Status | When to Apply |
|----|----------|--------|---------------|
| SOTA.001 | DDD Strategic (Khononov) | SOTA | Creating a Pack, defining BC, vocabulary, integrations |
| SOTA.002 | Context Engineering | SOTA (frontier) | Designing CLAUDE.md, memory/, agent context |
| SOTA.003 | Open API Specs | SOTA (mature) | Designing MCP, API contracts between systems |
| SOTA.004 | GraphRAG + KG | SOTA | Designing retrieval, typed `related:`, MCP tools |
| SOTA.005 | AI-Native Org Design | SOTA (emerging) | Organizing agents, distribution of responsibility |
| SOTA.006 | Agentic Development | SOTA (defining) | Multi-agent Architecture, orchestration, IPO pattern. **Amdahl Law:** multi-agent is justified ONLY when (1) context isolation, (2) parallelism gain, (3) tool specialization. Otherwise coordination cost > benefit. Start single-agent. (Anthropic 2026, Levenchuk). **Coordination Cost Check** (ArchGate Step 2b): apply at the activity scope scales where agents operate — Day (day-cycle agents) and Session (sub-agents of a task). |
| SOTA.007 | AI-Accelerated Ontology | SOTA (breakthrough) | KE pipeline, ontology generation, validation |
| SOTA.008 | Real-Time Knowledge Capture | SOTA (consensus) | Work Protocol, capture-to-pack, Work milestones |
| SOTA.009 | Knowledge-Based Digital Twins | Emerging | DDT Architecture, Pack + data + agents |
| SOTA.010 | DSL → DSLM Evolution | Evolving | Formalizing domain rules, validation |
| SOTA.011 | Coupling Model (Khononov) | SOTA | Evaluating connections: knowledge/distance/volatility coupling |
| SOTA.012 | Multi-Representation Arch | SOTA | Pack → multiple views (vector, graph, hierarchical) |
| SOTA.013 | SAI (Superhuman Adaptable Intelligence) | Emerging (LeCun 2026) | Evolvability as the primary AI characteristic. Not AGI (replicate humans) and not ASI (outperform on the same tasks), but SAI — rapidly mastering new classes of tasks, including those inaccessible to humans. World models + adaptability. Overlaps with Evolvability in ArchGate. |
| SOTA.020 | Quantum-Like Modeling Lens (FPF C.26*, Ilevsky 2026) | SOTA (live extension to FPF, edition 2026-04) | Probe-coupled state change, order effects, incompatibility, entanglement-like non-separability in sociotechnical systems. A lens, not an Ontology. Applied during ArchGate / metric design / diagnostics / Observability — after exhausting the classical toolset. Full application method: DP.METHOD.050. |

## Full Table: Pack Architecture SOTA (SPF.SPEC.003)

| Method | Source | Implementation in Pack |
|--------|--------|------------------------|
| RAPTOR (Hierarchical Indexing) | Stanford 2024 | manifest → MAP → entity cards (3 layers) |
| Contextual Chunking | Anthropic 2024 | `summary` in frontmatter of each entity |
| Hybrid Retrieval (dense+BM25) | Production 2025 | Vector search on summary + search by ID codes |
| LightRAG | HKUDS, EMNLP 2025 | Typed `related:` = graph edges for traversal |
| MemGPT/Letta | UCB 2023 | 3-layer memory: core (manifest) + recall (MAP) + archival (cards) |
| llms.txt | llmstxt.org 2024 | Manifest as machine-readable index |

## Operational Rules (derived from SOTA)

1. **Architectural decision** → check 7 EMOGSSB characteristics (evolvability, scalability, learnability, generativity, speed, currency, safety)
2. **New Pack** → BC (SOTA.001), Layer 0/1/2 (RAPTOR), summary required (Chunking)
3. **New agent** → define BC, IPO, contracts (SOTA.006), context (SOTA.002). **Coordination Cost Check:** (1) context isolation — does the agent need a separate context? (2) parallelism gain — are the tasks parallelizable? (3) tool specialization — does the agent need its own tools? All three "no" → do not create a separate agent
4. **Systems Integration** → coupling model: knowledge/distance/volatility (SOTA.011)
5. **Work milestone** → capture during-work (SOTA.008), do not defer
6. **MCP/API design** → Open Specs (SOTA.003), graph traversal (SOTA.004)
7. **Ontology/KE** → LLM-assisted first pass, human validates (SOTA.007)
8. **View, not a copy** → projectionView, not duplication (SOTA.012)
