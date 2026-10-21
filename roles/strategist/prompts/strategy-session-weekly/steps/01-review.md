---
gate: user
step: '01'
title: Review of the Previous Week + Stop List
---

# Step 01: Review of the Previous Week + Stop List

## IPO

| | |
|---|---|
| **Input** | The "Results W{N-1}" section from the current WeekPlan and the package of triggered/disputed hypotheses from Week Close |
| **Action** | Go through the results, hypothesis verdicts, and 6 stop-list criteria for each active Work milestone |
| **Output** | Carry-over decisions, the stop list, and the list of verdicts that require a strategy change |

## Instructions for Claude

### 1. Review of the Previous Week
- Read the "Results W{N-1}" section from the current WeekPlan
- Discuss with the pilot: what worked, what did not, and why
- Record conclusions and adjustments

### 2. Stop List (WP-196 Phase11 item3)
For each active Work milestone (especially carry-over items), check 6 criteria:

| # | Criterion | Signal | Action |
|---|-----------|--------|--------|
| 1 | Budget exhausted | >150% of budget with no Progress | re-assess: incorrect estimate or approach? |
| 2 | Blocker >2 weeks | external dependency is not moving | freeze (`status: blocked`) |
| 3 | Hypothesis disproved | original assumption is incorrect | close or reformulate |
| 4 | Priority dropped | the source of need is no longer relevant | move to Backlog or close |
| 5 | Result achieved another way | another Work milestone or external event resolved it | close as "resolved externally" |
| 6 | Caliber gap | requires a caliber 2+ levels higher with no plan | decompose or find a collaborator |

**Anti-pattern "sunk cost"** — base decisions on future value, not hours already invested.

### 3. Hypothesis Verdicts
- Read the Week Close package: triggered, disputed, and overdue hypotheses, their
  criteria and facts. If the selection could not be built, do not declare "0 hypotheses" —
  surface the failure as a blocker.
- For each verdict, ask the pilot what changes: confidence, Work milestone, review
  deadline, or the strategy itself. Do not edit the original entry: a verdict is
  a separate event recorded in `memory/lpf-hypothesis-log.md`.
- If a verdict affects the month's main hypothesis, the month's result, or the System of Interest,
  mark it for strategic review; the short weekly mode suggests switching to monthly.

### 4. Question for the Pilot
> "Continue to inbox review / adjust / skip?"
