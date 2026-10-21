# Strategist (R1)

> **Module template:** `roles/strategist/` in [IWE](../../README.md)
> **Role:** R1 Strategist — planning and tracking (DP.D.033 §7, DP.ROLE.001)

The Strategist role automates operational planning: morning plans, evening summaries, and weekly reviews. Current Role Performer: Claude (A1, Grade 3-4).

---

## Architecture: Prompts → Strategist → Outputs

```
IWE/              DS-strategy/ (separate repo)
  roles/strategist/                     current/
    prompts/                              WeekPlan W{N}.md
      add-wp.md                           WeekReport W{N} YYYY-MM-DD.md (week facts, WP-297)
      check-plan.md                       DayPlan YYYY-MM-DD.md
      evening.md                        docs/
    scripts/                              Strategy.md
      strategist.sh                       Dissatisfactions.md
  memory/                              inbox/
    protocol-open.md  (← day-plan)       WP-{N}-*.md (work item contexts)
    protocol-close.md (← day-close)    archive/
```

> **Note:** The `session-prep`, `strategy-session`, `day-plan`, `week-review`, `day-close`, and `note-review` prompts have been removed from the template. `day-plan` and `day-close` have migrated into the `memory/protocol-open.md` and `memory/protocol-close.md` protocols. The remaining prompts are created by the user in their DS repo during installation.

**Data flows:**
- Prompts (PLATFORM) → `prompts/` (3 base prompts) + `memory/protocol-*.md`
- Outputs (PERSONAL) → DS-strategy/ (separate private repo, not affected by updates)
- Inputs: MEMORY.md, MAPSTRATEGIC.md (from each repo), WakaTime

---

## Two Operating Modes

| | Operational (implemented) | Strategic (implemented) |
|---|---|---|
| **What it does** | Plans, tracks, and reports | Helps identify unsatisfied needs, select methods |
| **Horizon** | Day → week | Week → month → year |
| **Interaction** | Headless (session-prep) + interactive (strategy-session) | Deeply interactive |

---

## Scenarios

| # | Scenario | Prompt | Trigger | Status |
|---|----------|--------|---------|--------|
| 1 | Session preparation | DS: `session-prep.md` | Monday morning (headless) | Created by user |
| 1b | Strategy session | DS: `strategy-session.md` | Manual (interactive) | Created by user |
| 2 | Day plan | `memory/protocol-open.md` | Tue–Sun morning + manual | In template |
| 3 | Evening summary | `prompts/evening.md` | Manual | In template |
| 4 | Weekly summary | DS: `week-review.md` | Sunday night | Created by user |
| 5 | Add work item | `prompts/add-wp.md` | Manual | In template |
| 6 | Check work item (WP Gate) | `prompts/check-plan.md` | WP Gate | In template |
| 7 | Day Close | `memory/protocol-close.md` | Manual | In template |
| 8 | Note review | DS: `note-review.md` | As needed | Created by user |

---

## Schedule (launchd, macOS)

| Time (machine local time) | Day | Scenario | Plist |
|-------------|------|----------|-------|
| {{TIMEZONE_HOUR}}:00 | Monday | `session-prep` (headless) | `com.strategist.morning` |
| {{TIMEZONE_HOUR}}:00 | Tue–Sun | `day-plan` | `com.strategist.morning` |
| 00:00 | Monday | `week-review` | `com.strategist.weekreview` |

> The scheduled `day-plan` runs only the Day Open Pipeline (`scripts/day-open-pipeline.sh`). If the pipeline does not produce a plan, no fallback prompt runs in its place: a single "Day plan not assembled" message with the reason is sent to Telegram, and the plan is assembled in a session using the "open" command. A setup failure (pipeline not installed; no model gateway and the framework failed to start without a model) ends all attempts for that day — but only after the alert has been delivered: while the configured Telegram channel has not accepted it, the run exits with code 74 and logs the failure point; the next scheduler run only resends the alert without running the pipeline (no more than three sends per day). Any other failure is retried by the Synchronizer scheduler, if installed, up to three times per day. A pipeline deferral (code 7: the previous day is not yet closed) is not a failure: no alert is sent, it does not count as an attempt, and the pipeline reports the deferral itself.

> On Linux: configure cron manually (`crontab -e`). Without automation, the Strategist runs manually.

## Installation

```bash
./install.sh          # Install launchd agents

# Manual run
./scripts/strategist.sh morning           # session-prep (Mon) or day-plan (Tue–Sun)
./scripts/strategist.sh evening           # evening summary
./scripts/strategist.sh week-review       # weekly summary
./scripts/strategist.sh strategy-session  # strategy session (interactive)
./scripts/strategist.sh day-close         # Day Close
./scripts/strategist.sh note-review       # note review
```
