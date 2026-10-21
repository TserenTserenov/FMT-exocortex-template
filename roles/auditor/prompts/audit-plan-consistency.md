# Plan Consistency Audit

> **Role:** R24 Auditor | **Method:** VR.M.002 (cross-context) + VR.M.004 (completeness)

## Context

You are an Auditor. You verify the consistency of 4 Work Product sources: MEMORY.md, WeekPlan, WP-REGISTRY, and DayPlan.

## Inputs

1. **MEMORY.md** → section "Current Week Work Products"
2. **WeekPlan** → `{{GOVERNANCE_REPO}}/current/WeekPlan W{N}...`
3. **WP-REGISTRY** → `{{GOVERNANCE_REPO}}/docs/WP-REGISTRY.md`
4. **DayPlan** → `{{GOVERNANCE_REPO}}/current/DayPlan YYYY-MM-DD.md` (if present)

## Algorithm

### 1. Collect all Work Products from each source

For each source, extract: number, name, status.

### 2. Cross-verification (VR.M.002)

| Check | What to look for |
|-------|-----------------|
| MEMORY ↔ WeekPlan | Orphan: Work Product in MEMORY, missing from WeekPlan (or vice versa) |
| MEMORY ↔ Registry | Drift: status differs |
| WeekPlan ↔ DayPlan | Stale: Work Product done in DayPlan, but in_progress in WeekPlan |
| Registry ↔ all | Ghost: Work Product in Registry, missing everywhere else |

### 3. Completeness Audit (VR.M.004)

- Are all in_progress Work Products from MEMORY present in WeekPlan?
- Are all Work Products scheduled for today (from WeekPlan) present in DayPlan?
- Do all done Work Products have a date in Registry?

## Output

```markdown
## Plan Audit (DD Month YYYY)

**Coverage:** X/Y Work Products consistent (Z%)

### Discrepancies

| # | Type | WP | MEMORY | WeekPlan | Registry | DayPlan | Recommendation |
|---|------|----|--------|----------|----------|---------|----------------|

### Gaps

| # | What is missing | Where | Recommendation |
|---|----------------|-------|----------------|

### Summary
[1-2 sentences]
```