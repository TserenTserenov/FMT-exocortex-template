# ADR-004: IWE Data Domain Map

**Status:** Accepted (methodology, recommended structure)
**Date:** 2026-08-16 (amendment 2026-08-18: domains 2.5/2.6 → `machine-dialogue`; roles→family table and `MC-slug` rules added 2026-08-28)
**Context:** WP-526 (New IWE Structure), F2/F4/F5/Stage 6, peer sessions Claude+Kimi `2026-08-16-21-wp526-f4-template-transfer` and Claude+Kimi+Codex `2026-08-28-12-wp526-migration-continue`

---

## Context

The repository structure inside a single IWE instance (template + user repositories) grows without direction unless it is designed upfront. User data types (profile, events, knowledge, session dialogues, etc.) mix with code, plans, and machine artifacts in one place. Over time this degrades tool performance, weakens security (personal data quarantine depends on convention rather than structure), and makes it harder to update the template without manual conflict resolution.

This map is the output of a dedicated review (WP-526) that passed internal architectural assessment (EMOGSSB profile; critical characteristics — Security and Evolvability — without veto). It records the **recommended** structure for a new IWE user. It does not require existing users to migrate: each user may follow their own path and pace to align with this map, or may deviate from it by their own decision.

**Related document:** [DATA-RESIDENCY.md](../DATA-RESIDENCY.md) — an earlier and simpler predecessor (WP-475, 2026-07-10). Its §3 contains a plain-text table of 4 data types (2.1–2.4) without change rate, sensitivity, or flow rules. This ADR does not replace or edit that document (it holds its own, already-closed phase boundary). This ADR introduces a more complete, machine-readable map alongside it, with an explicit one-way cross-reference (from here → to there).

## Decision

### Domain Map (type × rate)

Rate axis: **hot** (edited daily / every session) · **warm** (by work phases, over weeks) · **cold** (archive, rarely or never).

| Domain | Rate | Storage role | Rationale |
|---|---|---|---|
| 2.1 facts about the carrier (profile, characteristics) | warm | `personal-declarative` (git) + platform runtime Projection | declaration and computed value are separated by role and do not mix |
| 2.2 events / telemetry | hot | `personal-data` (git, append-only) + platform DB | active write stream — the main source of history growth and conflicts when mixed with planning |
| 2.3 knowledge / captures | warm | `governance-personal`: monthly records `inbox/captures/YYYY-MM.md` — authoritative home for raw material; off-git Memory — recoverable Projection; formalized knowledge — `promoted-knowledge` (Pack) | raw notes and formalized knowledge are different lifecycle stages with different homes; see amendment 2026-11-27 below |
| 2.4 non-formalizable | — | explicit quarantine "do not place" | not a structure but a marker — the decision is made separately; this map only references it |
| agent dialogues (former code 2.5; session transcripts) | warm→cold | `machine-dialogue` (git, `MC-*`, e.g. `MC-sessions`; see amendment 2026-08-18 below) | not a fact, not telemetry, and not finished knowledge — raw material for later knowledge extraction; archived over time, not deleted |
| quarantined dialogues (former code 2.6; subset of agent dialogues) | — | same home as agent dialogues, with separate access control | third-party data inside dialogues requires a stricter access regime than other dialogues |
| runtime / state | hot | outside git (e.g. `.iwe-runtime/`) | declared explicitly as a home class; not carried into git history |
| code / scripts — working copy | hot | user's working Repository | edited during any session that requires a tool fix |
| code / scripts — promoted copy | warm | `IWE/scripts/` | updated by a promotion decision, not daily — same logic, different stage |
| plans / working contexts | hot | `governance-personal`, without a telemetry stream and without a single growing knowledge file inside | mixing planning with an active write stream causes conflicts at session close |

### Storage Roles

