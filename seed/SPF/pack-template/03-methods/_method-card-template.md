# Method Card Template

Copy this file to create a new method card. Replace all `_TBD_` and `DOMAIN.M.XXX` placeholders.

> **2026-07-11 — ADDITIVE CHANGE:** added `Forces` and `Bias-Annotation` sections (WP-448 Phase 9), initially optional.
> **2026-07-27 — REQUIRED FOR NEW CARDS (WP-448 Phase 12, decision B):** both sections are now required content for any method card created from this point forward — not headers left as placeholder. This does not retroactively invalidate cards created before 2026-07-27; the backlog of pre-existing cards is migrated separately under WP-448 Phase 12 batches, not by this template change.

---

## YAML Frontmatter

```yaml
---
id: DOMAIN.M.XXX
name: _Method Name_
status: draft | active | deprecated
summary: "_One sentence (≤150 chars) describing this method for index and retrieval_"
sota: current | deprecated-interpretation | hypothesis
created: YYYY-MM-DD
last_updated: YYYY-MM-DD
related:                                    # Typed relations (SPF.SPEC.003)
  produces: [DOMAIN.WP.XXX]               # Work products this method produces
  uses: [DOMAIN.D.XXX]                    # Distinctions/entities it relies on
  fails_with: [DOMAIN.FM.XXX]             # Associated failure modes
  requires_role: [DOMAIN.R.XXX]           # Roles needed
  precedes: []                             # Methods that follow
  follows: []                              # Methods that precede
tags: []                                    # Free-form search tags
---
```

---

## [DOMAIN.M.XXX] Method Name

### Definition

_One to three sentences describing what this method is. Focus on what it does, not how to do it._

### Purpose

_Why does this method exist? What problem does it address? What does it enable?_

### Forces

_What competing pressures does this method balance? Each force names a tension the method resolves or holds in check — not a step, not a distinction._

| Force | Tension |
|-------|---------|
| _Force 1_ | _What pulls against what, and how this method holds the balance_ |

### Inputs

_What does this method require to begin? (Information, prior work products, conditions)_

| Input | Description | Required? |
|-------|-------------|-----------|
| _Input 1_ | _What it is_ | Yes/No |
| _Input 2_ | _What it is_ | Yes/No |

### Outputs (Work Products)

_What does this method produce?_

| Output | Link | Description |
|--------|------|-------------|
| _Output 1_ | [DOMAIN.WP.XXX](../04-work-products/DOMAIN.WP.XXX.md) | _Brief description_ |

### Roles Involved

| Role | Responsibility in This Method |
|------|------------------------------|
| [DOMAIN.R.XXX](../02-domain-entities/02A-roles.md#r-xxx) | _What they do_ |

### Related Methods

| Method | Relationship |
|--------|--------------|
| [DOMAIN.M.YYY](./DOMAIN.M.YYY.md) | _precedes / follows / alternative to / component of_ |

### Key Distinctions

_What conceptual distinctions are essential to performing this method correctly?_

- [DOMAIN.D.XXX](../01-domain-contract/01B-distinctions.md#d-xxx): _Why it matters here_

### Bias-Annotation

_What systematic distortion does a practitioner risk when applying this method — and in which direction? Name the bias, not a generic warning._

| Bias | Direction of distortion |
|------|--------------------------|
| _Bias 1_ | _What gets over- or under-weighted, and why this method is prone to it_ |

### Failure Modes

_What commonly goes wrong when this method is performed poorly?_

| Failure Mode | Link |
|--------------|------|
| _Failure 1_ | [DOMAIN.FM.XXX](../05-failure-modes/DOMAIN.FM.XXX.md) |

### Tools Commonly Used

| Tool | How Used |
|------|----------|
| _Tool 1_ | _Brief note_ |

### SoTA Status

**Status**: `current` | `deprecated-interpretation` | `hypothesis`

**Basis**: _What evidence or consensus supports this method?_

**Revision criterion**: _What would change this status?_

---

## Checklist Before Committing

- [ ] ID follows pattern `DOMAIN.M.NNN`
- [ ] Definition is declarative (not "Step 1: ...")
- [ ] Forces section filled (≥1 named tension, not a placeholder)
- [ ] Outputs link to work product cards
- [ ] Failure modes are listed
- [ ] Bias-Annotation section filled (≥1 named distortion + direction, not a placeholder)
- [ ] SoTA status and revision criterion specified
- [ ] Added to `02C-methods-index.md`
- [ ] Added to `07-map/`