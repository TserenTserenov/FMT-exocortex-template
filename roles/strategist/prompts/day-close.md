> **DEPRECATED (WP-98, 2026-03-14).** Day Close has been moved to `memory/protocol-close.md § Day` (ORZ-fractal).
> This file is preserved for reference. When the "closing the day" trigger fires → read `protocol-close.md`.

Execute the Day Close scenario for the Strategist Role (R1).

> **Trigger:** Manual — on user request (`./scripts/strategist.sh day-close`).
> A separate report file is NOT created. The day's results will be included in the next morning's DayPlan.


## Context

- **WeekPlan:** {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/current/WeekPlan W*.md (most recent by date)
- **MEMORY:** ~/.claude/projects/{{CLAUDE_PROJECT_SLUG}}/memory/MEMORY.md
- **Exocortex backup:** {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/exocortex/

## Algorithm

### 1. Collect Today's Commits

```bash
# For EACH repo in {{WORKSPACE_DIR}}/:
git -C {{WORKSPACE_DIR}}/<repo> log --since="today 00:00" --oneline --no-merges
```

- Iterate over ALL repositories in `{{WORKSPACE_DIR}}/`
- Group commits by repository
- Map commits to Work Products from the weekly plan
- Determine the status of each affected Work Product: done / partial / not started
- Print the summary to screen (not to a file)

### 2. Update WeekPlan

Find the current `WeekPlan W*.md` in `{{GOVERNANCE_REPO}}/current/` and update it:

- Mark completed Work Products as **done**
- Update partial statuses with a Progress description
- Add carry-over items (what moves to tomorrow) at the end of the file
- **Do NOT delete** anything — only mark and append

### 3. Update MEMORY.md

Synchronize Work Product statuses in MEMORY.md with the updated WeekPlan:
- done → done
- partial → in_progress (with a Progress note)
- Remove completed Work Products from pending if they are in done

### 4. Exocortex Backup

Copy the current files to `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/exocortex/`:

```bash
# Root CLAUDE.md
cp {{WORKSPACE_DIR}}/CLAUDE.md {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/exocortex/CLAUDE.md

# Memory (Layer 3)
cp ~/.claude/projects/{{CLAUDE_PROJECT_SLUG}}/memory/MEMORY.md {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/exocortex/MEMORY.md
cp ~/.claude/projects/{{CLAUDE_PROJECT_SLUG}}/memory/*.md {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/exocortex/
```

### 5. Commit

- Commit all changes to `{{GOVERNANCE_REPO}}` (WeekPlan + exocortex backup)
- Push

## Rules

- **Do not delete** anything from WeekPlan — only mark and append
- **Do not create a separate report file** — the day's results will be included in the next morning's DayPlan (day-plan step 1)
- If there are no commits for the day — write "No activity" and perform the backup anyway
- Print the summary to screen for the user

## Screen Output (Template)

```
📋 Day Close: DD Month YYYY

Commits: N across M repos
- repo-name: N commits (brief description)

Work Products updated in WeekPlan:
- #N: status → new status

MEMORY.md: synchronized ✅
Exocortex backup: copied ✅
Git: committed and pushed ✅
```

Result: updated WeekPlan + MEMORY.md + exocortex backup.
