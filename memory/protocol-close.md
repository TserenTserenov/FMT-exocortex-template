---
description: Slim-core Close protocol — triggers, routing, Quick Close inline
domains:
- protocol
horizon: warm
name: protocol-close
originSessionId: b5655b53-7d87-478a-aad9-437479e81691
owner: platform
schema_version: 1
status: active
type: reference
valid_from: 2026-04-13
---
# Close Protocol (ORZ-fractal)

> **Four scales:** Session (Quick Close), Day (Day Close), Week (Week Close), Month (Month Close — triggers and invariants in `protocol-month-close.md`).
> **Entry point:** Call Skill `run-protocol` with the required argument (see table below).
> **Reading order (WP-484.md:1953, error 28.07):** if the conversation before Close was about a specific Work Product — read today's entries in its WP-context FIRST, then open the protocol itself. Protocol before context = root cause of the error "treated pilot's phrase as a reference to a past decision without re-reading the contextfile".
> **Principle:** Quick Close = "do not lose" (inline, no TodoWrite, ~3 min). Day/Week Close = via SKILL.md + TodoWrite (forced execution).
> **CGUS (WP-481 F5):** step order = attention-holding order, NOT execution order. `[[gate]]`/`[[gate:AR.NNN]]` = precondition (blocks); `[[narrative]]` = demonstration order (skippable). Close verifies that the gate set is satisfied, not that steps were completed linearly.

## Routing

| Trigger | Argument | Skill |
|---------|---------|-------|
| "closing session" / "done" / "close it" | `close` or `close session` | Quick Close (below, inline) |
| "closing the day" / "day summary" | `close day` | `.claude/skills/day-close/SKILL.md` — **step 6: WakaTime + IWE Multiplier** |
| "closing the week" / "week summary" | `week-close` | `.claude/skills/week-close/SKILL.md` |

> **`close` without qualifier** → Quick Close (session) by default.


## Quick Close (session, inline)

> **Role:** R6 Encoder. **Budget with pilot: ~1-2 min** (summary + reflection) + **agent completes full closing alone** (without pilot).
> **Principle (DP.D.288, WP-484 31.07 — quick closing ≠ full closing):** quick closing happens fast FOR THE PILOT — a short summary of what was committed, plus reflection, not mechanics. Full closing (WP-context, KE, MEMORY.md, R23) is completed by the agent immediately after, without the pilot — result goes to the archive, not the chat by default.
> "Close it" = push immediately without questions (user gave consent by word).
> **Day Close ≠ Quick Close.** Day Close is self-contained — do not repeat Quick Close inside it.

### Runner — conditional driver (WP-482 F3+F5, issue #356)

```bash
# #512: for an installation with author_mode: false the outcome is known in advance — the runner
# is a personal maintainer tool (issue #306/#356), not shipped with the template.
# Branching on params.yaml removes the file re-check from the hot path
# of every close; file-probe remains only when the flag cannot be read.
AUTHOR_MODE=$(grep -E '^author_mode:' "${IWE_WORKSPACE:-$HOME/IWE}/params.yaml" 2>/dev/null | awk '{print $2}')
if [ "$AUTHOR_MODE" = "false" ]; then
  echo "Quick Close: author_mode=false — runner not shipped, run protocol steps manually (standard template mode)"
else
RUNNER="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/process-runner.py"
GRAPH="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/processes/quick-close.yaml"
if [ -f "$RUNNER" ] && [ -f "$GRAPH" ]; then
  (cd "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}" && \
    python3 scripts/process-runner.py start quick-close --slug <session slug> \
      --input '{"agent":"<agent>","wp":"<WP-N of session or null if session has no own WP>","slug":"<slug>","session_file":"<path or null>","repos":["<repo1>", ...]}')
else
  echo "Quick Close: runner not shipped with this installation; run protocol steps manually"
fi
fi
```

If both files are available, the runner is mandatory: it walks through the steps below and stops at each `pilot`/`ai`/`requires_input` step; respond with `process-runner.py next <run_id> --input '{...}'`, using the text under each step as the response content. If at least one file is missing, walk through the same steps manually, and explicitly mark runner checklist items `not applicable: runner not installed` — this is the standard template mode, not a closing error.

**Three checklist items the runner does not yet cover**, even when installed — execute manually: Decision log, Docs Gate (conditional), conversational-report.

---

## PART A. Quick closing (with pilot, ~1-2 min)

> **DP.D.288.** The sole purpose of this part is to confirm that work is not lost (committed and pushed) and to collect the pilot's reflection. No mechanics are counted or written here — all mechanics are in Part B, without the pilot.

