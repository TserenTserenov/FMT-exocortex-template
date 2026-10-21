Execute the Month Close scenario for the Strategist role (R1).

> **Trigger:** Automatic — first Monday of the month, 00:00 (launchd), or on user request.
> **Input:** WeekPlans for the month + MEMORY.md + Strategy.md + Dissatisfactions.md.
> **Output:** Updated Strategy.md (archived monthly focus) + new R1-R6 + Month Close report.

## Work turn step

| Step | Input | Action | Output |
|------|-------|--------|--------|
| 1 | Trigger (start of month) | Invoke `skills/month-close/SKILL.md` | Skill result or fallback |

## Algorithm

### 1. Delegate to skill

```bash
# Check for skill presence
SKILL="${IWE_WORKSPACE:-$HOME/IWE}/.claude/skills/month-close/SKILL.md"
if [ -f "$SKILL" ]; then
  # Delegate execution to skill /month-close
  echo "Delegating to skills/month-close/SKILL.md"
  # LLM agent: read SKILL.md and execute its algorithm in full
else
  echo "WARN: skills/month-close/SKILL.md not found — running fallback (inline checklist)"
fi
```

### 2. Fallback (if skill is unavailable)

If `skills/month-close/SKILL.md` is not found:

0. **Extensions (before)** — issue #884: the delegation in step 1 reads `month-close.before/.after` through the standard mechanism (the skill loads them itself), but this inline fallback does not open the skill at all, so it does not read the extensions either. `bash .claude/scripts/load-extensions.sh month-close before` → Exit 0: `Read` each file from the output (alphabetic), execute as the first steps. Exit 1: no extensions, continue.
1. **Monthly retro** — compare R1-R6 (actual vs planned) from WeekPlans
2. **Focus archiving** — move monthly achievements into `Strategy.md`
3. **New R1-R6** — define goals for the new month
4. **TOC and hypothesis** — identify the top-3 priorities and growth hypothesis
5. **Red line check** — D7, runway, WakaTime, blockers
6. **MEMORY Audit** — rotate lessons, refresh the Role Performer table, check limits
7. **Extensions (after)** — `bash .claude/scripts/load-extensions.sh month-close after` → Exit 0: `Read` each file from the output (alphabetic), execute. Exit 1: no extensions, continue.
8. **Commit and push** — `git add` → commit → push

```
📋 Month Close: Month YYYY-MM

R1-R6 retro:
- R1: <actual> / <planned> → <status>
- ...

Monthly focus: <main achievement>
Next month TOC: <top-3>
Hypothesis: <growth hypothesis>

Red lines: <check>
Memory: <audit>

Git: committed and pushed ✅
```

## Rules

- **Month Close is not a Strategy Session.** It prepares input data for the Strategy Session (if one is scheduled).
- **Do not make strategic decisions** without the pilot — only record facts and generate proposals.
- **Archive, do not delete** — all monthly WeekPlans remain in `archive/week-plans/`.

## Sources

- **Skill (primary):** `{{WORKSPACE_DIR}}/.claude/skills/month-close/SKILL.md`
- **WeekPlans:** `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/archive/week-plans/WeekPlan W*.md`
- **Strategy:** `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/docs/Strategy.md`
- **MEMORY:** `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/memory/MEMORY.md`
- **Protocol:** `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/memory/protocol-month-close.md` (if present)