The `homes` field in [DATA-DOMAINS-REGISTRY.yaml](../DATA-DOMAINS-REGISTRY.yaml) uses portable role labels instead of concrete repository names (repository names are each user's personal choice, not part of the template). The "Family" column is the prefix under which the role is physically created (IWE repository map, WP-526 F5, pilot decision 2026-08-18 — see amendment below):

| Role | Purpose | Family | Example |
|---|---|---|---|
| `governance-personal` | Planning, working contexts | `DS-*` | user's personal strategy Repository |
| `personal-data` | Active event / telemetry stream (2.2), off-axis quarantine | `PD-*` | separate append-only Repository or DB |
| `personal-declarative` | Stable facts about the user (2.1) | `PD-*` | Repository with personal data |
| `promoted-knowledge` | Formalized, promoted knowledge (2.3) | `PACK-*` | domain Pack repositories |
| `platform-runtime` | Computed / aggregated representations | outside git | platform DB (optional for the distribution) |
| `machine-dialogue` | Session dialogues with agents (2.5/2.6) — not read by a human day-to-day | `MC-*` | dialogue Repository (see amendment below) |

**`MC-*` semantics (added 2026-08-18, WP-526).** At start the family contains exactly one Repository — `MC-sessions`. Expanding the family (a second or further `MC-*` Repository) requires a separate ADR and cannot be introduced by analogy.

**Expansion precedent: ADR-006** (pilot's personal decision context, not part of the template) — the second Repository in the family, a daily-input routing log. It clarifies the semantics: user-input content is acceptable as a log field if the record is an artifact of the routing act rather than a fact about the person (the home for facts remains `PD-*`). This precedent does not change the template for new repositories.

**Amendment 2026-08-18 (pilot decision, WP-526 F5, third pass evening 2026-08-18) — domains 2.5/2.6 moved from `governance-personal` to `machine-dialogue`.** The original decision of 2026-08-16 (this section, commit `f88a582`) placed session dialogues under `governance-personal` (`sessions/` inside the personal strategy Repository). The pilot reconsidered this two days later: dialogues are not governance content but machine agent-to-agent data, for which a separate fifth family `MC-` was established. The `homes` table for domains 2.5/2.6 in [DATA-DOMAINS-REGISTRY.yaml](../DATA-DOMAINS-REGISTRY.yaml) has been corrected accordingly. The previous value (`governance-personal (sessions/)`) is preserved here for the decision history, not as an alternative.

**Amendment 2026-11-27 (pilot decisions, WP-526 F14; revision of the August decision per method DP.M.643 "IWE Structure Formation Method", PACK-digital-platform).**

1. **Codes 2.5/2.6 removed.** Agent dialogues and quarantined dialogues are not types on the personal axis 2.1–2.4 (structure concept, revision 2026-09-08). Their home is `machine-dialogue` (`MC-*`), as in amendment 2026-08-18.
2. **Home for raw knowledge 2.3.** The authoritative home for raw material is monthly records `inbox/captures/YYYY-MM.md` in the Repository with role `governance-personal`. Off-git Memory is a recoverable Projection. Formalized knowledge lives in Pack. The previous row ("off-git memory + Pack") did not name a home for raw material.
3. **Starter storage set.** A storage is created when the installation path has an actual writer. Desktop installation (`setup.sh`) creates only the Repository with role `governance-personal`. The browser path (`create_personal_data_space`) currently creates two more immediately — events (`personal-data`) and personal facts (`personal-declarative`). The browser assistant writes to them via the platform's write tool when the user manually records events or facts; there is no separate automatic writer. Whether these have an actual writer from day one — verify in the write log. Without a writer, create on demand. Paths may differ, but follow the same rule.
4. **Dialogue storage for a new user.** The `machine-dialogue` Repository is created on the first dialogue write, not at installation. The decision is made; implementation is a separate Work item. Until then, the fallback path described below applies ("Behavior of `session-guard.sh` without `MC-sessions`").

### Machine-Readable Source of Truth

The full schema (12 domains, rate, sensitivity level, permitted flows, control mechanism, maturity) is in [DATA-DOMAINS-REGISTRY.yaml](../DATA-DOMAINS-REGISTRY.yaml). This table is a compact human-readable summary. The YAML remains the source of truth in case of discrepancy.

## What This Decision Does Not Cover

- Migration of an existing user's structure to this map is each user's personal decision, not a template requirement. **This ADR does not plan or provide automatic migration**: for an existing Exocortex with `sessions/` inside a governance Repository (the structure before amendment 2026-08-18 above), migration to `machine-dialogue`/`MC-sessions` is a manual procedure described in the original decision context (WP-526 F5, Stage 3: `DS-my-strategy/inbox/WP-526/WP-526.md`), not in this template.
- The technical access-control mechanism for the quarantine (2.4/2.6) — declared as a Requirement; implementation is outside the scope of this ADR.
- Edits to [DATA-RESIDENCY.md](../DATA-RESIDENCY.md) — that document belongs to a separate, already-closed decision (WP-475) and is not edited here.

## Behavior of `session-guard.sh` Without `MC-sessions` (2026-08-29, found bug + fix, peer session with Kimi+Codex)

A fresh template installation does not receive `MC-sessions` automatically (see the item above — the Repository is created "as needed", not by `setup.sh`). This meant that `scripts/session-guard.sh` (delivered by this same template; source of truth — the author's `~/IWE/scripts/session-guard.sh`; synced via `template-sync.sh`) would fail with "MC-sessions not found" on the very first session open for a new user, instead of operating normally.

**Bug found along the way (not an imaginary risk — already in the code):** a line unconditionally creating the `MC-sessions` directory on every Script run fired before any existence check. Because of this, the intended protection — "an explicit error instead of a silent write to the wrong place" — never triggered: the Script silently used the empty, non-git, just-created folder. Fixed by removing that early command and moving the creation to the point of actual use.

**Resulting behavior (`resolve_orz_sessions_dir()` in `session-guard.sh`):**
- `MC-sessions` exists and is a git Repository → used normally.
- `MC-sessions` is physically absent → treated as a not-yet-migrated or fresh installation; the path `$GOV_REPO/sessions` is used (behavior prior to WP-526 F2), with an explicit `WARN` to stderr.
- `MC-sessions` exists but is NOT a git Repository, OR `IWE_SESSIONS_ROOT` is explicitly set but the path is unavailable → treated as a broken already-migrated installation; the Script fails with an explicit error and does not fall back to `$GOV_REPO/sessions` (otherwise a second, undetectable source of truth would appear for a user who has already migrated).

**Accepted residual risk:** the Script can only distinguish "never migrated" from "migrated but `MC-sessions` disappeared" by the presence of the directory — no dedicated migration marker was created (extra infrastructure for a rare case). In practice this means: if a user who has already migrated loses `MC-sessions` (manually or by an external process), the Script will silently fall back to `$GOV_REPO/sessions` with only a `WARN` to stderr. In automated runs (cron/launchd) this warning may go unnoticed. This was judged low-probability (a local git Repository with history and a remote does not disappear on its own) and accepted deliberately, not as an oversight.

