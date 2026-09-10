# ADR-004: IWE Data Domain Map

**Status:** Accepted (methodology, recommended structure)
**Date:** 2026-08-16 (amended 2026-08-18: domains 2.5/2.6 → `machine-dialogue`; roles→family table and `MC-slug` rules added 2026-08-28)
**Context:** WP-526 (New IWE Structure), phases F2/F4/F5/Stage 6, peer sessions Claude+Kimi `2026-08-16-21-wp526-f4-template-transfer` and Claude+Kimi+Codex `2026-08-28-12-wp526-migration-continue`

---

## Context

Without deliberate design, the Repository structure inside a single IWE instance (template + user repos) grows organically. User data types — Profile, events, Knowledge, session dialogues, etc. — mix with code, plans, and machine Artifacts in one place. Over time this degrades tool performance, weakens security (personal-data quarantine relies on convention rather than structure), and makes template updates impossible without manual conflict resolution.

This map is the result of a dedicated review (WP-526) that passed an internal architectural Assessment (EMOGSSB Profile, critical characteristics: Security and Evolvability — no veto). It defines the **recommended** structure for a new IWE user. It does not require existing users to Migrate. Each user chooses their own path and pace for aligning their structure to this map — or may deviate from it by their own decision.

**Related document:** [DATA-RESIDENCY.md](../DATA-RESIDENCY.md) — an earlier, simpler predecessor (WP-475, 2026-07-10). Its §3 contains a plain-text table of four data types (2.1–2.4) without change rate, sensitivity, or flow rules. This ADR does not replace or edit that document — it has its own, already-closed phase boundary. This ADR introduces a more complete, machine-readable map alongside it, with an explicit one-way cross-reference (from here → to there).

## Decision

### Domain Map (type × change rate)

Change rate axis: **hot** (edited daily / per session) · **warm** (per work phase, weekly) · **cold** (archive, rarely or never).

| Domain | Rate | Storage Role | Rationale |
|---|---|---|---|
| 2.1 facts about the bearer (Profile, characteristics) | warm | `personal-declarative` (git) + platform runtime Projection | declaration and computed value are separated by Role — not mixed |
| 2.2 events / telemetry | hot | `personal-data` (git, append-only) + platform DB | active write Stream — the main source of history growth and conflicts when mixed with planning |
| 2.3 knowledge / captures | warm | off-git Memory + promoted Knowledge (Pack) | raw notes and formalized Knowledge are different lifecycle stages — different homes |
| 2.4 non-formalizable | — | explicit quarantine "do not store" | not a structure, but a marker — the decision is made separately; this map only references it |
| 2.5 dialogue Artifacts (session transcripts) | warm→cold | `machine-dialogue` (git, `MC-*`, e.g. `MC-sessions`; amendment 2026-08-18 below) | not a fact, not telemetry, not finished Knowledge — raw material for future Knowledge extraction; archived over time, not deleted |
| 2.6 quarantine dialogues (subset of 2.5) | — | same home as 2.5, with separate access control | data about third parties inside dialogues requires stricter access control than the rest of domain 2.5 |
| runtime / state | hot | outside git (e.g. `.iwe-runtime/`) | declared explicitly as a home class — not committed to git history |
| code / scripts — working copy | hot | user working Repository | edited during any session that requires a tool fix |
| code / scripts — promoted copy | warm | `FMT-exocortex-template/scripts/` | updated on a promotion decision, not daily — same logic, different stage |
| plans / work contexts | hot | `governance-personal`, with no telemetry Stream and no single growing Knowledge file inside | mixing planning with an active write Stream causes conflicts at session close |

### Storage Roles

