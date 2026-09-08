#!/bin/bash
# check-delivery-route-label.sh — WP-529 Ф2: a commit range that adds or
# removes a file from a manually-curated delivery category (the arrays in
# generate-manifest.sh backing docs/critical-files-map.yaml's *-explicit-*
# and dev-only-excluded/user-space-excluded categories, or update-manifest.json's
# deprecated_files) must carry a `Delivery-Route: <category-id>` git trailer
# naming every category it touches — cross-checked against what actually
# changed, not taken on trust from the commit message text.
#
# Uses git's own trailer parser (`%(trailers:key=...)`, same mechanism
# scripts/changelog-append.sh already uses for Changelog-Tag) — no custom
# trailer-parsing code to drift from it.
#
# Usage: bash scripts/check-delivery-route-label.sh <base-sha|"">
# Exit 0 = no curated category changed, or all changes are labeled correctly.
# Exit 1 = a curated category changed without a matching Delivery-Route trailer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="$SCRIPT_DIR/generate-manifest.sh"
MANIFEST="$SCRIPT_DIR/update-manifest.json"
MAP="$SCRIPT_DIR/docs/critical-files-map.yaml"
BASE="${1:-}"

[ -f "$MANIFEST" ] || { echo "ERROR: $MANIFEST не найден"; exit 2; }
[ -f "$MAP" ] || { echo "ERROR: $MAP не найден"; exit 2; }

if [[ -z "$BASE" || "$BASE" == "0000000000000000000000000000000000000000" ]]; then
    echo "  ℹ нет валидной base-ревизии (первый push/новая ветка) — проверка меток пропущена"
    exit 0
fi

if ! git -C "$SCRIPT_DIR" cat-file -e "$BASE" 2>/dev/null; then
    echo "  ⚠ base-ревизия $BASE недоступна в этом checkout — проверка меток пропущена"
    exit 0
fi

# Curated arrays: entries are hand-picked, not derived from a git-tree scan —
# adding/removing one IS the "manual decision" this gate cares about. Pattern-
# only arrays (SKIP_PATTERNS, FILES_EXCLUDE_PATTERNS, the delivered-default
# fallthrough) are directory-level defaults, not per-file decisions — out of
# scope by design (same boundary Codex proposed: threshold on curated
# membership changes, not on any edit of an already-included file).
CURATED_ARRAYS=(GITHUB_EXPLICIT_INCLUDE GITHUB_CI_ONLY_EXCLUDE SETUP_EXPLICIT_INCLUDE
    PLATFORM_HOOKS_EXPLICIT_INCLUDE SCRIPT_CONTRACT_EXPLICIT_INCLUDE
    EXCLUDED_EXACT EXCLUDED_SCRIPTS FILES_EXCLUDE_EXACT)

dump_arrays() {
    # $1 = path to a generate-manifest.sh revision. Runs full-script sourcing
    # (as scripts/check-critical-files-map.sh does) only for the CURRENT tree,
    # where SCRIPT_DIR resolves to a real checkout with CHANGELOG.md and a
    # real `git ls-files`. A base-revision dump via `git show` has neither —
    # sourcing the whole script would abort under `set -e` on the very first
    # SCRIPT_DIR-dependent line (found live: VERSION lookup against a
    # nonexistent /tmp/CHANGELOG.md silently killed the whole extraction,
    # making every array look "changed" because OLD_* was never populated).
    # The curated arrays are pure literals with no SCRIPT_DIR dependency —
    # extract just that self-contained block (SKIP_PATTERNS.. end of
    # is_explicit_include()) instead of running the rest of the script.
    sed -n '/^SKIP_PATTERNS=(/,/^}/p' "$1" | bash -c 'source /dev/stdin; declare -p "$@"' _ "${CURATED_ARRAYS[@]}" 2>/dev/null
}

TMP_BASE_GEN=$(mktemp)
TMP_ARRAY_MAP=$(mktemp)
trap 'rm -f "$TMP_BASE_GEN" "$TMP_ARRAY_MAP"' EXIT

if ! git -C "$SCRIPT_DIR" show "$BASE:generate-manifest.sh" > "$TMP_BASE_GEN" 2>/dev/null; then
    echo "  ℹ generate-manifest.sh не существовал на base-ревизии — проверка меток пропущена"
    exit 0
fi

eval "$(dump_arrays "$TMP_BASE_GEN" | sed 's/^declare -a \([A-Z_]*\)=/declare -a OLD_\1=/')"
eval "$(dump_arrays "$GENERATOR" | sed 's/^declare -a \([A-Z_]*\)=/declare -a NEW_\1=/')"

# A curated array can be newer than $BASE (generate-manifest.sh has grown
# arrays over time, e.g. SCRIPT_CONTRACT_EXPLICIT_INCLUDE) — dump_arrays then
# has nothing to report for its OLD_/NEW_ counterpart, and the indirect
# expansion below would hit an unbound variable under `set -u`. Missing = "no
# entries at that revision", not an error.
for arr in "${CURATED_ARRAYS[@]}"; do
    declare -p "OLD_$arr" >/dev/null 2>&1 || eval "OLD_$arr=()"
    declare -p "NEW_$arr" >/dev/null 2>&1 || eval "NEW_$arr=()"
done

