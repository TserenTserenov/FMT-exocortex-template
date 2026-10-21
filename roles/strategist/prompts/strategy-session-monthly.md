---
client: claude-code
mode: monthly
step: dispatcher
title: Strategy Session (monthly, full version)
---

# Dispatcher: Strategy Session (monthly)

> **Roles:** Strategist runs the strategic sync, Planner assembles the week, human approves decisions · **Frequency:** Once per month (first week) · **Duration:** ~45–60 min
>
> This is the **full version** with the Input-Output-Outcome cascade. The short weekly version is `strategy-session-weekly.md`.

The session is run by the personal Strategy HQ. Strategist and Planner hold designated roles within the HQ; steps 0–8 below are not separate systems. A completed session is a work episode. Expected inputs and outputs for each step are described in `.claude/skills/strategy-session/SKILL.md`.

## Communication style with the pilot

All responses in the session use **plain-language mode** (S-37, A1-A11):
- Russian only. English terms — only in parentheses after the Russian description.
- Technical labels such as "gate: skip", "exit 0", file names — **do not write in chat**. When skipping a step (gate: skip-if-empty) — notify the pilot briefly ("No irregular blocks"), then **STOP — wait for a response, do not proceed silently**.
- File paths — only in parentheses after a Russian verb, never as the subject of a sentence.
- Explain through "what this means for the plan", not through "what Claude did".

## Precondition

A WeekPlan draft (`status: draft`) has already been created by the `session-prep` script (Mon 04:00). If no draft exists — notify the user and offer to run `session-prep`.

## Resume — detecting an incomplete session

**Before reading step 00** — check `current/WeekPlan W*.md` for a `## Strategy Session Results` section with unresolved items (⏳):

```
grep -l "⏳" current/WeekPlan\ W*.md
```

If a WeekPlan with ⏳ in the session section is found:
- Notify the pilot: "Incomplete session W{N} found. Last completed step: [find the last ✅]. Resume from step [N+1] or start over?"
- **STOP — wait for the pilot's response.**
- Resume → read the file for step N+1. Start over → go to the session overview below.

If no incomplete session is found → go directly to the session overview below.

## Session overview (mandatory gate, once, before step 0)

This runs in both cases of a fresh start — Resume found no incomplete session, or the pilot chose "start over". Before reading the step 0 file (`00-open.md`), send the pilot a single message in plain language (no paths, no technical gate labels) listing the steps for this version of the session from the "Step Sequence" table below — one line per step name. Then **STOP — wait for the pilot's response**, and only then proceed to step 0.

## Instructions for Claude (execution semantics)

> **BLOCKING — one step at a time.** Violation = loss of session integrity: the pilot has not entered their data, and decisions have been made without them.

**One-step rule:**
1. Read the file for the CURRENT step.
2. Announce to the pilot in one line: step name + which data will be used (the "Input" field from this step's Input-Output-Outcome table, in plain language).
3. Execute the step and present the result to the pilot.
4. **STOP. Wait for the pilot's next message.**
5. Only after the pilot responds — read the file for the NEXT step.

**PROHIBITED:**
- Reading `strategy-session-weekly/steps/*` via glob or reading multiple files in one turn.
- Proceeding to the next step without the pilot's response (even if gate = `auto`).
- Combining multiple steps into one response.

**PERMITTED:** Read only the file for the step explicitly indicated at the current position in the sequence.

**After compaction / context restoration:** the rule applies without exception. The history of what was done before compaction does not remove the requirement to wait for the pilot at each step.

## Step sequence

| # | Step | Gate | File |
|---|-----|------|------|
| 0 | Opening + MonthClose gate | skip-if-empty | `strategy-session-weekly/steps/00-open.md` |
| 1 | Week review + stop list | user | `strategy-session-weekly/steps/01-review.md` |
| 2 | Inbox Triage | user | `strategy-session-weekly/steps/02-inbox.md` |
| 3 | Dissatisfactions | user | `strategy-session-weekly/steps/03-dissatisfactions.md` |
| 4 | Strategic sync | user | `strategy-session-weekly/steps/04-strategy-sync.md` |
| 5a | Caliber: measurement | auto | `strategy-session-weekly/steps/05a-measurement.md` |
| 5b | Caliber: recommendation | user | `strategy-session-weekly/steps/05b-recommendation.md` |
| 5c | Caliber: tracking | user | `strategy-session-weekly/steps/05c-tracking.md` |
| 6a | Plan: candidate pool | user | `strategy-session-weekly/steps/06a-pool.md` |
| 6b | Plan: budget + TOC | user | `strategy-session-weekly/steps/06b-budget.md` |
| 6c | Plan: finalization | user | `strategy-session-weekly/steps/06c-finalize.md` |
| 7 | Irregular blocks | skip-if-empty | `strategy-session-weekly/steps/07-irregular.md` |
| 8 | Approval and sync | user | `strategy-session-weekly/steps/08-confirm.md` |

## Jump handling

If the pilot decides to return to step 03 during the session:
1. Read `jump-handler.md`
2. Follow the jump-handler algorithm
3. After processing the jump — return to step 04

## Soft gate on ad-hoc jump

If the pilot writes "back to step 3" without an explicit critical signal — warn:
> "Returning to Dissatisfactions will reset steps 4 (strategic sync) and 5a/5b/5c (caliber). Continue?"

## Pre-session result verification (RP518 F17, pilot decision 19.10.2026)

If an independent verification of material is needed before the strategy session (for example, plan candidates for the plan step or the month's constraint analysis) — this verification **is not conducted as part of this step-by-step ritual** and does not replace the "one step, stop, wait for pilot" rule above. It runs separately, before this procedure begins: either as a dialogue with another agent (peer session, Codex/Kimi), or as a single-agent review (for example, a cold review by a sub-agent) — in both cases the reviewer's task is to examine what the first agent produced and not agree with it automatically. The result (report or review output) becomes one of the input sources for the relevant step. When announcing a step (see "One-step rule", item 2) — if a relevant verification result exists for that step, name it explicitly as part of the "Input".
