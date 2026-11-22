#!/usr/bin/env bash
# routing: helper  skill=iwe-rules-review  called-by=haiku  deterministic=true
# see DP.SC.159, DP.ROLE.059
# iwe-drift.sh — MVP drift-report on .claude/sync-manifest.yaml
#
# WP-217 Phase3b, draft 2026-04-10.
# Do NOT move to scripts/ until owner review.
#
# ROLE (clarification 10 Apr): R23-detector for pairs (A(pair), M1 compliance
# «are the source and the derived artifact in sync»). Detection ONLY, does not apply fix.
# Fix — separate operator scripts (R8 Synchronizer):
#   template-sync.sh, update.sh, dt_sync.py.
# Rule: the detector reports, the operator acts. Do not mix.
#
# Usage:
#   bash iwe-drift.sh                  # full report
#   bash iwe-drift.sh --critical       # only critical
#   bash iwe-drift.sh --top N          # top N by lag
#   bash iwe-drift.sh --manifest PATH  # specify path to manifest
#   bash iwe-drift.sh --activity       # candidates for "dormant" mode (§ activity_checks:)
#
# Requirements: bash, git, stat, awk (POSIX). No external dependencies.
# Output format: markdown-table, suitable for pasting into DayPlan/Week Report.

set -eu

# Detect stat mtime flag once — GNU/Linux uses -c %Y, BSD/macOS uses -f %m.
# NOTE: GNU stat accepts `-f %m` too (it prints the mount point), so we must
# detect GNU first by testing the flag it supports and BSD does not.
# Use unquoted $_STAT_FLAG in xargs pipelines (word-split is required for multi-token flags).
if stat -c %Y /dev/null >/dev/null 2>&1; then
    _STAT_FLAG="-c %Y"  # GNU/Linux
else
    _STAT_FLAG="-f %m"  # BSD/macOS
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# iwe-env-bootstrap.sh sets its own top-level SCRIPT_DIR when sourced, clobbering ours —
# save this script's own directory under a distinct name before sourcing (issue #259).
IWE_DRIFT_SCRIPT_DIR="$SCRIPT_DIR"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
MANIFEST="${MANIFEST:-$IWE_ROOT/.claude/sync-manifest.yaml}"
MODE="all"
TOP_N=0

while [ $# -gt 0 ]; do
    case "$1" in
        --critical) MODE="critical"; shift ;;
        --activity) MODE="activity"; shift ;;
        --top) TOP_N="$2"; shift 2 ;;
        --manifest) MANIFEST="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -20
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ ! -f "$MANIFEST" ]; then
    echo "Manifest not found: $MANIFEST" >&2
    exit 1
fi

# Parsing section activity_checks: (independent of pairs: section above in the manifest)
parse_activity() {
    local manifest="$1"
    awk '
        /^activity_checks:/ { started = 1; next }
        !started { next }
        /^  - id:/ {
            if (id != "") print_record()
            id = clean_prefix($0, "^  - id:")
        }
        /^    action:/           { action = clean_quoted(clean_prefix($0, "^    action:")) }
        /^    expected_per_period:/ { expected = clean_prefix($0, "^    expected_per_period:") }
        /^    period_days:/      { period = clean_prefix($0, "^    period_days:") }
        /^    commit_pattern_regex:/ { regex = clean_quoted(clean_prefix($0, "^    commit_pattern_regex:")) }
        /^    dormant_after_periods:/ { dormant = clean_prefix($0, "^    dormant_after_periods:") }
        /^    mtime_files:/      { mtime = clean_quoted(clean_prefix($0, "^    mtime_files:")) }
        END { if (id != "") print_record() }

        function clean_prefix(line, pat,    v) {
            v = line
            sub(pat, "", v)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            return v
        }
        function clean_quoted(v) {
            gsub(/^"|"$/, "", v)
            return v
        }
        function print_record() {
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", id, action, expected, period, regex, dormant, (mtime == "" ? "-" : mtime)
            id=""; action=""; expected=""; period=""; regex=""; dormant=""; mtime=""
        }
    ' "$manifest"
}

