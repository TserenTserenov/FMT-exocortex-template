# IWE Developer Guide

> For T4+ developers (TD1). If you do not know your tier — read the [tier path](../LEARNING-PATH.md) first.

## Development Pipeline — One Page

Development in IWE passes through **6 stations** with the invariant of **dual exit** (code + captured knowledge):

1. **Scoping** — raw need → task (routing tag, verification class, acceptance criterion).
2. **Opening** — WP Gate: role, work, class, assessment, model. Pilot sign-off is mandatory.
3. **Design** — IntegrationGate/ArchGate for non-trivial tasks; skip for trivial ones. **First question: is this a change to a platform file (L1, e.g. `day-close.sh`) or to `extensions/` (L3)?** Platform changes require sign-off — see [CONTRIBUTING.md](../../CONTRIBUTING.md).
4. **Work** — code + capture simultaneously (not "code first, documentation later"). At the transition into this station, tests are written BEFORE code as a boundary specification — see [testing as specification](testing-as-spec.md). Code changes follow the [IWE engineering code style](code-style.md) (P0–P12). Working with Claude Code inside the station is a separate Discipline — see [working with Claude in development](working-with-claude.md) (when it is useful/dangerous, prompt patterns, pre-merge checklist).
5. **Verification** — by verification class: closed-loop → checklist/tests; open-loop → peer session; problem-framing → comparison against reference (R23/VR).
6. **Closing** — PR, merge by lead developer (TD1+TA4) or pilot, Registry update.

**Dual exit:** a task that leaves only code behind is considered **unclosed**. Capture = Distinction, memory file, Pack update, or AGENTS.md update.

> **Integration/infra tasks** (environment setup, external API, CI/CD, Deployment — not business logic): dual exit is still mandatory, but capture may be **thin** — one Distinction or one entry in `memory/` about a pitfall that would otherwise be lost. Artificial "Distinction for the sake of a checkbox" is not required; absent capture = unclosed task.

## What to Do With the First Card

1. Copy the Template into your task folder: `cp docs/developer/card-template.md <your-space>/inbox/tasks/my-card.md` (the Registry and `inbox/tasks/` live in your DS space, not in the Template).
2. Fill in the frontmatter (wp, verification_class, estimate, double_exit).
3. Complete the 6 stations (the card is the input for station 1).
4. Closing: PR to the Repository + capture in distinctions/memory.

## WP Gate — How to Open a Task

See [CLAUDE.md §2 Pre-action Gates](../../CLAUDE.md). Declare: role, work, Role Performer, verification class, method, assessment, model. Wait for pilot sign-off.

## Definition of Done

- [ ] Code works (or Artifact is created)
- [ ] Capture is recorded (Distinction / memory / Pack)
- [ ] Role Performer is closed in the Registry (`<your-space>/docs/WP-REGISTRY.md`)
- [ ] PR is merged (merge — lead developer TD1+TA4 or pilot)

## Pull Request — Template Is Mandatory

When opening a Pull Request, the [template](../../.github/PULL_REQUEST_TEMPLATE.md) is applied automatically: link to the card, dual exit, 6-station checklist, verification class. Fill it in honestly — the reviewer uses it to confirm the Pipeline was completed. Empty checklist = PR not accepted.

## Who Approves the Merge

**Only** the lead developer (TD1+TA4) or the pilot. No one else — without explicit delegation.

## Failure Mode

If a task is stuck beyond the estimate (closed-loop — hours, open-loop — days) — escalate to the lead developer or pilot. Do not stall silently.

## Connection to the IWE Universal Guide

Section 7 "From Use to Creation" of the universal guide ([guide.system-school.ru, course 1-3-iwe-work-and-development](https://guide.system-school.ru/universal/lr/1-3-iwe-work-and-development)) and this guide address different purposes: Section 7 explains the principles to a Creator who does not yet write code in IWE; this file describes the concrete Pipeline for those who already do.

**What goes into Section 7 (universal) and what stays here (developer)** — a two-check test (WP-453, `pipeline-spec.md §3`), both must be true for Section 7:

| Check | Question | Goes into Section 7 | Stays here |
|-------|----------|---------------------|------------|
| C1 | Applicable without knowledge of specific IWE files/commands? | "Knowledge is extracted at every Work milestone" | "Run `ke` Skill with arguments" |
| C2 | Will a T3+ reader understand it without completing this guide? | "Testing is a specification of behavior" | "How to configure a pytest fixture for MCP" |

Both checks are true → material goes into Section 7. At least one is false → material stays here.

**Moving content to Section 7 is not a manual note — it is a working Pipeline (WP-453).** A commit tagged `[guide-impact: S7.SS_N]` in a modified file automatically creates a task for the pilot to update the corresponding section — the Hook is already connected (`.githooks/post-commit`). The "Testing as Specification" section (Phase 1 of this guide) has already gone through this process and was published on 2026-07-02. The texts for the "Code Style" and "Working with Claude" sections (Phases 2–3) were written on 2026-07-24, exist as drafts in the `docs` clone, and are awaiting the pilot's decision to publish — the Pipeline up to publication is not automatic (VitePress does not check `status: draft`; a push publishes immediately).

---

*Version: 2026-08-03. Related documents: [tier path](../LEARNING-PATH.md) (T1–T4), [card template](card-template.md), [CLAUDE.md](../../CLAUDE.md) (WP Gate), [testing as specification](testing-as-spec.md), [engineering code style](code-style.md), [working with Claude in development](working-with-claude.md).*

