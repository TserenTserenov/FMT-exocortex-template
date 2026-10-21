---
id: SPF.SPEC.002
name: Ontology
status: draft
created: 2026-02-10
---

# Ontology Specification

> Ontology architecture: FPF → SPF → Pack → Downstream.
> How concepts are inherited, how Pack describes its ontology, who changes it.

---

## 1. Ontology architecture

### 1.1. Four levels

```
FPF (meta-ontology)      — universal concepts: System, Method, Role, ...
       ↓ inherits
SPF (base ontology)      — fixes FPF concepts + Pack entity types
       ↓ inherits
Pack (domain ontology)   — domain concepts, each linked to an SPF concept
       ↓ references
Downstream               — uses Pack concepts, does not define new ones
```

### 1.2. Inheritance principles

| Rule | Description |
|------|-------------|
| **SPF ← FPF** | SPF ontology is extended **only** from FPF. No domain concepts |
| **Pack ← SPF** | Each Pack concept **must** have a parent concept from the SPF ontology |
| **Downstream ← Pack** | Downstream references Pack concepts. Does not introduce new concepts |
| **Owner of changes** | The ontology at any level is changed **only by the Knowledge Extractor** (DP.AISYS.013) |

### 1.3. Who defines what

| Level | Defines | Does not define |
|-------|---------|----------------|
| FPF | Universal concepts (U.*) | Domain concepts |
| SPF | Fixes FPF concepts + entity types + format | Domain content |
| Pack | Domain concepts linked to SPF | Concepts of other domains |
| Downstream | Nothing new | Does not define, only references |

---

## 2. SPF base ontology (inherited from FPF)

> These concepts are universal — the same for all domains.
> Source: FPF-Spec, Part A (Kernel Architecture Cluster).

### 2.1. Fundamental types

| FPF ID | Concept | EN | Definition |
|--------|---------|-----|-----------|
| U.Entity | Entity | Entity | Primitive of distinction — everything that can be singled out and named |
| U.Holon | Holon | Holon | Composition unit: a whole composed of parts, itself being a part |
| U.System | System | System | Holon with a boundary interacting with its environment |
| U.Episteme | Episteme | Episteme | Unit of knowledge/description as an artifact |
| U.BoundedContext | Bounded Context | Bounded Context | Semantic frame with its own vocabulary, roles and invariants |
| U.Boundary | Boundary | Boundary | Separation of internal and external |
| U.Interaction | Interaction | Interaction | Exchange across a system boundary |

### 2.2. Transformation (action and change)

| FPF ID | Concept | EN | Definition |
|--------|---------|-----|-----------|
| U.Method | Method | Method | Abstract way of acting (capability) that produces a work product |
| U.MethodDescription | Method Description | Method Description | Recipe/instruction for executing a method |
| U.Work | Work | Work | Record of a completed action (occurrence) |
| U.WorkPlan | Work Plan | Work Plan | Schedule of intent |

### 2.3. Roles and capabilities

