---
agents: single
browser_safe: false
description: Verification of the hypotheses log (hypotheses-log.md) on demand, outside
  the week-close rhythm. Filters entries with status "pending verification" and a
  due verification date, checks the falsification criterion against available evidence,
  proposes a verdict, the pilot confirms, and the verdict is written as a new entry.
  Invoke on an explicit pilot request only — not automatically.
gates_enforced: []
gates_rationale: IntegrationGate skipped by explicit pilot approval 19.07 (WP-496 Phase3)
  — role-host role for hypotheses has not been selected yet (Phase4 not completed), Service Clause/Role
  create prematurely before this decision
gates_required: []
interaction: multi-step
layer: L1
name: verify-hypotheses
status: experimental
triggers:
  phrases:
  - verify weekly hypotheses
  - verify hypotheses
  slash:
  - /verify-hypotheses
version: 0.1.0
---

# /verify-hypotheses

> **Scope:** read `hypotheses-log.md`, find entries whose verification date has arrived, check them against available evidence, propose a verdict, write the pilot-confirmed verdict as a new entry.
> **Not in scope:** does not create new hypotheses (that is Note-Review), does not run verification automatically on week-close (that is step 6a in `.claude/skills/week-close/SKILL.md` — this skill duplicates the same algorithm for use outside the weekly rhythm), does not edit original entries.
> **Role:** no dedicated role owner — used by whoever is currently running week-close (Strategist, R1). See open ArchGate question WP-496 F4.

## When to use

- The pilot says "verify this week's hypotheses" or "verify hypotheses" outside the normal Week Close rhythm.
- There is reason to believe a specific hypothesis has already resolved (the pilot observed the evidence before the scheduled verification date) and wants to check early.
- Diagnostics: how many hypotheses are currently "pending verification" and what are their dates.

## Preconditions

1. **WP Gate precondition.** The task is linked to WP-496 (Hypotheses log, LPF feedback regulation), phase 3.
2. **Log exists.** `{{GOVERNANCE_REPO}}/current/hypotheses-log.md` — if the file does not exist, notify the pilot and stop (the log has not been created yet or was created in a different location).

## Algorithm

### Step 1 — Read the log and filter

Input: `{{GOVERNANCE_REPO}}/current/hypotheses-log.md`
Action: read all entries. Select those where `Status: pending verification` AND `Verification date` ≤ today. Skip entries with status `draft` (not yet confirmed by the pilot in Note-Review) — they are outside the verification cycle. Skip entries that already have a verdict (`confirmed` / `refuted` / `partially confirmed` / `not applicable`).
Output: list of IDs (H-NNN) with a due verification date, ready for review. If the list is empty — report "No hypotheses with a due verification date" and stop (not an error; this is a normal result).

### Step 2 — Check each entry against available evidence

Input: list of IDs from Step 1
Action: for each entry, read the falsification criterion and check it against available sources — commits (`git log` for the affected repositories), `domain_event` (if the criterion concerns a measurable platform metric), infrastructure logs, facts from the nearest WeekReport/DayPlan. If the criterion requires data that is not available in the accessible sources — explicitly mark it "insufficient data for a verdict" and do not guess.
Output: for each entry — a draft verdict (confirmed / refuted / partially confirmed / not applicable) with justification (which facts were checked and where they came from).

**"Not applicable" rule:** if the precondition of the criterion was physically not met (for example, the dependent artifact the hypothesis concerns was never delivered) — the verdict is "not applicable", not "refuted". It is impossible to distinguish hypothesis failure from implementation failure when the criterion's precondition was not satisfied.

### Step 3 — Present to the pilot and obtain confirmation

Input: draft verdicts from Step 2
Action: show the pilot a table (ID, brief statement, proposed verdict, justification). Ask for confirmation or correction on each entry.
Output: final verdict for each entry, agreed with the pilot.

### Step 4 — Record the verdict and propose a follow-up action

Input: final verdicts from Step 3
Action: for each entry — append a **new** entry to the end of `hypotheses-log.md` in the format `## Verification H-NNN` with a reference to the original entry, the verdict, and the verification date. Do NOT edit the original entry (retroactive editing is prohibited — `memory/lpf-hypothesis-log.md`). Update the `Status` field in the original entry to reflect the outcome (this is the only field in the original entry that changes — status only, not content). Then ask: what action follows from this verdict — update confidence for the future / add a step to a checklist / open a work package / record a candidate pattern (Capture-to-Pack). The chosen action is executed outside this skill (terminal exit — goes to WeekPlan/Pack/work package, the consumer is outside the verify-hypotheses perimeter).
Output: log updated, each verdict has an associated action (no verdict is left hanging).

### Step 5 — Commit

Input: updated `hypotheses-log.md`
Action: commit to the governance repository (same process as other `current/` edits).
Output: changes saved, hypothesis history preserved.

## Bundled resources

None — the algorithm is entirely text-based, with no scripts or templates.

## Anti-patterns

- Do not issue a verdict without checking against real evidence — "it seemed confirmed" does not count.
- Do not edit the original hypothesis entry when issuing a verdict — only a new entry with a reference is allowed.
- Do not issue "refuted" instead of "not applicable" when the criterion's precondition was not met.
- Do not leave a verdict without a chosen follow-up action — a hanging verdict does not close the cycle.
- Do not run this skill automatically on every session — only on an explicit pilot request (the weekly rhythm is covered by step 6a of week-close).

## Verification

```bash
bash .claude/skills/skill-creator/scripts/verify-skill.sh verify-hypotheses
```
Expected result: PASS. Live check — invoke the skill manually after 2026-09-01 (the verification date of the first entry H-001 in `hypotheses-log.md`), and confirm that the algorithm finds exactly that entry and no others (the log currently contains only H-001).

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
