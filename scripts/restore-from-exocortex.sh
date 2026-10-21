#!/bin/bash
# restore-from-exocortex.sh — IWE memory restore IWE from exocortex-backup (closes #125)
#
# The second half of the portability story (the first — backup in day-close.sh + auto-mirror
# memory-exocortex-sync.sh). Applied on a NEW device or after loss/corruption
# local memory/: unpacks exocortex/ back into auto-memory + CLAUDE.md + symlink.
#
# Usage:
#   restore-from-exocortex.sh [<governance-repo-path>] [--force] [--dry-run]
#
#   <governance-repo-path>  path to governance-repo (default: $WORKSPACE_DIR/$GOVERNANCE_REPO)
#   --force                 overwrite a non-empty memory/ (by default — abort)
#   --dry-run               show what will be done, without making changes
#
# Source: the most recent completed Day Close from .iwe-runtime/day-close-backups,
# if it exists; otherwise the previous exocortex/ canonical repository.
# Path-path schema is identical to scripts/day-close.sh (v0.35.2): HOME_SLUG + override via env.

set -euo pipefail

# === Argument parsing ===
FORCE=false
DRY_RUN=false
GOV_ARG=""
for arg in "$@"; do
    case "$arg" in
        --force)   FORCE=true ;;
        --dry-run) DRY_RUN=true ;;
        --help|-h)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "Unknown flag: $arg" >&2; exit 1 ;;
        *)  GOV_ARG="$arg" ;;
    esac
done

