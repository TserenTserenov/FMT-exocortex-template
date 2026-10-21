Run the Evening Review scenario for the Role Strategist (R1).

## Context

- Plans: {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/current/

## Algorithm

1. **Data collection:**
   - Load today's plan
   - Retrieve today's commits (git log --since="today")

2. **Reconciliation:**
   - Compare planned Work Products with commits
   - Mark statuses: done, partial, not started

3. **Statistics:**
   - Planned: X Work Products
   - Completed: Y Work Products
   - Commits: Z

4. **Carry-over:**
   - Mark what carries over to tomorrow

5. **Update:**
   - Update statuses in the day plan
   - Commit

Result: end-of-day summary with updated statuses.