### 1. Pre-commit checks → Commit + Push (steps `precommit-checks` → `commit-push` → `commit-push-check`) [[gate:AR.005]]

**1a. Pre-commit checks (BLOCKING).** `bash .claude/scripts/load-extensions.sh protocol-close checks` — exit 0 → `Read` each file from output (alphabetic) → execute. Exit 1 → skip. **On ❌ commit is forbidden** — fix, repeat checks.

**1b. Commit + Push (BLOCKING, step `commit-push`, input `{"commits":[{"repo","paths","message"}, ...]}`).** Run `git status --short` across ALL repos touched during the session. Uncommitted changes → `git add <specific paths>` → commit → push. When the runner is available, use its handler and do not bypass `blocked-push-failed`; in manual mode a push failure equally blocks the transition to the next step.

### 2. Short summary + reflection (step `reflection-gate` → `session-reflection` when `duration_min > 15`, WP-484 31.07 — moved here from end of chain) [[gate]]

Show the pilot 2-3 lines: **numbers** (how many commits, files, repositories touched), not a prose list of what was done — same logic as Day Close, DP.D.288. Found live on 31.07 (WP-484): the agent twice replaced numbers with prose even though the data (repositories, commits from this session) were already at hand — the fact that the instruction here said "summary" did not guarantee numbers without the explicit word "numbers". If the session was longer than 15 minutes — ask: "What worked / did not work in this session? What is worth remembering?" In runner mode the runner stops at `session-reflection`, and `session-reflection-append` records the answer; in manual mode the agent writes the answer to the ledger itself. Session ≤ 15 min → skip the question.

### 3. "You are free" [[gate]]

Tell the pilot: **"You are free — I will finish closing on my own"** — and continue with Part B (WP-context, KE, MEMORY.md, R23) without further pilot involvement. When the runner is available, call `process-runner.py next` for each remaining step; without it, execute the same order manually.

---

## PART B. Full closing (agent alone, without pilot)

> **DP.D.288.** The pilot is already free. There is no need to show the pilot the process — only the final short report at the end (see "Quick Close Report" below). Details (SHA, full checklist) — on request, not by default.

**4. Session Index (step `session-index`/`session-index-write`, runner routes on the presence of `session_file` automatically — WP-7, 07.07).** If the session is recorded as a file `sessions/YYYY-MM-DD-<topic>.md` (not a folder-structure peer-conversation — that one is already registered by `peer-session-finalize.sh`) — add a row to `sessions/00-index.md`: `Agents` = only the executing agent, `Turns`/`Escal` = `—`, `Report` = link to session file. [[narrative]]

**5. WP Context File (BLOCKING, fact not template, step `wp-context-update` — ai-contract: input `[git_diff, session_summary]`, output `[status, what_tried, what_learned, what_next]`)** — update the "Remaining" section (structured format): [[gate]]
   - in_progress → structured handoff
   - **done → 5a. Closing confirmation gate (WP-5, pilot decision 2026-07-18, option B).** Before `status: done` verify: does WP-context contain a substantive closing fact (a specific result/acceptance criterion, not a template phrase)? Empty/template → closing does not proceed silently — write `decision_pending: true` to frontmatter and leave `in_progress`; ask the pilot at the next Work Product opening (the pilot is already free, there is nothing to ask in Part B — that is the exact situation that previously caused this gate to erroneously wait for a synchronous answer). A substantive fact is already present → proceed to 5b without pause. [[gate]]
   - **done → 5b. Set `status: done` → and immediately archive (step `wp-archive-run`, input `{"wp","repo"}`):**
     ```bash
     git mv inbox/WP-N archive/wp-contexts/WP-N   # folder
     git mv inbox/WP-N-slug.md archive/wp-contexts/WP-N-slug.md  # file
     # patch frontmatter: status: archived, archived_at: YYYY-MM-DD
     # no results_in → add results_not_captured: true
     ```
     *(Implements DP.SC.033 invariant: a done Work Product does not remain in inbox longer than one Day Close)*
   - Incomplete → context file. Idea → `MAPSTRATEGIC.md`. Seed → `drafts/draft-list.md`
   - **"Already done" discovered during the session** → mark done in WP-context RIGHT NOW. Writing a template "Remaining" phrase with no connection to what was actually verified is forbidden — R23 (below) will reject it.
   - Source: peer-session [2026-07-09-17-close-actualization-gap](../DS-strategy/sessions/2026-07/2026-07-09-17-close-actualization-gap/report.md) — the gap is not that Close "forgets" to update, but that the fact-check requirement was not explicit or verifiable.

