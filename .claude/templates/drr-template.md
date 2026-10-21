# DRR (Decision Record + Rationale) — Template

> **Purpose:** record an architectural or process decision at the moment it is made, and confirm that it is operationalized — not merely declared.
> **When to use:** after passing an ArchGate (Step 4.6 DRR Adequacy Pass), after completing the fast track (Step 0-A — see "Fast-track" section below), or for any significant user decision that requires a rationale.

---

## Context

- **Decision made:** YYYY-MM-DD HH:MM
- **Work Product / task:** WP-N / ...
- **Participants:** pilot, agent(s), roles
- **Trigger:** which decision point required a choice

## Problem / Decision Point

Describe what required a decision. One or two sentences.

## Decision

What was chosen. One paragraph, without justification (that belongs in the rationale).

## Rationale

Why this option was chosen. References to principles, ArchGate, and alternatives.

## Alternatives

| Option | Reason for rejection |
|--------|----------------------|
| A | ... |
| B | ... |

## Advice Log

> Advice Process (Harmel-Law): the author makes the decision, but advice from affected parties and experts is collected BEFORE the verdict. "No one is affected" is also a valid entry — with justification.

| Who was consulted (party / expert) | Advice given | Accepted / rejected and why |
|------------------------------------|--------------|------------------------------|
| ... | ... | ... |

## Consequences

- **Positive:** ...
- **Negative / risks:** ...

## Adequacy Checklist

- [ ] The decision is operationalized: a checklist, test, or invariant exists that verifies its fulfillment.
- [ ] The detector / gate actually blocks — it does not merely exist in a document.
- [ ] A forcing function or explicit user acknowledgement is present.
- [ ] The contract / promise has been verified by acceptance (verify-pass, smoke, canary, acceptance report).
- [ ] The record is maintained in one place (OwnerIntegrity); no duplication in other files.
- [ ] A review date or condition is specified (`review_date`, `superseded_by`, or a linked Work Product).
- [ ] An automated control (fitness-check) is named that protects the critical characteristic after implementation (Principle #27 Intervention Loop).

## References

- ADR: ...
- Work Product: `<governance-repo>/inbox/WP-N/WP-N.md`
- Related Artifacts: ...

---

## Fast-track (Mini-DRR)

> Use this section instead of the sections above when ArchGate Step 0-A returned `core_result = fast_tracked` (all admission axes are low). Store it in the same location as full DRRs.

- **Date:** YYYY-MM-DD
- **Decision:** one line
- **Cost of change is low because:** ...
- **Rollback window is low because:** ...
- **External commitments are not affected because:** ...
- **Decision owner:** ...