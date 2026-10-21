#!/usr/bin/env bash
# routing: helper  skill=validate-template
# check-changelog-entry.sh — release notes gate (WP-529, 29.09.2026).
#
# Verifies, that PR added to the section [Unreleased] CHANGELOG.md at least one
# entry-item "- ..." under the subsection heading "### ..." with a reference to the number
# this PR ("#<number>"). An entry outside [Unreleased] (for example, in an already released
# section) or without a reference to the PR does not count: otherwise the gate would pass from
# a cosmetic edit (P1: verification of observable result).
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

# Items of the [Unreleased] section [Unreleased] at the specified commit: "<subsection>\t<item>".
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
    echo "FAIL: PR did not add any item to the section [Unreleased] CHANGELOG.md"
    exit 1
fi

with_heading=$(printf '%s\n' "$added" | awk -F'\t' '$1 ~ /^### /')
if [[ -z "$with_heading" ]]; then
    echo "FAIL: new items in [Unreleased] are outside a subsection (a heading such as ### Added/Changed/Fixed/... is required) [Unreleased] are outside a subsection (a heading is required ### Added/Changed/Fixed/...)"
    exit 1
fi

if ! printf '%s\n' "$with_heading" | grep -Eq "#${pr}([^0-9]|$)"; then
    echo "FAIL: no new entry [Unreleased] does not reference this PR (#${pr})"
    exit 1
fi

echo "PASS: in [Unreleased] contains an entry with a reference to #${pr}"
exit 0