**6. KE (step `ke-routing` — ai-contract: input `[what_learned]`, output `[routed_to]`)** — read the "What we learned" field in "Remaining". Route: [[gate]]
   - rule (1-3 lines) → `CLAUDE.md` or `distinctions.md`
   - domain knowledge → Pack (specific file)
   - lesson → `memory/lessons_*.md` + line in MEMORY.md
   - no new knowledge → skip silently
   Announce routing in the final report: *"Capture: [what] → [where]"* — not as a separate message during the process (the pilot is already gone).

**7. Session-Close Feeder (step `session-close-feeder`/`session-close-feeder-run`, runner routes on `duration_min`; WP-247 F-MULTI-SOURCE.1, auto > 30 min):** [[narrative]]
   Auto-capture knowledge candidates from transcript + git diff into `captures.md`. Handler timeout — 120s (bug-2026-07-31-ke-routing-step-hangs-quick-close); on timeout degrades to `{ran: false}` and does not fail the closing.

**8. MEMORY.md (step `memory-update` — ai-contract: input `[wp_status]`, output `[memory_line]`)** — update Work Product status (one line: `in_progress` / `done`) [[gate]]

**9. Verification (step `verify-r23`)** — see "Quick Close Verification" section below; now runs entirely in Part B, without the pilot.

### "Remaining" format

```markdown
## Remaining

**What we tried:** [brief session summary — 1-2 sentences]
**What we learned:** [decisions, insights, context changes]
  → memory: [update: <what exactly> / not needed]
**What is next:**
- [ ] [specific next step]
- [ ] [the one after that]
**Next step:** [first unchecked item from the list above]
**Context for next session:** [files, decisions, blockers]
```

