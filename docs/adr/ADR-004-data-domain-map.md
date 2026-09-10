# ADR-004: IWE Data Domain Map

**Status:** Accepted (methodology, recommended structure)
**Date:** 2026-08-16 (amendment 2026-08-18: domains 2.5/2.6 → `machine-dialogue`; roles→family table and `MC-slug` rules added 2026-08-28)
**Context:** WP-526 (New IWE Structure), Phase 2/4/5/Stage 6, peer sessions Claude+Kimi `2026-08-16-21-wp526-f4-template-transfer` and Claude+Kimi+Codex `2026-08-28-12-wp526-migration-continue`

---

## Context

Without upfront design, the Repository structure inside a single IWE instance (template + user repos) grows organically: user data types (Profile, events, Knowledge, session dialogues, etc.) mix with code, plans, and machine Artifacts in one place. Over time this degrades tool performance, Security (personal data quarantine relies on convention rather than structure), and the ability to update the template without manual merge conflicts.

This map is the result of a dedicated review (WP-526) that passed internal architectural Assessment (EMOGSSB profile, critical characteristics — Security and Evolvability — no veto). It defines the **recommended** structure for a new IWE user. It does not require existing users to Migrate: each user may follow their own path and pace toward this map, or deviate from it by their own decision.

**Related document:** [DATA-RESIDENCY.md](../DATA-RESIDENCY.md) — an earlier and simpler predecessor (WP-475, 2026-07-10) whose §3 contains a plain-text table of 4 data types (2.1–2.4) without change rate, sensitivity, or flow rules. This ADR does not replace or edit that document (it holds its own, already-closed phase boundary) — it introduces a more complete, machine-readable map alongside it, with an explicit one-way cross-reference (from here → to there).

## Decision

### Domain Map (type × rate)

Rate axis: **hot** (edited daily / every session) · **warm** (per work phase, over weeks) · **cold** (archive, rarely or never).

| Domain | Rate | Storage Role | Rationale |
|---|---|---|---|
| 2.1 facts about the bearer (Profile, characteristics) | warm | `personal-declarative` (git) + platform runtime Projection | declaration and computed value are separated by Role, not mixed |
| 2.2 events / telemetry | hot | `personal-data` (git, append-only) + platform DB | active write Stream — the main source of history growth and merge conflicts when mixed with planning |
| 2.3 Knowledge / captures | warm | off-git Memory + promoted Knowledge (Pack) | raw notes and structured Knowledge are different lifecycle stages, different homes |
| 2.4 non-formalizable | — | explicit quarantine "do not place" | not a structure but a marker — the decision is made separately; this map only references it |
| 2.5 dialogue Artifacts (session transcripts) | warm→cold | `machine-dialogue` (git, `MC-*`, e.g. `MC-sessions`; amendment 2026-08-18 below) | not a fact, not telemetry, and not finished Knowledge — raw material for subsequent Knowledge extraction; archived over time, not deleted |
| 2.6 quarantine dialogues (subset of 2.5) | — | same home as 2.5 with separate access control | data about third parties inside dialogues requires a stricter access regime than the rest of domain 2.5 |
| runtime / state | hot | outside git (e.g. `.iwe-runtime/`) | declared explicitly as a home class, not carried into git history |
| code / scripts — working copy | hot | user working Repository | edited during any Session where a tool fix is needed |
| code / scripts — promoted copy | warm | `FMT-exocortex-template/scripts/` | updated by promotion decision, not daily — same logic, different stage |
| plans / work contexts | hot | `governance-personal`, no telemetry Stream and no single growing Knowledge file inside | mixing planning with an active write Stream causes conflicts at Session close |

### Storage Roles

