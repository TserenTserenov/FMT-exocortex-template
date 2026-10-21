---
annotations:
  destructive: true
  interactive: true
browser_safe: false
description: Restore IWE memory from an exocortex backup on a new device or after
  data loss — NL wrapper around restore-from-exocortex.sh.
layer: L1
name: restore-exocortex
owner_role: R6
related:
- '#125'
status: active
triggers:
  phrases:
  - restore the exocortex
  - restore memory
  - restore exocortex
  - restore exocortex
  - restore memory on a new device
  slash:
  - /restore-exocortex
version: 1.0.0
---

# /restore-exocortex — Restore Memory From Exocortex

> **Role:** R6 Coder
> **Trigger:** "restore exocortex / memory", new device, loss or corruption of `memory/`
> **Service Clause:** DP.SC.153 (parent, skills); implementation #125

## Promise (contract)

**Input:** (optional) path to the governance repo. Default: `$WORKSPACE_DIR/$GOVERNANCE_REPO` (`${IWE_WORKSPACE:-$HOME/IWE}/DS-strategy`).
**Output:** restored `memory/` + `extensions/` + `CLAUDE.md` + `memory/` symlink; report + reminder to restart Claude Code.
**Invariant:** does NOT overwrite a populated `memory/` or `extensions/` without explicit user confirmation.

> **Orchestration, not implementation.** The Skill judges (fresh device vs. existing installation, path resolution, confirmation) and calls the deterministic primitive `scripts/restore-from-exocortex.sh`. It does not perform file operations itself. On a bare terminal without an agent, run the Script directly — this is the bootstrap path (see SETUP-GUIDE).

## Algorithm

### Step 1. Resolve Script and Path
- Script: `$IWE_SCRIPTS/restore-from-exocortex.sh` → fallback `$WORKSPACE_DIR/IWE/scripts/restore-from-exocortex.sh`. File not found → see Failure Mode.
- Governance repo: user argument, otherwise `$WORKSPACE_DIR/${GOVERNANCE_REPO:-DS-strategy}`. Verify that `<gov>/exocortex/` exists.

### Step 2. Pre-flight (judgment — LLM is appropriate here)
- Determine the target auto-memory path: `~/.claude/projects/$(echo "$HOME" | tr '/_.' '-')-IWE/memory` (Claude Code slugifies `/`, `_`, `.` → `-`; `tr '/' '-'` will miss `_` in the username).
- **Empty or absent** → fresh device; restore without `--force`.
- **Populated** → existing installation. This is destructive: show `--dry-run` output and **request confirmation** before using `--force` (Rule 7, "irreversible action" exception).

### Step 3. Preview → Restore
1. Always run `restore-from-exocortex.sh <gov> --dry-run` first — show the user what will happen.
2. After confirmation (or immediately if memory is empty) — run without `--dry-run` (with `--force` if memory is populated and the user has confirmed).

### Step 4. Report
- Number of memory files restored, whether `CLAUDE.md` was restored, whether the symlink was created.
- **Reminder: restart Claude Code** — memory is loaded at session startup.

## Failure Mode

| Scenario | Behavior |
|---------|-----------|
| `exocortex/` not found | Stop: backup is absent or not pushed. Suggest running `git pull` on the governance repo or checking the path |
| Script not found | Before merge #151 — fetch from branch: `git checkout feat/exocortex-sync-restore -- scripts/restore-from-exocortex.sh`; otherwise file a bug report |
| Memory is populated, no confirmation | Do NOT overwrite. Show dry-run output and wait for an explicit "yes" or `--force` |
| Agent not yet configured (bare device) | Skill unavailable → instruct the user to run the Script from the terminal (bootstrap path, SETUP-GUIDE) |

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
