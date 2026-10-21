# SoTA Annotation Template

Use this template for standalone SoTA annotations. Alternatively, embed SoTA status directly in method/distinction cards.

---

## YAML Frontmatter

```yaml
---
id: DOMAIN.SOTA.XXX
target_type: method | distinction | claim | work-product
target_id: DOMAIN.M.XXX (or D.XXX, WP.XXX, etc.)
status: current | deprecated-interpretation | hypothesis
summary: "_One sentence (≤150 chars) describing what this SoTA annotation covers_"
created: YYYY-MM-DD
last_reviewed: YYYY-MM-DD
tags: []                                    # Free-form search tags
---
```

---

## [DOMAIN.SOTA.XXX] SoTA Annotation for [Target Name]

### Target

**Type**: method | distinction | claim | work-product

**ID**: [DOMAIN.M.XXX](link-to-target)

**Specific claim being annotated**: _Quote or paraphrase the claim._

### Status

| Status | Meaning |
|--------|---------|
| `current` | Reflects best available understanding; supported by evidence/consensus |
| `deprecated-interpretation` | Was once accepted but superseded by newer understanding |
| `hypothesis` | Plausible but not yet validated; provisional |

**This annotation status**: `_status_`

### Evidence Basis

_What supports this status assessment?_

| Evidence Type | Description |
|---------------|-------------|
| Research | _Citation or summary_ |
| Practice consensus | _Where/how established_ |
| Theoretical derivation | _From what principles_ |

### Revision Criterion

_What evidence or development would change this status?_

- If `current`: _What would make it deprecated?_
- If `hypothesis`: _What would confirm or refute it?_
- If `deprecated-interpretation`: _What would restore it?_

**Specific criterion**: _TBD_

### Review Schedule

| Field | Value |
|-------|-------|
| Last reviewed | YYYY-MM-DD |
| Next review | YYYY-MM-DD |
| Review trigger | _Event or time-based_ |

### Change History

| Date | Change | Rationale |
|------|--------|-----------|
| YYYY-MM-DD | Initial status: _status_ | _Why_ |

---

## Checklist Before Committing

- [ ] ID follows pattern `DOMAIN.SOTA.NNN`
- [ ] Target item is clearly identified and linked
- [ ] Status is one of: current, deprecated-interpretation, hypothesis
- [ ] Revision criterion is specific and actionable
- [ ] Evidence basis is documented
- [ ] Added to `07-map/` if significant