The `homes` field in [DATA-DOMAINS-REGISTRY.yaml](../DATA-DOMAINS-REGISTRY.yaml) uses portable Role labels instead of specific Repository names (Repository names are each user's personal choice, not part of the template). The "Family" column is the prefix under which a Role is physically created (IWE Repository map, WP-526 Phase 5, pilot decision 2026-08-18 — see amendment below):

| Role | Purpose | Family | Example |
|---|---|---|---|
| `governance-personal` | Planning, work contexts | `DS-*` | user's personal strategy Repository |
| `personal-data` | Active event / telemetry Stream (2.2), quarantine off-axis | `PD-*` | separate append-only Repository or DB |
| `personal-declarative` | Stable facts about the user (2.1) | `PD-*` | Repository with personal data |
| `promoted-knowledge` | Structured, promoted Knowledge (2.3) | `PACK-*` | Domain Pack repositories |
| `platform-runtime` | Computed / aggregated views | outside git | platform DB (optional for distribution) |
| `machine-dialogue` | Session dialogues with agents (2.5 / 2.6) — not read by humans day-to-day | `MC-*` | dialogue Repository (see amendment below) |

**`MC-*` semantics (added 2026-08-18, WP-526).** At launch the family contains exactly one Repository — `MC-sessions`. Expanding the family (a second or subsequent `MC-*` Repository) requires a separate ADR and is not introduced by analogy.

**Amendment 2026-08-18 (pilot decision, WP-526 Phase 5, third pass evening 2026-08-18) — domains 2.5/2.6 moved from `governance-personal` to `machine-dialogue`.** The original decision of 2026-08-16 (this section, commit `f88a582`) assigned session dialogues to `governance-personal` (`sessions/` inside the personal strategy Repository). The pilot revised this two days later: dialogues are not governance content but machine data agent-to-agent, for which a separate 5th family `MC-` was created. The `homes` table for domains 2.5/2.6 in [DATA-DOMAINS-REGISTRY.yaml](../DATA-DOMAINS-REGISTRY.yaml) has been corrected accordingly. The previous value (`governance-personal (sessions/)`) is preserved here for decision history, not as an alternative.

### Machine-Readable Source of Truth

The full schema (12 domains, rate, sensitivity level, permitted flows, control mechanism, maturity) is in [DATA-DOMAINS-REGISTRY.yaml](../DATA-DOMAINS-REGISTRY.yaml). This table is a compact human-readable summary; the YAML remains the source of truth in case of discrepancy.

## What Is Outside This Decision

- Migration of an existing user's structure to this map is each user's personal decision, not a template Requirement. **No automatic Migration is included or planned by this ADR**: for an existing exocortex with `sessions/` inside the governance Repository (structure prior to the 2026-08-18 amendment above), Migration to `machine-dialogue` / `MC-sessions` is a manual procedure described in the original decision context (WP-526 Phase 5, Stage 3: `DS-my-strategy/inbox/WP-526/WP-526.md`), not in this template.
- The technical access-control mechanism for quarantine (2.4 / 2.6) — declared as a necessity; implementation is outside the scope of this ADR.
- Edits to [DATA-RESIDENCY.md](../DATA-RESIDENCY.md) — that document belongs to a separate, already-closed decision (WP-475); it is not edited here.

## Behavior of `session-guard.sh` Without `MC-sessions` (2026-08-29, discovered bug + fix, peer session with Kimi+Codex)

A fresh template installation does not receive `MC-sessions` automatically (see above — the Repository is created on demand, not during `setup.sh`). This meant that `scripts/session-guard.sh` (delivered by this same template; source of truth — the author's `~/IWE/scripts/session-guard.sh`; synced via `template-sync.sh`) would fail with "MC-sessions not found" on the very first Session open for a new user, instead of working normally.

**Discovered incidental bug (not a hypothetical risk — already in the code):** a line unconditionally creating the `MC-sessions` directory on every Script run fired before any existence check. Because of this, the intended protection — "explicit error instead of silent write to the wrong place" — never triggered: the Script silently used an empty, non-git directory it had just created. Fixed by removing that early command and moving directory creation to the point of actual use.

**Resulting behavior (`resolve_orz_sessions_dir()` in `session-guard.sh`):**
- `MC-sessions` exists and is a git Repository → used normally.
- `MC-sessions` is physically absent → treated as a non-migrated / fresh installation; the path `$GOV_REPO/sessions` is used (behavior prior to WP-526 Phase 2), with an explicit `WARN` to stderr.
- `MC-sessions` exists but is **not** a git Repository, **or** `IWE_SESSIONS_ROOT` is explicitly set but the path is inaccessible → treated as a broken **already-migrated** installation; the Script fails with an explicit error. Fallback to `$GOV_REPO/sessions` does not occur (otherwise a second, undetectable source of truth would arise for a user who has already migrated).

**Consciously accepted residual risk:** the Script can distinguish "never migrated" from "migrated but the `MC-sessions` directory has disappeared" only by the presence of the directory — no Migration marker was introduced (extra Infrastructure for a rare case). In practice: if an already-migrated user's `MC-sessions` is deleted (manually or by an external process), the Script will silently fall back to `$GOV_REPO/sessions`, issuing only a `WARN` to stderr. In automated runs (cron / launchd) this warning may go unnoticed. This is considered low-probability (a local git Repository with history and a remote does not disappear on its own) and accepted deliberately, not as an oversight.
