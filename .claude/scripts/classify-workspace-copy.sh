#!/bin/bash
# classify-workspace-copy.sh — classify an author_mode-skipped workspace copy
# against the template clone's git history (WP-7 F71 stage A, peer-session
# 2026-08-14-05: observability only, never modifies anything).
#
# Usage: classify-workspace-copy.sh [--templated] <template_dir> <fpath> <dst>
#   template_dir  git clone of FMT-exocortex-template
#   fpath         path of the file relative to template_dir
#   dst           deployed workspace copy to classify
#
# Stdout: "<verdict> <reason>" (single line)
#   uptodate current    — dst is byte-identical to the template's current fpath
#   stale    history    — dst matches a historical template version: no user edits
#   authored diverged   — full history walked, no match: user edits present
#   unknown  <reason>   — cannot decide; reason ∈ no-file | no-git | shallow |
#                         history_truncated | templated | git-error
#
# --templated: the deploy pipeline substitutes {{KEY}} placeholders into dst
# (SKILL.md install_constants), so a raw blob can never match template history.
# A non-match then proves nothing — "authored" is downgraded to "unknown templated".
#
# Exit: 0 always when a verdict is printed; 2 on usage error.
set -uo pipefail

HISTORY_CAP=200

TEMPLATED=false
if [ "${1:-}" = "--templated" ]; then
    TEMPLATED=true
    shift
fi

if [ $# -ne 3 ]; then
    echo "usage: classify-workspace-copy.sh [--templated] <template_dir> <fpath> <dst>" >&2
    exit 2
fi

TEMPLATE_DIR="$1"
FPATH="$2"
DST="$3"

if [ ! -f "$DST" ]; then
    echo "unknown no-file"
    exit 0
fi

# Byte-identity with the current template copy needs no git at all.
if [ -f "$TEMPLATE_DIR/$FPATH" ] && cmp -s "$TEMPLATE_DIR/$FPATH" "$DST"; then
    echo "uptodate current"
    exit 0
fi

if ! git -C "$TEMPLATE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "unknown no-git"
    exit 0
fi

if [ "$(git -C "$TEMPLATE_DIR" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
    echo "unknown shallow"
    exit 0
fi

REV_COUNT=$(git -C "$TEMPLATE_DIR" rev-list --count HEAD -- "$FPATH" 2>/dev/null || echo "")
if [ -z "$REV_COUNT" ]; then
    echo "unknown git-error"
    exit 0
fi
if [ "$REV_COUNT" -gt "$HISTORY_CAP" ]; then
    echo "unknown history_truncated"
    exit 0
fi
if [ "$REV_COUNT" -eq 0 ]; then
    # No commits ever touched fpath: history proves nothing about the copy.
    echo "unknown no-history"
    exit 0
fi

DST_BLOB=$(git -C "$TEMPLATE_DIR" hash-object -- "$DST" 2>/dev/null || echo "")
if [ -z "$DST_BLOB" ]; then
    echo "unknown git-error"
    exit 0
fi

# bash 3.2 (macOS): no mapfile — plain read loop over process substitution.
while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    blob=$(git -C "$TEMPLATE_DIR" rev-parse "$commit:$FPATH" 2>/dev/null) || continue
    if [ "$blob" = "$DST_BLOB" ]; then
        echo "stale history"
        exit 0
    fi
done < <(git -C "$TEMPLATE_DIR" rev-list HEAD -- "$FPATH" 2>/dev/null)

if [ "$TEMPLATED" = "true" ]; then
    echo "unknown templated"
else
    echo "authored diverged"
fi
exit 0