# category-id → derived_from_block, from docs/critical-files-map.yaml — a
# rename in the yaml is picked up automatically, no hardcoded second copy.
# WP-529 (continuation, 19.08, peer-session 2026-08-19-29 turn 7): resolved
# via the shared F6 resolver instead of bare python3, same defect class
# Evgenii found elsewhere. Explicit failure on resolver miss (this file
# already fails hard on missing MANIFEST/MAP above -- same convention, not a
# soft skip like day-open-scaffold.sh's best-effort sites).
RESOLVED_PYTHON3=$("$SCRIPT_DIR/scripts/lib/find-python3.sh" 2>/dev/null) || RESOLVED_PYTHON3=""
[ -n "$RESOLVED_PYTHON3" ] || { echo "ERROR: python3 с библиотекой PyYAML не найден (pip install pyyaml)"; exit 2; }
# WP-529 Ф9 (Evgenii 20.08, bash 3.2 finding): было `declare -A` — Bash 3.2
# (stock macOS /bin/bash) не умеет ассоциативные массивы. CURATED_ARRAYS
# короткий (7 записей), и лукап идёт только внутри его цикла, не на каждый
# git-tracked файл — лукап через awk по TSV-файлу вместо hash.
"$RESOLVED_PYTHON3" - "$MAP" > "$TMP_ARRAY_MAP" <<'PY'
import re
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as fh:
    data = yaml.safe_load(fh)

for cat in data.get("categories", []):
    val = cat.get("derived_from_block") or ""
    if val.startswith("("):
        continue
    for name in re.split(r",\s*", val):
        name = name.strip()
        if name:
            print(f"{name}\t{cat['id']}")
PY

IMPLICATED=()
for arr in "${CURATED_ARRAYS[@]}"; do
    old_var="OLD_$arr"
    new_var="NEW_$arr"
    # WP-529 Ф9 (found live by this job's own first real run on system
    # /bin/bash, 20.08): `"${!ref}"` indirect array expansion (ref holding
    # "VAR[@]") crashed with "unbound variable" under Bash 3.2 — pre-existing
    # since Ф2, never exercised on real macOS before this CI job started
    # actually running these two scripts there. `eval` is the traditional,
    # maximally-portable indirect-array-access idiom (works since Bash 2).
    # `:-` guard is load-bearing, not defensive fluff: under `set -u`, Bash
    # 3.2 treats `${empty_arr[@]}` itself as unbound (fixed in Bash 4.4+) —
    # hit live on `NEW_GITHUB_EXPLICIT_INCLUDE` (empty on this diff range),
    # second real crash from the same CI run that caught the first.
    old_sorted=$(eval "printf '%s\n' \"\${${old_var}[@]:-}\"" | sort)
    new_sorted=$(eval "printf '%s\n' \"\${${new_var}[@]:-}\"" | sort)
    if [ "$old_sorted" != "$new_sorted" ]; then
        cat_id=$(awk -F'\t' -v k="$arr" '$1==k{print $2; exit}' "$TMP_ARRAY_MAP")
        if [ -z "$cat_id" ]; then
            echo "  ❌ $arr изменился, но не сопоставлен ни одной категории в $MAP — карта разошлась с гейтом" >&2
            exit 1
        fi
        IMPLICATED+=("$cat_id")
        echo "  ℹ $arr изменился → затронута категория '$cat_id'"
    fi
done

# EXCLUDED_EXACT literally contains "${EXCLUDED_SCRIPTS[@]}" (see
# generate-manifest.sh) — editing EXCLUDED_SCRIPTS makes both arrays "change"
# and both map to dev-only-excluded. That is one route decision, not two;
# dedupe so the same category is not reported/required twice.
if [ "${#IMPLICATED[@]}" -gt 0 ]; then
    # WP-529 Ф9 (Evgenii 20.08, bash 3.2 finding): mapfile — bash4-only.
    IMPLICATED_DEDUP=()
    while IFS= read -r cat_id; do
        IMPLICATED_DEDUP+=("$cat_id")
    done < <(printf '%s\n' "${IMPLICATED[@]}" | sort -u)
    IMPLICATED=("${IMPLICATED_DEDUP[@]}")
fi

# deprecated_files — manually curated list, not derived from a bash array at
# all (generate-manifest.sh reads it back from the existing manifest as-is).
OLD_DEPRECATED=$(git -C "$SCRIPT_DIR" show "$BASE:update-manifest.json" 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(sorted(e['path'] for e in d.get('deprecated_files',[])))" 2>/dev/null || echo "[]")
NEW_DEPRECATED=$(python3 -c "import json; d=json.load(open('$MANIFEST')); print(sorted(e['path'] for e in d.get('deprecated_files',[])))")
if [ "$OLD_DEPRECATED" != "$NEW_DEPRECATED" ]; then
    IMPLICATED+=("deprecated-removal")
    echo "  ℹ deprecated_files изменился → затронута категория 'deprecated-removal'"
fi

if [ "${#IMPLICATED[@]}" -eq 0 ]; then
    echo "  ✅ ни одна курируемая категория не менялась в этом диапазоне — метка не нужна"
    exit 0
fi

DECLARED=$(git -C "$SCRIPT_DIR" log \
    --format='%(trailers:key=Delivery-Route,valueonly,separator=%x2c)' \
    "$BASE"..HEAD -- generate-manifest.sh update-manifest.json 2>/dev/null \
    | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | sort -u || true)

FAIL=0
for cat_id in "${IMPLICATED[@]}"; do
    if printf '%s\n' "$DECLARED" | grep -qxF "$cat_id"; then
        echo "  ✅ '$cat_id' задекларирован меткой Delivery-Route"
    else
        echo "  ❌ '$cat_id' изменился, но не задекларирован ни в одном коммите диапазона (trailer 'Delivery-Route: $cat_id' отсутствует)" >&2
        FAIL=1
    fi
done

if [ "$FAIL" -eq 0 ]; then
    echo "  ✅ delivery-route-label: все затронутые категории задекларированы верно"
else
    echo "" >&2
    echo "  → Добавьте в тело коммита строку: Delivery-Route: <category-id>" >&2
    echo "    (одна строка на категорию, category-id из docs/critical-files-map.yaml)" >&2
fi
exit $FAIL
