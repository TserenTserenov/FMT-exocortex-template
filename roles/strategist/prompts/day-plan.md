
Execute a **complete** Day Open for the Strategist role (R1) **autonomously**.

## Algorithm (skill /day-open, steps 0-7)


### Step -1 — Extensions (before)

issue #884: same defect class as in `week-review.md` (see step 5b there) — user extensions `day-open.before.*` are wired to the interactive skill `/day-open`, but this manual scenario (`strategist.sh day-plan`) did not read them at all.

`bash .claude/scripts/load-extensions.sh day-open before` → Exit 0: `Read` each file from the output (alphabetic), execute as the first steps. Exit 1: no extensions, continue as normal.

### Step 0 — Scaffold (deterministic frame, BLOCKING)

```bash
DATE=$(date +%Y-%m-%d)
_IWE="${IWE_WORKSPACE:-$HOME/IWE}"
DAYPLAN_FILE="$_IWE/{{GOVERNANCE_REPO}}/current/DayPlan $DATE.md"

# If file does not exist — create via scaffold (if available)
if [ ! -f "$DAYPLAN_FILE" ]; then
  _SCAFFOLD="${IWE_SCRIPTS:-$_IWE/IWE/scripts}/day-open-scaffold.sh"
  if [ -f "$_SCAFFOLD" ]; then
    bash "$_SCAFFOLD" "$DATE" > "$DAYPLAN_FILE"
    SCAFFOLD_EXIT=$?
    if [ "$SCAFFOLD_EXIT" -eq 2 ]; then
      rm -f "$DAYPLAN_FILE"
      echo "Today is strategy_day, DayPlan is not created (plan lives in WeekPlan)."
      exit 0
    fi
  else
    echo "WARN: day-open-scaffold.sh not found at $_SCAFFOLD — creating minimal DayPlan, PENDING markers will be filled by LLM"
    cat > "$DAYPLAN_FILE" <<FRONTMATTER
---
type: daily-plan
date: $DATE
status: active
agent: Strategist
generated_by: fallback (scaffold missing)
---
FRONTMATTER
  fi
fi
```

### Steps 1-6 — filling PENDING markers (LLM synthesis)

**Read the created DayPlan**, find ALL `<!-- PENDING: ... -->` markers. For each one:

1. **Today's plan (today_plan)** — synthesize from:
   - `{{GOVERNANCE_REPO}}/current/WeekPlan W{N}.md` (current week plan)
   - `{{GOVERNANCE_REPO}}/inbox/WP-*.md` (Work Product context files with `status: active`)
   - Carry-over from yesterday's DayPlan (the "Start tomorrow with" section)
   - `day-rhythm-config.yaml → mandatory_daily_wps` (mandatory items)
   - Budget spread across days remaining in the week
   Result: a table with 5-12 Work Products, budget, and priorities (🔴/🟡/🟢/⚪).

2. **Yesterday's results** — `git log --since="yesterday 00:00" --until="today 00:00"` across ALL repositories in `{{WORKSPACE_DIR}}/`:
   - Grouped by repository
   - Commits mapped to Work Products
   - 1-3 key results (synthesis)

3. **Carry-over** — quote the "Start tomorrow with" section from `archive/day-plans/DayPlan {yesterday}.md`. If this is the first day — "none".

