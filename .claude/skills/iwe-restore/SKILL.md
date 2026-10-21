---
agents: single
argument-hint: '[path/to/DS-strategy]'
browser_safe: false
description: Restores agent memory from an exocortex Backup when moving to a new device.
  Locates DS-strategy/exocortex/, shows what will be restored, asks for confirmation,
  copies memory/ + CLAUDE.md + AGENTS.md, finalizes with /audit-installation.
gates_enforced: []
gates_rationale: operational skill; WP Gate applicable only when creating a new WP,
  not for operational calls
gates_required: []
interaction: multi-step
layer: L1
name: iwe-restore
routing:
  deterministic: false
  executor: sonnet
status: active
triggers:
  phrases:
  - restore memory
  - restore IWE
  - migrate to a new device
  slash:
  - /iwe-restore
user_invocable: true
version: 1.0.0
---

# IWE Restore — Agent Memory Restoration

> **When to use:** you moved to a new laptop, recreated a workspace, or lost `memory/`.
> If `memory/` is already populated and you only want to verify it — use `/audit-installation`.

Arguments: $ARGUMENTS

## When to use

Restores agent memory from an exocortex Backup when moving to a new device. Locates DS-strategy/exocortex/, shows what will be restored, asks for confirmation, copies memory/ + CLAUDE.md + AGENTS.md, finalizes with /audit-installation.

## Promise

In 5 minutes and one confirmation — restore agent memory from a GitHub Backup. The agent will not overwrite anything silently: it shows what was found first, then waits for "yes".

---

## Algorithm

## Step 1. Find the Backup

Determine the path to the governance repo. Priority order:

1. Skill argument `$ARGUMENTS` (if provided)
2. Environment variable `$DS_STRATEGY` or `$GOVERNANCE_REPO`
3. Default path `${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/`
4. Search: `find ${IWE_WORKSPACE:-$HOME/IWE} -maxdepth 2 -name "exocortex" -type d 2>/dev/null`

```bash
GOVERNANCE="${1:-${DS_STRATEGY:-$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}}}"
EXOCORTEX="$GOVERNANCE/exocortex"
```

If `exocortex/` is not found → say:

> "Backup not found. The `exocortex/` folder is missing from `$GOVERNANCE`. Make sure the governance repo is cloned: `git clone <url> ${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}`. If the repo is at a different path — call `/iwe-restore path/to/DS-strategy`."

Stop.

---

## Step 2. Show What Was Found

Collect information about the Backup:

```bash
# List files in the backup
find "$EXOCORTEX" -maxdepth 1 -type f \( -name "*.md" -o -name "*.yaml" -o -name "*.yml" \) | sort

# Modification date of the most recent file
find "$EXOCORTEX" -maxdepth 1 -type f | xargs ls -lt 2>/dev/null | head -1
```

Determine the path to `memory/` on the current device:

```bash
HOME_SLUG=$(echo "$HOME" | sed 's|/|-|g')
MEMORY_DST="$HOME/.claude/projects/${HOME_SLUG}-IWE/memory"
```

Show the user:

```
Backup found:
  Source:      ${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/exocortex/   (N files, last backup: DATE)
  Destination: ~/.claude/projects/.../memory/

What will be restored:
  memory/: [list of .md and .yaml files]
  CLAUDE.md → ${IWE_WORKSPACE:-$HOME/IWE}/CLAUDE.md
  AGENTS.md → ${IWE_WORKSPACE:-$HOME/IWE}/AGENTS.md  (if present)

Current state of memory/:
  [empty / N files already present]
```

---

## Step 3. Ask for Confirmation

Ask a single question:

> "Restore? (yes / no / show diff)"

- **no** → stop, change nothing.
- **show diff** → go to Step 3a.
- **yes** → go to Step 4.

### Step 3a. Diff (if requested)

For each file from the Backup that already exists in `memory/`:

```bash
diff "$EXOCORTEX/<file>" "$MEMORY_DST/<file>"
```

Show differences briefly. Then ask again: "Restore with overwrite? (yes / skip existing / no)"

---

## Step 4. Restore

### 4a. Create the memory/ folder if it does not exist

```bash
mkdir -p "$MEMORY_DST"
```

### 4b. Copy memory files

```bash
rsync -av --exclude='CLAUDE.md' --exclude='AGENTS.md' \
  --include='*.md' --include='*.yaml' --include='*.yml' \
  --exclude='*' \
  "$EXOCORTEX/" "$MEMORY_DST/"
```

If the user chose "skip existing" — add the `--ignore-existing` flag.

### 4c. Copy CLAUDE.md

> issue #217: substituting `{{HOME_DIR}}` → `$HOME` makes restoration OS-agnostic
> (the Backup is written with a placeholder in `day-close.sh`, symmetrically with `setup.sh`).
> `$HOME` appears in the replacement part of `sed s///` — escape `&`/`\`, otherwise `$HOME`
> containing `&` is treated as "the entire matched text" and corrupts the path (cold-review finding).

```bash
WORKSPACE_DIR="${IWE_WORKSPACE:-$HOME/IWE}"
HOME_SED_SAFE=$(printf '%s' "$HOME" | sed 's/[&\]/\\&/g')
if [ -f "$EXOCORTEX/CLAUDE.md" ]; then
  # If CLAUDE.md already exists — show: "CLAUDE.md already exists. Overwrite?"
  # On confirmation:
  sed "s|{{HOME_DIR}}|$HOME_SED_SAFE|g" "$EXOCORTEX/CLAUDE.md" > "$WORKSPACE_DIR/CLAUDE.md"
fi
```

### 4d. Copy AGENTS.md

```bash
if [ -f "$EXOCORTEX/AGENTS.md" ]; then
  sed "s|{{HOME_DIR}}|$HOME_SED_SAFE|g" "$EXOCORTEX/AGENTS.md" > "$WORKSPACE_DIR/AGENTS.md"
fi
```

### 4e. Report

```
Restored:
  memory/: N files copied, M skipped
  CLAUDE.md: ✅ / ⏭ skipped
  AGENTS.md: ✅ / — not present in backup
```

---

## Step 5. Verification

Run `/audit-installation` for a final integrity check of the installation.

Tell the user:

> "Memory restored. Restart Claude Code — the agent will pick up the files from `memory/` in the next Session."

---

## Edge Cases

| Situation | Behavior |
|----------|-----------|
| `memory/` is empty | Copy everything without prompting (only the final confirmation question) |
| `memory/` is already populated | Show the diff option, do not overwrite silently |
| `exocortex/` contains a very old backup (>30 days) | Warn: "Backup is from DATE — N days ago. Continue?" |
| `CLAUDE.md` in workspace is newer than the backup | Warn: "The file in the workspace is N days newer than the backup. Overwriting will discard your edits." |
| No write permission to `memory/` | Show the error and the command to fix permissions manually |

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
