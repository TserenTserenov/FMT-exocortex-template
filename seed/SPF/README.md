# SPF — Second Principles Framework

> **Repository type:** `Base/Principles`

> A framework for formalizing second principles of domain areas into engineering knowledge.

## What is this

**SPF (Second Principles Framework)** is a framework of requirements and processes that defines **how second principles** of a specific domain area can be captured and stabilized as **engineering knowledge**.

SPF answers the question:
> What form and criteria are needed so that second principles become a verifiable core of the domain?

## Key concepts

| Term | Definition |
|------|------------|
| **Second principles** | Stable domain-specific patterns and distinctions within a specific area |
| **Pack (domain passport)** | Formalized engineering core of a domain — the result of applying SPF |
| **FPF** | First Principles Framework — meta-ontology and base distinctions on which SPF is built |

## What SPF defines

**Minimum mandatory elements for an engineering description of a domain:**

| Element | FPF code | Description |
|---------|----------|-------------|
| Bounded context | A.1.1 | Domain boundaries, vocabulary |
| Distinctions | A.7 | Key distinctions |
| Characteristics | A.17-A.19 | Characteristics and indicators |
| Methods | A.3.1-A.3.2 | Assessment/verification methods |
| Work Products | A.15.1 | Work products |
| Failure modes | — | Typical interpretation errors |
| SoTA | Part G | Statuses and revision criteria |

**Structure requirements:**
- Identifier and reference rules
- Canonical pack structure

**Process gates:**
- Process lint: correctness checks
- Contracts between source-of-truth and downstream

## Repository structure

```
SPF/
├── README.md              # This file
├── ontology.md            # Base SPF ontology (SPF.SPEC.002)
├── REPO-TYPE.md           # Repository type
├── docs/                  # Conceptual documentation
│   └── conceptual-model.md
├── process/               # Pack creation process
│   ├── 00-process-overview.md
│   ├── 01-domain-selection.md
│   ├── 02-bounded-context.md
│   ├── 03-distinctions-work.md
│   ├── 04-domain-entities-identification.md
│   ├── 05-information-ingestion.md
│   ├── 06-analysis-and-formalization.md
│   ├── 07-method-and-product-extraction.md
│   ├── 08-failure-modes-extraction.md
│   ├── 09-sota-annotation.md
│   ├── 10-map-maintenance.md
│   ├── 11-review-and-evolution-cycle.md
│   ├── material-ingestion-protocol.md
│   └── process-lint.md
├── spec/                  # Specifications
│   ├── ai-view.md
│   ├── downstream-contract.md
│   ├── f-g-r-trust.md        # FPF B.3 — optional pattern
│   ├── human-guides.md
│   └── SPF.SPEC.001-entity-coding.md
└── pack-template/         # Pack structure template
    ├── 00-pack-manifest.md
    ├── 01-domain-contract/  # + 01C-ontology.md (SPF.SPEC.002)
    ├── 02-domain-entities/
    ├── 03-methods/
    ├── 04-work-products/
    ├── 05-failure-modes/
    ├── 06-sota/
    └── 07-map/
```

## What SPF does NOT do

- **Does not add domain content** — SPF does not know which second principles are valid in your domain
- **Does not build courses** — training is downstream
- **Does not replace research/expertise** — SPF defines form, not content

## Level hierarchy

```
FPF (Level 1)  →  first principles framework (meta-ontology + distinctions)
       ↓
SPF (Level 2)  →  second principles framework (form + process)  ← YOU ARE HERE
       ↓
Pack           →  formalized knowledge of a specific domain
       ↓
Downstream     →  derived representations (courses, AI agents, guides)
```

## Terminology note (ailev, 2026)

Anatoly Levenchuk's DPF (Domain Principles Framework) ≈ our Pack (the SPF-instance level); his authoring layer `E.4.DPF` ≈ our SPF (the methodology/form level). No renaming planned — see `memory/fpf-reference.md` for the full correspondence table.

## SPF universality

SPF is **universal in form and process**, but **not in content**:
- Pack structure is the same for any domain
- Knowledge creation process is the same
- Lint and gates are the same
- But pack content is always domain-specific

## Related repositories

| Repository | Type | Role |
|------------|------|------|
| [ailev/FPF](https://github.com/ailev/FPF) | Framework | First Principles Framework (upstream) |
| [PACK-digital-platform](https://github.com/TserenTserenov/PACK-digital-platform) | Pack | Digital platform domain |
| Pack repositories (downstream) | Pack | Created following SPF |

## How to start creating a pack

1. Study the [conceptual model](docs/conceptual-model.md)
2. Follow the [process](process/README.md)
3. Use the [pack template](pack-template/)
4. Run [lint](process/process-lint.md) checks

---

*SPF — Second Principles Framework*
