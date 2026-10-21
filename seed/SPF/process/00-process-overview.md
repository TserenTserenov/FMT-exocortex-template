# 00. Process Overview

## What This Process Is

This is a **normative process for creating and maintaining SPF packs** — repositories of second-level principles (domain knowledge) built on top of FPF.

| This process is | This process is not |
|-----------------|---------------------|
| Normative (prescribes what must happen) | Advisory (suggests what might help) |
| Activity description | System description |
| Repeatable across domains | Specific to one domain |
| Iterative and continuous | Linear and finite |

---

## Types of Activity Covered

This process covers four types of knowledge work:

| Activity | Description | When Triggered |
|----------|-------------|----------------|
| **Creation** | Building a new pack from scratch | New domain selected |
| **Extension** | Adding new elements (methods, products, failures) | Gap identified in existing pack |
| **Refinement** | Clarifying existing elements | Ambiguity or confusion observed |
| **Revision** | Changing status of claims (SoTA updates) | Evidence changes |

All four activities follow the same process stages; they differ in entry point and scope.

---

## Why the Process Does Not Start with Information

Common mistake: "We have sources/books/articles — let us extract knowledge."

This fails because:

| Starting Point | Problem |
|----------------|---------|
| Information (books, articles) | No filter for relevance; everything looks important |
| Practices ("what people do") | Captures habitual action, not principled knowledge |
| Terminology ("key terms") | Terms without distinctions are labels, not concepts |

**Correct starting point**: Distinctions.

Distinctions determine:
- What counts as information (vs. noise)
- What practices are methods (vs. habits)
- What terms are meaningful (vs. jargon)

Without distinctions first, the process has no criteria for selection or rejection.

---

## Process Stages

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  ┌──────────────┐                                           │
│  │ 01. Domain   │                                           │
│  │   Selection  │                                           │
│  └──────┬───────┘                                           │
│         ↓                                                   │
│  ┌──────────────┐                                           │
│  │ 02. Bounded  │                                           │
│  │   Context    │                                           │
│  └──────┬───────┘                                           │
│         ↓                                                   │
│  ┌──────────────┐     ┌──────────────┐                      │
│  │ 03. Distinct-│ ←── │ 11. Review & │ ←─────────┐          │
│  │     ions     │     │   Evolution  │           │          │
│  └──────┬───────┘     └──────────────┘           │          │
│         ↓                    ↑                   │          │
│  ┌──────────────┐            │                   │          │
│  │ 04. Domain   │            │                   │          │
│  │   Entities   │            │                   │          │
│  └──────┬───────┘            │                   │          │
│         ↓                    │                   │          │
│  ┌──────────────┐            │                   │          │
│  │ 05. Info     │            │                   │          │
│  │   Ingestion  │            │                   │          │
│  └──────┬───────┘            │                   │          │
│         ↓                    │                   │          │
│  ┌──────────────┐            │                   │          │
│  │ 06. Analysis │            │                   │          │
│  │   & Formal.  │            │                   │          │
│  └──────┬───────┘            │                   │          │
│         ↓                    │                   │          │
│  ┌──────────────┬──────────────┬──────────────┐  │          │
│  │ 07. Methods  │ 08. Failure  │ 09. SoTA     │  │          │
│  │ & Products   │    Modes     │  Annotation  │  │          │
│  └──────┬───────┴──────┬───────┴──────┬───────┘  │          │
│         └──────────────┼──────────────┘          │          │
│                        ↓                         │          │
│                 ┌──────────────┐                 │          │
│                 │ 10. Map      │─────────────────┘          │
│                 │ Maintenance  │                            │
│                 └──────────────┘                            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Iteration, Not Linearity

The process is **not** "do steps 1–11 once."

| Pattern | Description |
|---------|-------------|
| **Full cycle** | New pack: 01 → 02 → 03 → ... → 11 → 03 → ... |
| **Extension loop** | New method: 05 → 06 → 07 → 10 → (back to 05 or 11) |
| **Refinement loop** | Clarify distinction: 03 → 10 → 11 → 03 |
| **Revision loop** | Update SoTA: 09 → 10 |

Stage 11 (Review & Evolution) always loops back to earlier stages.

---

## Human and AI Collaboration

This process is designed for both human and AI execution.

| Actor | Strengths | Constraints |
|-------|-----------|-------------|
| **Human** | Domain expertise, judgment, novelty detection | Time, consistency, coverage |
| **AI** | Consistency, coverage, pattern matching | Needs explicit criteria; cannot originate distinctions |

**Division of labor**:
- Humans: Originate distinctions, judge correctness, decide SoTA status
- AI: Apply distinctions consistently, identify gaps, maintain structure
- Both: Analysis, formalization, extraction

**AI must not**:
- Invent distinctions without human validation
- Change SoTA status without evidence
- Skip process stages

---

## Entry Points by Activity Type

| Activity | Entry Stage | Rationale |
|----------|-------------|-----------|
| New pack | 01 | Must establish domain and context first |
| New method (same domain) | 05 or 06 | Distinctions exist; need information |
| New failure mode | 06 | Emerges from analysis |
| SoTA update | 09 | Evidence changed |
| Distinction refinement | 03 | Confusion identified |
| Structural change | 02 | Boundaries changed |

---

## Work Products by Stage

