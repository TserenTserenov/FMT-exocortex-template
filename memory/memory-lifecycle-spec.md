---
description: Memory ontology specification v1 — 4 axes, frontmatter schema, HOT/WARM/COLD
  archival rules
domains:
- protocol
- behaviour
horizon: warm
name: Memory Lifecycle & Classification Protocol
owner: user
schema_version: 1
status: active
type: protocol
valid_from: 2026-04-30
---

# Memory Lifecycle & Classification Protocol v1

> **Artifact WP-217 Phase10.1.** ArchGate passed 2026-04-30.
> **Implementation:** Phase10.2 (memory-validate.sh), Phase10.3 (Close Integration), Phase10.4 (Migration).

## 1. Problem

MEMORY.md is bloating: feedback_behaviour.md = 442 lines, feedback_architecture.md = 275 lines. Files are unclassified — no TTL, no explicit owner. OwnerIntegrity is violated: the live index (MEMORY.md) mixes navigation, content, and changelog in a single file.

Root cause: no memory Ontology. Files are created ad-hoc without a horizon or status.

## 2. Three-Layer Architecture

```
HOT (every session, ≤150 lines total)
 └→ WARM (14 days without access, on trigger)
     └→ COLD (30 days without access, on request)
         └→ memory/archive/ (90 days without access, physically moved)
```

| Layer | Loading | Limit | TTL before demotion |
|------|----------|-------|-----------------|
| **HOT** | Every session, automatically | ≤150 lines total (excluding frontmatter) | — |
| **WARM** | On trigger (topic, keyword) | None | 14 days without access |
| **COLD** | Only on explicit request | None | 30 days without access |
| **archive** | Retrospective only | — | Not demoted |

## 2a. All Known Memory Thresholds — Map (issue #736)

> Three independent discrepancies were found scattered across different files
> under similar names with no unified reference. This table does not change any
> numbers — it provides a single source→value→status list. Pilot decision
> (17.09): "≤11 files" was removed from `CLAUDE.md §4` entirely, with no
> replacement number or counter. The memory Architecture had long since moved
> to HOT/WARM/COLD with a token budget (line below); a separate file-count
> limit on top of it is unnecessary.

