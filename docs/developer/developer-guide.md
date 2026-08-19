# IWE Developer Guide

> For T4+ developers (TD1). If you do not know your tier, read the [tier path](../LEARNING-PATH.md) first.

## Development Pipeline — One Page

Development in IWE passes through **6 stations** with a **dual-exit invariant** (code + captured knowledge):

1. **Formulation** — raw need → task (routing tag, verification class, acceptance criterion).
2. **Opening** — WP Gate: role, work, class, assessment, model. Pilot sign-off is mandatory.
3. **Design** — IntegrationGate/ArchGate for non-trivial work; skip for trivial. **First question: is the change going into a platform file (L1, e.g. `day-close.sh`) or into `extensions/` (L3)?** Platform changes require sign-off — see [CONTRIBUTING.md](../../CONTRIBUTING.md).
4. **Work** — code + capture simultaneously (not "code first, document later"). At the transition into this station, tests are written BEFORE code as a boundary specification — see [testing as specification](testing-as-spec.md). Code changes follow the [IWE engineering style](code-style.md) (P0–P12). Working with Claude Code inside the station is a separate Discipline — see [working with Claude in development](working-with-claude.md) (when useful/dangerous, prompt patterns, pre-merge checklist).
5. **Verification** — by verification class: closed-loop → checklist/tests; open-loop → peer session; problem-framing → comparison against reference (R23/VR).
6. **Closing** — PR, merge by lead developer (TD1+TA4) or pilot, registry update.

**Dual exit:** a task that leaves only code behind is considered **unclosed**. Capture = a Distinction, a memory file, an update to a Pack or AGENTS.md.

> **Integration/infra tasks** (environment setup, external API, CI/CD, deployment — not business logic): dual exit is still required, but the capture may be **thin** — one Distinction or one entry in `memory/` about a pitfall that would otherwise be lost. Artificial "Distinction for the sake of ticking a box" is not needed; missing capture = unclosed task.

## What To Do With Your First Card

1. Copy the Template into your task folder: `cp docs/developer/card-template.md <your-space>/inbox/tasks/my-card.md` (the registry and `inbox/tasks/` live in your DS space, not in the Template).
2. Fill in the frontmatter (wp, verification_class, estimate, double_exit).
3. Complete the 6 stations (the card is the input to station 1).
4. Closing: PR to the Repository + capture in distinctions/memory.

## Python Environment

IWE Scripts use third-party libraries (`httpx`, `pyyaml`, `pytest` — full list in [`requirements.txt`](../../requirements.txt)). Do not install them into the system Python — create a separate Environment for this Repository:

```bash
python3 -m venv .venv
source .venv/bin/activate       # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

Activate `.venv` at the start of each work Session. `extensions/local-llm/` requires one additional library (`ruamel.yaml`) — it is not in the main list; install it separately only if you are working with that extension.

## WP Gate — How To Open a Task

See [CLAUDE.md §2 Pre-action Gates](../../CLAUDE.md). Declare the following: role, work, Work Product, verification class, method, assessment, model. Wait for pilot sign-off.

## Definition of Done

- [ ] Code works (or Artifact is created)
- [ ] Capture is recorded (Distinction / memory / Pack)
- [ ] Work Product is closed in the registry (`<your-space>/docs/WP-REGISTRY.md`)
- [ ] PR is merged (merge — lead developer TD1+TA4 or pilot)

## Pull Request — Template Is Mandatory

When you open a Pull Request, the [template](../../.github/PULL_REQUEST_TEMPLATE.md) is inserted automatically: link to the card, dual exit, 6-station checklist, verification class. Fill it in honestly — the reviewer uses it to confirm the Pipeline was completed. An empty checklist = PR is not accepted.

## Who Accepts Merges

**Only** the lead developer (TD1+TA4) or the pilot. No one else — without explicit delegation.

## Failure Mode

If a task is stuck longer than the estimate (closed-loop — hours, open-loop — days), escalate to the lead developer or pilot. Do not stall silently.

## Your Own Idea, Not an Assigned Task

If you have your own idea for developing IWE rather than a task from the pilot, there is a separate route: [developer proposal process](proposal-process.md) (proposal → sign-off → materials → work → acceptance).

## Connection to the Universal IWE Guide

Section 7 "From Using to Creating" of the universal guide ([guide.system-school.ru, course 1-3-iwe-work-and-development](https://guide.system-school.ru/universal/lr/1-3-iwe-work-and-development)) and this guide solve different problems. Section 7 explains principles to a Creator who does not yet write code in IWE. This file is the concrete Pipeline for those who already do.

**What goes into Section 7 (universal) versus what stays here (developer)** — a two-check test (WP-453, `pipeline-spec.md §3`); both must be true for Section 7:

| Check | Question | Goes to Section 7 | Stays here |
|-------|----------|-------------------|------------|
| C1 | Applicable without knowing specific IWE files/commands? | "Knowledge is extracted at every Work milestone" | "Run `ke` skill with arguments" |
| C2 | Will a T3+ reader understand this without completing this guide? | "Testing is a specification of behavior" | "How to configure a pytest fixture for MCP" |

Both checks are true → material goes to Section 7. At least one is false → material stays here.

**Moving content to Section 7 is not a manual note — it is a working Pipeline (WP-453).** A commit tagged `[guide-impact: S7.SS_N]` in a modified file automatically creates a task for the pilot to update the corresponding section — the Hook is already connected (`.githooks/post-commit`). The "Testing as Specification" section (Phase 1 of this guide) has already gone through this process and was published 2026-07-02. The texts for the "Code Style" and "Working with Claude" sections (Phases 2–3) were written 2026-07-24, exist as drafts in the `docs` clone, and are awaiting the pilot's decision to publish — the Pipeline up to publication is not automatic (VitePress does not check `status: draft`; a push publishes immediately).

---

*Version: 2026-08-19. Related documents: [tier path](../LEARNING-PATH.md) (T1–T4), [card Template](card-template.md), [CLAUDE.md](../../CLAUDE.md) (WP Gate), [testing as specification](testing-as-spec.md), [engineering code style](code-style.md), [working with Claude in development](working-with-claude.md), [developer proposal process](proposal-process.md).*