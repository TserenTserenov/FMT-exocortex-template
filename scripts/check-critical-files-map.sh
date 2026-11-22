#!/bin/bash
# check-critical-files-map.sh — WP-529 Phase1 acceptance check for
# docs/critical-files-map.yaml: (1) every category/special_route references
# a bash array that still exists in generate-manifest.sh (catches the map
# silently drifting from the real classification), (2) every git-tracked
# file lands in exactly one delivery category — none skipped, none double-
# counted, (3) every category and special_route has a non-empty owner
# (category only) and proof_of_delivery.
#
# Reuses generate-manifest.sh's own classification arrays instead of
# re-implementing them — a second independent classifier would drift from
# the real one exactly like update-manifest.json itself drifted (WP-529,
# found 2026-08-18).
#
# Usage: bash scripts/check-critical-files-map.sh
# Exit 0 = map is consistent with the tree. Exit 1 = a check failed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAP="$SCRIPT_DIR/docs/critical-files-map.yaml"
GENERATOR="$SCRIPT_DIR/generate-manifest.sh"
MANIFEST="$SCRIPT_DIR/update-manifest.json"

[ -f "$MAP" ] || { echo "ERROR: $MAP not found"; exit 2; }
[ -f "$GENERATOR" ] || { echo "ERROR: $GENERATOR not found"; exit 2; }

# WP-529 (continuation, 19.08, peer-session 2026-08-19-29 turn 7): resolved
# once here for both PyYAML consumers below, instead of each calling bare
# python3 -- same defect class Evgenii found elsewhere. Explicit failure on
# resolver miss, same convention as the MAP/GENERATOR checks just above.
RESOLVED_PYTHON3=$("$SCRIPT_DIR/scripts/lib/find-python3.sh" 2>/dev/null) || RESOLVED_PYTHON3=""
[ -n "$RESOLVED_PYTHON3" ] || { echo "ERROR: python3 with the library PyYAML not found (pip install pyyaml)"; exit 2; }

# generate-manifest.sh regenerates $MANIFEST as a side effect — same
# technique scripts/verify-manifest.sh already uses safely in CI.
BACKUP=$(mktemp)
WORKDIR=$(mktemp -d)
trap 'cp "$BACKUP" "$MANIFEST" 2>/dev/null; rm -rf "$BACKUP" "$WORKDIR"' EXIT
cp "$MANIFEST" "$BACKUP"

# Sourced *from this script* generate-manifest.sh would see $0 pointing at
# this file (bash keeps $0 unchanged across `source`), so its own
# `dirname "$0"` would resolve to scripts/ instead of the repo root. Run it
# in a throwaway `bash -c` invocation where $0 is set explicitly to
# $GENERATOR, then hand only the specific arrays back via `declare -p`.
ARRAY_DUMP=$(bash -c 'source "$0" >/dev/null; declare -p \
    SKIP_PATTERNS EXCLUDED_PATTERNS EXCLUDED_EXACT EXCLUDED_SCRIPTS \
    FILES_EXCLUDE_PATTERNS FILES_EXCLUDE_EXACT GITHUB_EXPLICIT_INCLUDE \
    GITHUB_CI_ONLY_EXCLUDE SETUP_EXPLICIT_INCLUDE PLATFORM_HOOKS_EXPLICIT_INCLUDE \
    SCRIPT_CONTRACT_EXPLICIT_INCLUDE \
    FILES EXCLUDED_PATHS' "$GENERATOR")
eval "$ARRAY_DUMP"

FAIL=0
fail() { echo "  ❌ $*" >&2; FAIL=1; }
ok() { echo "  ✅ $*"; }

echo "[1/3] Blocks generate-manifest.sh, referenced by the map..."
"$RESOLVED_PYTHON3" - "$MAP" > "$WORKDIR/referenced_blocks.txt" <<'PY'
import re
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as fh:
    data = yaml.safe_load(fh)

blocks = set()
for cat in data.get("categories", []):
    val = cat.get("derived_from_block") or ""
    if val.startswith("("):
        continue  # free-text — no literal array to check
    blocks.update(name.strip() for name in re.split(r",\s*", val) if name.strip())
print("\n".join(sorted(blocks)))
PY

while IFS= read -r block; do
    [ -z "$block" ] && continue
    if declare -p "$block" 2>/dev/null | grep -q '^declare -a'; then
        ok "$block exists in generate-manifest.sh"
    else
        fail "$block, referenced by the map, not found as an array in generate-manifest.sh — map has diverged from the code"
    fi
done < "$WORKDIR/referenced_blocks.txt"

