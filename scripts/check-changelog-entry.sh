#!/usr/bin/env bash
# routing: helper  skill=validate-template
# check-changelog-entry.sh — release-notes gate (WP-529, 29.09.2026).
#
# Checks that the PR added to the [Unreleased] section of CHANGELOG.md at least one
# list entry "- ..." under a subsection heading "### ..." with a reference to the number of
# this PR ("#<number>"). An entry outside [Unreleased] (e.g. in an already released
# section) or without a PR reference does not count: otherwise the gate would pass on
# a cosmetic edit (P1: checking an observable result).
#
# Usage:
#   bash check-changelog-entry.sh <base-sha> <head-sha> <pr-number>
# Exit: 0 - entry exists; 1 - no entry (reason in stdout); 2 - invocation error.

set -uo pipefail

base="${1:-}"; head="${2:-}"; pr="${3:-}"
if [[ -z "$base" || -z "$head" || ! "$pr" =~ ^[0-9]+$ ]]; then
    echo "usage: check-changelog-entry.sh <base-sha> <head-sha> <pr-number>" >&2
    exit 2
fi

# Items of the [Unreleased] section at the given commit: "<subsection>\t<item>".
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

# Added items: present on head, absent on base (line by line, order does not matter).
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
