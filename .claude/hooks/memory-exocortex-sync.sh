#!/bin/bash
# memory-exocortex-sync.sh — mirrors the changed file memory/* or extensions/* → exocortex/ (WP-033)
# Event: PostToolUse (matcher: Write|Edit|MultiEdit|Bash)
# see iwesys/IWE#125 (restore — the second half of the portability story)
# see iwesys/IWE#235 (extensions/ added — DATA-POLICY.md
#   promises it the same protection, as memory/, but the hook previously checked only memory/)
# see iwesys/IWE#411 (Bash-calls do not have .tool_input.file_path
#   and previously passed through the hook unnoticed — we do not parse the command (unreliable), instead
#   of this, after the Bash-event we compare the mtime of the entire mtime entire tree memory/extensions against the mirror)
#
# Purpose: on every change to a memory file/extensions file keep exocortex/ its
# mirror, so that migrating to another device / a crash does not lose edits, made during the day.
# Previously this was a manual `cp + commit` (rule feedback_exocortex_sync) — now automatic.
#
# Invariant: exocortex/ ⊇ current state memory/ and extensions/ at any point in time,
# except day-rhythm-config.yaml: its conflict-aware aware sync is deferred until Day Close.
# extensions/ is mirrored into exocortex/extensions/ (a separate subdirectory — prevents
# name collisions with memory/, if they ever-happen to overlap).
# Principles:
#   - NEVER blocks the operation (exit 0 always; mirroring — side effect).
#   - Cheap: early exit for non-memory and non-extensions files before any-memory/non-extensions files before any expensive operations.
#   - Commit/push does NOT perform — that happens at Close (day-close backup + dirty-repo handling).
#     The hook is responsible only for the file mirror, not for git-transport.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:${PATH:-}"

# jq is needed for parsing stdin; no jq — exit silently (the hook is not critical for the operation)
command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Bash-the call does not provide .tool_input.file_path — which exact file under memory/extensions
# it could have touched (heredoc, sed -i, cp, mv), cannot be reliably parsed from the command text.
# Instead of guessing — we compare mtime the entire tree of memory/ and extensions/ against the mirror
# (both folders are flat and few in number per policy CLAUDE.md §4, cheap).
if [ "$TOOL_NAME" = "Bash" ] && [ -z "$FILE_PATH" ]; then
    RECONCILE_BASH=1
elif [ -z "$FILE_PATH" ]; then
    exit 0
else
    # Only .md / .yaml / .yml (memory/ and extensions/ both consist of such files). Early exit for code/other.
    case "$FILE_PATH" in
        *.md|*.yaml|*.yml) ;;
        *) exit 0 ;;
    esac
fi

# Path-scheme: override via env > symlink $WORKSPACE_DIR/memory > slug rebuild slug.
# IMPORTANT: Claude Code slugifies the project path, replacing with '-' not only '/', but also
# '_' and '.'. If in $HOME contains '_' (e.g.. username john_doe), the real project folder —
# '-home-john-doe-IWE', while 'tr / -' produces a phantom '-home-john_doe-IWE' → the mirror is not written.
# Therefore slug = tr '/_.' '-', and the primary source is — symlink (does not depend on slugification).
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/IWE}"
GOVERNANCE_REPO="${GOVERNANCE_REPO:-${IWE_GOVERNANCE_REPO:-DS-strategy}}"
# issue #875: the fallback slug comes from the workspace itself, not from "$HOME" + "-IWE"
# (an install in a folder not named IWE would otherwise mirror another workspace's memory).
WORKSPACE_SLUG=$(echo "$WORKSPACE_DIR" | tr '/_.' '-')
MEMORY_SRC="${IWE_MEMORY_SRC:-$HOME/.claude/projects/${WORKSPACE_SLUG}/memory}"
EXOCORTEX_DST="$WORKSPACE_DIR/$GOVERNANCE_REPO/exocortex"

# Canonical real path of memory/ memory/. Priority is — symlink $WORKSPACE_DIR/memory
# (points to auto-memory independent of slugification rules); fallback — MEMORY_SRC.
if [ -z "${IWE_MEMORY_SRC:-}" ] && [ -d "$WORKSPACE_DIR/memory" ]; then
    MEMORY_REAL=$(cd "$WORKSPACE_DIR/memory" 2>/dev/null && pwd -P) || exit 0
else
    MEMORY_REAL=$(cd "$MEMORY_SRC" 2>/dev/null && pwd -P) || exit 0
fi
EXTENSIONS_REAL=$(cd "$WORKSPACE_DIR/extensions" 2>/dev/null && pwd -P) || EXTENSIONS_REAL=""

mirror_file() {
    local src_dir="$1" dst_dir="$2" fname="$3"
    [ -f "$src_dir/$fname" ] || return 1
    mkdir -p "$dst_dir" 2>/dev/null || return 1
    cp "$src_dir/$fname" "$dst_dir/$fname" 2>/dev/null
}

if [ -n "${RECONCILE_BASH:-}" ]; then
    reconcile_dir() {
        local src_dir="$1" dst_dir="$2" skip_day_rhythm="${3:-0}"
        [ -d "$src_dir" ] || return 0
        find "$src_dir" -maxdepth 1 -type f \( -name '*.md' -o -name '*.yaml' -o -name '*.yml' \) 2>/dev/null |
        while IFS= read -r f; do
            local fname; fname=$(basename "$f")
            # day-rhythm has a conflict-aware Day Close contract (#536). A raw
            # hook cp would bypass the empty-calendar guard and destroy its
            # byte-preserving decision, so neither direct nor Bash reconcile
            # may mirror this root file.
            if [ "$skip_day_rhythm" = "1" ] && [ "$fname" = "day-rhythm-config.yaml" ]; then
                continue
            fi
            if [ ! -f "$dst_dir/$fname" ] || [ "$f" -nt "$dst_dir/$fname" ]; then
                mirror_file "$src_dir" "$dst_dir" "$fname"
            fi
        done
    }
    reconcile_dir "$MEMORY_REAL" "$EXOCORTEX_DST" 1
    [ -n "$EXTENSIONS_REAL" ] && reconcile_dir "$EXTENSIONS_REAL" "$EXOCORTEX_DST/extensions"
    exit 0
fi

# Real directory of the changed file (resolving a possible symlink-path)
FILE_DIR=$(cd "$(dirname "$FILE_PATH")" 2>/dev/null && pwd -P) || exit 0
FNAME=$(basename "$FILE_PATH")

# The file must reside DIRECTLY in memory/ or in extensions/ (flat structure of both folders)
if [ "$FILE_DIR" = "$MEMORY_REAL" ]; then
    [ "$FNAME" = "day-rhythm-config.yaml" ] && exit 0
    mirror_file "$MEMORY_REAL" "$EXOCORTEX_DST" "$FNAME"
elif [ -n "$EXTENSIONS_REAL" ] && [ "$FILE_DIR" = "$EXTENSIONS_REAL" ]; then
    mirror_file "$EXTENSIONS_REAL" "$EXOCORTEX_DST/extensions" "$FNAME"
fi

exit 0
