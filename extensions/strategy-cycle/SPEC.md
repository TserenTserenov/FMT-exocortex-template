---
date: 2026-08-11
designed_via: Architecture Gate 2026-08-11 (author IWE), EMOGSSB profile — variant
  «contract without binding to WP numbers» versus two rejected variants (owner-skeleton
  as a separate integrator; owner-skeleton as the sole host-component)
related:
  memory:
  - lpf-hypothesis-log.md
  - dry-run-contract.md
  pack: []
status: draft
type: architecture-spec
---

# Strategy Cycle Contract — Specification

> **Purpose:** define the data structure by which a period closing (session/day/week/month) passes facts to the next opening, and by which the opening assembles those facts into a bounded decision package for the strategic session. The contract is not tied to specific Work Product numbers — any IWE installation implements the producer/consumer using its own means, including "manually, using the template below."

## 1. Problem

A period closing and the next opening occur at different points in time, and often involve different processes (a person at the keyboard vs. overnight automation). Without a shared contract, each closing → opening pair invents its own format for passing facts, and the experience of one installation (what entered the decision package, what was filtered out, and why) does not transfer to another. A second symptom of the same gap: the `/verify-hypotheses` skill already references the `memory/lpf-hypothesis-log.md` regulation, which did not physically exist in the template before this revision — the implementation was ahead of the specification.

## 2. What This Contract Does NOT Do

- Does not prescribe a specific storage mechanism (file, log, database) — only the record structure.
- Does not replace the existing `roles/strategist/prompts/session-prep.md` — that file remains the reference implementation for the week opening (it reads the "Results" section directly from WeekPlan) until the producer/consumer under this contract passes live acceptance testing on an installation without a dedicated server.
- Does not require a hypothesis log or ledger-based closing mechanics as mandatory components — their absence means an empty input, not an error (see §5).

## 3. Event (Minimal Form)

Any producer (session/day/week/month closing, hypothesis verification, consumer context feedback) can describe a fact as a single record:

```yaml
event_type: <string>   # e.g. session_closed, hypothesis_verdict, dissatisfaction_stale, guide_feedback
source: <repo or source component>
period: <date or range the fact applies to>
summary: <1-2 human-readable sentences>
requires_pilot_decision: true|false   # is this a fact for reference, or a question requiring a pilot choice?
```

Storage of specific `event_type` values is left to the implementation (a ledger file, a YAML accumulator, or anything else). The contract fixes only one requirement: every producer must answer `requires_pilot_decision` explicitly — this field is the boundary between "decision package" and "background statistics" as defined in §4.

## 4. Decision Package (Assembly for the Strategic Session)

The consumer (week/month opening) assembles available events for the period into a package with a hard ceiling of **no more than 10 items requiring a pilot decision** (`requires_pilot_decision: true`). Everything else becomes an aggregated summary, not a line-by-line list.

Mandatory categories of the package, if the corresponding producer exists in the installation (no producer → the category is empty, not absent from the layout):

1. Actual load and available capacity of the pilot for the period.
2. 1–3 candidates for changing the system Constraint (bottleneck) of the period.
3. Due, disputed, or overdue hypotheses (if the hypothesis log is connected) — with alternative explanations for the result, not only "confirmed/refuted."
4. Changes to the dissatisfaction registry: resolved for closing, new, **stale without movement for 8+ weeks** — stale items require a mandatory forced pilot choice (close / reformulate / keep with an explicit review trigger); silent carry-forward is prohibited.
5. Work Products of the period that passed the filter (system constraint, period result, hypothesis deadline, red line, new blocker, mandatory pilot decision) — items that did not pass are shown in aggregate, not line by line.
6. Red-line violations / protocol Incidents (discrepancy between the planned scenario and actual execution).
7. *(optional, if the installation includes a business/product perimeter)* Customer, market, and financial signals — threshold events only (crossed a red line / requires a decision), not raw analytics; the specific business model of the installation is not part of the contract.

A "do not include" decision on any package item receives a review deadline or a trigger event that automatically returns the item — silent disappearance is prohibited.

## 5. Degradation Rule

The consumer must treat the absence of a producer (no hypothesis log, no closing ledger, no personal guide generator) as an **empty input for that category**, not as a package assembly error. An installation with no producer at all receives a package with a single category — Work Products of the period — which is a valid degenerate case, not a process failure.

This requirement exists because the reference overnight closing/opening Pipeline (if present in the installation) typically assumes a dedicated server. Installations without a server must produce the same decision package either manually or through a lightweight chain, without losing the structure.

## 6. Open Questions (Before Removing Draft Status)

- **Controlled acceptance testing was attempted on 16.08.2026** (WP-518) against verdict `H-270` from the hypothesis log: the event form (5 fields from §3) covers everything consumers need — compatibility confirmed. However, the executable test (a sub-agent without access to the raw log, receiving only a structured event and the `06a-pool.md` step instruction) found a gap not in the form but in the pairing choice: `hypothesis_verdict` describes an already-closed hypothesis, while `06a-pool.md` ("Stake") expects an open record not yet verified. The correct consumer for `hypothesis_verdict` is category 3 of the §4 decision package ("due/disputed/overdue hypotheses"), not `06a-pool.md`. The `hypothesis_verdict → 06a-pool.md` pair **did not pass** acceptance; the `hypothesis_verdict → §4 category 3` pair has not been tested (next candidate). Testing `06a-pool.md` itself requires a different type of producer (an open hypothesis record without a verdict), which the current list of example `event_type` values does not explicitly name.
- Replacing (not supplementing) `session-prep.md` with a consumer under this contract is a separate decision, outside the scope of this delivery.
- Contract revision — no later than the first complete application cycle on real verification data, synchronized with the nearest scheduled hypothesis log review (if connected).

## 7. Related Documents

- `memory/lpf-hypothesis-log.md` — hypothesis log regulation; one of the possible producers of the `hypothesis_verdict` event.
- `roles/strategist/prompts/strategy-session-weekly/steps/03-dissatisfactions.md`, `06a-pool.md`, `06b-budget.md` — steps that read the §4 decision package where it is available.
- `extensions/strategy-cycle/scripts/validate-event.sh` (+ `test-validate-event.sh`) — mechanical validation of the §3 event form: five fields, `requires_pilot_decision` strictly `true|false`, `period` as an ISO date or range.
