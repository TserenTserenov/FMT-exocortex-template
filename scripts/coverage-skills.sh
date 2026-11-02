#!/bin/bash
# routing: helper  skill=week-close  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# coverage-skills.sh — detector B12a/B12b/B12c/B12d (promotion coverage)
#
# Three-way detector: author/.claude/skills/ vs FMT/.claude/skills/ vs
# FMT/.claude/skills-catalog.yaml. Closes the classes:
# - B12b Missing: the skill is in author, not in FMT
# - B12a Catalog: the skill is in FMT, not in the FMT catalog
# - B12d Deletion: the skill is in FMT, deleted in author (dead code)
# - B12c Reverse: substantive diff author↔FMT after normalize
#
# Usage:
#   bash coverage-skills.sh                  # all 4 checks
#   bash coverage-skills.sh --check          # exit 1 on any drift
#   bash coverage-skills.sh --check-missing  # B12b only
#   bash coverage-skills.sh --check-catalog  # B12a only
#   bash coverage-skills.sh --check-reverse  # B12c only (diff with normalize)
#   bash coverage-skills.sh --check-deletion # B12d only

set -uo pipefail

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
FMT_DIR="${IWE_TEMPLATE:-$IWE/FMT-exocortex-template}"
AUTHOR_SKILLS="$IWE/.claude/skills"
FMT_SKILLS="$FMT_DIR/.claude/skills"
FMT_CATALOG="$FMT_DIR/.claude/skills-catalog.yaml"

check_mode=false
only=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) check_mode=true; shift ;;
        --check-missing) only="missing"; check_mode=true; shift ;;
        --check-catalog) only="catalog"; check_mode=true; shift ;;
        --check-reverse) only="reverse"; check_mode=true; shift ;;
        --check-deletion) only="deletion"; check_mode=true; shift ;;
        --help|-h)
            grep "^# " "$0" | head -25 | sed 's/^# //'
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

[[ -d "$AUTHOR_SKILLS" ]] || { echo "[ERROR] Author skills not found: $AUTHOR_SKILLS" >&2; exit 1; }
[[ -d "$FMT_SKILLS" ]] || { echo "[ERROR] FMT skills not found: $FMT_SKILLS" >&2; exit 1; }

# Utility: normalize body for diff (B12c). Removes placeholder discrepancies and
# trivial whitespace differences, not substantive ones.
# Replacement literals are taken from ENV (avoids hardcoding author-specifics in the template):
#   IWE_GOVERNANCE_REPO_AUTHOR  — name of the author's governance repo (default: DS-strategy)
#   IWE_GOVERNANCE_REPO_TMPL    — name of the template governance repo (default: DS-strategy)
NORM_HOME='/Users\|/home'
NORM_GOV_AUTHOR="${IWE_GOVERNANCE_REPO:-DS-strategy}"
NORM_GOV_TMPL="${IWE_GOVERNANCE_REPO_TMPL:-DS-strategy}"
normalize_for_diff() {
    sed -E "
        s|\\{\\{[A-Z_]+\\}\\}|<placeholder>|g
        s|<governance-repo>|<placeholder>|g
        s|\\\$HOME|<placeholder>|g
        s|(${NORM_HOME})/[^/]+|<placeholder>|g
        s|~/IWE|<placeholder>|g
        s|${NORM_GOV_AUTHOR}|<governance>|g
        s|${NORM_GOV_TMPL}|<governance>|g
        s|[[:space:]]+\$||g
        s|^layer: L[13]\$|layer: <layer>|
    "
}

# Skill name lists
author_list=$(ls "$AUTHOR_SKILLS" 2>/dev/null | sort)
fmt_list=$(ls "$FMT_SKILLS" 2>/dev/null | sort)

# B12b Missing: present in author, absent in FMT
b12b_missing=()
for s in $author_list; do
    [[ -d "$FMT_SKILLS/$s" ]] || b12b_missing+=("$s")
