# ADR-004: IWE Data Domain Map

**Status:** Accepted (methodology, recommended structure)
**Date:** 2026-08-16
**Context:** WP-526 (New IWE Structure), Ph2/Ph4, peer session Claude+Kimi `2026-08-16-21-wp526-f4-template-transfer`

---

## Context

The repository structure inside a single IWE instance (template + user repos) grows organically if not designed upfront: user data types (profile, events, knowledge, session transcripts, etc.) mix with code, plans, and machine Artifacts in one place. Over time this degrades tool performance, weakens security (personal data quarantine depends on convention rather than structure), and makes template updates require manual conflict resolution.

This map is the outcome of a dedicated review (WP-526) that passed an internal architectural Assessment (EMOGSSB profile; critical characteristics — Security and Evolvability — no veto). It establishes the **recommended** structure for a new IWE user. It does not require existing users to Migrate: each user may follow their own path and pace when aligning their structure to this map — or may deviate from it by their own decision.

**Related document:** [DATA-RESIDENCY.md](../DATA-RESIDENCY.md) — an earlier and simpler predecessor (WP-475, 2026-07-10). Its §3 contains a plain-text table of 4 data types (2.1–2.4) without change cadence, sensitivity, or flow rules. This ADR does not replace or edit that document (it holds its own, already-closed phase boundary) — it introduces a more complete, machine-readable map alongside it, with an explicit one-way cross-reference (from here → to there).

## Decision

### Domain Map (type × cadence)

Cadence axis: **hot** (edited daily/per-session) · **warm** (per work phase, weekly cadence) · **cold** (archive, rarely or never).

| Domain | Cadence | Storage role | Rationale |
|---|---|---|---|
| 2.1 facts about the bearer (profile, characteristics) | warm | `personal-declarative` (git) + platform runtime Projection | declaration and computed value are separated by role, not mixed |
| 2.2 events/telemetry | hot | `personal-data` (git, append-only) + platform DB | active write Stream — the main source of history growth and conflicts when mixed with planning |
| 2.3 knowledge/captures | warm | off-git Memory + promoted knowledge (Pack) | raw notes and formalized knowledge are different lifecycle stages with different homes |
| 2.4 non-formalizable | — | explicit quarantine "do not store" | not a structure, but a marker — the decision is made separately; this map only references it |
| 2.5 dialogue Artifacts (session transcripts) | warm→cold | `governance-personal` (git, `sessions/`) | not a fact, not telemetry, and not finished knowledge — raw material for subsequent knowledge extraction; archived over time, not deleted |
| 2.6 quarantine dialogues (subset of 2.5) | — | same home as 2.5, with separate access control | data about third parties inside dialogues requires a stricter access regime than the rest of domain 2.5 |
| runtime/state | hot | outside git (e.g. `.iwe-runtime/`) | declared explicitly as a storage class; not committed to git history |
| code/scripts — working copy | hot | user working Repository | edited in any Session where a tool fix is needed |
| code/scripts — promoted copy | warm | `FMT-exocortex-template/scripts/` | updated by a promotion decision, not daily — same logic, different stage |
| plans/working contexts | hot | `governance-personal`, without a telemetry Stream and without a single growing knowledge file inside | mixing planning with an active write Stream is a source of conflicts during Session Closing |

### Storage Roles

The `homes` field in [DATA-DOMAINS-REGISTRY.yaml](../DATA-DOMAINS-REGISTRY.yaml) uses portable role labels instead of specific repository names (repository names are each user's personal choice and are not part of the template):

| Role | Purpose | Example |
|---|---|---|
| `governance-personal` | Planning, working contexts, session dialogues (2.5/2.6) | user's personal strategic Repository |
| `personal-data` | Active event/telemetry Stream (2.2), off-axis quarantine | separate append-only Repository or DB |
| `personal-declarative` | Stable facts about the user (2.1) | Pack with personal data |
| `promoted-knowledge` | Formalized, promoted knowledge (2.3) | Domain Pack repositories |
| `platform-runtime` | Computed/aggregated representations outside git | platform DB (optional for distribution) |

### Machine-Readable Source of Truth

The full schema (12 domains, cadence, sensitivity level, permitted flows, control mechanism, maturity) is in [DATA-DOMAINS-REGISTRY.yaml](../DATA-DOMAINS-REGISTRY.yaml). The table above is a condensed human-readable summary; the YAML remains the source of truth in case of discrepancy.

## What This Decision Does Not Cover

- Migration of an existing user's structure to this map — a personal decision for each user, not a template Requirement.
- Technical access-control mechanism for quarantine (2.4/2.6) — declared as a necessity; Implementation is outside the scope of this ADR.
- Edits to [DATA-RESIDENCY.md](../DATA-RESIDENCY.md) — that document belongs to a separate, already-closed decision (WP-475); it is not edited here.