3a. **Calendar** (issue #581 — single source: calendar connector):
   - If the system context states "Calendar disabled" — skip this step entirely (issue #942); if it states "from server-calendar.sh only" — do not query the connector, go directly to the second point.
   - If calendar connector tools are available in this session (name contains "calendar", case-insensitive, e.g. `mcp__claude_ai_Google_Calendar__*` — actual names from the tool list): retrieve the list of calendars (own + connected shared), then events from each for today (00:00–23:59 local time). Show ALL events: a table "Time | Event | Duration | Link to WP" + a row of free blocks ≥1h (within 09:00–22:00).
   - No connector — fallback: `bash $IWE_SCRIPTS/server-calendar.sh $DATE` (the installation has its own key file). A response of "Google credentials not configured" means the key file is absent from the SCRIPT, not that the calendar is unavailable: in this case the section reads "Calendar unavailable (neither connector nor key file)", not empty tables.

4. **Day budget** — STRICT format required to pass the protocol-artifact-validate.sh hook:
   ```
   **Day budget:** ~Xh WP / ~Yh physical / Planned multiplier ~N.Nx
   ```
   - X = aggregate budget of all WPs for the day (single number, not a range)
   - Y = physical time (single number, or a range 6-8 is acceptable)
   - N.N = multiplier as a single number `~2.75x` (NOT a range `~2.5-3x` — hook fail)
   - Do NOT write "aggregate" before "WP" (hook regex looks for `~Xh WP`)

5. **Mandatory check** — verify the plan contains: every WP from `day-rhythm-config.yaml → mandatory_daily_wps` (if the list is empty or the file is absent — skip) + ≥1 content WP.

5a. **Platform health (format validation)** — the `<details><summary>Health ...</summary>` section MUST contain a markdown table with **numeric cells** OR the explicit text "no data". Hook regex: `\| *[0-9]|no data`. For example:
   ```markdown
   | Metric | Value |
   |--------|-------|
   | Triage 7d | <real number> |
   | Open Issues | <real number or "not checked"> |
   ```
   A traffic-light table (`| Scheduler | 🟢 | ...`) **does not pass** validation (the character after the pipe is a letter, not a digit).

6. **Inbox Triage** (if needed):
   - Read `{{GOVERNANCE_REPO}}/inbox/fleeting-notes.md` — are there any **bold** notes?
   - If yes — classify by 7 categories (New Economic Policy / Task / Knowledge / Draft / Personal / Noise).
   - Do NOT tag notes and do NOT archive them (note review is only done on pilot command, the Note-Review scenario; no scheduled auto-run, this is the template owner's decision, July 2026).

### Step 6b — Extensions (after)

`bash .claude/scripts/load-extensions.sh day-open after` → Exit 0: `Read` each file from the output (alphabetic), execute. Exit 1: no extensions, continue.

### Step 7 — save and commit

```bash
REPO_DIR="${IWE_WORKSPACE:-$HOME/IWE}/{{GOVERNANCE_REPO}}"
git -C "$REPO_DIR" add current/DayPlan*.md
git -C "$REPO_DIR" commit -m "day-plan: $DATE autonomous full (strategist morning)"
git -C "$REPO_DIR" pull --rebase  # in case Mac also committed something
git -C "$REPO_DIR" push
```

## AUTONOMOUS MODE (BLOCKING)

- ❌ **Do NOT ask questions** such as "what do you need from me?" / "option A/B/C?"
- ❌ **Do NOT stop** if the DayPlan file already exists — fill the PENDING sections (do not recreate)
- ❌ **Do NOT ask for confirmation** — make all decisions per the algorithm
- ✅ Make all decisions according to skill /day-open (`${IWE_WORKSPACE:-{{WORKSPACE_DIR}}}/.claude/skills/day-open/SKILL.md`)
- ✅ Final output: SUCCESS + git push (Telegram notification is sent automatically by strategist.sh after completion)

## Sources

- HUB: `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/current/`
- SPOKES: `{{WORKSPACE_DIR}}/*/WORKPLAN.md`
- MEMORY: `~/.claude/projects/{{CLAUDE_PROJECT_SLUG}}/memory/`
- Skill: `{{WORKSPACE_DIR}}/.claude/skills/day-open/SKILL.md`
- Templates: `~/.claude/projects/{{CLAUDE_PROJECT_SLUG}}/memory/templates-dayplan.md`
- Scaffold: `{{WORKSPACE_DIR}}/IWE/scripts/day-open-scaffold.sh` (resolved via `$IWE_SCRIPTS`)
- Extensions: `{{WORKSPACE_DIR}}/extensions/day-open.before.md`, `.after.md`, `.checks.md`

## If something is missing

- File or repository not found → log a warning, continue with what is available. Do NOT fail.
- Calendar: do not issue a false "Mac-only" diagnosis. First try the available server script / MCP / fallback path; if it cannot be checked — write "calendar not checked", not "unavailable".
- GitHub Issues: a false zero is worse than "not checked". Count via `gh issue list` / GitHub API; if it cannot be checked — write "not checked", not `0`.
- Video: if scaffold found 0 files — section reads "no new videos today".

Result: DayPlan in `current/` with all PENDING sections filled, committed, and pushed.
