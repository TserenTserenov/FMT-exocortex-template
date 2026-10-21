---
description: Operational maintenance checklist for closing protocols
domains:
- reference
- maintenance
horizon: warm
name: t-checklist
owner: platform
promoted: 2026-04-25
schema_version: 1
status: active
type: protocol
valid_from: 2026-04-10
wp: 217
---
# T-Checklist (single source for skill /close)

> Linear, requires no judgment. Each item includes: owner, trigger, symptom-if-skipped.
> **Class T (True maintenance):** idempotent, calendar-driven, autopilot.
> Distinction T ≠ S ≠ R: see `.claude/rules/distinctions.md`.

## Session Close (Quick Close ≤15 min, or on trigger "close")

| # | Action | Owner | Trigger | Symptom-if-skipped |
|---|--------|-------|---------|--------------------|
| T1 | Commit all changes (git add -p → commit) | agent | session with changes | uncommitted files, work lost |
| T2 | Push (on trigger "push"/"upload"/"close") | agent | explicit trigger | recovery not guaranteed, collaboration breaks |
| T3 | WP Context "Remaining" updated (handoff for next session) | agent | any Work Product session | next session starts with lost context |
| T4 | MEMORY.md Work Product status — condensed note "what was done / what is next" | agent | any session | Work Product not visible in next Day Open |
| T5 | Open Work Product session closed (open-sessions.log) | agent | if entry existed | double-booking, "session not completed" in next Day Open |
| T5a | WP card with `verification_class` ∈ {open-loop, problem-framing} and budget ≥3h has a `## Stages` section | agent | such a Work Product was created or touched in this session | stage plan does not appear in card — structural gap, found in 18 of 20 checked cards (structural-hole fix, see `scripts/create-wp.sh --verification-class`) |

**Exceptions:** sessions ≤15 min WITH NO file changes → T1–T5 are skipped (verbal summary only).

**Verification:** Haiku R23 checks formal compliance (whether a commit exists, whether MEMORY.md is updated, whether handoff is filled in). **T5a is a warning, not a block:** R23 does not create a `/decompose` plan itself (context isolation, separate sub-agent) — it only notifies the pilot of the missing section. The deterministic gate (`check-trace-satisfaction`) for this rule is not yet implemented (issue #678), so a hard block here is premature.

## Day Close

| # | Action | Owner | Trigger | Symptom-if-skipped |
|---|--------|-------|---------|--------------------|
| T6 | All T1–T5 completed for the current session | agent | end of day | see above |
| T7 | Archive done WP contexts → archive/wp-contexts/ | agent | day | inbox/ cluttered, confusion between active and closed items |
| T8 | Backup memory/ + CLAUDE.md → `<strategy-repo>/exocortex/` (user governance repo) | agent | day | exocortex falls behind, recovery breaks |
| T9 | Archive old DayPlans → archive/day-plans/ | agent | day (auto-chore) | current/ cluttered with outdated DayPlans |
| T10 | Downstream sync (update.sh — reindex + pack-project + template) | agent | day when Pack changes | MCP server serves stale Pack, template-sync breaks |
| T11 | Linear sync (Linear ↔ git statuses) | agent | day | Linear does not reflect what is in git |
| T12 | Governance batch: WeekPlan/DayPlan/WP-REGISTRY/open-sessions.log updated | agent | day | plan vs. actuals diverges |
| ~~T13~~ | ~~Drift top-3 critical in Day Report~~ **removed (WP-545 Phase 5, 21.08, pilot decision)** — duplicated T18 (full weekly reconciliation using the same `iwe-drift.sh`); daily granularity on top of weekly is redundant and not embedded in the current Day Close order | — | — | — |
| T14 | Tomorrow's Day Open file ready (pre-populate calendar, notes) | agent | end of day | Day Open starts from scratch in the morning |

**Verification:** Haiku R23 checks the checklist and confirms all 8 active items are marked (T13 removed 21.08, see above).

## Week Close (Sunday)

| # | Action | Owner | Trigger | Symptom-if-skipped |
|---|--------|-------|---------|--------------------|
| T15 | All T1–T14 completed for the week | agent | Sunday | debt accumulates |
| T16 | Fresh Work Product table — done items cleared, in_progress carried to next week | agent | Week Close | MEMORY.md bloats |
| T17 | Week Report assembled: commits / Work Products / metrics | agent | Week Close | no feedback on "what was accomplished" |
| T18 | Full drift (`iwe-drift.sh`) → section in Week Report | agent (S) | Week Close | S-actions accumulate |
| T19 | Staging check: STAGING.md — entries marked `validated` → propose promotion | agent (S+T) | Week Close | staging freezes, rules never reach FMT |
| T20 | `/iwe-rules-review` run — which rules were bypassed | agent | Week Close | dead rules live forever |
| T21 | R-questionnaire completed (see `r-questionnaire.md`) → answers in Week Report | human + agent moderator | Week Close | formal week closing not done |
| T22 | Next-week plan created | agent + human | Week Close | Monday starts from scratch |
| ~~T22a~~ | ~~Check scheduled task logs (launchd/cron) for `FAIL`/`ERROR` during the week~~ **removed (WP-545 Phase 4, 02.10.2026, pilot decision 01.10)** — was delegated to `extensions/week-close.checks.md`, which exists neither in the template nor for the user, meaning the check was never performed; the function is covered by the catalog process watchdog (overdue launch) and the weekly maintenance log silence reconciliation | — | — | — |

**Verification:** Haiku R23 checks the checklist. For T21, only the presence of answers is verified, not their quality.

## Month Close (first Monday of the month)

> **Trigger:** skill `/month-close` (see `.claude/skills/month-close/SKILL.md`). T23–T25 are executed as steps 6–7 of the Month Close algorithm.

| # | Action | Owner | Trigger | Symptom-if-skipped |
|---|--------|-------|---------|--------------------|
| T23 | Lesson Hygiene at monthly scale: compress MEMORY.md, rotate lessons, identify stale entries (#5 revived, absorbs former #13 rotation and #17 monthly audit) | agent + human | Month Close | MEMORY.md bloated, lessons lost |
| T24 | Protocol audit for bypassed steps (#22 revived): go through `memory/protocol-*.md` and skills, identify steps that are regularly bypassed or become dead | human | Month Close | dead protocol steps accumulate (WP-217 is a consequence of this) |
| T25 | Decommission triage: get candidates from drift script (`activity_checks:`) + manual question from R-questionnaire, make decisions: active → dormant → archived | human + agent | Month Close | dormant/archived sections not updated |

**Verification:** Haiku R23 — formal only (checks whether entries exist).
