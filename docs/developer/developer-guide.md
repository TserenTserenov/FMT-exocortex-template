<body>
# IWE Developer Guide

> For T4+ developers (TD1). If you do not know your tier — read the [tier path](../LEARNING-PATH.md) first.

## Development Pipeline — One Page

Development in IWE passes through **6 stations** with a **dual-exit invariant** (code + captured knowledge):

1. **Framing** — raw need → task (routing tag, verification class, acceptance criterion).
2. **Opening** — WP Gate: role, work, class, assessment, model. Pilot sign-off is required.
3. **Design** — IntegrationGate/ArchGate for non-trivial work; skip for trivial. **First question: is this a change to a platform file (L1, e.g. `day-close.sh`) or to `extensions/` (L3)?** Platform changes require sign-off — see [CONTRIBUTING.md](../../CONTRIBUTING.md).
4. **Work** — code + capture simultaneously (not "code first, documentation later"). At the transition to this station, tests are written BEFORE code as a boundary specification — see [testing as specification](testing-as-spec.md).
5. **Verification** — by verification class: closed-loop → checklist/tests; open-loop → peer session; problem-framing → comparison against reference (R23/VR).
6. **Closing** — PR, merge by lead developer (TD1+TA4) or pilot, registry update.

**Dual exit:** a task that leaves only code behind is considered **unclosed**. Capture = distinction, memory file, Pack or AGENTS.md update.

> **Integration/infra tasks** (environment setup, external API, CI/CD, deployment — not business logic): dual exit is still required, but capture may be **thin** — one distinction or one entry in `memory/` about a pitfall that would otherwise be lost. Artificial "distinction for the sake of ticking a box" is not needed; absence of capture = unclosed task.

## What To Do With Your First Card

1. Copy the template to your task folder: `cp docs/developer/card-template.md <your-space>/inbox/tasks/my-card.md` (the registry and `inbox/tasks/` live in your DS space, not in the template).
2. Fill in the frontmatter (wp, verification_class, estimate, double_exit).
3. Go through the 6 stations (the card is the input for station 1).
4. Closing: PR to the repo + capture in distinctions/memory.

## WP Gate — How To Open a Task

See [CLAUDE.md §2 Pre-action Gates](../../CLAUDE.md). Declare: role, work, role performer, verification class, method, assessment, model. Wait for pilot sign-off.

## Definition of Done

- [ ] Code works (or artifact is created)
- [ ] Capture is recorded (distinction / memory / Pack)
- [ ] Role performer is closed in the registry (`<your-space>/docs/WP-REGISTRY.md`)
- [ ] PR is merged (merge — lead developer TD1+TA4 or pilot)

## Pull Request — Template Is Required

When opening a Pull Request, the [template](../../.github/PULL_REQUEST_TEMPLATE.md) is applied automatically: link to the card, dual exit, 6-station checklist, verification class. Fill it in honestly — the reviewer uses it to confirm the pipeline was completed. An empty checklist = PR is not accepted.

## Who Approves the Merge

**Only** the lead developer (TD1+TA4) or pilot. No one else — without explicit delegation.

## Failure Mode

If a task is stuck longer than the estimate (closed-loop — hours, open-loop — days) — escalate to the lead developer or pilot. Do not stall silently.

---

*Version: 2026-07-01. Related documents: [tier path](../LEARNING-PATH.md) (T1–T4), [card template](card-template.md), [CLAUDE.md](../../CLAUDE.md) (WP Gate), [testing as specification](testing-as-spec.md).*
</body>