# File modification time in seconds (GNU stat on Linux, BSD stat on macOS); empty, if the file does not exist.
file_mtime() {
    stat -c %Y -L "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Repository for commit lookup: root IWE, if it is git; otherwise iwe-local-config
# (on Linux-host root ~/IWE is not git, and git log is always empty for it).
activity_git_root() {
    if [ -e "$IWE_ROOT/.git" ]; then echo "$IWE_ROOT"
    elif [ -e "$IWE_ROOT/iwe-local-config/.git" ]; then echo "$IWE_ROOT/iwe-local-config"
    else echo "$IWE_ROOT"; fi
}

# Number of files from the list mtime_files (paths relative to IWE_ROOT, comma-separated),
# modified within the window [now - since_days, now - until_days]. For actions that do not, that do not
# produce commits (for example, lesson hygiene: memory resides outside git).
count_mtime_hits() {
    local files="$1" since_days="$2" until_days="$3" now lo hi f m hits=0
    now=$(date +%s); lo=$(( now - since_days * 86400 )); hi=$(( now - until_days * 86400 ))
    local IFS=','
    for f in $files; do
        m=$(file_mtime "$IWE_ROOT/$f")
        [ -n "$m" ] && [ "$m" -ge "$lo" ] && [ "$m" -le "$hi" ] && hits=$(( hits + 1 ))
    done
    echo "$hits"
}

# Candidates for "dormant mode": N consecutive windows (dormant_after_periods) without
# commit, matching commit_pattern_regex, counting backwards from today.
report_activity() {
    local manifest="$1"
    local tmp
    tmp=$(mktemp)
    parse_activity "$manifest" > "$tmp"

    echo "## Candidates for «dormant» mode ($(date +%Y-%m-%d))"
    echo ""

    local found=0
    local git_root
    git_root=$(activity_git_root)
    while IFS=$'\t' read -r id action expected period regex dormant mtime_files; do
        [ -z "$id" ] && continue

        local window all_windows_empty=1 since_days until_days count
        for window in $(seq 0 $(( dormant - 1 ))); do
            since_days=$(( (window + 1) * period ))
            until_days=$(( window * period ))
            if [ "$mtime_files" != "-" ] && [ -n "$mtime_files" ]; then
                count=$(count_mtime_hits "$mtime_files" "$since_days" "$until_days")
            else
                count=$(git -C "$git_root" log --oneline -E \
                    --since="${since_days} days ago" --until="${until_days} days ago" \
                    --grep="$regex" 2>/dev/null | wc -l | tr -d '[:space:]')
            fi
            if [ "$count" -ge "$expected" ]; then
                all_windows_empty=0
                break
            fi
        done

        if [ "$all_windows_empty" -eq 1 ]; then
            found=1
            printf -- "- **%s** (%s): did not fire %s consecutive windows (of %s days) — present to the user in M6.\n" \
                "$id" "$action" "$dormant" "$period"
        fi
    done < "$tmp"
    rm -f "$tmp"

    if [ "$found" -eq 0 ]; then
        echo "_No candidates — all T-actions fired at least once in the recent windows._"
    fi
}

if [ "$MODE" = "activity" ]; then
    report_activity "$MANIFEST"
    exit 0
fi

# Get mtime file mtime in days from today (uses $_STAT_FLAG, defined above)
mtime_days_ago() {
    local path="$1"
    if [ ! -e "$path" ]; then
        echo "-1"
        return
    fi
    local mtime
    # shellcheck disable=SC2086  # $_STAT_FLAG intentionally unquoted (multi-token flag)
    mtime=$(stat $_STAT_FLAG "$path")
    local now
    now=$(date +%s)
    echo $(( (now - mtime) / 86400 ))
}

# Get the most recent mtime in the directory (recursively)
dir_newest_mtime_days_ago() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        mtime_days_ago "$dir"
        return
    fi
    local newest
    # shellcheck disable=SC2086  # $_STAT_FLAG intentionally unquoted (multi-token flag)
    newest=$(find "$dir" -type f -not -path '*/.git/*' -print0 2>/dev/null \
        | xargs -0 stat $_STAT_FLAG 2>/dev/null \
        | sort -nr | head -1)
    if [ -z "${newest:-}" ]; then
        echo "-1"
        return
    fi
    local now
    now=$(date +%s)
    echo $(( (now - newest) / 86400 ))
}

