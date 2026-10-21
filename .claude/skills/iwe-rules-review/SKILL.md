---
argument-hint: ''
browser_safe: false
description: Weekly review of IWE work culture (element 14 — System Evolution). Runs
  during Week Close.
name: iwe-rules-review
routing:
  deterministic: false
  executor: haiku
version: 1.0.0
---

# IWE Work Culture Review

> **Trigger:** Week Close (automatic) or manual.
> **Role:** R1 Strategist.
> **Input:** DP.M.008 (Pack) + weekly data (commits, DayPlans, Quick Close reports).
> **Output:** Change proposal → approval → update DP.M.008 + implementations.

## Algorithm

### 1. Load the rules

Read `PACK-digital-platform/pack/digital-platform/03-methods/DP.M.008-iwe-operating-rules.md` → §2 Registry (14 work culture elements).

### 2. Four questions (for each rule)

| # | Question | Data source | Action |
|---|----------|-------------|--------|
| 1 | **What did I learn?** | Quick Close reports, captures for the week | Record new knowledge |
| 2 | **Which rule was an obstacle?** | DayPlans, git diff | Rule is unrealistic → simplify or remove |
| 3 | **Which rule was missing?** | fleeting-notes, memory/ lessons | Recurring pattern with no rule → candidate for formalization |
| 4 | **Which rule did I work around?** | Quick Close reports | Systematically bypassed → candidate for removal or rework. Dead weight = illusion of control |

### 3. Generate the report

```markdown
## IWE Work Culture Review (W{N})

### Health

| Metric | Value | Norm |
|--------|-------|------|
| Violations this week | N | 0-2 |
| Not applied >2 weeks | N rules | 0-1 |
| Candidates for new rule | N | 0-2 |

### Violations

| # | Rule | Count | Reason | Proposal |
|---|------|-------|--------|----------|

### Dead weight

| # | Rule | Last applied | Proposal |
|---|------|-------------|----------|

### Candidates for formalization

| Pattern | Source | Proposed rule |
|---------|--------|---------------|

### Summary

- Changes to DP.M.008: N (remove: ..., add: ..., modify: ...)
- Changes to implementation: N (CLAUDE.md, protocol-*.md, skills/)
```

### 4. Approval

Present the report → user approves → apply changes to DP.M.008 and implementations.
