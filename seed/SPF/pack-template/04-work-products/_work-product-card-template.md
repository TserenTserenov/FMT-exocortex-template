# Work Product Card Template

Copy this file to create a new work product card. Replace all `_TBD_` and `DOMAIN.WP.XXX` placeholders.

---

## YAML Frontmatter

```yaml
---
id: DOMAIN.WP.XXX
name: _Work Product Name_
status: draft | active | deprecated
summary: "_One sentence (≤150 chars) describing this work product for index and retrieval_"
created: YYYY-MM-DD
last_updated: YYYY-MM-DD
related:                                    # Typed relations (SPF.SPEC.003)
  produced_by: [DOMAIN.M.XXX]             # Methods that produce this WP
  consumed_by: [DOMAIN.M.YYY]             # Methods that use this WP as input
  fails_with: [DOMAIN.FM.XXX]             # Associated failure modes
tags: []                                    # Free-form search tags
---
```

---

## [DOMAIN.WP.XXX] Work Product Name

### Definition

_One to three sentences describing what this work product is. A work product is an observable, verifiable output of a method._

### Purpose

_Why is this work product valuable? What decisions or actions does it enable?_

### Produced By

| Method | Notes |
|--------|-------|
| [DOMAIN.M.XXX](../03-methods/DOMAIN.M.XXX.md) | _Primary method_ |
| [DOMAIN.M.YYY](../03-methods/DOMAIN.M.YYY.md) | _Alternative method_ |

### Consumed By

_What methods or roles use this work product as input?_

| Consumer | How Used |
|----------|----------|
| [DOMAIN.M.ZZZ](../03-methods/DOMAIN.M.ZZZ.md) | _As input for..._ |
| [DOMAIN.R.XXX](../02-domain-entities/02A-roles.md#r-xxx) | _For decision-making about..._ |

### Observability Criteria

_How do you know this work product exists and is adequate? Be specific._

**Existence check**:
- [ ] _Observable indicator that the WP exists_

**Quality criteria**:
- [ ] _Criterion 1 for adequacy_
- [ ] _Criterion 2 for adequacy_
- [ ] _Criterion 3 for adequacy_

### Typical Form

_What does this work product usually look like? (Document, artifact, state, etc.)_

| Form | Description |
|------|-------------|
| _Form 1_ | _e.g., "Written document with sections X, Y, Z"_ |
| _Form 2_ | _e.g., "Diagram showing..."_ |

### Anti-Patterns

_What does a BAD version of this work product look like?_

| Anti-Pattern | Why It's Problematic |
|--------------|---------------------|
| _Anti-pattern 1_ | _Consequence_ |
| _Anti-pattern 2_ | _Consequence_ |

### Related Work Products

| Work Product | Relationship |
|--------------|--------------|
| [DOMAIN.WP.YYY](./DOMAIN.WP.YYY.md) | _precedes / follows / component of_ |

### Failure Modes

_What goes wrong related to this work product?_

| Failure Mode | Link |
|--------------|------|
| _Failure 1_ | [DOMAIN.FM.XXX](../05-failure-modes/DOMAIN.FM.XXX.md) |

---

## Checklist Before Committing

- [ ] ID follows pattern `DOMAIN.WP.NNN`
- [ ] Definition is declarative
- [ ] Observability criteria are specific and checkable
- [ ] Produced-by methods are linked
- [ ] Anti-patterns described
- [ ] Added to relevant method cards
- [ ] Added to `07-map/`
