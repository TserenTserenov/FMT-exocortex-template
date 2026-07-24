# IWE Developer Guide

> For T4+ developers (TD1). If you do not know your tier — read the [tier path](../LEARNING-PATH.md) first.

## Development Pipeline — One Page

Development in IWE passes through **6 stations** with a **dual-exit invariant** (code + captured knowledge):

1. **Definition** — raw need → task (routing tag, verification class, acceptance criterion).
2. **Opening** — WP Gate: role, work, class, assessment, model. Pilot sign-off is mandatory.
3. **Design** — IntegrationGate/ArchGate for non-trivial work; skip for trivial. **First question: is the change going into a platform file (L1, e.g. `day-close.sh`) or into `extensions/` (L3)?** Platform-level changes require sign-off — see [CONTRIBUTING.md](../../CONTRIBUTING.md).
4. **Work** — code + capture simultaneously (not "code first, documentation later"). At the transition into this station, tests are written BEFORE code as a boundary specification — see [testing as specification](testing-as-spec.md). Code changes follow the [IWE engineering style](code-style.md) (P0–P12). Working with Claude Code inside the station is a separate Discipline — see [working with Claude in development](working-with-claude.md) (when useful/dangerous, prompt patterns, pre-merge checklist).
5. **Verification** — by verification class: closed-loop → checklist/tests; open-loop → peer session; problem-framing → comparison with reference (R23/VR).
6. **Closing** — PR, merge by the lead developer (TD1+TA4) or pilot, Registry update.

**Dual exit:** a task that leaves only code behind is considered **unclosed**. Capture = a Distinction, a memory file, or an update to a Pack or AGENTS.md.

> **Integration/infra tasks** (environment setup, external API, CI/CD, Deployment — not business logic): the dual-exit requirement still applies, but capture may be **thin** — one Distinction or one entry in `memory/` about a pitfall that would otherwise be lost. Artificial "Distinction for the sake of a checkbox" is not needed; absence of capture = unclosed task.

## What to Do With Your First Card

1. Copy the Template into your task folder: `cp docs/developer/card-template.md <your-space>/inbox/tasks/my-card.md` (the Registry and `inbox/tasks/` live in your DS space, not in the Template).
2. Fill in the frontmatter (wp, verification_class, estimate, double_exit).
3. Complete all 6 stations (the card is the input for station 1).
4. Closing: PR to the Repository + capture in distinctions/memory.

## WP Gate — How to Open a Task

See [CLAUDE.md §2 Pre-action Gates](../../CLAUDE.md). Declare: role, work, Role Performer, verification class, Method, assessment, model. Wait for pilot sign-off.

## Definition of Done

- [ ] Code works (or Artifact is created)
- [ ] Capture is recorded (Distinction / memory / Pack)
- [ ] Role Performer is closed in the Registry (`<your-space>/docs/WP-REGISTRY.md`)
- [ ] PR is merged (merge by lead developer TD1+TA4 or pilot)

## Pull Request — Template is Mandatory

When opening a Pull Request, the [template](../../.github/PULL_REQUEST_TEMPLATE.md) is applied automatically: link to the card, dual exit, 6-station checklist, verification class. Fill it in honestly — the reviewer uses it to confirm that the Pipeline was completed. Empty checklist = PR is not accepted.

## Who Approves the Merge

**Only** the lead developer (TD1+TA4) or the pilot. No one else — without explicit delegation.

## Failure Mode

If a task is stuck longer than the estimate (closed-loop — hours, open-loop — days) — escalate to the lead developer or pilot. Do not stall silently.

---

*Version: 2026-07-24. Related documents: [tier path](../LEARNING-PATH.md) (T1–T4), [card template](card-template.md), [CLAUDE.md](../../CLAUDE.md) (WP Gate), [testing as specification](testing-as-spec.md), [engineering code style](code-style.md), [working with Claude in development](working-with-claude.md).*
