# Developer Proposal Process

> For T4+ IWE developers (Andrey, Natalya, and other staff members) who have their own ideas for Platform development. Linked from [developer-guide.md](developer-guide.md) — a separate route, not a station in the general six-station Pipeline.

## Scope — Difference From Service Access

This file covers the proposal and acceptance of **ideas** for IWE development: Template and Platform Repositories without production secrets.

Connecting to **platform services** with real credentials (live tokens, databases, production) is a separate route: the owner of the specific service grants minimum access and accepts the result through their own procedure. If a proposed idea goes beyond IWE Repositories and involves secrets or production access, the route switches to the service owner's procedure — this file does not replace it.

## Step 1 — Proposing an Idea

The developer submits an idea as an issue using the [`Developer Proposal`](../../.github/ISSUE_TEMPLATE/developer_proposal.md) Template — opens a new issue in the Repository and selects that Template from the list. It contains the same fields described below:

1. **Artifact** — what is being proposed, in one phrase.
2. **Why** — what problem or dissatisfaction it solves.
3. **Materials** — which Packs, Repositories, or access credentials will likely be needed. "Unknown" is acceptable — the pilot will clarify during approval.
4. **Assessment** — a rough estimate of the work volume.
5. **Definition of done** — how we will know it is complete: a test, an example result, or a manual verification Scenario.

Without the fifth field, the pilot cannot quickly evaluate acceptance — it is required, even if the wording is a draft at this Stage.

## Step 2 — Approval and Materials

Final approval of an idea always comes from the pilot personally. An idea consumes the pilot's Priority and working materials, so this decision is not fully automated: the pilot approves, rejects, or requests clarification.

Upon approval, the pilot grants read-only access to the required materials:

- **Packs** — the same mechanism that `/pack-subscribe` uses for external subscribers (clone read-only, mark in CLAUDE.md, include in search scope), but **not the same access channel**. Internal Platform Packs (`PACK-digital-platform`, `PACK-verification`, `PACK-autonomous-agents`, `PACK-agent-rules`) are not issued to external subscribers at all — they are specifically needed by IWE developers for code work, and access to them for a T4+ developer is free, by the pilot's decision at the idea approval Stage. The paid subscription model (see the WP on Pack subscription) is for external content consumers, not for the internal team.
- **Repositories** — read access to the target Repository, if the developer does not already have it.

## Step 3 — Work

The developer completes the work according to the definition of done in the issue. If a discrepancy between reality and the original plan is discovered along the way, report it to the pilot — do not fix it silently (the same Drift Reporting rule that applies to agents).

## Step 4 — Acceptance

The completed work arrives as a Pull Request. The pilot Reviews it against the definition of done stated in the issue when the idea was proposed, then either merges it or returns it with a comment.

## External Developer / Candidate

Steps 1–4 above are written for staff T4+ developers. The same route works for an outside person — an external developer or candidate who is not part of the team. This is not the "external subscriber" who, in Step 2, is not issued internal Platform Packs at all (paid model WP-532) — this is a separate channel: one-time access for a single approved idea, not a content subscription.

**Difference from Step 2 for T4+:** the pilot grants access not to "all materials needed for the work in general," but strictly to the Packs and Repositories listed in the issue — the minimum set for this idea, nothing more.

**Mandatory conditions before granting access** (recorded by the pilot at approval in Step 2):

- The pilot personally approves disclosure of each Pack and remains responsible for subsequently revoking Repository access.
- The identity of the external participant is confirmed — a real name and a previously used communication channel, not anonymous.
- The participant agrees not to share materials with third parties and not to use them outside of work on the approved idea.
- Access is limited to the duration of work on the idea in the issue — it is not indefinite.
- For each Pack, the pilot decides separately whether to grant full access or only a sanitized excerpt — there is no default general rule.

**Important note on revoking access:** revoking Repository permissions blocks access to future changes, but does not delete the read-only copy the participant has already made locally — this is a limitation of read-only access itself, not a gap in this process. The conditions above (do not share / do not use materials outside the idea) are the only protection beyond the revocation itself.

**Open question:** whether a separate legal document (e.g., an NDA) is required for such access — no such policy exists yet. The decision on the first real case rests with the pilot; this route does not replace that decision and does not imply one automatically.

**Letter to the participant:** see the message Template — [`external-developer-letter.md`](external-developer-letter.md).

## When This Grows Into a Separate WP

This route is not a permanent queue management system — it is a lightweight process for individual proposals. Signs that it is time to create a separate WP:

- Recurring delegation cases appear (not one-off proposals).
- A dedicated owner is needed for the idea or access queue.
- The WP Gate itself needs to change.

Until that point, the route remains part of the developer guide, not a separate system.

## Details To Be Clarified Through Use

The first live case has not yet been completed — the details below are intentionally left open:

- Checking a proposed idea for overlap with an already open pilot WP.
- The pilot's response time for a proposal.

## Source

The route was designed in a Peer partner session with Codex (DP.SC.154), consensus reached in 3 turns with no escalations.
