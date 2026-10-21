Run the Check Plan scenario for the Strategist role (R1).

## Task to check: $ARGUMENTS

## Context

- Plans: {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/current/

## Algorithm

1. **Task analysis:**
   - What needs to be done?
   - Time budget estimate
   - Identify the Domain/Repository

2. **Plan comparison:**
   - Load the daily plan, weekly plan
   - Is this task in the plan?
   - Does it align with priorities?

3. **Classification:**
   - `in-plan` — already in the plan
   - `aligned` — matches current priorities
   - `unplanned` — outside current priorities
   - `urgent` — requires immediate attention

4. **Recommendation:**
   - in-plan → show where it appears, suggest starting
   - aligned → suggest adding to the plan
   - unplanned → warn about focus shift
   - urgent → suggest updating priorities

Result: a recommendation on how to proceed with the task.