The `homes` field in [DATA-DOMAINS-REGISTRY.yaml](../DATA-DOMAINS-REGISTRY.yaml) uses portable role labels instead of specific Repository names (Repository names are each user's personal choice — not part of the template). The "Family" column is the prefix under which the Role is physically created (IWE Repository map, WP-526 F5, pilot decision 2026-08-18 — see amendment below):

| Role | Purpose | Family | Example |
|---|---|---|---|
| `governance-personal` | Planning, work contexts | `DS-*` | user's personal strategy Repository |
| `personal-data` | Active event / telemetry Stream (2.2), quarantine off-axis | `PD-*` | separate append-only Repository or DB |
| `personal-declarative` | Stable facts about the user (2.1) | `PD-*` | Repository with personal data |
| `promoted-knowledge` | Formalized, promoted Knowledge (2.3) | `PACK-*` | Domain Pack repositories |
| `platform-runtime` | Computed / aggregated views | outside git | platform DB (optional for distribution) |
| `machine-dialogue` | Session dialogues with agents (2.5/2.6) — not read by humans day-to-day | `MC-*` | dialogue Repository (see amendment below) |

**`MC-*` semantics (added 2026-08-18, WP-526).** At launch, the family contains exactly one Repository: `MC-sessions`. Expanding the family (a second or subsequent `MC-*` Repository) requires a separate ADR — it is not introduced by analogy.

**Expansion precedent: ADR-006** (personal decision context, not part of the template) — a second family Repository, a daily-input routing log. Clarifies semantics: user input content is acceptable as a log field when the record is an Artifact of the routing act, not a fact about the person (the facts home remains `PD-*`). This precedent does not change the template for new repositories.

**Amendment 2026-08-18 (pilot decision, WP-526 F5, third pass evening of 2026-08-18) — domains 2.5/2.6 moved from `governance-personal` to `machine-dialogue`.** The original decision of 2026-08-16 (this section, commit `f88a582`) placed session dialogues in `governance-personal` (`sessions/` inside the personal strategy Repository). The pilot revised this two days later: dialogues are not governance content — they are machine-to-machine data for which a separate fifth family `MC-` was created. The `homes` table for domains 2.5/2.6 in [DATA-DOMAINS-REGISTRY.yaml](../DATA-DOMAINS-REGISTRY.yaml) has been updated accordingly. The previous value (`governance-personal (sessions/)`) is preserved here for decision history only — it is not an alternative.

### Machine-Readable Source of Truth

The full schema (12 domains, change rate, sensitivity level, allowed flows, control mechanism, maturity) is in [DATA-DOMAINS-REGISTRY.yaml](../DATA-DOMAINS-REGISTRY.yaml). The table above is a compact human-readable summary. The YAML remains the source of truth when the two diverge.

## What This Decision Does Not Cover

- Migration of an existing user's structure to this map is each user's personal decision — not a template Requirement. **This ADR does not provide and does not plan any automatic migration.** For an existing exocortex with `sessions/` inside the governance Repository (structure prior to the 2026-08-18 amendment above), Migration to `machine-dialogue`/`MC-sessions` is a manual procedure described in the original decision context (WP-526 F5, Stage 3: `DS-my-strategy/inbox/WP-526/WP-526.md`), not in this template.
- The technical access-control mechanism for the quarantine (2.4/2.6) — declared as necessary; implementation is outside the scope of this ADR.
- Edits to [DATA-RESIDENCY.md](../DATA-RESIDENCY.md) — that document belongs to a separate, already-closed decision (WP-475) and is not edited here.

## `session-guard.sh` Behavior Without `MC-sessions` (2026-08-29 — discovered bug + fix, peer session with Kimi+Codex)

A fresh template installation does not receive `MC-sessions` automatically (see the point above — the Repository is created on demand, not during `setup.sh`). This meant that `scripts/session-guard.sh` (delivered by this template; source of truth: the author's `~/IWE/scripts/session-guard.sh`; synced via `template-sync.sh`) would fail on the very first session open for a new user, with the error "MC-sessions not found", instead of operating normally.

**Discovered bug (not a hypothetical risk — already present in the code):** a line unconditionally creating the `MC-sessions` directory on every Script run fired before any existence check. As a result, the intended safeguard — "explicit error instead of silently writing to the wrong location" — never triggered: the Script silently used an empty, non-git, just-created directory. Fixed by removing that early command and moving the directory creation to the point of actual use.

**Resulting behavior (`resolve_orz_sessions_dir()` in `session-guard.sh`):**
- `MC-sessions` exists and is a git Repository → used normally.
- `MC-sessions` is physically absent → treated as an unmigrated or fresh installation; path `$GOV_REPO/sessions` is used (pre-WP-526-F2 behavior), with an explicit `WARN` to stderr.
- `MC-sessions` exists but is **not** a git Repository, **or** `IWE_SESSIONS_ROOT` is explicitly set but the path is unavailable → treated as a broken, already-migrated installation; the Script fails with an explicit error; no fallback to `$GOV_REPO/sessions` occurs (a fallback would create a second, undetectable source of truth for a user who has already migrated).

**Consciously accepted residual risk:** the Script can distinguish "never migrated" from "migrated but the `MC-sessions` directory is gone" only by checking whether the directory exists — no dedicated migration marker was introduced (adding Infrastructure for a rare edge case was not justified). In practice, this means: if an already-migrated user's `MC-sessions` is deleted (manually or by an external process), the Script will silently fall back to `$GOV_REPO/sessions` and emit only a `WARN` to stderr. In automated runs (cron/launchd) this warning may go unnoticed. This was judged low-probability — a local git Repository with history and a remote does not disappear on its own — and accepted as a deliberate trade-off, not an oversight.
