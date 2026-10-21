#!/usr/bin/env bash
# add-skill-markers.sh — inject empty USER-SPACE block into L1 SKILL.md files that lack it.
# Run once after WP-432 to retrofit existing FMT L1 skills.
# Safe to re-run: skips files that already carry the marker.
#
# Usage:
#   bash add-skill-markers.sh [--dry-run]
#
# Options:
#   --dry-run   list files that would be modified without changing them

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FMT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_DIR="$FMT_ROOT/.claude/skills"

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
    esac
done

if [ ! -d "$SKILLS_DIR" ]; then
    echo "add-skill-markers: skills dir not found: $SKILLS_DIR" >&2
    exit 1
fi

added=0
skipped=0
not_l1=0

while IFS= read -r -d '' md_file; do
    # Only process L1 skills
    if ! grep -qE '^layer:[[:space:]]*L1' "$md_file" 2>/dev/null; then
        not_l1=$((not_l1 + 1))
        continue
    fi

    # Skip if USER-SPACE marker already present
    if grep -q '^<!-- USER-SPACE -->' "$md_file" 2>/dev/null; then
        skipped=$((skipped + 1))
        continue
    fi

    rel="${md_file#$FMT_ROOT/}"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  [dry-run] would add USER-SPACE block: $rel"
        added=$((added + 1))
        continue
    fi

    # Append empty USER-SPACE block at end of file
    printf '\n<!-- USER-SPACE -->\n<!-- /USER-SPACE -->\n' >> "$md_file"
    echo "  ✓ added USER-SPACE block: $rel"
    added=$((added + 1))
done < <(find "$SKILLS_DIR" -name "SKILL.md" -print0 2>/dev/null)

if [ "$DRY_RUN" -eq 1 ]; then
    echo ""
    echo "Dry-run: $added L1 SKILL.md files would receive USER-SPACE block ($skipped already have it, $not_l1 non-L1 skipped)"
else
    echo ""
    echo "Done: added USER-SPACE block to $added L1 SKILL.md files ($skipped already had it, $not_l1 non-L1 skipped)"
fi