> **Rule `→ memory:`** (mandatory field): the agent explicitly answers the question "does MEMORY.md or memory/*.md need to be updated?" Update triggers: blocker resolved, external fact changed (someone else's deploy, a meeting happened, Pasha fixed something), Work Product status changed. If an update is needed — do it NOW, do not defer to Day Close.

### Quick Close Report

> Values are data from completed steps, not template text. When the runner is available, `process-runner.py status <run_id>` provides them; in manual mode the agent takes the same facts from the session log and Git.

```
**WP:** #N — [title] (from wp-context-update.wp)
**Status:** done / in_progress / in_progress_background (from wp-context-update.status)
**Duration:** N min, M turns (from gather-session-facts.duration_min, turns)
**Git:** K commits across J repos, pushed ✅ (from commit-push.commits, count repos)
**Reflection:** [answer to §18 question, if asked] / — (threshold not reached)
**EXTENSION POINT (protocol-close after):** `bash .claude/scripts/load-extensions.sh protocol-close after` — exit 0 → `Read` each file from output (alphabetic) → execute. Exit 1 → skip. Supports `extensions/protocol-close.after.md` AND `extensions/protocol-close.after.<suffix>.md`.
**Handoff:** → WP context "Remaining" updated / done
**Background:** [if status=in_progress_background] "you can close the session, I will finish and send the result to Telegram" (channel exists) / "I will finish on next opening, you can continue or close now — but nothing is running in background" (no channel)
```

### Quick Close Verification (Haiku R23) · [[gate:AR.007]]

> Conditional step: if `params.yaml → verify_quick_close: false` → skip.
> Exceptions: session ≤ 15 min, question-only session with no file changes.
> **Trace-satisfaction (WP-481 F5.1):** before running R23 — `bash .claude/hooks/rule-engine.sh check-trace-satisfaction --section "Quick Close"` (without `--section` the Week Close and Exit Protocol gates from this same file are also included in the check — a block is guaranteed since they are not completed in a 3-minute session). The gate set = lines with `[[gate…]]` inside the section; list keys via `list-gates --section "Quick Close"`; mark completed gates with `mark-gate <key>` as Close progresses. Verdict block → return to the unclosed gate, then R23. Attach the JSON verdict to the R23 input.

Run sub-agent Haiku in role R23 (context isolation). Pass: checklist, WP context "Remaining", `git diff --name-only`, brief session summary (what was done / what was found).

**Fact-matching check (not just section presence):**
1. "Remaining" is not a template — it contains specifics from this session (specific files/decisions from `git diff`), not a generic phrase that could apply to any session.
2. If during the session the agent mentioned "already done" / "turned out to be done" — the corresponding item in WP-context is marked done, not left pending.
3. Discrepancy (item marked pending despite clear evidence of done in the session) → ❌, return for correction before the user report.
4. **Runner Discipline (WP-482 F3+F5).** First check for the presence of `scripts/process-runner.py` and `scripts/processes/quick-close.yaml` in the governance repository. Both available → the card `inbox/agent/tasks/RUN-quick-close-<slug>*.md` is mandatory; verify `process_id == "quick-close"`, terminal `status` ∈ {`completed`, `failed`} and record `runner_terminated_cleanly`. At least one file missing → record `runner_check: not_applicable (runner not installed)`; absence of the card is not a ❌. Short-session and question-session exceptions remain in effect.

### Quick Close Checklist

- [ ] Everything committed and pushed
- [ ] WP Context: "Remaining" written (or done marked) **and reflects a fact verified by R23 against `git diff`** — not a template
- [ ] **WP closing gate (2a):** if `status: done` — WP-context contains a substantive closing fact (not a template phrase in "Remaining") OR pilot was explicitly asked and answered before archiving
- [ ] KE: "What we learned" routed (or "no new knowledge")
- [ ] MEMORY.md: Work Product status updated
- [ ] Decision log: read session entries in `${IWE_GOVERNANCE_REPO:-DS-strategy}/decisions/decision-log-YYYY-MM.md`, correct if inaccurate
- [ ] **Docs Gate (conditional):** did the Work Product touch UX or onboarding behavior (skills, MCP services, bot `/start`, access tiers T0-T4, role names)? → check and update onboarding documents in `IWE/docs/` (QUICK-START, SETUP-GUIDE, onboarding/, LEARNING-PATH, IWE-HELP) + `/verify` the updated file. Owner: user. If not touched → skip silently.
- [ ] **Routing check (conditional, WP-476 F6):** did the session create or place a new artifact containing personal/domain data? → take the "Information types → target homes" declaration from the Opening Ritual of this session (if there was one) and compare with `git diff --name-only`: (a) the artifact resides in the declared home for its type 2.x, not in a transient meta-folder (`inbox/` for non-WP content, repo root); (b) the file does not mix different information types (example gap: `memory/*.md` with no `type:` frontmatter — see `docs/data-pipelines-registry.yaml` PIPE-12 sub_type_routing). No declaration was made but an artifact with data appeared — that is itself a discrepancy (Opening skipped the field). Any discrepancy → do not fix silently, use Drift Reporting. No new artifact with data created → skip silently.
- [ ] **Conversational sessions:** report.md created OR status: interrupted (DP.SC.154 Q8)
- [ ] **Runner (conditional, WP-482 F3+F5):** if script and graph are available — card `RUN-quick-close-<slug>*` exists in terminal status and `runner_terminated_cleanly` is recorded; otherwise `runner_check: not_applicable (runner not installed)` is recorded.


## Week Close

> **Role:** R1 Strategist. **Budget:** ~20-30 min. **Trigger:** "closing the week" / `/week-close`.
> Executed via `.claude/skills/week-close/SKILL.md` + platform steps.

### Week Close Steps

> **Trace-satisfaction (WP-481 F5.1):** `bash .claude/hooks/rule-engine.sh check-trace-satisfaction --protocol memory/protocol-close.md --section "Week Close"` (without `--section` the Quick Close gates are also included in the check). Called from `.claude/skills/week-close/SKILL.md` step 12, before R23.

1. **Backup + dirty repos** — `backup-icloud.sh` + `check-dirty-repos.sh` (platform) [[gate]]
2. **Memory Validate** — `memory-bleed.sh` (HOT limit, orphans, superseded_by) [[gate]]
3. **Memory maintenance (T, SC.024.3)** — static load health check: [[narrative]]
   - `wc -l {{WORKSPACE_DIR}}/.claude/rules/distinctions.md` → **> 80 lines = drift flag** (per rule DP.KR.001 §6: 1-3 lines per distinction). Propose an Audit in WP-7.
   - `wc -l` on MEMORY.md of the current project in `~/.claude/projects/<project-slug>/memory/` (slug = working directory path, `/` → `-`) → **> 200 lines = flag** (limit exceeded).
   - Feedback/lessons files in `memory/` with `mtime > 14 days` without access → propose lowering `horizon: warm`.
   - Flags are informational. User decides on action.
4. **iwe-drift.sh** — full drift report in Week Report (S) [[narrative]]
5. **STAGING.md** — any `validated`? → propose promotion (S+T) [[narrative]]
6. **iwe-rules-review** — which rules were bypassed? (S) [[narrative]]
7. **R-questionnaire** (3 questions, `memory/r-questionnaire.md`, step 3 of Part A `week-close/SKILL.md`, WP-484 30.07 — moved to the beginning) → answers in Week Report [[gate]]
8. **Archive done Work Products** → `archive/wp-contexts/` (T) [[gate]]
9. **Update WeekPlan** — mark outcomes, create carry-over section [[gate]]
10. **Week Retrospective in free text** (WP-484, 30.07) — reflection question asked to pilot, answer recorded in ledger via `pilot_answer/preclose_retro` (step 1 of Part A `week-close/SKILL.md`, moved to the beginning on evening of 30.07) [[gate]]

### Symptom of skipped Week Close

- STAGING.md frozen ≥ 2 weeks with `validated`
- distinctions.md > 80 lines without a flag in Week Report
- Week Report without R-answers
- MEMORY.md > 200 lines for 2+ consecutive weeks

## Month Close

> **Role:** R1 Strategist (execution), R23 Verifier (Haiku, checklist). **Budget:** 30-45 min. **Trigger:** last days of the closing month, or the first Monday of the next month (if not done earlier), before the Strategy Session of the first week.
> Executed via `.claude/skills/month-close/SKILL.md`.

### Month Close Steps

> **Trace-satisfaction (WP-484 F5a):** `bash .claude/hooks/rule-engine.sh check-trace-satisfaction --protocol memory/protocol-close.md --section "Month Close"` (without `--section` the gates of the other scales are also included in the check). Called from `.claude/skills/month-close/SKILL.md` step 12, before R23. Before this phase (19.07) Month Close had no gate tracing at all — the checklist at the bottom of SKILL.md was the only check, with no automated backing.

1. **Project review P1-P6** — for each active project: what moved, whether it stalled, hour balance (step 4 `month-close/SKILL.md`) [[gate]]
2. **R-questionnaire M1-M6** — answers recorded in `MonthClose YYYY-MM.md` (step 5 `month-close/SKILL.md`) [[gate]]
3. **Decommission triage applied** — active/dormant/archived transition table (step 7 `month-close/SKILL.md`) [[gate]]
4. **Decision log review** — at least 1 insight from the month's decisions (step 8 `month-close/SKILL.md`) [[gate]]
5. **Strategy.md § Month Results updated** — R{N} closed/carried over/new ones opened (step 9 `month-close/SKILL.md`) [[gate]]
6. **Month Retrospective in free text** (WP-484, 30.07) — reflection question asked to pilot, answer recorded in ledger via `pilot_answer/preclose_retro` (step 0.5 `month-close/SKILL.md`, moved to the beginning on evening of 30.07) [[gate]]

### Symptom of skipped Month Close

- `MonthClose YYYY-MM.md` created but R-questionnaire M1-M6 is empty
- Decision log review without an insight for 2+ consecutive months
- Strategy.md § Month Results untouched, yet Month Close is marked as closed

## IWE Multiplier (WP-299 F5, step 6 Day Close)

> **Full specification → `.claude/skills/day-close/SKILL.md` § 6.**

- **WakaTime source:** CLI `~/.wakatime/wakatime-cli --today` (on Windows the binary is named `wakatime-cli-windows-amd64.exe`: search by mask `~/.wakatime/wakatime-cli*`) → if unavailable: Neon `domain_event WHERE event_type='coding_time'` for the date (fallback).
- **Multiplier** = sum of closed Work Product budgets for the day / WakaTime (sec). Format: `N.Nx`.
- **Emission:** after calculation — emit `day_close` event to domain_event, `external_id = "day-close-YYYY-MM-DD"` (ON CONFLICT DO NOTHING — idempotent). Payload: `{wakatime_h, multiplier, date, session_id, source}`.
- **Pending multiplier (if Day Close did not run):** Day Open step 1 "Yesterday" — if no `day_close` record exists for yesterday, recalculate from Neon WakaTime (WakaTime API `summaries?start={yesterday}&end={yesterday}`).

## Deferred (to Day Close)

> Quick Close intentionally excludes: DayPlan, WP-REGISTRY (day scale, not session scale).
> **Clarification (WP-484, 31.07):** Verification Gate and report — before DP.D.288 these were genuinely deferred; they are now part of Part B (items 9 and "Quick Close Report" below) — Quick Close includes them, just without the pilot.
> KE is included (Part B, item 6) — knowledge is lost if deferred to Day Close.
> Rationale (ADR-207): atomic steps that always execute > a long list where half are skipped.


## Exit Protocol (on completing any role)

| # | Step | Action |
|---|-----|-----------|
| 1 | **Artifact** [[gate]] | Record the result (commit, file, entry) |
| 2 | **Status** [[gate]] | Update the tracker (MEMORY.md, WP context) |
| 3 | **Notification** [[gate]] | Notify the next party (user, agent, Strategist) |
