#!/usr/bin/env bash
# routing: helper  skill=day-close  called-by=day-close
# see DP.SC.159, DP.ROLE.059
# week-report-ensure.sh — create the paired skeleton of `WeekReport W{N} YYYY-MM-DD.md`
# for the current week when it does not exist yet (issue #886).
#
# Why: day-close appends a summary of every day to the WeekReport (steps 2f/9b),
# but nothing created the file before the end of the week, so the first days
# fell back into the WeekPlan and left with it into the archive. The first
# Day Close of a week now creates the skeleton; the nightly week-review and
# `/week-close` append their "Итоги W{N}" section to the same file.
#
# Usage:
#   week-report-ensure.sh [--governance-dir <path>]
#
# Output (one line, machine-readable): WEEKREPORT: created|exists|skipped <path or reason>
# Exit: 0 always for the three states above (never blocks Day Close), 2 on bad usage.

set -uo pipefail

GOV_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --governance-dir) GOV_DIR="${2:-}"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$GOV_DIR" ]; then
    ROOT="${IWE_WORKSPACE:-${WORKSPACE_DIR:-$HOME/IWE}}"
    GOV_DIR="$ROOT/${IWE_GOVERNANCE_REPO:-DS-strategy}"
fi
CURRENT="$GOV_DIR/current"

if [ ! -d "$CURRENT" ]; then
    echo "WEEKREPORT: skipped no current/ in $GOV_DIR"
    exit 0
fi

# The newest WeekPlan names the running week (sort -V keeps W9 before W10).
PLAN=$(find "$CURRENT" -maxdepth 1 -type f -name 'WeekPlan W[0-9]* [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md' \
    | sort -V | tail -1)
if [ -z "$PLAN" ]; then
    echo "WEEKREPORT: skipped no WeekPlan in $CURRENT"
    exit 0
fi

BASE=$(basename "$PLAN" .md)                       # WeekPlan W42 2026-10-12
STEM=${BASE#WeekPlan }                             # W42 2026-10-12
WEEK=${STEM%% *}                                   # W42
DATE=${STEM##* }                                   # 2026-10-12

EXISTING=$(find "$CURRENT" -maxdepth 1 -type f -name "WeekReport $WEEK *.md" | sort | tail -1)
if [ -n "$EXISTING" ]; then
    echo "WEEKREPORT: exists $EXISTING"
    exit 0
fi

TARGET="$CURRENT/WeekReport $STEM.md"
{
    printf -- '---\n'
    printf 'type: week-report\n'
    printf 'week: %s\n' "$WEEK"
    printf 'created: %s\n' "$(date +%Y-%m-%d)"
    printf -- '---\n\n'
    printf '# WeekReport %s\n\n' "$WEEK"
    printf '> Факты недели (WP-297: WeekPlan = намерения, WeekReport = факты). Сводки дней дописывает Day Close (шаги 2f/9b), итог недели дописывает week-review.\n\n'
    printf '## Итоги %s\n\n' "$WEEK"
    printf '_Сводки дней ниже, обратная хронология._\n'
} > "$TARGET" || { echo "WEEKREPORT: skipped cannot write $TARGET"; exit 0; }

echo "WEEKREPORT: created $TARGET"
exit 0
