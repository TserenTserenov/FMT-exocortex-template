# Auditor (R24)

> **Module Template:** `roles/auditor/` in [IWE](../../README.md)
> **Role:** R24 Auditor — completeness and consistency verification (PACK-verification VR.R.002, DP.ROLE.001)

The Auditor role systematically checks completeness and coverage: whether all elements are in place and whether discrepancies exist between related contexts.

---

## When Invoked

| Mode | Trigger | How |
|------|---------|-----|
| **Day Open** | Plan consistency check | Automatically (step 2 of protocol-open) |
| **Strategizing** | Full Audit of work products and coverage | Automatically |
| **On demand** | "Check coverage of MAP.002 with scenarios" | Explicit command |

## Two Methods

### VR.M.002 — Cross-Context Verification

Finds discrepancies between related contexts:

| Pattern | Description |
|---------|-------------|
| **Orphan** | Present in A, absent in B |
| **Ghost** | Present in B, absent in A |
| **Drift** | Present in both, but diverged |
| **Stale** | One updated, the other not |

### VR.M.004 — Completeness Audit

Checks coverage: whether all source elements are covered in the target.

## Prompts

| Prompt | Scenario |
|--------|----------|
| `audit-plan-consistency.md` | MEMORY↔WeekPlan↔DayPlan↔Registry |
| `audit-coverage.md` | Any source×target (MAP.002↔UC, manifest↔entities) |

## Work Products

- **Audit report** (VR.WP.003): coverage %, list of gaps
- **Discrepancy list** (VR.WP.004): divergences between contexts

## Related Roles

| Role | Interaction |
|------|-------------|
| R23 Verificator | The Verificator checks a single Artifact; the Auditor checks many |
| R1 Strategist | The Strategist uses the audit report for planning |

---

*Source-of-truth: PACK-verification (VR.R.002)*