---
created: 2026-02-10
id: SPF.SPEC.001
name: Entity Coding Rule
status: draft
---

# Entity Coding Rule

> SPF specification: how to identify and code entities across all Packs and in SPF itself.

---

## Foundation (FPF)

### Object ≠ Description ≠ Carrier

FPF (A.7 Strict Distinction) requires distinguishing:

| Level | What it is | Example |
|-------|-----------|---------|
| **Object** | Thing in reality | Knowledge extraction method (capability) |
| **Description** | Episteme about the thing (U.Episteme) | Method card in Pack |
| **Carrier** | Physical/digital medium (U.SymbolCarrier) | File `DP.M.001-knowledge-extraction.md` |

**Pack contains descriptions of domain entities on carriers (`.md` files).** The code indicates what is being described, not the level of description.

---

## Terminology

### Entity types

SPF defines **base types** — they may appear in any domain.

| Type | EN | Definition | not (what this is NOT) |
|------|----|-----------|-----------------------|
| **Method** | Method | Description of a capability to produce a work product | not a scenario (step-by-step instruction), not a tool, not execution (work) |
| **Work Product** | Work Product | Observable result of applying a method; exists on a carrier | not a method description, not a skill |
| **Failure Mode** | Failure Mode | Typical violation of a method or work product with observable symptoms | not a code bug, not a risk (probability) |
| **Distinction** | Distinction | Conceptual boundary whose violation creates irresolvable confusion | not a fact, not a definition |
| **Role** | Role | Contextual function (mask) in a bounded context | not a position, not a person, not behavior |
| **Characteristic** | Characteristic | Measurable evaluation axis for an entity | not a metric (measurement), not an indicator (observable sign) |
| **SoTA Annotation** | SoTA Annotation | Currency status of a statement + revision criterion | not a literature review |
| **Map** | Map | Navigation structure of connections between entities | = structural artifact, not content |

### Domain entities

A Pack may contain entities specific to its bounded context. For these, the Pack defines **extended types** and registers them in the manifest (`00-pack-manifest.md`).

### Distinction: type ≠ characteristic

- **Type** — category of the entity (what it belongs to): method, role, work product.
- **Characteristic** — measurable axis (how the entity is evaluated): complexity, maturity, currency.

Type answers "what is it?". Characteristic answers "what is it like?".

---

## Coding rule

### Code format

All identifiable entities are coded by a single rule:

```
<CONTEXT>.<TYPE>.<NUMBER>
```

| Segment | Format | Definition |
|---------|--------|-----------|
| CONTEXT | 2–4 uppercase Latin letters | Bounded context mnemonic (FPF: U.BoundedContext) — semantic frame with its own vocabulary, roles and invariants |
| TYPE | 1–6 uppercase Latin letters | Entity type code. Base types — from SPF; extended types — from Pack |
| NUMBER | 3 digits | Sequential numbering within context + type |

### Code properties

1. **Immutability** — code does not change after assignment
2. **Uniqueness** — one code = one entity, forever
3. **No reuse** — deleted/deprecated entities retain their code
4. **Sequence** — numbers are assigned in order of creation
5. **Gaps are permitted** — `001, 002, 005` is valid (003, 004 may be deprecated)

> **Uniqueness enforcement (WP-388 Phase 14, DP.SC.181).** Concurrent agents picking
> `max+1` independently can collide on the same number. `scripts/check-id-collision-delta.sh`
> (wired into the `pre-commit-pack-map` hook) blocks any commit whose newly added
> entity file reuses an existing code, and suggests the next free one. Global
> `pack-lint.sh` stays a warning; CI `check-pack-collisions.sh` is the backstop.

---

## Type codes

### Base types (defined by SPF, available to all Packs)

| Code | Type | Folder in Pack |
|------|------|---------------|
| `M` | Method | `03-methods/` |
| `WP` | Work Product | `04-work-products/` |
| `FM` | Failure Mode | `05-failure-modes/` |
| `D` | Distinction | `01-domain-contract/` |
| `R` | Role | `02-domain-entities/` |
| `CHR` | Characteristic | `02-domain-entities/` |
| `SOTA` | SoTA Annotation | `06-sota/` |
| `MAP` | Map | `07-map/` |
| `SC` | Service Clause | `08-service-clauses/` |

### Extended types (defined by a specific Pack)

A Pack may define additional types for its domain entities. They:

- Are registered in the Pack manifest (`00-pack-manifest.md`)
- Are placed in `02-domain-entities/`
- Code: 1–6 uppercase Latin letters, unique within the Pack

### SPF types (for the framework itself)

| Code | Type | Description |
|------|------|-------------|
| `SPEC` | Specification | Normative specification (rule) |
| `TPL` | Template | Structure template |
| `D` | Distinction | Distinction (common to all Packs) |
| `MAP` | Map | SPF navigation map |

---

## Levels and coding

| Level | Codes itself? | Format | Creates new codes? |
|-------|--------------|--------|--------------------|
| **FPF** | Yes | `U.*` (own format) | Yes (meta-level) |
| **SPF** | Yes | `SPF.TYPE.NUMBER` | Yes (form rules) |
| **Pack** | Yes | `CONTEXT.TYPE.NUMBER` | Yes (domain knowledge) |
| **Downstream** | No | References Pack codes | No |

---

## Context registry

