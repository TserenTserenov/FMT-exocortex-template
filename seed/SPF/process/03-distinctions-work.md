# 03. Distinctions Work

## Purpose

Establish the conceptual vocabulary that structures all subsequent work. Distinctions are not definitions or glossary entries — they are **conceptual cuts that separate things that must not be confused**.

Without distinctions:
- Methods cannot be identified (what is a method vs. a habit?)
- Products cannot be specified (what is a product vs. a description?)
- Failure modes cannot be typed (what kind of error is this?)

---

## Why Distinctions Come First

| If distinctions come after | Result |
|---------------------------|--------|
| After methods | Methods lack criteria; anything is a "method" |
| After information | Information overwhelms; no filter |
| After products | Products are confused with descriptions |
| Never | Pack is a list of terms, not structured knowledge |

**Distinctions are the filter** that makes later stages possible.

---

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| Bounded context | Stage 02 manifest | Yes |
| FPF distinction patterns | FPF documentation | Yes |
| Domain expertise | Practitioners, literature | Yes |

---

## Activity

### 1. Import FPF Distinctions

Every pack inherits core FPF distinctions:

| FPF Distinction | Apply to Domain As |
|-----------------|-------------------|
| method vs. tool | Methods are ways of acting; tools support them |
| role vs. person | Roles are functional positions |
| work product vs. description | Products are artifacts, not narratives |
| system vs. process | Do not conflate |

These are not optional. Document how each applies to this domain.

### 2. Identify Domain-Specific Distinctions

Ask: **"What do practitioners in this domain confuse that must not be confused?"**

| Source of Distinctions | How to Find |
|-----------------------|-------------|
| Common errors | What mistakes do beginners make? |
| Expert vs. novice | What do experts separate that novices conflate? |
| Adjacent domains | What does this domain call X while another calls Y? |
| Failed practices | What confusion caused the failure? |

### 3. Formulate Each Distinction

A distinction is NOT:
- A definition ("X is...")
- A synonym list ("X is also called Y")
- A taxonomy ("X has subtypes A, B, C")

A distinction IS:
- A contrast ("X vs. Y")
- A test ("How to tell X from Y")
- A consequence ("Confusing them causes...")

### 4. Document Distinction Entry

For each distinction in `01-domain-contract/01B-distinctions.md`:

```markdown
## [D.NNN] X vs. Y

**Definition**: X is... Y is...

**Distinction Test**: [How to tell them apart]

| X | vs. | Y |
|---|-----|---|
| Property A | | Property A' |
| Property B | | Property B' |

**Typical Confusion**: [What conflation looks like]

**Why It Matters**: [Consequence of confusion]

**Related Items**: [Links to methods, failure modes]

**SoTA**: current | deprecated-interpretation | hypothesis
- Revision criterion: [What would change this]
```

### 5. Link Distinctions to Failure Modes

Every distinction implies potential failure modes:

| Distinction | Implied Failure Mode |
|-------------|---------------------|
| method vs. tool | "Tool confused with method" |
| accounting vs. planning | "Accounting confused with planning" |
| work product vs. description | "Description substituted for product" |

Note these for Stage 08.

---

## Output: Work Product

**Primary**: `/pack/<domain>/01-domain-contract/01B-distinctions.md`

**Two modes, by pack scale** (see `SPF.SPEC.003` § Size limit for domain knowledge files — reconciled 2026-07-18, drift found in PACK-digital-platform: `DS-my-strategy/inbox/bugs/drift-2026-07-18-dpd-numbering-collisions.md`):

| Mode | When | 01B contains |
|------|------|---------------|
| Single-file | Pack below the SPF.SPEC.003 scalability threshold | Index table + full entry for every distinction |
| Index + entity card | Pack has crossed the threshold | Index table only (ID, name, one-line summary, status, link); full entry lives in its own `<DOMAIN>.D.<NNN>-<slug>.md` file under `02-domain-entities/` |

A pack that switches to index+entity-card mode does NOT retroactively migrate existing single-file entries — old entries stay in 01B as-is; only new distinctions are written in the new mode going forward. Writing some new distinctions as 01B sections and others as files for the same pack after the switch re-creates a two-registry ID-collision risk (see `DP.SC.181` / `check-id-collision-delta.sh`, which blocks staged additions of new section headers to an already-existing `*-distinctions.md` file) — pick one mode per pack and hold it.

Index table (ID, name, status, related items) is present in 01B in both modes.

---

## Completion Criteria

| Criterion | Test |
|-----------|------|
| FPF distinctions imported | Core FPF distinctions documented for domain |
| Domain distinctions identified | At least 5 domain-specific distinctions |
| Each distinction has test | "How to tell X from Y" is answerable |
| Each distinction has consequence | "Why confusion matters" is specified |
| Failure mode candidates noted | Implied FMs identified (for Stage 08) |
| SoTA status assigned | Each distinction has status + revision criterion |

---

## Typical Errors

### E1. Distinctions Are Definitions

**Symptom**: "Time accounting is the practice of recording time" (no contrast)

**Problem**: Definitions don't prevent confusion; distinctions do.

**Correction**: Always state "X vs. Y" — what is this NOT?

### E2. Distinctions Are Terminology Lists

**Symptom**: List of terms without contrasts or tests.

**Problem**: Terms without distinctions are labels, not concepts.

**Correction**: For each term, identify what it must not be confused with.

### E3. Skipping to Methods

**Symptom**: "We know the methods, let's skip distinctions."

**Problem**: Methods will be poorly bounded; tool/method confusion will occur.

**Correction**: Complete distinctions before methods. If methods are "known," use them to derive distinctions.

### E4. Distinctions Without Tests

**Symptom**: "Method is different from tool" but no way to tell which is which.

**Problem**: Distinction exists in theory but cannot be applied.

**Correction**: Every distinction needs an operational test.

### E5. Missing Failure Mode Links

**Symptom**: Distinction documented but no corresponding failure mode.

**Problem**: The confusion the distinction prevents is not formalized.

**Correction**: For each distinction, create or reference a failure mode.

### E6. FPF Contradictions

**Symptom**: Domain distinction uses "method" differently than FPF.

**Problem**: Pack will be inconsistent with other packs.

**Correction**: Align with FPF or explicitly note the extension.

---

## Distinctions vs. Later Stages

| Stage | Relationship to Distinctions |
|-------|------------------------------|
| 04 Domain Entities | Entities are identified using distinctions |
| 05 Information Ingestion | Distinctions filter relevant information |
| 06 Analysis | Distinctions are the analytical lens |
| 07 Method Extraction | Distinctions define what counts as a method |
| 08 Failure Modes | Each distinction implies potential failures |

---

## Transition to Next Stage

When Distinctions Work is complete:
- `01-domain-contract/01B-distinctions.md` exists with indexed entries
- FPF distinctions are domain-applied
- Domain-specific distinctions are formulated with tests
- Failure mode candidates are noted

Proceed to [04. Domain Entities Identification](04-domain-entities-identification.md) to identify stable structures.
