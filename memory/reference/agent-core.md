---
description: 'Full text of SYNC-CORE/CLAUDE.md §1-2 blocks collapsed during the M2
  slim (WP-7 HOTBUDGET-M2). Restored from git history (commit fee0f85^) — issue #283.'
domains:
- agent-core
horizon: warm
name: Agent Core — elaboration
owner: platform
schema_version: 1
status: active
type: reference
valid_from: 2026-07-20
---
# Agent Core — Elaboration

> Slim versions of these rules live in `CLAUDE.md` (SYNC-CORE block + §1-2). This file contains the full formulations for cases where the hot-framework does not provide enough context (conflict resolution, rare branches, examples).

## Pull-on-Touch (CLAUDE.md §2 p.4) — Conflict Resolution

The PreToolUse Hook automatically runs `git pull --rebase --autostash` on the first **access** to a repo per Session, once per repo. The agent does not repeat the pull manually and does not change the working directory via `cd`; use `git -C <repo>` for all git commands.

Before the pull — run `git status`:
- **dirty** → stash or skip with the label "output potentially stale"
- **rebase conflict** → two options: (A) stash uncommitted changes + mark output as potentially stale → continue; (B) abort the Session + report to the pilot. **Default: option A.** No automatic conflict resolution.
- **Network fail** → work with the local copy, mark outputs as potentially stale.

Reason for expanding the trigger from "changes" to "accesses": on 2026-05-05, a false "Day Open missed" diagnosis occurred because the agent read a stale local copy of the governance repo (origin was 3 commits ahead).

## Git Staging — Examples (CLAUDE.md SYNC-CORE)

**NEVER `git add -u`, `git add .`, `git add -A`** — these capture changes from OTHER agents (Kimi/Hermes run in parallel in the same repo) → incorrect attribution, accidental commit of another agent's work.

**Always stage only specific files:**
```bash
# Correct
git add path/to/specific-file.md

# FORBIDDEN — captures other agents' work
git add -u
git add .
git add -A
```

**Before every commit — verify the staged scope:**
```bash
git diff --cached --name-only
```
If unexpected files appear — run `git restore --staged <file>` before committing.

## State-Transition Gate — Cross-Axis (CLAUDE.md Pre-action Gates)

> This section is not a restoration from the M2 slim (the rule was introduced later, WP-457, and was not present in the pre-slim version of CLAUDE.md). The source is `memory/protocol-open.md` (current version), duplicated here as an elaboration of the "cross-axis → agent-core.md" reference in CLAUDE.md.

The axis model is defined in `archive/wp-contexts/WP-457/CONCEPT-user-states.md §5` (in the author's governance repo). If an action affects multiple axes simultaneously (permission/belonging/engagement/mastery) — record the transition as `provisional` until it passes ArchGate (Phase9); do not arbitrarily select a single axis.

## Status Reporting — Team Mode and Fail-Safe (CLAUDE.md SYNC-CORE)

**Team mode (WP-398 Phase5):** when working with files from a team repo (multiple participants in one repo), pass `repo="org/repo-name"` to `agent_status_update`. This allows other team agents to see your active files and avoid conflicts.

Example:
```
agent_status_update(agent="claude-code", status=working, task="WP-X phase", files=["src/marathon.py"], repo="your-org/{{GOVERNANCE_REPO}}")
```

**Fail-safe:** if the status is not updated manually — deterministically writes `scripts/agent-status-report.sh <agent> <status> [task] [files-csv]` (Claude — from the Stop Hook, Kimi — from `kimi-peer-adapter.sh`). This does not replace the primary path via the MCP tool.

## WP-REGISTRY Naming — ✅/❌ Examples (CLAUDE.md SYNC-CORE)

Prohibited in the "Name" column: closing dates, references to peer Sessions, Phase metrics, commit SHAs, verification results, test counts, and any other service data.

- ✅ `Diagnostic algorithm`
- ❌ `Diagnostic algorithm — closed 30 May (PHASE1=5, MANDATORY=5...)`

**Where to put everything else:**
- Work Product closing summary → `## Closing` section in `archive/wp-contexts/WP-NNN-*.md`
- Current phases and Progress → `phases`/`progress` frontmatter fields in `inbox/WP-NNN/WP-NNN.md`

**When starting work on a Work Product:** read `inbox/WP-NNN/WP-NNN.md`. When Phase status changes → update the card's frontmatter, NOT the Registry name.

## Calendar Events — Recovery Steps (CLAUDE.md SYNC-CORE)

If an event was created after 09:00 by mistake:
1. Delete the incorrect event immediately.
2. Recreate it before 09:00 on the same day, or at the nearest available slot before 09:00.
3. Notify the pilot of the error.

## Code Style — Delivery and Detectors by Agent (CLAUDE.md SYNC-CORE)

For Claude, rules P0-P5 are delivered via a Hook (`inject-code-style.sh` — UserPromptSubmit, injects a reminder when code is being edited). The safety-net detector `code-style-hook.sh` writes P1/P2/P4 findings to a unified style log for subsequent Review.

## Source

Most of the content was restored from `git show fee0f85^:CLAUDE.md` (the parent commit before the M2 slim on 2026-07-16, WP-7 HOTBUDGET-M2) — Pull-on-Touch, Git Staging, Status Reporting, WP-REGISTRY Naming, Calendar Events, Code Style. Commit `fee0f85` moved the slim versions into CLAUDE.md but did not create this elaboration file — issue #283. The State-Transition Gate section has a separate source; see the note inside that section.
