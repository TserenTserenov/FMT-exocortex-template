---
argument-hint: ''
browser_safe: false
description: Day Open protocol. Collects yesterday's commits, issues, notes, calendar,
  bot QA, Scout, world events — builds DayPlan and compact dashboard.
layer: L1
name: day-open
routing:
  deterministic: false
  executor: sonnet
status: active
triggers:
  phrases:
  - open
  slash:
  - /day-open
version: 1.1.0
---

# Day Open (day opening protocol)

> **Role:** Planner (DP.ROLE.066) manages the day plan; Strategist (R1) joins when reprioritizing. **Two outputs:** DayPlan (git, 80+ lines) + compact dashboard (VS Code, 20–30 lines).
> **Order:** DayPlan first → compact dashboard second. **Date:** FIRST action = `date`.
> **Mode:** `memory/day-rhythm-config.yaml` → `interactive: false` = deliver as a single block; decisions → "Requires Attention".
> **Freshness filter:** issues, videos, notes — last 2 days. Urgent — always.
> **Issues — actionable only:** skip read-only repos and upstream repos without push access.
> **Templates:** `.claude/skills/day-open/templates.md` (read before steps 7a and 7d).
> **Step details:** `day-open/day-open-details.md`

## BLOCKING: step-by-step execution

Day Open is a Protocol. The blocking requirement is an observable property: **no step is silently skipped**; each step is marked complete before moving to the next.
The default tool is the session task list (TodoWrite): each step → a separate task (pending → in_progress → completed).
**TodoWrite is unavailable in the session** (on models newer than Sonnet 4.6 the client does not expose this tool by default — enable it with `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` in the `env` settings, issue #1216) → do NOT stop and do NOT track steps mentally: notify the pilot in one line ("step-by-step tracking without TodoWrite — using explicit numbering"), track steps with explicit numbering in responses ("Step X of Y: <name> — done"), mark each step before moving to the next, and record the substitution in the day opening report.
Step is impossible → blocked (do not skip silently).
**Why:** without explicit tracking the agent skips steps due to context pollution (SOTA.002). The rule is defined as a property, not as a specific tool: tool availability is controlled by the client, not the template (issues #561, #563).

## Algorithm

### 0. Extensions (before)
`bash .claude/scripts/load-extensions.sh day-open before` → Exit 0: Read each file, execute. Exit 1: skip.
<!-- Details: day-open-details.md § Step 0 -->

### 1. Yesterday
Read yesterday's DayPlan (sections "Results", "Start tomorrow with", and "Requires Attention" only). Commits from yesterday across all `$IWE_WORKSPACE/*/` repos.
<!-- Details (targeted reading, fallback): day-open-details.md § Step 1 -->

### 1b. GitHub Issues
`day-open-scaffold.sh` (`render_repo_issues`) performs the sweep. Critical FMT issues: `bash $IWE_SCRIPTS/fmt-critical-alert.sh --no-telegram`.
<!-- Details (filters, cache): day-open-details.md § Step 1b -->

### 1c. Inbox Triage
Process `inbox/fleeting-notes.md`, `inbox/captures.md`, `inbox/extraction-reports/*.md` (pending-review). Categorize per PD.FORM.083. Domain Knowledge without an "To Extractor" marker → **Extractor Candidates** table in DayPlan. Each note in DayPlan is a markdown link to its source.
<!-- Details (hyperlinks, blocking rules): day-open-details.md § Step 1c -->

### 2. Plan for today
Priority: (1) carry-over from Day Close → all items, untruncated; (2) WeekPlan: in_progress + pending → check relevance, budget (Budget Spread); (3) MEMORY.md "Current week's Work Products"; (4) `mandatory_daily_wps`. Slot 1 = self-development.
<!-- Details (Budget Spread algorithm, context economy): day-open-details.md § Step 2 -->

### 3. Self-development
Governance, current position, drafts (`<governance-repo>/drafts/`).

### 4. Strategizing
If `strategy_day` → do NOT create DayPlan; write plan in WeekPlan. Skip step 7.

### 4b. Pomodoros
From `day-rhythm-config.yaml → pomodoro`.

### 4c. Calendar
Single source of truth — the connected calendar connector (MCP calendar tools; names depend on the installation, the name contains "calendar" case-insensitively, e.g. `mcp__claude_ai_Google_Calendar__*`): list calendars → fetch each calendar's events for the day → "Calendar" section for DayPlan (Meetings + Reminders).
If no connector is available — fallback: `bash $IWE_SCRIPTS/server-calendar.sh YYYY-MM-DD`. Note: a response of "Google credentials not configured" is a fact about the script (it looks for its own key file at `~/.secrets/google-calendar`), not about the calendar; when the connector is working, the script is not needed (issue #581).
If `strategy_day`: same logic for the week (fallback uses `--week YYYY-MM-DD`) → "Week Calendar" section in WeekPlan.
<!-- Details (classification algorithm, format): day-open-details.md § Step 4c -->

### 5. IWE overnight (traffic light)
`(cd "$IWE_TEMPLATE" && bash update.sh --check --fast)` + check Base repos (FPF, SPF, ZP) for lag behind origin. Updates → "Requires Attention". Scout report not reviewed → "Requires Attention".
<!-- Details (bash scripts): day-open-details.md § Step 5 -->

### 5a2. Video
`video.enabled: true` → show only new files from today (`-mtime 0`). `false` → skip.
<!-- Details: day-open-details.md § Step 5a2 -->

### 5c. Content editor
`content_editor.enabled: true` → top-3 drafts from `drafts/` by relevance/recency/completeness → table in DayPlan. Ready-to-publish signal → "Requires Attention". Any other value, including a missing `content_editor` section (issue #804) → skip.
<!-- Details (full scoring algorithm): day-open-details.md § Step 5c -->

### 6. World
`news.enabled: false` → skip. Otherwise: Feeds/WebSearch → headlines with URLs. Haiku sub-agent (context isolation) analyzes headlines + top-5 Work Products → "Conclusion: 2–4 sentences" at the start of the section.
<!-- Details (sub-agent prompt, section format): day-open-details.md § Step 6 -->

### 6b. Requires Attention
Collect from steps 1–6. Nothing collected → do not output.

### 6c. Extensions (after)
`bash .claude/scripts/load-extensions.sh day-open after` → Exit 0: Read each file, execute. Exit 1: skip.

### 6b2. Current/Important/Urgent markup
Mark each Work Product as Current / Important / Urgent. At least one Important block is required. Urgent — only when the Pipeline is at risk of stopping.
<!-- Details (Current/Important/Urgent rules, distinctions): day-open-details.md § Step 6b2 -->

### 7. Write

> ⚠️ **Before steps 7a and 7d:** `Read .claude/skills/day-open/templates.md`. File not found → notify the pilot, do not continue.
> Read `params.yaml → multiplier_enabled` (no key = `true`). When
> `false`, select only `multiplier:off` branches: do not output physical time,
> WakaTime, planned/actual multiplier, or the corresponding Week Close subsection.

**7a.** DayPlan: `<governance-repo>/current/DayPlan YYYY-MM-DD.md` using the template from `templates.md`. Previous DayPlan → `archive/day-plans/`.
**7a2.** Session Log: `<governance-repo>/sessions/YYYY-MM-DD.md`. If the file exists — do not overwrite.
<!-- Session Log template: day-open-details.md § Step 7a2 -->
**7b.** `bash .claude/scripts/load-extensions.sh day-open checks` → Exit 0: run Verification. BLOCKING: commit is forbidden until all checks pass.
**7c.** `git commit` + `git push`.
**7d.** Compact dashboard → output in VS Code using the "Compact dashboard template" from `templates.md`.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
