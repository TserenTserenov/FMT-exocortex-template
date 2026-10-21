---
description: 'Hypothesis log regulations: verifiable bets, events, and connection
  to strategy'
domains:
- protocol
- hypothesis
- feedback-loop
horizon: warm
name: lpf-hypothesis-log
owner: user
schema_version: 1
status: active
type: protocol
valid_from: 2026-08-11
---

# LPF Regulations: Hypothesis Log

The log stores verifiable bets, not a list of ideas. Its purpose is to carry a fact from period closing to a pilot decision, strategy update, or next work plan.

## Owner and Boundaries

- The source of records is `current/hypotheses-log.md` in the management Repository.
- The monthly frame is owned exclusively by `docs/Strategy.md`: the pilot defines 1–3 main monthly hypotheses, monthly results, and TOC there. The week references this version rather than copying it.
- Week Close collects facts and proposes a verdict; no strategic decision is made without the pilot.
- The strategic session connects the verdict to a strategy and work plan change.

## Capture and Required Fields

Trigger: "What hypothesis about the world do I currently consider true, and what could refute it?" Without an answer to the second part, this is a note or draft — not a log entry.

| Field | Rule |
|---|---|
| Statement | A verifiable prediction, not an emotion or intention |
| Confidence | Percentage at the time of entry, not editable retroactively |
| Falsification criterion | An observable fact; for a number — an explicit baseline |
| Review date | A specific date |

Note Review may propose a draft of the fields, but only a formulation confirmed by the pilot becomes active. Confidence drives action: around 95% — act; around 80% with a costly error — add a check now; around 50% — do not decide without data.

## Capacity and Entry Filter

8–15 P1/P2 records are live at any time. Overflow means cleanup, not expanding the next session. The pilot distributes records: accept, reject, or leave as background with a priority reduction.

P1 is accepted only with a bet on the current period result. Without that link, a hypothesis is allowed at P2–P4 but not at P1.

## Priority Scale

Four levels, in descending order:

- **P1** — there is a bet on the current period result (see above). The only level with a formal entry criterion.
- **P2, P3, P4** — no bet on the current period result. Three levels of reduced importance within this group; the boundary between them is not formalized and is assigned by the pilot based on subjective judgment at capture time. The regulations do not define a rule for choosing between P2 and P3, or between P3 and P4 — this is a deliberate gap, not a silent omission.

The machine contract (see "Events and Machine Contract") accepts only these four values in the `p=` field. Any other value is a record format error, not a new priority level.

## Lifecycle

1. Note Review proposes a record.
2. The pilot confirms it; the record receives the status "under review."
3. Week Close finds records whose review date has arrived, matches the criterion against facts, and proposes: confirmed, refuted, partially confirmed, or not applicable.
4. The pilot approves the verdict; it is written as a separate immutable event.
5. At the "Week Review" step, arrived and disputed records are examined; at the "Strategic Review" — the main monthly hypotheses are also examined, even if their date has not yet arrived.
6. The pilot saves, modifies, replaces, stops the review, or turns a consequence into a work plan item. A work plan item that tests or changes a hypothesis references `H-NNN`.

After each verdict, an action is chosen: change confidence, strategy, or plan; create or close a work plan item; schedule a new review; save a candidate to a Pack. A verdict without an action remains an incomplete Week Close result.

## Events and Machine Contract

The original record is never overwritten. A verdict, amendment, withdrawal, and replacement are each written as new events referencing the original record.

```html
<!-- h id=H-001 p=P1 due=2026-08-31 status=review -->
<!-- h id=H-001-verdict ref=H-001 date=2026-08-31 status=event -->
```

Allowed events: `verdict`, `amendment`, `withdrawal`, `replacement`. A `verdict` event excludes the original record from subsequent queries for arrived hypotheses. A new review is a new hypothesis, not an edit of the old line.

## Connection to Work Plan Items and the Artifactor

A work plan item can `tests`, `enables`, or `responds` to a specific H; or it can be `researches`/`operational` without a separate hypothesis. Multiple work plan items can work toward one H, but a new H is not created automatically for every work plan item.

The Artifactor does not guess the bet: it creates `hypothesis_relation: unclassified`. A draft work plan item can be registered, but `session-guard.sh` will not open a work Session for it until the pilot selects a relation. This preserves lightweight idea capture and prevents work from proceeding without a clear strategic basis.

## Calibration and Improvement

The Week Report displays the number of reviewed hypotheses and the share confirmed among hypotheses with confidence of 80% or higher. For records around 95%, the target is at least 0.9N confirmations; fewer indicates overconfidence.

A recurring discrepancy in one area is a candidate for a Pack or for these regulations. The route is the existing Capture-to-Pack flow, with no separate channel.
