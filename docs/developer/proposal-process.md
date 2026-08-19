# Developer Proposal Process

> For T4+ IWE developers (Andrey, Natalia, and other staff members) who have their own platform development ideas. Linked from [developer-guide.md](developer-guide.md) — a separate route, not a station in the general 6-station Pipeline.

## Scope — Distinction From Service Access

This file covers the proposal and acceptance of **ideas** for IWE development: template and platform repositories, without production secrets.

Connecting to **platform services** with real credentials (live tokens, databases, production) is a separate route: the owner of the specific service grants minimal access and accepts the result according to their own procedure. If a proposed idea goes beyond IWE repositories and involves secrets or production access, the route switches to the service owner's procedure — this file does not replace it.

## Step 1 — Proposing an Idea

The developer submits the idea as an issue using the ready-made [`Developer Proposal`](../../.github/ISSUE_TEMPLATE/developer_proposal.md) template — opens a new issue in the repository and selects this template from the list. It contains the same fields described below:

1. **Artifact** — what is being proposed, in one phrase.
2. **Why** — what problem or dissatisfaction it addresses.
3. **Materials** — which Packs, repositories, or access are likely needed. "Don't know" is acceptable — the pilot will clarify during approval.
4. **Assessment** — rough estimate of the work volume.
5. **Acceptance Criterion** — how we will know it is done: a test, an example result, or a manual verification scenario.

Without the fifth field, the pilot cannot quickly evaluate acceptance — it is mandatory, even if the wording is still a draft at this stage.

## Step 2 — Approval and Materials

Final approval of an idea always comes from the pilot personally. An idea consumes their Priority and working materials, so this decision is not fully automated: the pilot accepts, rejects, or requests clarification.

On approval, the pilot grants read-only access to the required materials:

- **Packs** — the same mechanism that `/pack-subscribe` uses for external subscribers (clone read-only, mark in CLAUDE.md, include in the search scope), but **not the same access channel**. Internal platform Packs (`PACK-digital-platform`, `PACK-verification`, `PACK-autonomous-agents`, `PACK-agent-rules`) are not issued to external subscribers at all — they are needed specifically by IWE developers for code work, and access to them for a T4+ developer is free, by the pilot's decision at the time of idea approval. The paid subscription model (see the Work Product on Pack subscriptions) is for external content consumers, not for the internal team.
- **Repositories** — read access to the target repository, if the developer does not already have it.

## Step 3 — Work

The developer completes the work according to the Acceptance Criterion in the issue. If a discrepancy between reality and the original plan is discovered along the way, notify the pilot — do not silently fix it (the same Drift Reporting rule that applies to agents).

## Step 4 — Acceptance

The completed work arrives as a Pull Request. The pilot reviews it against the Acceptance Criterion specified in the issue at the time of proposal, then merges it or returns it with a comment.

## When This Grows Into a Separate Work Product

This route is not a permanent queue management system — it is a lightweight process for individual proposals. Signs that it is time to create a separate Work Product:

- Recurring delegation cases appear (not one-off proposals).
- A dedicated owner for the idea queue or access management is needed.
- The WP Gate itself needs to change.

Until that point, the route remains part of the developer guide, not a separate system.

## Details to Be Clarified During Rollout

The first real case has not yet been completed — the details below are intentionally left flexible:

- Checking a proposed idea for overlap with an already open pilot Work Product.
- The pilot's response time for a proposal.

## Source

The route was designed in a Peer partner session with Codex (DP.SC.154), consensus reached in 3 turns with no escalations.