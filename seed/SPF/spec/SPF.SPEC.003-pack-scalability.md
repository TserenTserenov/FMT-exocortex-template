---
id: SPF.SPEC.003
name: Pack Scalability
status: draft
created: 2026-02-11
---

# Pack Scalability

> SPF specification: how to build a Pack that stays comprehensible to AI agents as it grows by orders of magnitude.

---

## Problem

A Pack is loaded into an AI agent's context window in its entirety. At the current volume (~30 files, ~5K lines) this works. As it grows (100+ files, 15K+ lines) it stops working: the context overflows, the LLM loses accuracy on long context (lost-in-the-middle effect), and cost grows linearly.

**Threshold:** ~100 files / ~15K lines — the boundary of the context-loading approach.

---

## Distinction: Context-loading ≠ Retrieval-based

| Mode | Description | When it works | Limit |
|------|-------------|--------------|-------|
| **Context-loading** | Full Pack loaded into context | <100 files, <15K lines | ~200K tokens |
| **Retrieval-based** | Agent requests needed parts via search | Any volume | Retrieval quality |

**Strategy:** prepare Pack for retrieval-based loading without breaking context-loading for small Packs.

---

## SOTA methods (rationale for decisions)

### What is applicable to Pack

| Method | Source | Application in Pack |
|--------|--------|---------------------|
| **RAPTOR** (Hierarchical Indexing) | Stanford, 2024 | Pack already has 3 levels: manifest → MAP → entity cards. Formalize as layers |
| **Contextual Chunking** | Anthropic, 2024 | Add `summary` to the frontmatter of each entity — retrieval without reading the full file |
| **Hybrid Retrieval** (dense + BM25) | Production default 2025 | Vector search on summary + exact search on ID codes |
| **LightRAG** | HKUDS, EMNLP 2025 | Typed `related:` in frontmatter forms a graph — traversal along links |
| **MemGPT/Letta** | UCB, 2023 | 3-layer memory: core (manifest) + recall (MAP/indices) + archival (entity cards) |
| **llms.txt** | llmstxt.org, 2024 | Manifest as machine-readable index of all entities |
| **Context Engineering** | Anthropic, 2025 | Write/Select/Compress/Isolate — Pack supports all 4 strategies via layers |

### What is NOT applicable

| Method | Why it does not fit |
|--------|---------------------|
| Subfolders by entity type | Solves the human problem, not AI. AI navigates by indices, not folders |
| Static `_index.md` | Become outdated just like manual MAP. Generation is needed |
| Full GraphRAG (Microsoft) | Excessive for structured Pack. LightRAG-style via frontmatter `related:` is sufficient |

---

## Specification: 3-layer loading

### Principle

An AI agent loads Pack layer by layer: from overview to details. Each layer is self-sufficient for its level of tasks.

### Layer 0: Always-in-context (<=2K tokens)

Always loaded, on any access to Pack.

| File | Content | Max size |
|------|---------|---------|
| `00-pack-manifest.md` | ID, scope, entity count, version, entity index with summary | 1.5K tokens |
| `01A-bounded-context.md` | Object of description, scope, truth criteria (summary) | 500 tokens |

**Requirement:** manifest MUST contain a machine-readable table of ALL entities with a 1-line summary (see Extended Manifest section).

### Layer 1: On-demand indices (<=5K tokens each)

Loaded during navigation, link search, work planning.

| File | Content | When to load |
|------|---------|-------------|
| `07-map/DOMAIN.MAP.001.md` | Full navigation (auto-generated) | Overview of all links needed |
| `01B-distinctions.md` | All distinctions with summary | Working with concepts |
| `02C-methods-index.md` | All methods with inputs/outputs | Working with methods |

### Layer 2: Full entity cards (<=1K tokens each)

Loaded point-by-point, by ID.

| File | When to load |
|------|-------------|
| `DOMAIN.M.NNN-*.md` | Method details needed |
| `DOMAIN.WP.NNN-*.md` | Product criteria needed |
| `DOMAIN.FM.NNN-*.md` | Error analysis |

**Loading protocol:**

```
1. Agent receives a task
2. Loads Layer 0 (manifest + bounded context)
3. From manifest finds needed entities (by summary and tags)
4. Loads Layer 1 index for navigation (if needed)
5. Loads specific entity cards from Layer 2
```

---

## Size limit for domain knowledge files

### Distinction: knowledge ≠ meta-structure

| Category | Example files | Limit |
|----------|--------------|-------|
| **Domain knowledge** | Entity cards: M, WP, FM, D, R, CHR, SOTA, + domain-specific kinds (FMT, PRG, etc.) | **10,000 characters** (hard gate) |
| **Pack meta-structure** | Manifest (00), Bounded Context (01A), Distinctions index (01B), MAP (07), Ontology | No limit |

### Rule

An entity card exceeding 10,000 characters is a signal of an overloaded entity. The file does NOT need to be mechanically split. **Entity decomposition** is needed: one entity becomes two or more with their own bounded contexts.

### Protocol when exceeded

1. Extractor (or author) discovers an entity card > 10K characters
2. Analyzes content: are there two different objects of description inside?
3. Proposes decomposition: which entities to extract, which links (`related:`) to establish
4. After approval — creates separate entity cards + updates manifest

### Why 10K