| Code | Context | Level | Repo |
|------|---------|-------|------|
| `SPF` | Second Principles Framework | Framework | SPF/ |
| `PD` | Personal Development | Pack | PACK-personal/ |
| `DP` | Digital Platform | Pack | PACK-digital-platform/ |
| `EC` | Ecosystem | Pack | PACK-ecosystem/ |
| `MIM` | Engineering Managers Workshop | Pack | PACK-MIM/ |
| `VR` | Verification & Acceptance | Pack | PACK-verification/ |

Requirements for a new context code:

- 2–4 uppercase Latin letters
- Bounded context mnemonic
- Globally unique (in this registry)

---

## File name

```
<CODE>-<slug>.md
```

- **Code** — full entity code
- **Slug** — Latin characters, kebab-case, without repeating the number

Examples:

```
SPF.SPEC.001-entity-coding.md
DP.M.001-knowledge-extraction.md
DP.AISYS.013-knowledge-extractor.md
EC.R.001-mentor.md
```

---

## References

### Within a single Pack

```markdown
See [DP.M.001](../03-methods/DP.M.001-knowledge-extraction.md)
```

### Cross-Pack references

```markdown
See [DP.M.001](https://github.com/.../03-methods/DP.M.001-knowledge-extraction.md)
```

With version:

```markdown
See [DP.M.001@v1.0.0](https://github.com/...@v1.0.0/.../DP.M.001-knowledge-extraction.md)
```

### References to FPF

```markdown
Per FPF, method ≠ tool (see FPF A.7, Strict Distinction).
```

### In YAML Frontmatter

```yaml
---
id: DP.M.001
name: Knowledge Extraction
status: active
created: 2026-02-10
related:
  - DP.WP.001
  - DP.FM.002
---
```

---

## Validation

Codes are validated for:

- [ ] Format: `CONTEXT.TYPE.NNN`
- [ ] Uniqueness within repo
- [ ] File exists at expected path
- [ ] All references resolve
- [ ] Extended types are registered in Pack manifest

---

## NameCard Extension

> Added 2026-08-05 (WP-474 Phase 8.6c, design consensus 2026-07-17, pilot decision on
> semantics 2026-08-05). Governs the durable **Plain/Tech name pair** for a
> term, distinct from the entity **code** defined above — a code (`DP.M.001`)
> is an immutable pointer; a NameCard governs the human-facing *name* attached
> to that pointer, which can legitimately be revisited without touching the
> code.

### Why a separate mechanism

An entity's code (`CONTEXT.TYPE.NNN`) never changes once assigned — that stability is
the point. But the **name** a term is known by (`plain` for a general reader,
`tech` for precise cross-reference) is a naming decision with its own
candidates, rejected alternatives and rationale — the kind of decision that,
left undocumented, gets silently re-litigated by the next author who wasn't
there for the first one. NameCard makes that decision durable and inspectable
without freezing the code itself.

### Trigger — not a `status:` value

Earlier drafts of this design assumed a `status: public` value would gate the
requirement. Live inventory (2026-07-24, 2960+ Pack files) found `public`
appears **zero times** as an actual `status:` value anywhere — the real values
in use are `active`, `draft`, and others unrelated to name durability. Gating
on a non-existent value would have made the gate permanently inert.

**Correct trigger: the act of creating a NameCard is itself the "this name is
now public-grade" declaration** — not a side effect of any existing `status:`
value, and not automatically inferred from `active`. An author decides a term
has reached durable, cross-referenced naming (used by other Packs, cited by ID
outside this Pack, or the author simply wants it locked) and *at that point*
creates the NameCard. Until that decision is made, a term can carry any
`status:` value (including `active`) without a NameCard — there is no implicit
backfill obligation for entities already `active` at the time this extension
was added (thousands, across all Packs); NameCard coverage grows forward, one
deliberate promotion at a time, not retroactively.

### Level A — frontmatter block (per-entity, lightweight)

Added to the entity file's YAML frontmatter alongside `id`/`name`/`status`:

```yaml
name_card:
  governed_value_ref: <FPF value-type this name resolves against — not a row id by default>
  bounded_context_ref: <context registry entry this name is scoped to>
```

Static reference fields — they point at where the name's authority lives, not
the naming history itself (that's Level B).

### Level B — per-entity history file

`09-name-cards/<code>.yaml` (one file per entity that has a NameCard; empty
directory at Pack scaffold, per-entity file created on first promotion):

```yaml
code: <CONTEXT.TYPE.NNN>              # same code as the entity file
plain: <name for a general reader>
tech: <name for precise cross-reference>
candidate_set: []                     # names considered
rejected_candidates: []               # [{name, reason}] — why each alternative lost
selection_rationale: ""               # why the chosen pair, one paragraph
lineage_entries: []                   # append-only: [{date, event, note}]
```

`lineage_entries` is append-only — a later rename adds an entry, it does not
edit or remove prior ones (same provenance principle as `superseded-by` for
DR-records, `SPF.SPEC.` design pattern reused here, not reinvented).

### Both levels required together

A NameCard is complete only with both Level A (frontmatter pointer) and
Level B (history file) present. Level A without Level B is a dangling
reference; Level B without Level A is an orphaned history nobody's frontmatter
points to. `pack-creator` creates both together (see Pack process
docs) — never one without the other.

### Deferred (not in this extension)

`LocalSenseRef`, `RefreshCondition`, `UnifiedTermRowRef` — named in the
original design pass but out of scope until a live case needs them. Adding
them speculatively would be exactly the kind of un-requested field growth
this spec elsewhere warns against (see Code properties: no reuse, sequential,
gaps permitted — the same minimalism applies to schema fields, not just
codes).

---

*This document: `SPF.SPEC.001`*
