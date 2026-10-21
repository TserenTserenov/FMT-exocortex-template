# Verifier (R23)

> **Module template:** `roles/verifier/` in [IWE](../../README.md)
> **Role:** R23 Verifier — verifies Artifacts against a reference standard (PACK-verification VR.R.001, DP.ROLE.001)

The Verifier Role checks whether Artifacts conform to a reference standard (Pack, SPF, principles). The key principle is **context isolation**: the Verifier loads a different context than the Creator.

---

## When It Is Invoked

| Mode | Trigger | How |
|-------|---------|-----|
| **On demand** | Explicit user command | `/verify [artifact]` |
| **Quick Close** | Checklist Verification (step 7 protocol-close § Session) | Sub-agent Haiku, context isolation |
| **Day Close** | Checklist Verification (step 10 protocol-close § Day) | Sub-agent Haiku, context isolation |
| **Session Close** | Verification Gate (step 3 protocol-close) | Automatic for open-loop/problem-framing Work Products |
| **At a Work milestone** | A significant Artifact has been created | Proposal in protocol-work §2b |

## What It Checks

| Type | Depth | What |
|-----|---------|-----|
| **Formal** (VT.001) | Structure, frontmatter, links | Low — automatable |
| **Substantive** (VT.002) | Principles, Ubiquitous Language, consistency | Medium — requires Pack context |
| **Cross-context** (VT.003) | Pack↔DS, BC↔BC alignment | High — multiple sources |

## Context Isolation

```
Verifier loads:                 Verifier does NOT load:
├─ Artifact (result)            ├─ Creator's assignment
├─ Reference standard (Pack/SPF)├─ Intermediate reasoning
└─ Checklist (if present)       └─ Iteration history
```

## Prompts

| Prompt | Scenario |
|--------|----------|
| `verify-pack-entity.md` | Verification of a Pack entity (D, M, WP, FM, R) |
| `verify-content.md` | Verification of a post/publication |
| `verify-wp-acceptance.md` | Work Product acceptance at Session Close |

## Work Products

- **Verdict** (VR.WP.001): pass/fail/conditional + justification
- **Discrepancy list** (VR.WP.004): specific deviations

## Related Roles

| Role | Interaction |
|------|---------------|
| R24 Auditor | The Auditor checks completeness; the Verifier checks a single Artifact |
| R26 Acceptor | The Acceptor (human) makes the final decision based on the verdict |
| R2 Extractor | The Extractor creates Pack entities → the Verifier checks them |

---

*Source-of-truth: PACK-verification (VR.R.001)*