| FPF ID | Concept | EN | Definition |
|--------|---------|-----|-----------|
| U.RoleAssignment | Role Assignment | Role Assignment | Contextual binding of a role to a holder (Holder#Role:Context) |
| U.Capability | Capability | Capability | Dispositional property — the ability to perform an action |
| U.ServiceClause | Service Clause | Service Clause | Service contract (promise content) |
| U.Commitment | Commitment | Commitment | Deontic object (obligation/permission/prohibition) |

### 2.4. Types and measurement

| FPF ID | Concept | EN | Definition |
|--------|---------|-----|-----------|
| U.Kind | Kind/Type | Kind | Classification unit with intension and extension |
| U.Characteristic | Characteristic | Characteristic | Measurable evaluation axis for an object |
| U.Flow | Flow | Flow | Evolution of constraints (constraint validity) |

### 2.5. Key FPF distinctions (A.7 Strict Distinction)

| Distinction | Meaning |
|------------|---------|
| Object ≠ Description ≠ Carrier | Thing in reality ≠ model of thing ≠ file where the model resides |
| Role ≠ Role holder | Function (Role) ≠ the one who performs it (Holder) |
| Method ≠ Method description ≠ Work | Capability ≠ recipe ≠ fact of execution |
| Characteristic ≠ Metric ≠ Indicator | Evaluation axis ≠ unit of measurement ≠ observable sign |
| Knowledge ≠ Learning ≠ Representation | Pack ≠ course/training ≠ specific assembly for an audience |

> **Update.** When a new concept is added to FPF — it must be added to this table.

---

## 3. SPF entity types

> SPF defines entity types that Pack uses to organize knowledge.
> Each type is linked to one or more FPF concepts.

| Code | Type | FPF concept | Definition |
|------|------|-------------|-----------|
| `M` | Method | U.Method | Description of a capability to produce a work product |
| `WP` | Work Product | U.Work + U.Episteme | Observable result of applying a method |
| `FM` | Failure Mode | — (SPF-specific) | Typical violation of a method with observable symptoms |
| `D` | Distinction | A.7 Strict Distinction | Conceptual boundary whose violation causes confusion |
| `R` | Role | U.RoleAssignment | Contextual function in a bounded context |
| `CHR` | Characteristic | U.Characteristic | Measurable evaluation axis for an entity |
| `SOTA` | SoTA annotation | — (SPF-specific) | Currency status of a statement + revision criterion |
| `MAP` | Map | U.Episteme | Navigation structure of connections between entities |
| `SC` | Service Clause | U.ServiceClause | Service contract: for whom, why, what they receive, acceptance criterion |

---

## 4. Requirements for Pack ontology

### 4.1. Placement

```
<repo>/ontology.md    — in the root of each repo
```

Uniform placement: `ontology.md` in the repo root at **all levels** (SPF, Pack, Downstream). For Downstream the file references Pack and SPF-ontology concepts and introduces no new concepts.

### 4.2. Required sections

#### Section 1: Entity types

All Pack types (base from SPF + extended) linked to SPF:

| Code | Type | FPF/SPF concept | Definition | not (what this is NOT) |
|------|------|-----------------|-----------|------------------------|
| `M` | Method | U.Method | ... | not a scenario |
| `ARCH` | Architecture | U.System + U.Episteme | ... | not an implementation |

**Required column "FPF/SPF concept"** — parent concept from the base ontology (section 2 of this document). Each extended Pack type must specify which FPF concept it belongs to.

#### Section 2: Domain glossary

Key domain concepts linked to the SPF ontology:

| Term | Definition | Parent concept (SPF) | Related to |
|------|-----------|---------------------|-----------|
| Digital platform | Digital ecosystem environment | U.System | DP.ARCH.001 |
| AI system | System using LLM | U.System + U.Capability | DP.ROLE.001 |

**Required column "Parent concept (SPF)"** — which universal concept from the base ontology this domain term belongs to.

#### Section 3: Relations between types

As in the current version (unchanged).

#### Section 4 (opt.): Type hierarchy

#### Section 5 (opt.): Cross-Pack links

### 4.4. Competency Questions (CQ)

> Method from ontology engineering: before a Pack is accepted, it must answer 3–5 questions that define its purpose.
> CQ are not machine-checkable — they are a **Definition of Done** for the Pack author and reviewer.

**Requirement:** Each new Pack (created after the adoption of this section) must contain 3–5 Competency Questions in its `00-pack-manifest.md` under the section `## Competency Questions`.

**Examples of valid CQ:**
- «Can entity X be both type A and type B at the same time?» — checks disjointness coverage
- «What work products are produced by applying method M?» — checks completeness of WP coverage
- «What happens to downstream repositories if concept Y is removed from this Pack?» — checks downstream impact
- «Which distinctions in this Pack have a test boundary?» — checks operational readiness
- «What is the fallback chain for a concept not found in this Pack?» — checks inheritance correctness

**Acceptance criteria for CQ:**
1. Each CQ is answerable from the Pack's ontology.md and 01B-distinctions.md
2. At least one CQ covers type disjointness (D.* coverage)
3. At least one CQ covers downstream impact (Pack → DS relationship)
4. CQ are written in the primary language of the Pack (RU for IWE Packs)

**Migration strategy (soft-gate):**
- Existing Packs: CQ are **recommended** — linter emits a warning if `00-pack-manifest.md` lacks the `## Competency Questions` section
- New Packs (created after SPF.SPEC.002 update): CQ are **required** — linter emits an error (non-blocking in CI, blocking in review gate)
- Existing Packs undergoing significant ontology update: CQ are **required** for new or changed concepts

---

### 4.3. Downstream requirements

Downstream repositories (code, bots, courses) contain two kinds of concepts:

#### Reference concepts (from Pack)

Downstream **references** Pack and SPF-ontology concepts. These concepts are not redefined — used as-is with source indicated.

#### Own concepts (implementation)

Downstream **may** introduce its own concepts specific to the implementation (code terminology, UI terms, internal abstractions). Requirements:

1. **Linked to Pack.** Each own concept must be connected to a concept from the upstream Pack's ontology.md
2. **Domain check.** The Knowledge Extractor upon discovering a new concept in downstream checks: is it a domain concept (universal to the subject area)?
   - **Yes, domain** — propose adding to Pack (via Extraction Report), keep a reference in downstream
   - **No, implementation** — keep in downstream ontology.md with a link to the Pack concept
3. **No duplication.** If the concept already exists in Pack — reference it, do not redefine

#### Test: domain vs implementation

| Criterion | Domain (Pack) | Implementation (Downstream) |
|-----------|--------------|------------------------------|
| Used in another downstream? | Yes | No |
| Tied to specific code/UI? | No | Yes |
| Makes sense without this repo? | Yes | No |

#### Required sections of downstream ontology.md

| Section | Content |
|---------|---------|
| Upstream dependencies | Which Packs and SPF are used |
| Concepts used from Pack | Reference concepts with indication of how they are used |
| Implementation terminology | Own concepts linked to Pack |

---

## 5. Rules

1. **Inheritance FPF → SPF.** The base ontology (section 2) is extended only from FPF. No domain concepts should be in the SPF ontology
2. **Parent link.** Each Pack domain concept must have a parent concept from the SPF ontology
3. **Owner of changes — Extractor.** The ontology (`ontology.md`) at all levels is changed only by the Knowledge Extractor (DP.AISYS.013). The user proposes changes; the Extractor formalizes, validates and applies them
4. **Completeness.** The ontology includes ALL Pack entity types
5. **Consistency.** Definitions in the ontology = definitions in the bounded context
6. **No duplication.** Distinctions remain in `01B-distinctions.md`
7. **Coding.** Type codes — per SPF.SPEC.001
8. **Currency.** When adding an entity — update the ontology
9. **Cross-level links.** Concepts between levels are linked, not overlapping:

| Level | Link to level above | Own concepts |
|-------|---------------------|-------------|
| FPF | — | Universal (U.*) |
| SPF | Inherits FPF | Entity types, format |
| Pack | Extends SPF, linked to U.* | Domain concepts |
| Downstream | References Pack + own implementation | Implementation, linked to Pack |

10. **Cascading.** When ontology.md changes at a higher level — check and update lower ones (SPF → Pack → Downstream)
11. **Bilingualism (DDD UL).** The domain glossary (section 2 in Pack, section 2 in downstream) must contain Term (RU) and Term (EN) columns. EN is used in code, files, git. RU — in documents and discourse
12. **Abbreviations.** Each ontology.md contains an Abbreviations section. Abbreviations are inherited top-down (FPF/SPF → Pack → Downstream) with indication of origin level
13. **Language of documents.** Russian is the primary language of all IWE templates, protocols and documents. English is permitted only for: (a) technical keys (YAML frontmatter: `type`, `status`, `date`), (b) established abbreviations from the Abbreviations section, (c) proper names (GitHub, Railway). English phrases with a Russian equivalent are not permitted. Established loanwords are permitted

---

## 6. Abbreviations (FPF/SPF level)

> Abbreviations defined at the FPF and SPF level. Packs inherit them and add their own.

| Abbreviation | Full form (RU) | Full form (EN) | Level |
|-------------|----------------|----------------|-------|
| FPF | First Principles Framework | First Principles Framework | FPF |
| SPF | Second Principles Framework | Second Principles Framework | SPF |
| UL | Ubiquitous Language | Ubiquitous Language | FPF (DDD) |
| BC | Bounded Context | Bounded Context | FPF (DDD) |
| UTS | Unified Terminology System | Unified Terminology System | FPF |
| SoTA | State of the Art | State of the Art | SPF |
| KE | Knowledge Extraction | Knowledge Extraction | SPF |
| FM | Failure Mode | Failure Mode | SPF |
| WP | Work Product | Work Product | SPF |
| M | Method | Method | SPF |
| D | Distinction | Distinction | SPF |
| R | Role | Role | SPF |
| CHR | Characteristic | Characteristic | SPF |
| MAP | Map | Map | SPF |
| IPO | Input-Processing-Output | Input-Processing-Output | SPF |

---

## 7. Relationship to other specifications

| Specification | Relationship |
|--------------|-------------|
| FPF-Spec (Part A) | Source of base ontology (section 2) |
| SPF.SPEC.001 (coding) | Entity type codes |
| 01A-bounded-context | Domain boundaries; ontology defines concepts within boundaries |
| 01B-distinctions | Distinctions; ontology references them |
| 00-pack-manifest | Registration of extended types |
| 07-map | Links between specific entities (ontology — between types) |
| DP.AISYS.013 (Extractor) | Sole agent that changes the ontology |

---

*This document: `SPF.SPEC.002`*