# === Configuration (configured via env) ===
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/IWE}"
GOVERNANCE_REPO="${GOVERNANCE_REPO:-${IWE_GOVERNANCE_REPO:-DS-strategy}}"
DS_STRATEGY="${GOV_ARG:-$WORKSPACE_DIR/$GOVERNANCE_REPO}"
EXOCORTEX_SRC="$DS_STRATEGY/exocortex"
BACKUP_SELECTED=false
if [ -z "$GOV_ARG" ]; then
    BACKUP_ROOT="$WORKSPACE_DIR/.iwe-runtime/day-close-backups"
    BACKUP_POINTER="$BACKUP_ROOT/latest"
    if [ -e "$BACKUP_POINTER" ] || [ -L "$BACKUP_POINTER" ]; then
        if [ -L "$BACKUP_ROOT" ] || [ -L "$BACKUP_POINTER" ] || [ ! -f "$BACKUP_POINTER" ]; then
            echo "Invalid backup pointer: $BACKUP_POINTER" >&2
            exit 1
        fi
        IWE_BACKUP_NAME=$(cat "$BACKUP_POINTER") || exit 1
        if [[ ! "$IWE_BACKUP_NAME" =~ ^day-close-[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]]; then
            echo "Invalid backup name in $BACKUP_POINTER" >&2
            exit 1
        fi
        EXOCORTEX_SRC="$BACKUP_ROOT/$IWE_BACKUP_NAME/exocortex"
        if [ -L "$BACKUP_ROOT/$IWE_BACKUP_NAME" ] || [ -L "$EXOCORTEX_SRC" ] || [ ! -d "$EXOCORTEX_SRC" ]; then
            echo "Latest backup is not available: $EXOCORTEX_SRC" >&2
            exit 1
        fi
        BACKUP_SELECTED=true
    fi
fi
# Claude Code slugifies the project path, replacing with '-' not only '/', but also '_' and '.'.
# If $HOME contains '_' (e.g.. username john_doe), the actual folder — '-home-john-doe-IWE'.
# tr '/' '-' would produce a phantom '-home-john_doe-IWE' → restore will miss auto-memory.
# Here symlink-symlink resolve is not applicable: on a new machine $WORKSPACE_DIR/memory has not been created yet.
WORKSPACE_SLUG=$(printf '%s' "$WORKSPACE_DIR" | tr '/_.' '-')
COMPUTED_MEMORY="$HOME/.claude/projects/${WORKSPACE_SLUG}/memory"
PHYSICAL_MEMORY=""
if [ -d "$WORKSPACE_DIR/memory" ]; then
    PHYSICAL_MEMORY=$(cd -P -- "$WORKSPACE_DIR/memory" 2>/dev/null && pwd -P) || exit 1
fi
if [ -n "$PHYSICAL_MEMORY" ] && [ -d "$COMPUTED_MEMORY" ]; then
    COMPUTED_PHYSICAL=$(cd -P -- "$COMPUTED_MEMORY" 2>/dev/null && pwd -P) || exit 1
    if [ "$PHYSICAL_MEMORY" != "$COMPUTED_PHYSICAL" ]; then
        echo "Ambiguous memory-memory configuration: workspace/memory → $PHYSICAL_MEMORY, slug target → $COMPUTED_PHYSICAL" >&2
        exit 1
    fi
fi
MEMORY_DST="${IWE_MEMORY_SRC:-${PHYSICAL_MEMORY:-$COMPUTED_MEMORY}}"

# Restore is a privacy boundary: names which differ from protected ownership
# roots only by case or Unicode compatibility spelling must not enter Claude's
# auto-memory. Resolve one standard-library Python 3 interpreter up front so a
# missing normalizer fails before the first destination write.
RESTORE_STDLIB_PYTHON3=""
for _restore_python_candidate in python3 python; do
    if command -v "$_restore_python_candidate" >/dev/null 2>&1 && \
       "$_restore_python_candidate" -c \
           'import sys; raise SystemExit(sys.version_info[0] != 3)' \
           >/dev/null 2>&1; then
        RESTORE_STDLIB_PYTHON3="$_restore_python_candidate"
        break
    fi
done
unset _restore_python_candidate

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[restore]${NC} $1"; }
warn() { echo -e "${YELLOW}[restore]${NC} $1"; }
err()  { echo -e "${RED}[restore]${NC} $1" >&2; }

run_cmd() {
    if $DRY_RUN; then
        printf '  [dry-run]'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

memory_restore_path_is_protected() {
    "$RESTORE_STDLIB_PYTHON3" - "$1" <<'PYEOF'
import sys
import unicodedata


def canonical_component(component):
    return unicodedata.normalize(
        "NFKC", unicodedata.normalize("NFKC", component).casefold()
    )


protected_roots = {
    ".git",
    ".day-close-backup-quarantine",
    "quarantine",
    "agent-fault-profile",
    "hindsight",
    "decisions",
    "extensions",
    "rules",
}
protected_files = {
    "claude.md",
    "params.yaml",
    "day-rhythm-config.yaml",
    ".day-close-backup-manifest.json",
    ".day-close-backup-incomplete",
    ".day-close-backup.lock",
}

try:
    relative = sys.argv[1]
    first, separator, _remainder = relative.partition("/")
    canonical_first = canonical_component(first)
except (IndexError, TypeError, ValueError):
    raise SystemExit(2)

is_protected = canonical_first in protected_roots or (
    not separator and canonical_first in protected_files
)
raise SystemExit(0 if is_protected else 1)
PYEOF
}

root_entry_has_exact_name() {
    "$RESTORE_STDLIB_PYTHON3" - "$EXOCORTEX_SRC" "$1" <<'PYEOF'
import os
import sys


try:
    names = os.listdir(sys.argv[1])
except OSError:
    raise SystemExit(2)
raise SystemExit(0 if sys.argv[2] in names else 1)
PYEOF
}

atomic_restore_copy() {
    local src="$1" dst="$2" label="$3" parent tmp
    parent=$(dirname -- "$dst")
    if $DRY_RUN; then
        echo "  [dry-run] atomic copy $src -> $dst"
        return 0
    fi
    mkdir -p -- "$parent"
    if [ -e "$dst" ] && [ ! -f "$dst" ] && [ ! -L "$dst" ]; then
        err "$label: destination is not a regular file: $dst"
        return 1
    fi
    tmp=$(mktemp -- "$parent/.$(basename -- "$dst").tmp.XXXXXX") || {
        err "$label: failed to create a temporary file"
        return 1
    }
    if ! cp -p -- "$src" "$tmp"; then
        rm -f -- "$tmp"
        err "$label: failed to prepare atomic copy"
        return 1
    fi
    if [ -L "$dst" ] && ! rm -- "$dst"; then
        rm -f -- "$tmp"
        err "$label: failed to remove destination symlink"
        return 1
    fi
    if ! mv -f -- "$tmp" "$dst"; then
        rm -f -- "$tmp"
        err "$label: atomic replacement failed"
        return 1
    fi
}

atomic_restore_claude() {
    local src="$1" dst="$2" parent tmp
    parent=$(dirname -- "$dst")
    if $DRY_RUN; then
        printf '  [dry-run] render CLAUDE.md atomically: %q -> %q\n' "$src" "$dst"
        return 0
    fi
    mkdir -p -- "$parent"
    if [ -e "$dst" ] && [ ! -f "$dst" ] && [ ! -L "$dst" ]; then
        err "CLAUDE.md: destination is not a regular file: $dst"
        return 1
    fi
    tmp=$(mktemp -- "$parent/.CLAUDE.md.render.XXXXXX") || {
        err "CLAUDE.md: failed to create a temporary file"
        return 1
    }
    if ! sed "s|{{HOME_DIR}}|$HOME_SED_SAFE|g" "$src" > "$tmp"; then
        rm -f -- "$tmp"
        err "CLAUDE.md: HOME substitution HOME was not performed"
        return 1
    fi
    if [ -L "$dst" ] && ! rm -- "$dst"; then
        rm -f -- "$tmp"
        err "CLAUDE.md: failed to remove destination symlink"
        return 1
    fi
    if ! mv -f -- "$tmp" "$dst"; then
        rm -f -- "$tmp"
        err "CLAUDE.md: atomic replacement failed"
        return 1
    fi
}

# === Checks ===
if [ ! -d "$EXOCORTEX_SRC" ]; then
    err "exocortex not found: $EXOCORTEX_SRC"
    err "Provide the path to the governance-repo: restore-from-exocortex.sh <path>"
    exit 1
fi
if $BACKUP_SELECTED; then
    BACKUP_LINK=$(find "$EXOCORTEX_SRC" -type l -print -quit) || exit 1
    if [ -n "$BACKUP_LINK" ]; then
        err "Latest backup contains a symlink: $BACKUP_LINK"
        exit 1
    fi
fi

if [ -z "$RESTORE_STDLIB_PYTHON3" ]; then
    err "Safe restore requires Python 3 (Unicode-Unicode protection for private paths)"
    exit 1
fi

PARAMS_SRC="$EXOCORTEX_SRC/params.yaml"
PARAMS_DST="$WORKSPACE_DIR/params.yaml"
DAY_RHYTHM_SRC="$EXOCORTEX_SRC/day-rhythm-config.yaml"
DAY_RHYTHM_DST="$MEMORY_DST/day-rhythm-config.yaml"
PARAMS_SRC_PRESENT=false
if root_entry_has_exact_name "params.yaml"; then
    PARAMS_SRC_PRESENT=true
else
    exact_entry_rc=$?
    if [ "$exact_entry_rc" -ne 1 ]; then
        err "Failed to safely verify the name params.yaml in exocortex"
        exit 1
    fi
fi
DAY_RHYTHM_SRC_PRESENT=false
if root_entry_has_exact_name "day-rhythm-config.yaml"; then
    DAY_RHYTHM_SRC_PRESENT=true
else
    exact_entry_rc=$?
    if [ "$exact_entry_rc" -ne 1 ]; then
        err "Failed to safely verify the name day-rhythm-config.yaml in exocortex"
        exit 1
    fi
fi
if $PARAMS_SRC_PRESENT && [ -L "$PARAMS_SRC" ]; then
    err "params.yaml in exocortex is a symlink; restore halted before writing"
    exit 1
fi
if $DAY_RHYTHM_SRC_PRESENT && [ -L "$DAY_RHYTHM_SRC" ]; then
    err "day-rhythm-config.yaml in exocortex is a symlink; restore stopped before writing"
    exit 1
fi

# Refusing silent overwrite of populated memory/ (unless --force)
if [ -d "$MEMORY_DST" ] && [ -n "$(ls -A -- "$MEMORY_DST" 2>/dev/null)" ] && ! $FORCE && ! $DRY_RUN; then
    err "memory/ is not empty: $MEMORY_DST"
    err "This looks like an existing installation. To overwrite — --force (or --dry-run for a preview)."
    exit 1
fi

log "Source:    $EXOCORTEX_SRC"
log "Destination:  $MEMORY_DST"
$DRY_RUN && warn "mode --dry-run: changes are not applied"

# === Step 1: memory-files → auto-memory ===
run_cmd mkdir -p -- "$MEMORY_DST"
mem_count=0
# issue #343, second half: flat glob at the top level returned only
# memory/*.md and silently lost subdirectories — memory/reference/agent-core.md was not restored
# even from a backup, where it exists. find traverses the entire tree, relative path
# is preserved, so nesting arrives as-is.
while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    rel="${f#"$EXOCORTEX_SRC"/}"
    # Workspace-level files and private/multi-writer subtrees have their own
    # restore destinations or owners. Compare their first component after
    # NFKC+casefold so case-insensitive filesystems and Unicode aliases cannot
    # leak them into Claude auto-memory.
    if memory_restore_path_is_protected "$rel"; then
        continue
    else
        protection_rc=$?
        if [ "$protection_rc" -ne 1 ]; then
            err "Unsafe relative path in exocortex; restore stopped"
            exit 1
        fi
    fi
    run_cmd mkdir -p -- "$MEMORY_DST/$(dirname -- "$rel")"
    run_cmd cp -- "$f" "$MEMORY_DST/$rel"
    mem_count=$((mem_count + 1))
done < <(find -- "$EXOCORTEX_SRC" -type f \( -name '*.md' -o -name '*.yaml' -o -name '*.yml' \) -print0 2>/dev/null)
log "memory-files restored: $mem_count"

# Day-rhythm is an owned root artefact in exocortex, but its live destination
# remains auto-memory. Keep it out of the generic scan (including case/NFKC
# aliases) and restore only the canonical regular file explicitly.
if $DAY_RHYTHM_SRC_PRESENT && [ -f "$DAY_RHYTHM_SRC" ]; then
    atomic_restore_copy "$DAY_RHYTHM_SRC" "$DAY_RHYTHM_DST" \
        "day-rhythm-config.yaml" || exit 1
    log "day-rhythm-config.yaml restored → $DAY_RHYTHM_DST"
else
    warn "day-rhythm-config.yaml in exocortex is absent — skipping"
fi

# === Step 1b: extensions/ → workspace (issue #235: exocortex/extensions/ is mirrored
# by hook memory-exocortex-sync.sh since 2026-07-11; backups older than that date do not contain it) ===
EXTENSIONS_DST="$WORKSPACE_DIR/extensions"
if [ -d "$EXOCORTEX_SRC/extensions" ]; then
    if [ -d "$EXTENSIONS_DST" ] && [ -n "$(ls -A -- "$EXTENSIONS_DST" 2>/dev/null)" ] && ! $FORCE && ! $DRY_RUN; then
        warn "extensions/ is not empty: $EXTENSIONS_DST — skipping (to overwrite — --force)"
    else
        run_cmd mkdir -p -- "$EXTENSIONS_DST"
        ext_count=0
        shopt -s nullglob
        for f in "$EXOCORTEX_SRC/extensions"/*.md; do
            [ -f "$f" ] || continue
            fname=$(basename -- "$f")
            run_cmd cp -- "$f" "$EXTENSIONS_DST/$fname"
            ext_count=$((ext_count + 1))
        done
        shopt -u nullglob
        log "extensions-files restored: $ext_count"
    fi
else
    warn "exocortex/extensions/ is absent (backup predates fix #235, or extensions/ was empty) — skipping"
fi

# === Step 1c: rules/ → workspace ===
RULES_DST="$WORKSPACE_DIR/.claude/rules"
if [ -d "$EXOCORTEX_SRC/rules" ]; then
    if [ -d "$RULES_DST" ] && [ -n "$(ls -A -- "$RULES_DST" 2>/dev/null)" ] && ! $FORCE && ! $DRY_RUN; then
        warn "rules/ is not empty: $RULES_DST — skipping (to restore — --force)"
    else
        run_cmd mkdir -p -- "$RULES_DST"
        rules_count=0
        while IFS= read -r -d '' f; do
            [ -f "$f" ] || continue
            rel="${f#"$EXOCORTEX_SRC/rules/"}"
            run_cmd mkdir -p -- "$RULES_DST/$(dirname -- "$rel")"
            run_cmd cp -- "$f" "$RULES_DST/$rel"
            rules_count=$((rules_count + 1))
        done < <(find -- "$EXOCORTEX_SRC/rules" -type f -print0 2>/dev/null)
        log "rules-files restored: $rules_count"
    fi
else
    warn "exocortex/rules/ is missing (old backup) — skipping"
fi

# === Step 2: CLAUDE.md → workspace root ===
# issue #217: direct substitution {{HOME_DIR}} -> $HOME makes the restore
# OS-agnostic (backup is written with a placeholder in day-close.sh, step 1).
# $HOME appears in the replacement-part sed s/// — escape & and \, otherwise HOME with &
# is interpreted as «the entire matched text» and corrupts the path (cold-review finding).
HOME_SED_SAFE=$(printf '%s' "$HOME" | sed 's/[|&\]/\\&/g')
if [ -f "$EXOCORTEX_SRC/CLAUDE.md" ]; then
    atomic_restore_claude "$EXOCORTEX_SRC/CLAUDE.md" "$WORKSPACE_DIR/CLAUDE.md" || exit 1
    log "CLAUDE.md restored → $WORKSPACE_DIR/CLAUDE.md"
else
    warn "CLAUDE.md in exocortex is missing — skipping"
fi

# params.yaml belongs in the workspace root. Existing user configuration is
# never overwritten implicitly; --force is the explicit recovery decision.
if $PARAMS_SRC_PRESENT && [ -f "$PARAMS_SRC" ]; then
    if { [ -e "$PARAMS_DST" ] || [ -L "$PARAMS_DST" ]; } && ! $FORCE; then
        warn "params.yaml already exists in workspace — skipping (to overwrite — --force)"
    else
        atomic_restore_copy "$PARAMS_SRC" "$PARAMS_DST" "params.yaml" || exit 1
        log "params.yaml restored → $PARAMS_DST"
    fi
else
    warn "params.yaml in exocortex is missing — skipping"
fi

# === Step 3: symlink $WORKSPACE_DIR/memory → auto-memory ===
LINK="$WORKSPACE_DIR/memory"
if [ -L "$LINK" ]; then
    current=$(readlink -- "$LINK")
    if [ "$current" = "$MEMORY_DST" ]; then
        log "Symlink memory/ is already correct"
    else
        warn "Symlink memory/ points to $current (expected $MEMORY_DST) — recreating"
        run_cmd rm -- "$LINK"
        run_cmd ln -s -- "$MEMORY_DST" "$LINK"
    fi
elif [ -e "$LINK" ]; then
    warn "$LINK exists and is NOT a symlink — leaving it untouched (resolve manually)"
else
    run_cmd ln -s -- "$MEMORY_DST" "$LINK"
    log "Symlink created: $LINK → $MEMORY_DST"
fi

echo ""
if $DRY_RUN; then
    warn "dry-run completed. To apply — run without --dry-run."
else
    log "Restore complete. Restart Claude Code to load memory/.. Restart Claude Code to load memory/."
fi
