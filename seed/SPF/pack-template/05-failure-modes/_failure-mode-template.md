# Failure Mode Card Template

Copy this file to create a new failure mode card. Replace all `_TBD_` and `DOMAIN.FM.XXX` placeholders.

---

## YAML Frontmatter

```yaml
---
id: DOMAIN.FM.XXX
name: _Failure Mode Name_
category: method-failure | work-product-failure | role-failure | distinction-confusion
severity: critical | major | minor
status: draft | active | deprecated
summary: "_One sentence (≤150 chars) describing this failure mode for index and retrieval_"
created: YYYY-MM-DD
last_updated: YYYY-MM-DD
related:                                    # Typed relations (SPF.SPEC.003)
  affects_method: [DOMAIN.M.XXX]           # Methods affected
  affects_wp: [DOMAIN.WP.XXX]             # Work products affected
  confused_distinction: [DOMAIN.D.XXX]     # Distinctions confused
tags: []                                    # Free-form search tags
---
```

---

## [DOMAIN.FM.XXX] Failure Mode Name

### Definition

_One to three sentences describing what this failure mode is. What goes wrong?_

### Category

| Category | Description |
|----------|-------------|
| `method-failure` | A method is performed incorrectly or incompletely |
| `work-product-failure` | A work product is missing, incomplete, or malformed |
| `role-failure` | A role is absent, unclear, or poorly performed |
| `distinction-confusion` | Key concepts are conflated or misunderstood |

**This failure mode is**: `_category_`

### Observable Symptoms

_How do you recognize this failure mode is occurring? Be specific._

- [ ] _Symptom 1_
- [ ] _Symptom 2_
- [ ] _Symptom 3_

### Root Causes

_What typically causes this failure mode?_

| Cause | Description |
|-------|-------------|
| _Cause 1_ | _Explanation_ |
| _Cause 2_ | _Explanation_ |

### Consequences

_What happens if this failure mode is not addressed?_

- _Consequence 1_
- _Consequence 2_

### Related Items

| Type | Item | Relationship |
|------|------|--------------|
| Method | [DOMAIN.M.XXX](../03-methods/DOMAIN.M.XXX.md) | _fails when..._ |
| Work Product | [DOMAIN.WP.XXX](../04-work-products/DOMAIN.WP.XXX.md) | _missing/malformed_ |
| Distinction | [DOMAIN.D.XXX](../01-domain-contract/01B-distinctions.md#d-xxx) | _confused with..._ |

### Detection Methods

_How can this failure mode be detected early?_

| Detection Method | When to Apply |
|------------------|---------------|
| _Method 1_ | _Trigger condition_ |

### Notes

_Additional context, examples (anonymized), or references._

---

## Checklist Before Committing

- [ ] ID follows pattern `DOMAIN.FM.NNN`
- [ ] Category is one of: method-failure, work-product-failure, role-failure, distinction-confusion
- [ ] Observable symptoms are specific
- [ ] Related items are linked
- [ ] Added to `07-map/`
