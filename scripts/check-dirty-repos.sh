#!/bin/bash
# routing: helper  skill=week-close,day-close  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# check-dirty-repos.sh — Scan all IWE repos for uncommitted changes
# Usage: ./scripts/check-dirty-repos.sh
# Called from Day Close to detect "forgotten" files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
IWE_DIR="$WORKSPACE_DIR"
DIRTY=0
UNPUSHED=0
# RP-485 F21: a symlink (e.g. memory -> ~/.claude/.../memory) satisfies
# `-d "$dir/.git"` once per path that points at it, so the same physical repo
# was counted as a separate "dirty repo" for each symlink (live case: memory,
# iwe-local-config/memory, wp561-wp530-close/memory all pointed at one path,
# tripling the headline count). Dedup by `git rev-parse --show-toplevel`, not
# by skipping symlinks outright: a symlink can be the only path to a repo, and
# a git worktree has its own distinct toplevel even when it shares history
# with another checkout, so two worktrees of the same repo still get scanned
# separately (peer-session 2026-10-18-16-dirty-repos-fixes, Codex). Plain
# string containment, not an associative array: this script runs under bash
# 3.2 on macOS, which has no associative arrays.
SEEN_TOPLEVELS="|"

check_repo() {
    local dir="$1"
    local name="$2"

    if [ ! -d "$dir/.git" ]; then return; fi

    local toplevel
    toplevel=$(cd "$dir" && git rev-parse --show-toplevel 2>/dev/null) || toplevel="${dir%/}"
    case "$SEEN_TOPLEVELS" in
        *"|$toplevel|"*) return ;;
    esac
    SEEN_TOPLEVELS="$SEEN_TOPLEVELS$toplevel|"

    cd "$dir"

    # Uncommitted changes
    local changes=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [ "$changes" -gt 0 ]; then
        echo "⚠️  $name: $changes uncommitted files"
        git status --porcelain 2>/dev/null | head -5
        [ "$changes" -gt 5 ] && echo "   ... and more $((changes - 5))"
        DIRTY=$((DIRTY + 1))
    fi

    # Unpushed commits
    local ahead=$(git rev-list --count HEAD...@{upstream} --left-only 2>/dev/null || echo "0")
    if [ "$ahead" -gt 0 ]; then
        echo "↗️  $name: $ahead unpushed commits"
        UNPUSHED=$((UNPUSHED + 1))
    fi
}

echo "🔍 Scanning IWE repositories..."
echo ""

# Top-level repos
for dir in "$IWE_DIR"/*/; do
    [ -d "$dir/.git" ] && check_repo "$dir" "$(basename "$dir")"
done

# Nested repos (two levels deep)
for dir in "$IWE_DIR"/*/*/; do
    [ -d "$dir/.git" ] && check_repo "$dir" "$(basename "$(dirname "$dir")")/$(basename "$dir")"
done

echo ""
if [ "$DIRTY" -eq 0 ] && [ "$UNPUSHED" -eq 0 ]; then
    echo "✅ All repos are clean and pushed"
else
    [ "$DIRTY" -gt 0 ] && echo "⚠️  $DIRTY repos with uncommitted changes"
    [ "$UNPUSHED" -gt 0 ] && echo "↗️  $UNPUSHED repos with unpushed commits"
fi
