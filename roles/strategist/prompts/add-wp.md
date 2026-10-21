Execute the Add Work Product scenario for the Strategist role (R1).

## Work Product: $ARGUMENTS

## Context

- Plans: {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/current/

## Algorithm

1. **Collect information:**
   - name: Work Product name
   - area: area
   - repo: target Repository
   - budget: time budget (hours)
   - criteria: acceptance criteria

2. **Check budget:**
   - Current week budget
   - Warn if exceeded

3. **Add:**
   - Find the latest WeekPlan in {{GOVERNANCE_REPO}}/current/
   - Add the Work Product to the table
   - Update the budget
   - Update MEMORY.md
   - Commit

Result: Work Product added to the week plan.
