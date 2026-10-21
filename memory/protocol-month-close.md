---
description: Slim core of the Month Close protocol — triggers, position in the VDV
  v9 cascade, minimal algorithm
domains:
- protocol
horizon: warm
name: protocol-month-close
owner: platform
schema_version: 1
status: active
type: reference
valid_from: 2026-04-24
---
# Month Close Protocol (ORZ-fractal, "Month" scale — 4th of four)

> **Entry point:** Invoke Skill `month-close`. Alias for `/run-protocol month-close`.
> **Principle:** Month Close = stage 7 of the VDV v9 cascade (PD.METHOD.008). Aggregates 4–5 Week Closes and reassesses phase and caliber. Does not repeat Week Close — it reads its outputs.
> **Full algorithm:** `.claude/skills/month-close/SKILL.md`. This document covers only triggers and invariants.

## Routing

| Trigger | Argument | Skill |
|---------|----------|-------|
| "closing the month" / "monthly results" / `/month-close` | `month-close` | `.claude/skills/month-close/SKILL.md` |

## Position in VDV v9

| # | Stage | Frequency | Input | Output |
|---|-------|-----------|-------|--------|
| 5 | Day Close | evening | commits + DayPlan | DayPlan updated |
| 6 | Week Close | Sun/Mon | DayPlan W{N}-1..7 + WeekPlan | Report W{N} |
| **7** | **Month Close** | **first Mon of month** | **Report W{N} from previous month + Strategy.md** | **Strategy.md § R1-RN + archive/MonthClose YYYY-MM.md** |

## Invariants

1. **Trigger = first Monday of the month.** Run before the Strategy Session of the first week.
2. **Precondition:** Week Close for the previous week must be complete. Month Close does not start without a fresh Report W{N-1}.
3. **Do not merge with Strategy Session.** Run sequentially: `/month-close` first, then Strategy Session. Different roles (R23 Verifier / R1 Strategist), different artifacts.
4. **No auto-start.** Manual invocation, documented in the DayPlan of the first Monday (line "Month Close YYYY-MM", 0.75h).
5. **Output = two artifacts.** (1) Updated Strategy.md § Monthly Results (R1-RN closed / carried over / new ones created). (2) `{{GOVERNANCE_REPO}}/archive/MonthClose YYYY-MM.md` — a standalone monthly report.

## Minimal Algorithm (8 steps)

1. Preconditions (first Monday? Week Close done?)
2. Collect month data (commits, Week Reports, drift, decision log)
3. Month multiplier
4. Metrics retrospective: phase PD.FORM.078 + caliber PD.CHR.007
5. Project review P1–P6 (VDV v9 § Project)
6. R-questionnaire M1–M6 (`memory/r-questionnaire.md`)
7. T-checklist T23–T25 (`memory/t-checklist.md`) + add-ons: Decommission triage + Decision log review
8. Update Strategy.md + write `MonthClose YYYY-MM.md` + commit + R23 verification

Full step breakdown, report template, and verification checklist → SKILL.md.

## Related Protocols

- **protocol-close.md** — Day/Week Close. Month Close depends on their outputs.
- **protocol-open.md** — Session / Day Open. Not affected.
- **protocol-work.md** — session work. Month Close is a special case of a session with a fixed algorithm.

## History

- 2026-04-24: protocol created (WP-196 F12.2 + WP-226 F3). First run — May 4, 2026, closing April.