echo "[2/3] Coverage: every git-tracked file — in exactly one category..."
# WP-529 Phase9 (Evgenii 20.08, bash 3.2 finding): membership used to be two
# `declare -A` hash sets checked per file. Bash 3.2 (stock macOS /bin/bash)
# has no associative arrays. Replaced with one set-difference over sorted
# files (`comm`) instead of a bash4 hash *or* an N×grep loop — same O(n log n)
# shape, portable to Bash 3.2.
FILES_SORTED="$WORKDIR/files_sorted.txt"
EXCLUDED_SORTED="$WORKDIR/excluded_sorted.txt"
ALL_TRACKED_SORTED="$WORKDIR/all_tracked_sorted.txt"
REMAINING="$WORKDIR/remaining.txt"
printf '%s\n' "${FILES[@]}" | LC_ALL=C sort -u > "$FILES_SORTED"
printf '%s\n' "${EXCLUDED_PATHS[@]}" | LC_ALL=C sort -u > "$EXCLUDED_SORTED"
git -C "$SCRIPT_DIR" ls-files | LC_ALL=C sort > "$ALL_TRACKED_SORTED"
LC_ALL=C comm -23 "$ALL_TRACKED_SORTED" "$FILES_SORTED" | LC_ALL=C comm -23 - "$EXCLUDED_SORTED" > "$REMAINING"

FILES_COUNT=$(wc -l < "$FILES_SORTED" | tr -d ' ')
EXCLUDED_COUNT=$(wc -l < "$EXCLUDED_SORTED" | tr -d ' ')
TOTAL=$(wc -l < "$ALL_TRACKED_SORTED" | tr -d ' ')

is_in() {
    local rel="$1"; shift
    local item
    for item in "$@"; do [ "$rel" = "$item" ] && return 0; done
    return 1
}

INVISIBLE_VCS=0
INVISIBLE_SETUP=0
INVISIBLE_USERSPACE=0
UNCLASSIFIED=()

while IFS= read -r rel; do
    matched=false
    for pattern in "${SKIP_PATTERNS[@]}"; do
        case "$rel" in "$pattern"*) matched=true; break ;; esac
    done
    [ "$(basename "$rel")" = ".gitkeep" ] && matched=true
    if $matched; then INVISIBLE_VCS=$((INVISIBLE_VCS + 1)); continue; fi

    if [[ "$rel" == setup/* ]] && ! is_in "$rel" "${SETUP_EXPLICIT_INCLUDE[@]}"; then
        INVISIBLE_SETUP=$((INVISIBLE_SETUP + 1)); continue
    fi

    for pattern in "${FILES_EXCLUDE_PATTERNS[@]}"; do
        case "$rel" in "$pattern"*) matched=true; break ;; esac
    done
    is_in "$rel" "${FILES_EXCLUDE_EXACT[@]}" && matched=true
    if $matched; then INVISIBLE_USERSPACE=$((INVISIBLE_USERSPACE + 1)); continue; fi

    UNCLASSIFIED+=("$rel")
done < "$REMAINING"

ACCOUNTED=$((FILES_COUNT + EXCLUDED_COUNT + INVISIBLE_VCS + INVISIBLE_SETUP + INVISIBLE_USERSPACE))

echo "  Total files in git: $TOTAL"
echo "  delivered-default/explicit-include (files[]): $FILES_COUNT"
echo "  visible exclusions (excluded_paths[]) (excluded_paths[]): $EXCLUDED_COUNT"
echo "  vcs-tooling-internal: $INVISIBLE_VCS"
echo "  setup-install-time-only: $INVISIBLE_SETUP"
echo "  user-space-excluded: $INVISIBLE_USERSPACE"

if [ "${#UNCLASSIFIED[@]}" -gt 0 ]; then
    fail "${#UNCLASSIFIED[@]} file(s) did not fall into any category known to the map:"
    for f in "${UNCLASSIFIED[@]}"; do echo "      - $f" >&2; done
elif [ "$ACCOUNTED" -eq "$TOTAL" ]; then
    ok "all $TOTAL files classified exactly once (sum of categories $ACCOUNTED)"
else
    fail "sum of categories ($ACCOUNTED) does not match the total number of files ($TOTAL) — double-counting is possible"
fi

echo "[3/3] owner + proof_of_delivery non-empty for each category/special_route..."
if "$RESOLVED_PYTHON3" - "$MAP" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as fh:
    data = yaml.safe_load(fh)

fail = False
for cat in data.get("categories", []):
    problems = []
    if not str(cat.get("owner", "")).strip():
        problems.append("empty owner")
    if not str(cat.get("proof_of_delivery", "")).strip():
        problems.append("empty proof_of_delivery")
    if problems:
        print(f"  ❌ category {cat.get('id')}: {', '.join(problems)}", file=sys.stderr)
        fail = True
    else:
        print(f"  ✅ category {cat.get('id')}: owner and proof_of_delivery are filled in")

known_ids = {cat.get("id") for cat in data.get("categories", [])}
for route in data.get("special_routes", []):
    if route.get("category") not in known_ids:
        print(f"  ❌ special_route {route.get('path')}: category '{route.get('category')}' does not exist in categories", file=sys.stderr)
        fail = True
    elif not str(route.get("proof_of_delivery", "")).strip():
        print(f"  ❌ special_route {route.get('path')}: empty proof_of_delivery", file=sys.stderr)
        fail = True
    else:
        print(f"  ✅ special_route {route.get('path')}: consistent")

sys.exit(1 if fail else 0)
PY
then
    :
else
    FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
    echo ""
    echo "✅ critical-files-map: map is consistent with the tree and generate-manifest.sh"
else
    echo ""
    echo "❌ critical-files-map: discrepancies found (see. above)"
fi
exit $FAIL