# Parsing YAML (naive, only for the fixed format of this manifest)
parse_manifest() {
    local manifest="$1"
    awk '
        /^activity_checks:/ { if (id != "") print_record(); exit }
        /^  - id:/ { if (id != "") print_record(); id = clean($3) }
        /^    source:/ { source = clean($2) }
        /^    derived:/ { derived = clean($2) }
        /^    relation:/ { relation = clean($2) }
        /^    check:/ { check = clean($2) }
        /^    threshold_days:/ { thresh = clean($2) }
        /^    critical_days:/ { crit = clean($2) }
        /^    owner_role:/ { owner = clean($2) }
        /^    symptom:/ {
            sub(/^[[:space:]]*symptom:[[:space:]]*"?/, "", $0)
            sub(/"[[:space:]]*$/, "", $0)
            symptom = $0
        }
        END { if (id != "") print_record() }

        function clean(v) {
            gsub(/^["[:space:]]+|["[:space:]]+$/, "", v)
            return v
        }

        function print_record() {
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", id, source, derived, relation, check, thresh, crit, owner, symptom
            id=""; source=""; derived=""; relation=""; check=""; thresh=""; crit=""; owner=""; symptom=""
        }
    ' "$manifest"
}

# Collect records → lines markdown
collect() {
    local records_file="$1"

    while IFS=$'\t' read -r id source derived relation check thresh crit owner symptom; do
        [ -z "$id" ] && continue

        # issue #220: check: script:<path> was previously read, but was never executed —
        # such pairs were silently treated as mtime-lag (source==derived → lag always 0 → always "ok").
        case "$check" in
            script:*)
                # issue #259: helpers are template-based (live alongside scripts/iwe-drift.sh), and not
                # part of workspace-root — resolve relative to SCRIPT_DIR, not IWE_ROOT.
                local helper_path="$IWE_DRIFT_SCRIPT_DIR/../${check#script:}"
                local script_status
                if [ ! -f "$helper_path" ]; then
                    script_status="missing"
                elif bash "$helper_path" >/dev/null 2>&1; then
                    script_status="ok"
                else
                    case "$?" in
                        2) script_status="critical" ;;
                        # 1/3: helper was found and executed, but the pair source is not applicable for
                        # this installation (for example there is no WP-REGISTRY.md) — do not confuse with "missing"
                        # (the helper itself was not found).
                        1|3) script_status="unavailable" ;;
                        *) script_status="missing" ;;
                    esac
                fi
                printf "%s\t%s\t%s\t%s\t%s\t%s\n" "?" "$id" "$relation" "$script_status" "$owner" "$symptom"
                continue
                ;;
        esac

        local src_path="$source"
        local dst_path="$derived"
        case "$src_path" in /*) ;; *) src_path="$IWE_ROOT/$src_path" ;; esac
        case "$dst_path" in /*) ;; *) dst_path="$IWE_ROOT/$dst_path" ;; esac

        if [ "$check" = "content-diff" ]; then
            local content_status
            if [ ! -f "$src_path" ] || [ ! -f "$dst_path" ]; then
                content_status="missing"
            elif cmp -s "$src_path" "$dst_path"; then
                content_status="ok"
            else
                content_status="critical"
            fi
            printf "%s\t%s\t%s\t%s\t%s\t%s\n" "?" "$id" "$relation" "$content_status" "$owner" "$symptom"
            continue
        fi

        local src_age dst_age lag status
        src_age=$(dir_newest_mtime_days_ago "$src_path")
        dst_age=$(dir_newest_mtime_days_ago "$dst_path")

        if [ "$src_age" -lt 0 ] || [ "$dst_age" -lt 0 ]; then
            lag="?"
            status="missing"
        else
            # lag = dst_age - src_age (positive = derived is behind)
            lag=$(( dst_age - src_age ))
            if [ "$lag" -lt 0 ]; then lag=0; fi
            if [ -z "$crit" ] || [ -z "$thresh" ]; then
                status="ok"
            elif [ "$lag" -ge "$crit" ]; then
                status="critical"
            elif [ "$lag" -ge "$thresh" ]; then
                status="warn"
            else
                status="ok"
            fi
        fi

        printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$lag" "$id" "$relation" "$status" "$owner" "$symptom"
    done < "$records_file"
}

TMP_RECORDS=$(mktemp)
TMP_ROWS=$(mktemp)
trap 'rm -f "$TMP_RECORDS" "$TMP_ROWS"' EXIT

parse_manifest "$MANIFEST" > "$TMP_RECORDS"
collect "$TMP_RECORDS" > "$TMP_ROWS"

# Filtering
if [ "$MODE" = "critical" ]; then
    awk -F'\t' '$4 == "critical"' "$TMP_ROWS" > "$TMP_ROWS.filtered"
    mv "$TMP_ROWS.filtered" "$TMP_ROWS"
fi

# Sort by lag (numeric descending, '?' to the end)
sort -t$'\t' -k1,1 -rn "$TMP_ROWS" > "$TMP_ROWS.sorted"
mv "$TMP_ROWS.sorted" "$TMP_ROWS"

# Top-N
if [ "$TOP_N" -gt 0 ]; then
    head -n "$TOP_N" "$TMP_ROWS" > "$TMP_ROWS.top"
    mv "$TMP_ROWS.top" "$TMP_ROWS"
fi

# Output markdown-table
echo "## Drift-report ($(date +%Y-%m-%d))"
echo ""
if [ ! -s "$TMP_ROWS" ]; then
    echo "_No drift'drift for the selected filter._"
    exit 0
fi
echo "| lag (days) | ID | relation | status | owner | symptom |"
echo "|---:|---|---|---|---|---|"
while IFS=$'\t' read -r lag id relation status owner symptom; do
    # icon
    case "$status" in
        critical) icon="critical" ;;
        warn)     icon="warn" ;;
        ok)       icon="ok" ;;
        missing)  icon="missing" ;;
        *)        icon="$status" ;;
    esac
    printf "| %s | %s | %s | %s | %s | %s |\n" "$lag" "$id" "$relation" "$icon" "$owner" "$symptom"
done < "$TMP_ROWS"
