---
argument-hint: ''
browser_safe: false
description: Day Close protocol. Alias for /run-protocol close day — symmetric with
  /day-open.
layer: L1
name: day-close
routing:
  deterministic: false
  executor: haiku
status: active
triggers:
  phrases: []
  slash:
  - /day-close
version: 1.1.0
---

# Day Close (day closing protocol)

> **Role:** R1 Strategist. **Budget:** ~10 min.
> **Principle:** SKILL.md = L1 platform file. The user does not edit it directly — only through `extensions/`.

## BLOCKING: step-by-step execution

Day Close = protocol. The blocking requirement is an observable property: **no step is skipped silently**; each step is marked complete BEFORE moving to the next.
**Step 0 — FIRST action:** record the step list right now (before any other action) — in TodoWrite, or if unavailable, as explicit numbering in the response.
The default tool is TodoWrite: each algorithm step → a separate task (pending → in_progress → completed). **TodoWrite unavailable** (on models newer than Sonnet 4.6, the client does not expose this tool by default — enable it with `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` in the `env` settings, issue #1216) → notify the pilot in one line, track steps with explicit numbering ("Step X of Y: <name> — done"), record the substitution in the closing report (issues #561, #563).
Move to the next step ONLY after marking the current one complete. Step is impossible → blocked (do not skip silently).

## Algorithm

### 0. Extensions (before)
`bash .claude/scripts/load-extensions.sh day-close before` → exit 0: `Read` each file from the output (alphabetic) → execute as the first steps. Exit 1/3 (no matches / no `extensions/` directory — normal for a new installation, or the directory is corrupted) → skip silently. Supports `extensions/day-close.before.md` AND `extensions/day-close.before.<suffix>.md`.

### 0b. Digest — token discipline (issue #234)
`IWE_PATHS="${IWE_PATHS_FILE:-}"; if [ -z "$IWE_PATHS" ]; then for _c in "$PWD/.iwe-paths" "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-paths" "$HOME/.iwe-paths"; do [ -r "$_c" ] && { IWE_PATHS="$_c"; break; }; done; fi; [ -n "$IWE_PATHS" ] && . "$IWE_PATHS" 2>/dev/null; bash "$IWE_SCRIPTS/day-close-prepare.sh"` — variables are sourced explicitly (issue #688: a top-level Bash call does not process `.bashrc`/`.zshenv`/`BASH_ENV`, `$IWE_SCRIPTS` may be empty without an explicit `.`), one call instead of ~10 scan queries. Numbered digest sections REPLACE the scan commands inside the steps below (the steps themselves still execute — but they read data from the digest, not re-run scans): §1→step 1, §2→10b, §3→2d, §4→4b, §5→4c, §6→4, §7→6, §8→6 (prerequisite), §9-10→3, §11→2f. React only to flagged items; a drift hit that genuinely "is waiting for X" is not drift. Script absent → legacy: use inline commands from the steps.
**Sub-agent execution (recommended for large day sessions):** the parent executes only the digest → dispatch → agreement (step 8) → verification; steps 1–7 are executed by ONE general-purpose sub-agent (sonnet, context isolation) with the digest in the prompt; steps 9–10b are handled by a finalizer sub-agent with `day-close-prepare.sh --verify` instead of inline-grep 9a/9b; step 11 (R23) is dispatched by the parent — a sub-agent cannot call sub-agents. Fallback: Agent tool unavailable / sub-agent failed twice → execute inline, still with the digest.
<!-- Details: day-close-details.md § Step 0b -->

> **Best practice:** run `/day-close` in a fresh session, not as a tail of the working session — the protocol needs files on disk, not a conversation about the day.

### 0c. Strategy_day guard (issue #286)
Check `day_open.strategy_day` in `day-rhythm-config.yaml` (same key that `/day-open` reads, default `monday`) against today's day of the week. Symmetric with `/day-open` (SKILL.md step 4: "If `strategy_day` → do NOT create DayPlan"): on a strategy day, `current/DayPlan <date>.md` was not created — steps 1, 2b, 3, 9a are **not applicable** (not FAIL); see the notes inside them. Day results go only into the WeekReport (step 9b), as prescribed by the section below.
<!-- Details: day-close-details.md § Step 0c -->

### 1. Data collection
**Strategy_day (step 0c) → not applicable, skip** (no DayPlan; nothing to compare the "Today" table against). Otherwise: run the bash script to collect today's commits across all git repos in `${IWE_WORKSPACE:-$HOME/IWE}/`. Match against the "Today" table from the DayPlan → determine statuses.
<!-- Details: day-close-details.md § Step 1 -->

### 2. Governance batch
**2a.** WeekPlan (`current/Plan W{N}...`): update Work Product statuses — grep by Work Product number, update ALL mentions.
**2b.** **Strategy_day (step 0c) → not applicable, skip** (DayPlan was not created). Otherwise: DayPlan `current/DayPlan YYYY-MM-DD.md`: statuses of ALL rows (Work Products + ad-hoc). Done → strike through.
**2c.** `docs/WP-REGISTRY.md`: statuses + dates.
**2d.** `inbox/open-sessions.log`: remove lines for closed sessions.
**2e.** New repos/services today? → REPOSITORY-REGISTRY, navigation.md, MAP.002.
**2f.** WeekReport — first run `bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/week-report-ensure.sh"` (issue #886: creates the paired skeleton `WeekReport W{N} YYYY-MM-DD.md` if the file does not yet exist, and leaves it untouched if it does), then: add `<details><summary><b>Results {Day} {Date}</b></summary>` **before** previous results (reverse chronology).
<!-- Details 2f: day-close-details.md § Step 2f -->

**EXTENSION POINT (checks):** `bash .claude/scripts/load-extensions.sh day-close checks` → exit 0: `Read` each file → execute. Exit 1/3 (no matches / no `extensions/` directory — normal for a new installation, or the directory is corrupted) → skip silently.

### 3. Archiving
- **Strategy_day (step 0c) → skip archiving today's DayPlan** (it was not created — nothing to archive). DayPlans from previous days in `current/` (stale) — archive in all cases.
- Otherwise: today's DayPlan → `git mv current/DayPlan $(date +%Y-%m-%d).md archive/day-plans/`.
- Done WP context files → `mv inbox/WP-{N}-*.md → archive/wp-contexts/`
- Done Work Products → remove the row from MEMORY.md. MEMORY.md stores ONLY active Work Products.

### 4b. Memory Drift Scan
Two independent checks (issue #326 — a single lexical check missed status mismatches with no trigger words):
1. **Structural:** `IWE_PATHS="${IWE_PATHS_FILE:-}"; if [ -z "$IWE_PATHS" ]; then for _c in "$PWD/.iwe-paths" "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-paths" "$HOME/.iwe-paths"; do [ -r "$_c" ] && { IWE_PATHS="$_c"; break; }; done; fi; [ -n "$IWE_PATHS" ] && . "$IWE_PATHS" 2>/dev/null; T="${IWE_TEMPLATE:-$HOME/IWE/IWE}"; PY3="$(bash "$T/.claude/lib/find-python3.sh")" && "$PY3" "$T/.claude/scripts/memory-drift-scan.py"` — compares the "Status" column of MEMORY.md against the `status` field of each WP context by Work Product number. Exit 1 → for each stale row found, update it.
2. **Lexical:** Grep MEMORY.md for patterns "waiting/blocker/blocked/stopped" (catches text-based blockers without a status change — a separate class that the script in item 1 does not see). For each hit: find the WP context, check the status, update stale data.
Announce when 0 discrepancies across both checks: *"Drift-scan: N patterns + M structural, no stale items."*
<!-- Details: day-close-details.md § Step 4b -->

### 4c. Index Health Check
`IWE_PATHS="${IWE_PATHS_FILE:-}"; if [ -z "$IWE_PATHS" ]; then for _c in "$PWD/.iwe-paths" "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-paths" "$HOME/.iwe-paths"; do [ -r "$_c" ] && { IWE_PATHS="$_c"; break; }; done; fi; [ -n "$IWE_PATHS" ] && . "$IWE_PATHS" 2>/dev/null; T="${IWE_TEMPLATE:-$HOME/IWE/IWE}"; PY3="$(bash "$T/.claude/lib/find-python3.sh")" && "$PY3" "$T/.claude/scripts/check-index-health.py"` — for each FAIL/WARN: diagnose (dump vs. genre) → move or mark skip.
<!-- Details: day-close-details.md § Step 4c -->

### 4. Lesson Hygiene
Review "Lessons" in MEMORY.md. Not applied for >1 week and present in `lessons_*.md` → delete. New lesson → add a row to MEMORY.md + `lessons_*.md`. Goal: ≤8 lessons.

### 5. Automated steps
`IWE_PATHS="${IWE_PATHS_FILE:-}"; if [ -z "$IWE_PATHS" ]; then for _c in "$PWD/.iwe-paths" "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-paths" "$HOME/.iwe-paths"; do [ -r "$_c" ] && { IWE_PATHS="$_c"; break; }; done; fi; [ -n "$IWE_PATHS" ] && . "$IWE_PATHS" 2>/dev/null; "$IWE_SCRIPTS/day-close.sh"` — variables are sourced explicitly (issue #688, see step 0b), Linear sync, backup (memory/ + CLAUDE.md), reindex, session consolidation for the day. Platform update (`update.sh`) is NOT included here (issue #945): it is a network operation with its own ritual; the IWE status table at Day Open reports available updates (`update.sh --check --fast`) and the update is applied separately (`/iwe-update`).

### 6. IWE Multiplier
> Conditional step: if `params.yaml → multiplier_enabled: false` → skip and
> when recording results, use only the `multiplier:off` branch of the template. Do not add
> WakaTime, actual time, the formula, or a placeholder saying "multiplier not calculated."

WakaTime CLI (`~/.wakatime/wakatime-cli --today` (on Windows the binary is named `wakatime-cli-windows-amd64.exe`: search using the mask `~/.wakatime/wakatime-cli*`)) or Neon-fallback → Actual budget / WakaTime = multiplier `N.Nx`. Prerequisite: read `sessions/00-index.md` (grep today) → list of peer sessions with the number of turns. Sanity check: <1.5x with ≥10 peer sessions → recalculate.
<!-- Details: day-close-details.md § Step 6 -->

### 7. Results draft (show to user)
Overview (Work Products × status) + What I learned today + Praise + Not forgotten (dirty repos, /slot hours, thoughts, commitments) + Video + Draft list + Setup for tomorrow + **Morning priorities (priorities.yaml)**.
<!-- Details: day-close-details.md § Step 7 -->

### 8. Agreement
The user reads the draft → adjusts → approves.

### 9. Recording results
**9a.** **Strategy_day (step 0c) → not applicable, skip entirely** (DayPlan was not created — there is nowhere to write "Day results"; the postcondition grep is unreachable by design, not FAIL). Strategy day results go only to 9b/WeekReport; a regular day — facts only, do not copy planned rows (day-close-details.md § strategy_day). Otherwise: append "Day results" to the DayPlan (template: `memory/templates-dayplan.md`, branch by `multiplier_enabled`). Validation: "Start tomorrow with" is non-empty + each pending Work Product has a concrete next action. Postcondition: bash-grep for pattern `Day results|Day summary` (both languages — issue #234: when `language: english` the DayPlan header is "Day summary", a Russian-only grep always FAILs) → `9a OK/FAIL`.

When archiving the DayPlan (step 3) — frontmatter `status: active` → `status: closed`:
```bash
TODAY_DAYPLAN="${IWE_GOVERNANCE_REPO:-DS-strategy}/archive/day-plans/DayPlan $(date +%Y-%m-%d).md"
[ -f "$TODAY_DAYPLAN" ] && sed -i.bak 's/^status: active$/status: closed/' "$TODAY_DAYPLAN" && rm -f "$TODAY_DAYPLAN.bak"
```
Do not confuse this with step 10c below (P1, WP-5 Ubuntu-audit): the day-open-pipeline.sh guard checks for the presence of the archived DayPlan in git, not this field — `status: closed` is for humans and third-party tools only, not the current guard implementation.
**9b.** Append a summary to the WeekReport (`<details>`, reverse chronology). Fall back to WeekPlan only if `week-report-ensure.sh` fails (no `current/` or no WeekPlan). Postcondition: bash-grep for pattern `Results|Summary` (both languages — issue #234) → `9b OK/FAIL`.
`*a/*b FAIL` → do NOT mark completed, return to recording.
<!-- Postcondition details: day-close-details.md § Step 9 -->

### 10. Rule Classifier
`SCRIPT="${IWE_WORKSPACE:-$HOME/IWE}/.claude/scripts/rule-classifier.py"; [ -f "$SCRIPT" ] && python3 "$SCRIPT" || echo "skip: rule-classifier.py requires manual installation (claude CLI + PACK-agent-rules)"` (idempotent, kill if >60 sec). **BEFORE commit** — otherwise its changes end up in an uncommitted tail (issue #249).

### 10a. Extensions (after)
`bash .claude/scripts/load-extensions.sh day-close after` → exit 0: `Read` each file from the output (alphabetic) → execute. Exit 1/3 (no matches / no `extensions/` directory — normal for a new installation, or the directory is corrupted) → skip silently. Supports `extensions/day-close.after.md` AND `extensions/day-close.after.<suffix>.md`. Symmetric with week-close (step 9): called BEFORE the final commit (10b), so that extension changes are included in the same commit and do not remain as an uncommitted tail (issue #320/#322).

### 10b. Final commit (all touched repositories, not only governance)
Run `git status --short` for EACH repo the session touched during the day — at minimum the workspace root (`${IWE_WORKSPACE:-$HOME/IWE}/`, where `MEMORY.md` and `memory/*.md` physically reside and are modified by steps 4b/4) and `${IWE_GOVERNANCE_REPO:-DS-strategy}` (WeekPlan/DayPlan/WP-REGISTRY). Stage and commit all uncommitted changes (including changes from step 10a) using only the single fail-closed command below: a non-zero exit code = STOP, a separate `git commit` after it is forbidden. Proceed to step 11 only when `git status` is clean in all repos.

<!-- issue-511-guard:start -->
```bash
# issue #1176: helper functions live in day-close-helpers.sh, not inline here,
# so Claude Code skill-arg substitution does not corrupt $1/$2 in function bodies.
# Relative to the workspace root, same convention as step 0's load-extensions.sh call.
source .claude/skills/day-close/day-close-helpers.sh
```
<!-- issue-511-guard:end -->

The two helper functions (`assert_staged_scope_or_stop`, `stage_and_commit_or_stop`) are defined in `day-close-helpers.sh` in this directory. Source that file before calling them. Their full bodies and postconditions remain unchanged.


> **Double commit guard (#511, twice-reproduced class "git mv + edit → empty/stale diff"):** the 21.08 mechanism is confirmed — `git mv` had already placed the rename in the index, the edit of the new path remained only in the worktree, `git add` of the old path failed, but a separate commit ignored the error and recorded the previous staged rename. The function above eliminates exactly this path: a commit is unreachable after a failed add. The 18.08 mechanism is still not established from available evidence, so the issue remains open.
> 1. BEFORE commit: the function first rejects staged paths outside the explicit list, then checks the `git add` exit code itself, the non-empty total staged diff, and non-empty staged content for each explicitly passed path (`git diff --cached -- <path>`). `git add -- <explicit paths>` after this check cannot add a foreign path; a repeated post-add name check would produce a false rejection for a rename that Git reclassified as delete+add after content modification. Do not repeat the commit manually after the function fails.
> 1a. **After `git mv` in the same turn, pass ONLY the new (current) file path** — the old path no longer exists on disk, `git add` on it fails (exit code 68), and the commit correctly stops. For a staged rename, the scope check compares both sides of the rename and accepts the new path (issue #557, note on DayPlan archiving).
> 2. AFTER commit: verify that the changes are actually in HEAD — `git show HEAD --stat` contains the moved file, and `git diff HEAD -- <file>` is empty (no uncommitted edit remnants on disk).
> 3. Any trigger → STOP + collect diagnostics in the day report: `git status`, `git diff`, `git log -1 --stat`, the exact sequence of commands executed — and report to the pilot. Do not reset the index automatically: it may contain evidence of the incident or a previously run `git mv`. After diagnosis, fix the path list and re-run the single function. This is material for establishing the root cause of #511.

### 10c. Heartbeat for Day Open guard
Written AFTER the push in step 10b — the DayPlan is already actually committed. day-open-pipeline.sh on the next day reads this file as the "Day Close done" signal (fallback — presence of the archived DayPlan in git, symmetric with day-open):
```bash
mkdir -p ~/.claude/state
jq -n \
  --arg date "$(date +%Y-%m-%d)" \
  --arg commit "$(git -C "${IWE_GOVERNANCE_REPO:-DS-strategy}" rev-parse HEAD)" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{date: $date, commit_hash: $commit, timestamp: $ts, status: "success"}' \
  > ~/.claude/state/day-close-last-success.json
```

### 11. Verification (Haiku R23)
Sub-agent Haiku R23 (context isolation): pass the checklist + results draft + list of updated files. For each ❌ — fix before showing to the user.

**EXTENSION POINT (checks):** `bash .claude/scripts/load-extensions.sh day-close checks` → exit 0: `Read` each file → execute. Exit 1/3 (no matches / no `extensions/` directory — normal for a new installation, or the directory is corrupted) → skip silently.

---

## Day Close Checklist

- [ ] All changes committed and pushed (across all repos)
- [ ] MEMORY.md: done Work Products removed, active ones current, drift-scan complete (step 4b)
- [ ] Index Health Check (step 4c): all FAIL/WARN resolved or marked skip
- [ ] WP-REGISTRY.md updated
- [ ] WeekPlan updated (grep by Work Product numbers — ALL mentions)
- [ ] DayPlan updated (statuses of ALL rows: Work Products + ad-hoc) — **N/A on strategy_day** (step 0c)
- [ ] open-sessions.log: lines for closed sessions removed
- [ ] Day captures applied (all Quick Close → KE completed)
- [ ] Morning priorities (step 7): `current/priorities.yaml` → `last_updated` = the day after the closing day, OR the closing report explicitly states "priorities not updated (skipped by pilot)." If neither — return to step 7 and ask the pilot (issue #944)
- [ ] **Working copy synchronization (pilot directive 21.08):** all machines/installation copies ↔ GitHub synchronized, except for currently active sessions. Check: `git status -sb` in the governance repo (no ahead/behind) + sync-script status for secondary copies (if configured, e.g. `remote-git-sync.sh --status`). "Deferred due to live semaphore" — normal for a genuinely active session; a stale semaphore with a pushed report is an anomaly: close the semaphore before finishing Day Close.
- [ ] Linear sync: statuses match git. Count of active Work Products in REGISTRY = active issues in Linear
- [ ] Repo CLAUDE.md: feat commits → new rules?
- [ ] Today's DayPlan → `archive/day-plans/` (old DayPlans in `current/` too) — **today's DayPlan N/A on strategy_day** (step 0c), old ones — archive in all cases
- [ ] WP context: done → `mv inbox/ → archive/wp-contexts/`
- [ ] Lesson Hygiene: MEMORY.md lessons ≤8
- [ ] Draft list: Pack enriched → draft proposed?
- [ ] Video: processed items marked (if video.enabled)
- [ ] Governance: REPOSITORY-REGISTRY, navigation.md, MAP.002
- [ ] Backup: `day-close.sh` executed
- [ ] **Rule-engine FP-stats** (WP-272 phase 2.5): `[ -f ${IWE_WORKSPACE:-$HOME/IWE}/.claude/scripts/fp-stats.py ] && python3 ${IWE_WORKSPACE:-$HOME/IWE}/.claude/scripts/fp-stats.py --date $(date +%Y-%m-%d) || echo "skip: fp-stats.py requires rule-classifier.py"` → if `⚠️ REVISE` is present → **ask the pilot about the specific flag** (WP-545 phase 5, 21.08 — replaces the previous weekly R8 question, which asked blindly on schedule rather than in response to a concrete signal): "rule `<X>` — is this a false positive from the detector, or a real but inconvenient signal?" Answer → into "Start tomorrow with" along with the decision (reformulate the rule / leave as-is)
- [ ] Compliance verification: was /verify run today?
- [ ] WakaTime + Multiplier: hours / actual budget (sessions/00-index.md listed; ad-hoc estimated by turns; over-plan — by actual); sanity check ≥10 peer sessions
- [ ] Day results recorded in DayPlan **(postcondition 9a: grep confirmed)** — **N/A on strategy_day** (step 0c)
- [ ] Handoff validation: "Start tomorrow with" contains ALL pending Work Products with a concrete next action — **N/A on strategy_day** (step 0c; on strategy_day this field lives in WeekPlan, not DayPlan)
- [ ] Results summary recorded in WeekReport (`<details>`, reverse chronology) **(postcondition 9b: grep confirmed)**
- [ ] New repo → MAPSTRATEGIC.md + Strategy.md

All ✅ → "Day closed." Otherwise — specify what remains.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
