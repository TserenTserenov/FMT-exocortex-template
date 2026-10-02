#!/usr/bin/env bash
# routing: helper  skill=validate-template
# check-changelog-entry.sh — гейт заметок выпуска (WP-529, 29.09.2026).
#
# Проверяет, что PR добавил в секцию [Unreleased] CHANGELOG.md хотя бы одну
# запись-пункт "- ..." под заголовком подраздела "### ..." со ссылкой на номер
# этого PR ("#<номер>"). Запись вне [Unreleased] (например, в уже выпущенной
# секции) или без ссылки на PR не засчитывается: иначе гейт проходил бы от
# косметической правки (P1: проверка наблюдаемого результата).
#
# Использование:
#   bash check-changelog-entry.sh <base-sha> <head-sha> <pr-number>
# Выход: 0 - запись есть; 1 - записи нет (причина в stdout); 2 - ошибка вызова.

set -uo pipefail

base="${1:-}"; head="${2:-}"; pr="${3:-}"
if [[ -z "$base" || -z "$head" || ! "$pr" =~ ^[0-9]+$ ]]; then
    echo "usage: check-changelog-entry.sh <base-sha> <head-sha> <pr-number>" >&2
    exit 2
fi

# Пункты секции [Unreleased] на указанном коммите: "<подраздел>\t<пункт>".
unreleased_entries() {
    git show "$1:CHANGELOG.md" 2>/dev/null | awk '
        /^## \[/ { in_unreleased = ($0 ~ /^## \[Unreleased\]/); heading = ""; next }
        !in_unreleased { next }
        /^### / { heading = $0; next }
        /^- / { printf "%s\t%s\n", heading, $0 }
    '
}

base_entries=$(unreleased_entries "$base")
head_entries=$(unreleased_entries "$head")

# Добавленные пункты: есть на head, нет на base (построчно, порядок не важен).
added=$(comm -13 <(printf '%s\n' "$base_entries" | sort) <(printf '%s\n' "$head_entries" | sort) | sed '/^$/d')

if [[ -z "$added" ]]; then
    echo "FAIL: PR не добавил ни одного пункта в секцию [Unreleased] CHANGELOG.md"
    exit 1
fi

with_heading=$(printf '%s\n' "$added" | awk -F'\t' '$1 ~ /^### /')
if [[ -z "$with_heading" ]]; then
    echo "FAIL: новые пункты в [Unreleased] стоят вне подраздела (нужен заголовок ### Added/Changed/Fixed/...)"
    exit 1
fi

if ! printf '%s\n' "$with_heading" | grep -Eq "#${pr}([^0-9]|$)"; then
    echo "FAIL: ни один новый пункт [Unreleased] не ссылается на этот PR (#${pr})"
    exit 1
fi

echo "PASS: в [Unreleased] есть запись со ссылкой на #${pr}"
exit 0