| Threshold | Value | Source | Status |
|---|---|---|---|
| Number of memory files | — | — | **Removed** (issue #736, pilot decision 17.09) — the text "≤11 files" was removed from `CLAUDE.md §4`: it had no executing code, had long diverged from practice, and duplicated the already-active token budget below |
| HOT layer total | ≤150 lines | `verify-context-budget.sh` (this specification §2) | **Enforced** — blocks commit of hot files. Canon for all locations below that measure the same file |
| `.claude/rules/distinctions.md` (platform hot layer) | ≤150 lines (canon above) | `verify-context-budget.sh`, `.claude/skills/week-close/SKILL.md` | **Enforced** + drift flag on Week Close — both synchronized to 150 (issue #736; was 80 in week-close, diverged from enforced threshold) |
| `memory/hard-distinctions.md` (expanded distinctions) | no threshold of its own | — | **Not measured** — currently 626 lines, unchecked; the similar name to distinctions.md above is misleading |
| Collapsible markup for artifact files | >80 lines | `.claude/rules/formatting.md` | **Advisory** — Formatting guidance (when to collapse sections in markdown), NOT a memory budget for distinctions.md; different measured quantities; the number coincidentally matched the former (incorrect) distinctions.md threshold |
| MEMORY.md (index) | >200 lines | `.claude/skills/week-close/SKILL.md:192` | **Advisory** — agent checks visually at Week Close; independent criterion from the KB size below (lines ≠ bytes/line length) — left as-is, not merged into one number |
| Index file (`check-index-health.py`) | 30 KB warn / 100 KB fail, 300/500 chars/line (warn/fail), 200/400 chars/cell (warn/fail) | `.claude/scripts/check-index-health.py` | **Enforced** — Day Close step 4c |
| Same script, `memory/` overall | 21.2 KB warn / 25 KB fail (separate, stricter threshold) | `check-index-health.py` (`MEMORY_SIZE_WARN/FAIL`) | **Enforced** |

**Known unresolved discrepancies (not resolved by this table):** the index threshold at Week Close (200 lines, manual) and in `check-index-health.py` (KB + line/cell length, automatic) are two different measured quantities for the same file (lines vs bytes/length). They are intentionally kept separate and not merged into one number.

## 3. Frontmatter Schema v1

**All `memory/*.md` files must contain frontmatter.** A file without frontmatter is a violation and is blocked by `memory-validate.sh` (Phase10.2).

> **Two forms, one canon (#513, 23.08.2026).** The canonical form uses flat
> top-level keys. The nested form (`metadata:` with the same keys) is written
> by the Claude Code system instruction — it cannot be prohibited. It is READ
> on equal terms with the flat form by the unified reader
> (`.claude/lib/frontmatter.sh::get_field`); all consumers read through it
> only. A conflict (a key present in both forms with different values) is a
> validation error — silent priority is forbidden. Any file REWRITE by tooling
> serializes canonically flat, so nesting is flushed out naturally without
> blocking it at input.

### Required Fields

```yaml
---
name: "Short name (matches filename without extension)"
description: "One line — used in MEMORY.md as the index hook string"
type: user | feedback | project | reference | lesson | protocol
horizon: hot | warm | cold | archive
domains: [tag1, tag2]
status: active | dormant | superseded | archived
valid_from: YYYY-MM-DD
owner: user | platform
schema_version: 1
---
```

### Optional Fields

```yaml
valid_until: YYYY-MM-DD       # expiry date (for project context)
superseded_by: filename.md    # REQUIRED if status: superseded
originSessionId: <uuid>       # creation session ID
review_at: YYYY-MM-DD         # REQUIRED if type: lesson (issue #736, design session with Codex)
```

### Invariants

- `status: superseded` → field `superseded_by` is REQUIRED
- `horizon: hot` → file counts toward the HOT limit (≤150 lines total)
- `schema_version` = 1 (current)
- Changing `schema_version` → Migration via `memory-migrate.sh` (§8)
- `type: lesson` → field `review_at` is REQUIRED (default `valid_from + 90 days` if not set manually) AND the file body must contain the marker `**How to apply:**` — a one-time incident chronicle without an explicit generalization to future behavior is not a lesson but a single-session log (issue #736, design session with Codex, 2026-09-09: 90% of `lessons_*.md` files in a live installation were not even mentioned in the index — this pair of checks stops such a file from being written at creation time, rather than relying on subsequent cleanup)

## 4. Four Classification Axes

### Axis 1: type

| type | Contents | Default horizon |
|------|-------------|----------------------|
| `user` | Profile: Role, goals, Skills, preferences | hot |
| `feedback` | Agent behavior rules: what to do / not do | hot (if actively applied) |
| `project` | Context for initiatives, decisions, deadlines | warm |
| `reference` | Links to external systems, URLs, configs | warm |
| `lesson` | Lessons extracted from specific work | warm |
| `protocol` | Operational Protocols (lazy-load) | warm |

### Axis 2: horizon

| horizon | Description |
|---------|----------|
| `hot` | Needed by the agent at the start of every session. Limit: ≤150 lines total across all HOT files |
| `warm` | Loaded when a topical trigger is detected (keyword, service, work product) |
| `cold` | Loaded only on explicit request such as "find the history for X" |
| `archive` | Physically in `memory/archive/`. Not present in the MEMORY.md index |

### Axis 3: domains (tags)

Allowed tags: `behaviour`, `architecture`, `infrastructure`, `writing`, `protocol`, `user-profile`, `project-iwe`, `project-bot`, `project-mcp`, `neon`, `railway`, `cloudflare`, `linear`, `git`, `memory`

Multiple tags: `domains: [behaviour, architecture]`

Adding a new tag: simply use it. No tag registry is needed.

### Axis 4: status

| status | Condition | Next step |
|--------|---------|---------------|
| `active` | Regularly used | — |
| `dormant` | Not referenced for >30 days | At Month Close: propose demoting horizon or superseding |
| `superseded` | Replaced by another file | Set `superseded_by:`, remove from HOT index |
| `archived` | Physically moved to `memory/archive/` | Remove from MEMORY.md active index |

## 5. Archival Rules

### Horizon Demotion (proposed by agent)

| Transition | Condition | Who decides |
|---------|---------|-----------|
| HOT → WARM | `horizon: hot` + not referenced for ≥14 days | Agent proposes at Week Close |
| WARM → COLD | `horizon: warm` + not referenced for ≥30 days | Agent proposes at Month Close |
| COLD → archive | `horizon: cold` + not referenced for ≥90 days | Agent proposes + user confirms |

**The agent proposes — it does not act autonomously.** Exception: updating `horizon` in frontmatter (non-destructive) during an explicit Week Close step.

### HOT Limit

If a new file with `horizon: hot` would push the total over 150 lines, the agent MUST propose moving one of the HOT files to WARM before adding the new one.

Measurement: `wc -l memory/*.md | awk` filtered by `horizon: hot` in frontmatter (implemented in Phase10.2).

## 6. Rules for Creating memory/ Files

1. Determine the **type** (one of 6 values) and **horizon** (default per §4.1)
2. Fill in all required frontmatter fields
3. Add a line to MEMORY.md in the appropriate section: `- [Name](filename.md) — hook`
4. Check the HOT limit: if exceeded → demote an existing HOT file

When created automatically via the memory system (Write to `memory/`):
- Claude MUST add frontmatter with all fields filled in
- A file without frontmatter is an OwnerIntegrity violation and requires immediate correction

## 7. Rules for Updating MEMORY.md

- MEMORY.md is an index, not a content store
- Each file = one line in its section: `- [Name](filename.md) — hook`
- `status: superseded` → the line is ~~struck through~~
- `status: archived` (physically moved) → the line is removed from the active index
- HOT files go in the first sections; WARM files are organized by topic; COLD files appear only if explicit mention is required

## 8. Schema Migration (v1 → v2)

When a required frontmatter field changes:
1. Update `schema_version: 2` in this document
2. Write `memory-migrate.sh --from 1 --to 2` (Template: adds the new field with a default value to each file's frontmatter)
3. Run: `for f in memory/*.md; do bash scripts/memory-migrate.sh "$f" --from 1 --to 2; done`
4. Update §3 Frontmatter Schema with the new field

The Template Script is included in Phase10.2 as `scripts/memory-migrate.sh.example`.

---

*Created: 2026-04-30. Artifact WP-217 Phase10.1. ArchGate: E=⚠️ (schema_version mitigates), S=✅.*