done

# B12d Deletion: present in FMT, absent in author
b12d_deletion=()
for s in $fmt_list; do
    [[ -d "$AUTHOR_SKILLS/$s" ]] || b12d_deletion+=("$s")
done

# B12a Catalog: in FMT skills, not in catalog (or catalog is missing)
b12a_catalog=()
if [[ -f "$FMT_CATALOG" ]]; then
    for s in $fmt_list; do
        [[ "$s" == "_template" ]] && continue
        if ! grep -qE "^[[:space:]]+- id: $s$" "$FMT_CATALOG"; then
            b12a_catalog+=("$s")
        fi
    done
else
    echo "[WARN] FMT/.claude/skills-catalog.yaml отсутствует — все FMT-скиллы помечены B12a"
    for s in $fmt_list; do
        [[ "$s" == "_template" ]] && continue
        b12a_catalog+=("$s")
    done
fi

# B12c Reverse: both present, but a substantive diff (after normalize)
b12c_reverse=()
for s in $author_list; do
    a="$AUTHOR_SKILLS/$s/SKILL.md"
    f="$FMT_SKILLS/$s/SKILL.md"
    [[ -f "$a" && -f "$f" ]] || continue
    a_norm=$(normalize_for_diff < "$a")
    f_norm=$(normalize_for_diff < "$f")
    if [[ "$a_norm" != "$f_norm" ]]; then
        b12c_reverse+=("$s")
    fi
done

# Output
echo "=== Coverage Skills audit ==="
echo "Author skills dir: $AUTHOR_SKILLS"
echo "FMT skills dir:    $FMT_SKILLS"
echo "FMT catalog:       $FMT_CATALOG"
echo ""
echo "Всего скиллов: author=$(echo "$author_list" | wc -l | tr -d ' ') · FMT=$(echo "$fmt_list" | wc -l | tr -d ' ')"
echo ""

print_section() {
    local name="$1"
    local id="$2"
    local count="$3"
    shift 3
    [[ -n "$only" && "$only" != "$id" ]] && return
    echo "=== $name ($count) ==="
    if [[ "$count" -gt 0 ]]; then
        for s in "$@"; do
            echo "  - $s"
        done
    fi
    echo ""
}

print_section "B12b Missing (в author, нет в FMT)" "missing" "${#b12b_missing[@]}" "${b12b_missing[@]+"${b12b_missing[@]}"}"
print_section "B12a Catalog (в FMT, нет в FMT catalog)" "catalog" "${#b12a_catalog[@]}" "${b12a_catalog[@]+"${b12a_catalog[@]}"}"
print_section "B12c Reverse (содержательный diff author↔FMT после normalize)" "reverse" "${#b12c_reverse[@]}" "${b12c_reverse[@]+"${b12c_reverse[@]}"}"
print_section "B12d Deletion (в FMT, нет в author — dead code)" "deletion" "${#b12d_deletion[@]}" "${b12d_deletion[@]+"${b12d_deletion[@]}"}"

total_drift=$((${#b12b_missing[@]} + ${#b12a_catalog[@]} + ${#b12c_reverse[@]} + ${#b12d_deletion[@]}))
echo "ИТОГО drift: $total_drift"

if $check_mode; then
    case "$only" in
        missing)  exit $([[ ${#b12b_missing[@]}  -eq 0 ]] && echo 0 || echo 1) ;;
        catalog)  exit $([[ ${#b12a_catalog[@]}  -eq 0 ]] && echo 0 || echo 1) ;;
        reverse)  exit $([[ ${#b12c_reverse[@]}  -eq 0 ]] && echo 0 || echo 1) ;;
        deletion) exit $([[ ${#b12d_deletion[@]} -eq 0 ]] && echo 0 || echo 1) ;;
        *)        exit $([[ $total_drift -eq 0 ]] && echo 0 || echo 1) ;;
    esac
fi

exit 0
