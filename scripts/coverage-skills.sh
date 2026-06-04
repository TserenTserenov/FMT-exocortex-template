#!/bin/bash
# routing: helper  skill=week-close  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# coverage-skills.sh — детектор B12a/B12b/B12c/B12d (promotion coverage)
#
# Three-way detector: author/.claude/skills/ vs FMT/.claude/skills/ vs
# FMT/.claude/skills-catalog.yaml. Закрывает классы:
# - B12b Missing: скилл в author, нет в FMT
# - B12a Catalog: скилл в FMT, нет в FMT catalog
# - B12d Deletion: скилл в FMT, удалён в author (dead code)
# - B12c Reverse: содержательный diff author↔FMT после normalize
#
# Использование:
#   bash coverage-skills.sh                  # все 4 проверки
#   bash coverage-skills.sh --check          # exit 1 при любом drift
#   bash coverage-skills.sh --check-missing  # только B12b
#   bash coverage-skills.sh --check-catalog  # только B12a
#   bash coverage-skills.sh --check-reverse  # только B12c (diff с normalize)
#   bash coverage-skills.sh --check-deletion # только B12d

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

# Утилита: normalize body для diff (B12c). Убирает placeholder-расхождения и
# тривиальные whitespace-отличия, не содержательные.
# Литералы для замены берутся из ENV (избегаем хардкода author-specifics в шаблоне):
#   IWE_GOVERNANCE_REPO_AUTHOR  — имя авторского governance-репо (default: DS-strategy)
#   IWE_GOVERNANCE_REPO_TMPL    — имя шаблонного governance-репо (default: DS-strategy)
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

# Списки имён скиллов
author_list=$(ls "$AUTHOR_SKILLS" 2>/dev/null | sort)
fmt_list=$(ls "$FMT_SKILLS" 2>/dev/null | sort)

# B12b Missing: в author есть, в FMT нет
b12b_missing=()
for s in $author_list; do
    [[ -d "$FMT_SKILLS/$s" ]] || b12b_missing+=("$s")
done

# B12d Deletion: в FMT есть, в author нет
b12d_deletion=()
for s in $fmt_list; do
    [[ -d "$AUTHOR_SKILLS/$s" ]] || b12d_deletion+=("$s")
done

# B12a Catalog: в FMT skills, нет в catalog (или catalog отсутствует)
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

# B12c Reverse: оба есть, но содержательный diff (после normalize)
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

# Вывод
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