- Typical entity card: 2–4K characters (50–80 lines)
- 10K — 2.5x margin for complex methods with expanded inputs/outputs
- Above 10K — almost always a sign of mixing two entities or didactic content in the ontology

---

## Extended Manifest

Manifest MUST contain an **Entity Index** section — a full list of all entities with summaries:

```markdown
## Entity Index

| ID | Name | Kind | Summary | Status |
|----|------|------|---------|--------|
| DP.D.001 | Object ≠ Model | D | Model simplifies; abstraction must not be confused with reality | active |
| DP.M.001 | Knowledge Extraction | M | Transformation of raw information into pack-compatible entities | active |
| DP.WP.001 | Extraction Report | WP | Structured extraction report with classifications | active |
| DP.FM.001 | Information as Knowledge | FM | Raw information is accepted as formalized knowledge | active |
```

**Requirement:** Entity Index is generated automatically from file frontmatter (see Auto-MAP section).

---

## Extended Frontmatter

### New required fields

```yaml
---
id: DOMAIN.M.XXX
name: Method Name
status: draft | active | deprecated
summary: "One sentence describing this entity for retrieval and index generation"
created: YYYY-MM-DD
last_updated: YYYY-MM-DD
---
```

**`summary`** (required, new):
- One sentence, <= 150 characters
- Sufficient to understand the entity without reading the full file
- Used in Entity Index, MAP, and retrieval

### New optional fields

```yaml
---
# ... required fields ...
related:
  produces: [DOMAIN.WP.001]           # Typed: what it produces
  uses: [DOMAIN.D.006, DOMAIN.D.001]  # Typed: what it uses
  fails_with: [DOMAIN.FM.001]         # Typed: which errors
  requires_role: [DOMAIN.R.001]       # Typed: which roles are needed
  precedes: [DOMAIN.M.002]            # Typed: what it precedes
  follows: [DOMAIN.M.003]             # Typed: what follows it
  component_of: [DOMAIN.M.004]        # Typed: part of what
tags: [extraction, knowledge, formalization]  # For search
---
```

**`related` (typed):**
- Replaces flat list `related: [DP.WP.001, DP.FM.002]`
- Each link has a type (produces, uses, fails_with, etc.)
- Enables building a Knowledge Graph and navigating by links
- Backward compatibility: flat list is still valid, but deprecated

**`tags`:**
- Free labels for full-text search
- Supplement ID-based navigation with semantic search

---

## Auto-MAP

### Requirement

MAP (`07-map/DOMAIN.MAP.001.md`) MUST be generated automatically from Pack file frontmatter.

### Mechanism

1. Script `scripts/generate-map.py` (template in SPF)
2. Run: manually, pre-commit hook, or CI
3. Input: all `.md` files in Pack with YAML frontmatter
4. Output: updated MAP + Entity Index in manifest

### What is generated

- Tables: Core Distinctions, Methods, Work Products, Failure Modes, SoTA Annotations
- Dependency graph (from typed `related:`)
- Statistics: counts, coverage, staleness (entities not updated >90 days)
- Warnings: broken links, missing summary, unregistered kinds

---

## Sub-Pack Protocol

### When to extract a Sub-Pack

A Pack extracts a sub-domain into a separate Pack when:

1. **A separate bounded context emerges** — with its own object of description and truth criteria
2. **Files > 100** in one sub-domain (indicator, not criterion)
3. **A separate maintainer appears** — a different person/team manages this part of knowledge

**Test:** if a standalone bounded context (01A) can be written for the sub-domain — it is a Sub-Pack.

### Mechanism

1. Create a new Pack repo with a separate `pack_id`
2. Register in the context registry (SPF.SPEC.001)
3. Establish cross-pack links
4. Original Pack references Sub-Pack in manifest (Dependencies)

---

## Future: MCP server for Pack

> This is an architecture description, not a current version requirement.

When Pack volume exceeds 100 files, an MCP server with the following tools is recommended:

| Tool | Description |
|------|-------------|
| `pack_search(query, kind?)` | Search entities by summary/tags + optional kind filter |
| `pack_get(id)` | Load full entity card by ID |
| `pack_list(kind)` | List all entities of a given kind |
| `pack_graph(id, depth?)` | Entity link graph (from typed related) |
| `pack_stats()` | Pack statistics: counts, staleness, coverage |

Implementation: Python + frontmatter parser + vector search (embeddings of summary fields).

---

## Checklist for Pack authors

- [ ] Each entity card <= 10,000 characters (otherwise decompose)
- [ ] Each entity card has `summary` in frontmatter
- [ ] `related:` is typed (produces, uses, fails_with, etc.)
- [ ] Entity Index in manifest is current (or auto-generated)
- [ ] MAP is generated automatically (script configured)
- [ ] At > 50 files: check whether there are Sub-Pack candidates
- [ ] At > 100 files: consider MCP server for retrieval

---

## Backward compatibility

| Change | Compatibility |
|--------|--------------|
| `summary` in frontmatter | New required field. Existing Packs: add at next update |
| Typed `related:` | Flat list is still valid, but deprecated. Migrate gradually |
| `tags` | Optional. No backward incompatibility |
| Auto-MAP | Manual MAP is still valid. Auto-generation is a recommendation, not a requirement |
| Entity Index in manifest | New required section. Add at next update |

---

*This document: `SPF.SPEC.003`*
