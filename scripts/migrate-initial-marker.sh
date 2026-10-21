#!/bin/bash
# routing: migration  one-time=true
# see DP.SC.159, DP.ROLE.059
# migrate-initial-marker.sh — add skeleton-marker IWE-INITIAL-NEEDED to Strategy.md
# for existing users (clone before 0.28.5).
#
# Scenario: old clone → user runs update to 0.28.5 → they already have
# Strategy.md without the marker. Skill /strategy-session will fall into weekly mode,
# initial flow will not trigger.
#
# The script is safe:
#   1. If the marker is already present — exits without changes.
#   2. If Strategy.md contains seed-signature (placeholder dates `YYYY-MM-DD`
#      in frontmatter) — automatically adds the marker.
#   3. If the content looks real (filled-in dates, custom blocks) —
#      asks for confirmation; default skip.
#
# Usage:
#   bash migrate-initial-marker.sh                           # auto-detect path
#   bash migrate-initial-marker.sh /path/to/Strategy.md      # explicit path
#   bash migrate-initial-marker.sh --force /path/to/file     # without confirmation

set -euo pipefail

MARKER='<!-- IWE-INITIAL-NEEDED: marker from seed-template. Removed after the first strategy session (skill `/strategy-session` initial flow §2.5). If the marker is present — Strategy.md contains only a skeleton, not the real user strategy. -->'

FORCE=0
TARGET=""
while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=1; shift ;;
        -h|--help)
            grep '^#' "$0" | head -25
            exit 0 ;;
        --*)
            echo "Unknown flag: $1" >&2
            echo "Usage: $0 [--force] [/path/to/Strategy.md]" >&2
            exit 1 ;;
        *) TARGET="$1"; shift ;;
    esac
done

# Auto-detect path, if not provided
if [ -z "$TARGET" ]; then
    # Try .exocortex.env
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    ENV_FILE="$(dirname "$SCRIPT_DIR")/.exocortex.env"
    if [ -f "$ENV_FILE" ]; then
        WS=$(grep -E '^WORKSPACE_DIR=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
        GOV=$(grep -E '^GOVERNANCE_REPO=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
        if [ -n "$WS" ] && [ -n "$GOV" ]; then
            TARGET="$WS/$GOV/docs/Strategy.md"
        fi
    fi
    if [ -z "$TARGET" ]; then
        echo "Usage: $0 [--force] /path/to/Strategy.md"
        echo "Auto-detect did not work (no .exocortex.env or WORKSPACE_DIR/GOVERNANCE_REPO)."
        exit 1
    fi
fi

if [ ! -f "$TARGET" ]; then
    echo "Strategy.md not found: $TARGET"
    exit 1
fi

if [ ! -w "$TARGET" ]; then
    echo "Error: $TARGET — read-only (no write permission)." >&2
    echo "Remove the protection: chmod u+w \"$TARGET\"" >&2
    exit 1
fi

# Marker already present?
if grep -qF 'IWE-INITIAL-NEEDED' "$TARGET"; then
    echo "✓ Marker is already present in $TARGET — migration is not needed."
    exit 0
fi

# Heuristic: seed-signature (placeholder dates in frontmatter)
IS_SEED=0
if grep -qE '^created: YYYY-MM-DD$' "$TARGET" || \
   grep -qE '^updated: YYYY-MM-DD$' "$TARGET" || \
   grep -qE '\{month\} \{\{YEAR\}\}' "$TARGET"; then
    IS_SEED=1
fi

if [ "$IS_SEED" -eq 1 ]; then
    echo "Detected seed-skeleton (placeholder dates) — adding marker automatically."
elif [ "$FORCE" -eq 0 ]; then
    echo "⚠ Strategy.md looks like a real filled-in file (no seed-signatures)."
    echo "  If initial-session has already taken place — the marker is not needed (skill will proceed to weekly)."
    echo "  If initial-session has NOT been conducted and you want to start it — add --force."
    exit 0
fi

# Backup
BACKUP="${TARGET}.pre-marker.$(date +%Y%m%d-%H%M%S)"
cp "$TARGET" "$BACKUP"
echo "Backup: $BACKUP"

# Insert marker after frontmatter (after the second `---`).
# If frontmatter is absent OR broken (only one `---`) — insert at the beginning.
TMP=$(mktemp)
INSERTED_AFTER_FM=0
if head -1 "$TARGET" | grep -q '^---$'; then
    # frontmatter is present, looking for the second ---
    if [ "$(grep -c '^---$' "$TARGET")" -ge 2 ]; then
        awk -v marker="$MARKER" '
            BEGIN { fm_count = 0; inserted = 0 }
            /^---$/ { fm_count++; print; if (fm_count == 2 && !inserted) { print ""; print marker; inserted = 1 } ; next }
            { print }
        ' "$TARGET" > "$TMP"
        INSERTED_AFTER_FM=1
    fi
fi

if [ "$INSERTED_AFTER_FM" -eq 0 ]; then
    # No frontmatter OR broken (one ---) — insert at the very beginning.
    {
        echo "$MARKER"
        echo ""
        cat "$TARGET"
    } > "$TMP"
fi

# Sanity check: TMP must not be empty (protection against silent corruption)
if [ ! -s "$TMP" ]; then
    echo "Error: migration produced an empty result — original left untouched." >&2
    rm -f "$TMP"
    exit 1
fi

mv "$TMP" "$TARGET"
echo "✓ Marker added to $TARGET"
echo ""
echo "Now run /strategy-session — skill will detect mode initial."
