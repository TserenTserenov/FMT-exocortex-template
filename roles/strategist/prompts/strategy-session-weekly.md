---
client: claude-code
mode: weekly
step: dispatcher
title: Strategy Session (weekly, short variant)
---

# Dispatcher: Strategy Session (weekly)

> **Roles:** Planner runs weekly selection and budget; Strategist joins when direction is under revision; human approves decisions · **Frequency:** weekly (Mon) · **Duration:** ~15–20 min
>
> This is the **short variant** for the weekly rhythm. The full variant (monthly) is `strategy-session-monthly.md`.

The session is run by the personal Strategy HQ in short configuration. Planner and Strategist are assignment names, not two separate systems alongside the human. A completed session is a work episode; its output is recorded in the week plan and related notes. An overview of the full session inputs and outputs is in `.claude/skills/strategy-session/SKILL.md`; this route uses only the steps listed below.

## Communication Style With the Pilot

All session responses use **plain-language mode** (S-37, A1-A11):
- Natural language only. Technical terms appear only in parentheses after the plain-language description.
- Technical labels such as "gate: skip", "exit 0", and file names — **do not write in chat**. When skipping a step (gate: skip-if-empty), notify the pilot briefly ("No irregular blocks found"), then **STOP — wait for a response; do not proceed silently**.
- File paths appear only in parentheses after a plain-language verb, never as the subject of a sentence.
- Explain things through "what this means for the plan", not through "what Claude did".

## Precondition

A WeekPlan draft (`status: draft`) has already been created by the `session-prep` script (Mon 04:00). If no draft exists, notify the user and offer to run `session-prep`.

## Resume — Detecting an Incomplete Session

**Before reading step 00** — check `current/WeekPlan W*.md` for a `## Strategy Session Results` section containing open items (⏳):

If a WeekPlan with ⏳ in the session section is found:
- Notify the pilot: "Incomplete session found for W{N}. Last completed step: [find last ✅]. Resume from step [N+1] or start over?"
- **STOP — wait for the pilot's response.**
- Resume → read the file for step N+1. Start over → go to the session overview below.

If no incomplete session is found → go directly to the session overview below.

## Session Overview (mandatory gate, once, before step 0)

Runs in both cases of a fresh start — Resume found no incomplete session, or the pilot chose "start over". Before reading the step 0 file (`00-open.md`), display to the pilot in a single message, in plain language (no paths, no technical gate labels), the list of stages for this specific (short) session variant from the Step Sequence table below — one line per stage name. Then **STOP — wait for the pilot's response**, and only after that proceed to step 0.

## Instructions for Claude (execution semantics)

> **BLOCKING — one step at a time.** Violation = loss of session integrity: the pilot has not entered their data; decisions are made without them.

**One-step rule:**
1. Read the file for the CURRENT step.
2. Announce to the pilot in one line: the step name + what data will be used (the "Input" field from the I/O table for this step, in plain language).
3. Execute the step and present the result to the pilot.
4. **STOP. Wait for the pilot's next message.**
5. Only after the pilot responds — read the file for the NEXT step.

**PROHIBITED:**
- Reading `strategy-session-weekly/steps/*` via glob or reading multiple files in one turn.
- Proceeding to the next step without the pilot's response (even if gate = `auto`).
- Combining multiple steps into one response.

**PERMITTED:** Read only the file for the step explicitly indicated at the current position in the sequence.

**After compaction / context restoration:** the rule applies without exception. The history of what was done before compaction does not remove the requirement to wait for the pilot at each step.

## Step Sequence

| # | Step | Gate | File |
|---|------|------|------|
| 0 | Opening | skip-if-empty | `strategy-session-weekly/steps/00-open.md` *(MonthClose gate in this step — do not trigger or mention: monthly dispatcher only)* |
| 1 | Week review + stop list | user | `strategy-session-weekly/steps/01-review.md` |
| 7 | Irregular blocks | skip-if-empty | `strategy-session-weekly/steps/07-irregular.md` |
| 2 | Inbox processing | user | `strategy-session-weekly/steps/02-inbox.md` |
| 4 | Strategic sync | user | `strategy-session-weekly/steps/04-strategy-sync.md` |
| — | **Weekly-stop gate** | — | If any signal (from 07 or 04) requires revision of the current week's Role Performer composition (remove or add ≥1 Role Performer) → **stop**, offer `strategy-session-monthly.md` |
| 6a | Plan: candidate pool | user | `strategy-session-weekly/steps/06a-pool.md` |
| 6b | Plan: budget + constraints | user | `strategy-session-weekly/steps/06b-budget.md` |
| 8 | Approval | user | `strategy-session-weekly/steps/08-confirm.md` |

## What Counts as "Urgent" in a Strategy Session (CVU model)

> Distinction: Current ≠ Important ≠ Urgent (CVU) + Deadline ≠ Urgency. CVU = Current · Important · Urgent.

A strategy session is a place for **important** work (raising the norm), not for urgent work. By default, in a strategy session **almost nothing is urgent**:

- **Urgent** = only a physical threat of pipeline stoppage (prod/billing down, blocking other agents/users, data loss, security-critical). Genuinely urgent issues do NOT wait for a session — they interrupt and are fixed immediately.
- NOT urgent (= important or current, even if it feels "burning"): an approaching deadline, strong dissatisfaction / high motivation to act, "pilot wants to add a Role Performer", accumulated routine tasks. A deadline on something important keeps it important.

Therefore, when evaluating "does the Role Performer composition need revision", do NOT escalate an item to urgent based on a deadline or the intensity of a negative emotional pull. Escalation to monthly = a signal to revise priorities for the important, not a "fire".

## Weekly-Stop Gate (operational criterion)

After step 04, evaluate:
> Is a revision of the current week's Role Performer composition required (remove or add at least one Role Performer)?

- **Yes** → notify the pilot:
  > "A signal has been detected that requires revision of the current week's Role Performers. I recommend switching to the full session (`strategy-session-monthly.md`) for strategic sync."
  - If the pilot agrees → close weekly, offer monthly
  - If the pilot declines → record the risk in WeekPlan ("pilot declined monthly during Role Performer revision") and continue
- **No** → continue to 06a

## Jump Handling

In weekly mode, the jump handler is not used. A critical signal (dissatisfaction raised in conversation, or a strategy divergence from step 04) is handled by the weekly-stop gate.

## Pre-Session Result Verification (Role Performer 518 Phase 17, pilot decision 19.10.2026)

If an independent verification of material is needed before the strategy session (for example, candidates for the plan step) — that verification **is not conducted as part of this step-by-step ritual** and does not replace the "one step, stop, wait for pilot" rule above. It runs separately, before this procedure begins: either as a dialogue with another agent (peer session, Codex/Kimi), or as a review by a single agent (for example, a cold review by a sub-agent) — in both cases the reviewer's task is to examine what the first agent produced and not agree with it automatically. The result (report or review output) becomes one of the input sources for the relevant step. When announcing a step (see "One-step rule", item 2) — if a relevant verification result exists for that step, name it explicitly as part of the "Input".
