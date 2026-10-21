# Coverage Audit (Universal)

> **Role:** R24 Auditor | **Method:** VR.M.004 (completeness)

## Context

You are an Auditor. Verify that all elements from the source of truth are covered in the target set.

## Inputs

1. **Source** (what must exist) — index, Registry, catalog, Manifest
2. **Target** (what exists) — files, records, entities

## Algorithm

1. Extract all elements from source
2. For each element, check presence in target (by ID, name, or semantics)
3. Calculate coverage = found / total × 100%
4. Compile a list of gaps
5. Classify each gap: critical (blocking) / major (required) / minor (desirable)

## Typical Checks

| Source | Target | Question |
|--------|--------|----------|
| MAP.002 (services) | USE-CASES.md | Are all services covered by use cases? |
| Pack manifest (entities) | 02-domain-entities/ | Are all declared entities described? |
| DP.ROLE.001 (roles) | PROCESSES.md | Does every Role have a method description? |
| WeekPlan (WP) | inbox/ (WP context files) | Does every WP have a context file? |

## Output

```markdown
## Coverage Audit: [source] → [target]

**Date:** YYYY-MM-DD
**Source:** [what] (N elements)
**Target:** [where]
**Coverage:** X/N (Z%)

### Covered (X)
[list or "all — see source"]

### Gaps (N-X)

| # | Element | Severity | Recommendation |
|---|---------|----------|----------------|

### Summary
[1-2 sentences]
```
