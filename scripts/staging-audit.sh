#!/bin/bash
# routing: helper  skill=week-close,day-close  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# staging-audit.sh — detector B12e Decay drift in STAGING.md
#
# Parses STAGING.md (inline table S-NN | name | files | status | date | criteria),
# identifies records with status `testing` older than N days (default 30) and records
# with passed prose-deadlines (format «at Week Close WNN» / «by D May»).
#
# Usage:
#   bash staging-audit.sh                     # default report (testing >30d)
#   bash staging-audit.sh --threshold 14      # threshold in days
#   bash staging-audit.sh --check             # exit 1 exit 1 if zombies are found zombies
#   bash staging-audit.sh --staging <path>    # path to STAGING.md (default $IWE/STAGING.md)
#
# MVP-cut: machine-readable per-row frontmatter (decay_after, ready_signals) deferred
# to the full version. Currently works with inline-table via regex by date of 5-th column.

set -uo pipefail

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
STAGING="${IWE}/STAGING.md"
THRESHOLD=30
check_mode=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --check) check_mode=true; shift ;;
        --staging) STAGING="$2"; shift 2 ;;
        --help|-h)
            grep "^# " "$0" | head -20 | sed 's/^# //'
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

[[ -f "$STAGING" ]] || { echo "[ERROR] STAGING.md not found: $STAGING" >&2; exit 1; }

TODAY=$(date +%Y-%m-%d)
TODAY_EPOCH=$(date +%s)
threshold_epoch=$((TODAY_EPOCH - THRESHOLD * 86400))

# Global metrics calculation
total=$(grep -cE "^\| S-[0-9]+ " "$STAGING" || echo 0)
promoted=$(grep -cE "^\| S-[0-9]+ .*\| promoted " "$STAGING" || echo 0)
testing=$(grep -cE "^\| S-[0-9]+ .*\| testing " "$STAGING" || echo 0)
rejected=$(grep -cE "^\| S-[0-9]+ .*\| rejected " "$STAGING" || echo 0)

echo "=== STAGING.md audit ($STAGING) ==="
echo "Report date: $TODAY · Threshold decay: ${THRESHOLD} days"
echo ""
echo "Total records: $total"
echo "  promoted: $promoted"
echo "  testing:  $testing"
echo "  rejected: $rejected"
echo ""

# Searching for zombies — testing-records with date in 5-th column older than threshold
zombies=0
echo "=== Zombie candidates (testing >${THRESHOLD}d) ==="

while IFS= read -r line; do
    # Extract S-NN, status, date (format YYYY-MM-DD in 5-th column)
    id=$(echo "$line" | grep -oE "^\| S-[0-9]+" | tr -d '| ')
    [[ -z "$id" ]] && continue
    status=$(echo "$line" | awk -F'|' '{ for(i=1;i<=NF;i++) if($i ~ /testing|promoted|rejected/) { gsub(/ /,"",$i); print $i; break }}')
    [[ "$status" != "testing" ]] && continue
    # Date — first match of YYYY-MM-DD in the line after status
    date=$(echo "$line" | grep -oE "20[0-9]{2}-[0-9]{2}-[0-9]{2}" | head -1)
    [[ -z "$date" ]] && { echo "  $id: testing (no date in line) — manual audit required"; ((zombies++)); continue; }
    if [[ "$(uname)" == "Darwin" ]]; then
        date_epoch=$(date -j -f "%Y-%m-%d" "$date" "+%s" 2>/dev/null || echo 0)
    else
        date_epoch=$(date -d "$date" "+%s" 2>/dev/null || echo 0)
    fi
    [[ "$date_epoch" -eq 0 ]] && continue
    if [[ "$date_epoch" -lt "$threshold_epoch" ]]; then
        age_days=$(( (TODAY_EPOCH - date_epoch) / 86400 ))
        # Extract short description (2-nd column, first 50 characters)
        desc=$(echo "$line" | awk -F'|' '{print $3}' | sed 's/^ *//;s/ *$//' | cut -c1-50)
        echo "  $id (${age_days}d): $desc..."
        ((zombies++))
    fi
done < <(grep -E "^\| S-[0-9]+ " "$STAGING")

echo ""
echo "Found zombies: $zombies"

# Gap-check numbering
echo ""
echo "=== Gap-check numbering S-* ==="
nums=$(grep -oE "^\| S-[0-9]+" "$STAGING" | grep -oE "[0-9]+" | sort -n | uniq)
prev=0
gaps=0
for n in $nums; do
    if [[ $prev -gt 0 ]] && [[ $((n - prev)) -gt 1 ]]; then
        for ((i=prev+1; i<n; i++)); do
            echo "  GAP: S-$i is missing (between S-$prev and S-$n)"
            ((gaps++))
        done
    fi
    prev=$n
done
echo "Gaps in numbering: $gaps"

# Prose-deadline detector (best-effort)
echo ""
echo "=== Prose deadlines require manual review ==="
prose_deadlines=$(grep -cE "Week Close W[0-9]+|by [0-9]+ May|by [0-9]+ Jun" "$STAGING" || echo 0)
echo "Records with prose-deadline: $prose_deadlines (require machine-readable criteria — see. B12e)"

# Exit-code in check mode
if $check_mode; then
    if [[ $zombies -gt 0 ]]; then
        echo ""
        echo "❌ FAIL: found $zombies zombie(s)"
        exit 1
    fi
    echo ""
    echo "✅ PASS: zombies not detected"
fi

exit 0