| Stage | Primary Work Product |
|-------|---------------------|
| 01 | Domain name and boundary statement |
| 02 | `00-pack-manifest.md` with bounded context |
| 03 | `01-domain-contract/01B-distinctions.md` entries |
| 04 | `02-domain-entities/` files |
| 05 | Ingestion log (not in pack) |
| 06 | Candidate list (not in pack) |
| 07 | `03-methods/` and `04-work-products/` files |
| 08 | `05-failure-modes/` files |
| 09 | `06-sota/` files |
| 10 | `07-map/` files |
| 11 | Review log, change decisions |

---

## Extension Mechanism

> **Invariant:** SPF and FPF are **read-only upstream** for every Pack. Local customization happens in `PACK-X/pack/X/`, never by editing `SPF/` or `FPF/`. Direct modification of upstream breaks `update.sh` and loses customizations on the next upgrade.

### What is upstream

| Layer | Location | Status from a Pack's perspective |
|-------|----------|----------------------------------|
| FPF | `~/IWE/FPF/` | Read-only — first principles, meta-ontology |
| SPF | `~/IWE/SPF/` (this repo) | Read-only — form (`pack-template/`), process (`process/`), specs (`spec/`) |
| Pack | `PACK-X/pack/X/` | Writable — domain content authored locally |

Reading upstream is unrestricted. Writing to upstream from inside Pack work is forbidden.

### What is extension

An **extension** is a local artifact inside `PACK-X/pack/X/<section>/` that **adds to** or **replaces** an upstream element without modifying upstream. Extensions live in the section of the Pack that mirrors the upstream concept:

| Upstream concept | Local extension location |
|------------------|--------------------------|
| `pack-template/01-domain-contract/01B-distinctions.md` (form) | `PACK-X/pack/X/01-domain-contract/01B-distinctions.md` (Pack's own distinctions) |
| `pack-template/03-methods/_method-card-template.md` (form) | `PACK-X/pack/X/03-methods/<METHOD>.md` (Pack's own methods) |
| `pack-template/05-failure-modes/` (form) | `PACK-X/pack/X/05-failure-modes/` (Pack's failure modes) |
| FPF distinction (e.g. A.7: Method ≠ Tool) | Pack-local distinction that refines or specializes the FPF one, with explicit `extends: FPF.A.7` |

The Pack's section is **the** extension point — by construction. There is no separate `*-ext.md` naming convention; the Pack's mirror file **is** the extension of the corresponding upstream form.

### Rules

| Rule | Statement |
|------|-----------|
| **R1. Mirror, do not edit** | Add Pack-local content to `PACK-X/pack/X/<section>/`. Never edit `SPF/pack-template/<section>/` or `SPF/process/`. |
| **R2. Read order** | Upstream is read first (form, process); Pack-local content is read after (domain content). Pack-local content cannot remove upstream constraints — it can only add specializations within them. |
| **R3. Explicit reference** | When a Pack entity refines an upstream entity, the Pack file references it explicitly (`extends: FPF.A.7`, `references: SPF.SPEC.005`). Silent override is forbidden. |
| **R4. Process changes go through SPF spec workflow** | A change to the process itself (steps, lint rules, template structure) is **not** an extension — it is an SPF specification change, handled per `SPF/CLAUDE.md §8.1`, with explicit downstream notification. |

### Anti-pattern

Directly editing `SPF/process/*.md`, `SPF/spec/*.md`, `SPF/pack-template/**`, or `FPF/FPF-Spec.md` from inside Pack work:
- Local edits are silently overwritten on the next `update.sh` / `git pull` of SPF/FPF, losing the customization.
- If kept locally via merge conflict resolution, the Pack diverges from upstream and breaks `process-lint.md` validation.
- Cross-Pack consistency fails: other Packs cannot see the local edit and apply different forms.

The correct response to a felt need to "edit SPF" is one of:
1. Place the change in the Pack's mirror section (extension — R1).
2. If the change is structural (affects all Packs), open a separate SPF specification change per `SPF/CLAUDE.md §8.1`.

### Application by Pack Creator (R30) mode

The Pack Creator role (DP.ROLE.062, DP.SC.048) uses the extension mechanism differently depending on the author's `cp.iwe` stage:

| Mode | Stage | Use of extension mechanism |
|------|-------|----------------------------|
| **Assembly** | cp.iwe ≤ 2 | Skill extracts distinction candidates from the Pack's own SoTA sources (`06-sota/`, Step 1.5), presents them as a checklist. Author selects applicable candidates into their own `01-domain-contract/01B-distinctions.md`. The author's stated practice is a gated fallback only (when `sota_sources: none`; must be formalized into `06-sota/` as `source: author practice` with claims/evidence). Neighboring Packs are referenced only for form (heading structure, maturity checklist), never for content. No upstream touched. |
| **Hybrid** | cp.iwe = 3 | Author starts from SoTA-derived candidates, modifies for own domain — writes only in `PACK-X/pack/X/`. Neighboring Packs: form only. |
| **Full SPF** | cp.iwe ≥ 4 | Author originates own distinctions, writes in `PACK-X/pack/X/`. Upstream still read-only. |

In all three modes, R30 blocks any write attempt to `SPF/` or `FPF/` (logged as `upstream_touch: BLOCKED_WRITE_ATTEMPT`) and redirects to the appropriate Pack section.
