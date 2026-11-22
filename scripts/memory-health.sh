#!/usr/bin/env bash
# routing: helper  skill=audit-installation  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# memory-health.sh — health metrics memory/ (WP-217 Phase10.2)
#
# Shows: distribution by horizons, HOT-limit, orphans, age-distribution.
# Output: markdown-table for insertion into DayPlan/Week Report.
#
# Usage:
#   bash scripts/memory-health.sh             # full report
#   bash scripts/memory-health.sh --summary   # key metrics only
#   bash scripts/memory-health.sh --dir PATH  # alternative directory
#
# Spec: memory/memory-lifecycle-spec.md §2 (WP-217 Phase10.1)

set -eu

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
# NOTE: iwe-env-bootstrap.sh reassigns SCRIPT_DIR to its OWN location (via its
# BASH_SOURCE[0]) as a side effect of being sourced — save ours first so the
# frontmatter.sh source below still resolves relative to THIS script (issue #229).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MEMORY_HEALTH_DIR="$SCRIPT_DIR"
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
# issue #658: was a private get_field() unaware of the `metadata:`-nested
# frontmatter dialect (issue #281) — memory-validate.sh/memory-bleed.sh
# already source the shared reader; this closes the gap for the two scripts
# that still had their own copy.
source "$_MEMORY_HEALTH_DIR/../.claude/lib/frontmatter.sh" || exit 1
MEMORY_DIR="$IWE_ROOT/memory"
HOT_LIMIT=150
MODE="full"
EXCLUDE="MEMORY.md"

while [ $# -gt 0 ]; do
    case "$1" in
        --summary) MODE="summary"; shift ;;
        --dir)     MEMORY_DIR="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -12
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

has_frontmatter() {
    head -1 "$1" | grep -q '^---$'
}

# Counters
total=0; orphans=0
hot_files=0; warm_files=0; cold_files=0; archive_files=0
hot_lines=0
superseded=0; archived_status=0; dormant=0
oldest_date="9999-99-99"; oldest_file=""
newest_date="0000-00-00"; newest_file=""

for f in $(find "$MEMORY_DIR/" -maxdepth 1 -name "*.md" | sort); do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    skip=0; for exc in $EXCLUDE; do [ "$name" = "$exc" ] && skip=1 && break; done
    [ $skip -eq 1 ] && continue
    total=$((total + 1))

    if ! has_frontmatter "$f"; then
        orphans=$((orphans + 1))
        continue
    fi

    horizon=$(get_field "$f" "horizon")
    status=$(get_field "$f" "status")
    valid_from=$(get_field "$f" "valid_from")

    # Count lines of file without frontmatter (remove the --- block) frontmatter (remove the --- block ---)
    file_lines=$(awk '/^---/{f++; next} f>=2{print}' "$f" | wc -l | tr -d ' ')

    case "$horizon" in
        hot)
            hot_files=$((hot_files + 1))
            hot_lines=$((hot_lines + file_lines))
            ;;
        warm)    warm_files=$((warm_files + 1)) ;;
        cold)    cold_files=$((cold_files + 1)) ;;
        archive) archive_files=$((archive_files + 1)) ;;
    esac

    case "$status" in
        superseded) superseded=$((superseded + 1)) ;;
        archived)   archived_status=$((archived_status + 1)) ;;
        dormant)    dormant=$((dormant + 1)) ;;
    esac

    # Age tracking
    if [ -n "$valid_from" ]; then
        if [ "$valid_from" \< "$oldest_date" ]; then
            oldest_date="$valid_from"; oldest_file="$name"
        fi
        if [ "$valid_from" \> "$newest_date" ]; then
            newest_date="$valid_from"; newest_file="$name"
        fi
    fi
done

# HOT-status
if [ $hot_lines -le $HOT_LIMIT ]; then
    hot_status="✅ ${hot_lines}/${HOT_LIMIT} lines"
else
    hot_status="❌ ${hot_lines}/${HOT_LIMIT} lines — EXCEEDED"
fi

orphans_pct=0
[ $total -gt 0 ] && orphans_pct=$((orphans * 100 / total))

echo "## Memory Health Report"
echo ""
echo "| Metric | Value |"
echo "|---------|----------|"
echo "| Total files memory/ | $total |"
echo "| Without frontmatter (orphans) | $orphans (${orphans_pct}%) |"
echo "| HOT | $hot_files files — $hot_status |"
echo "| WARM | $warm_files files |"
echo "| COLD | $cold_files files |"
echo "| archive | $archive_files files |"
echo "| status: superseded | $superseded |"
echo "| status: dormant | $dormant |"
echo "| Oldest (valid_from) | ${oldest_date} — ${oldest_file} |"
echo "| Newest (valid_from) | ${newest_date} — ${newest_file} |"

if [ "$MODE" = "full" ]; then
    echo ""
    echo "### HOT-files (limit ${HOT_LIMIT} lines)"
    echo ""
    echo "| File | Lines | Horizon | Status |"
    echo "|------|-------|----------|--------|"
    for f in $(find "$MEMORY_DIR/" -maxdepth 1 -name "*.md" | sort); do
        [ -f "$f" ] || continue
        has_frontmatter "$f" || continue
        h=$(get_field "$f" "horizon")
        [ "$h" = "hot" ] || continue
        s=$(get_field "$f" "status")
        lines=$(awk '/^---/{f++; next} f>=2{print}' "$f" | wc -l | tr -d ' ')
        echo "| $(basename $f) | $lines | $h | $s |"
    done
fi

echo ""
if [ $orphans -gt 0 ]; then
    echo "⚠️  $orphans files without frontmatter — run \`memory-validate.sh\` for details"
fi

# issue #735: memory-validate.sh existed and was working, but was not called from any
# from any working path — it was only mentioned in the text of this warning.
# Fail-soft (WARN, not a block): memory-health.sh is itself used in several
# places (day-close, audit-installation), crash due to-a missing/
# non-executable validate-validate script on another installation is not allowed.
_VALIDATE_SCRIPT="$_MEMORY_HEALTH_DIR/memory-validate.sh"
if [ -x "$_VALIDATE_SCRIPT" ]; then
    _validate_fails=$(bash "$_VALIDATE_SCRIPT" --quiet --dir "$MEMORY_DIR" 2>/dev/null | grep -c '^FAIL' || true)
    if [ "$_validate_fails" -gt 0 ]; then
        echo "❌ memory-validate.sh: $_validate_fails violations frontmatter — run \`memory-validate.sh\` for details"
    fi
else
    echo "⚠️  memory-validate.sh is not available ($_VALIDATE_SCRIPT) — frontmatter validation frontmatter skipped"
fi

if [ $hot_lines -gt $HOT_LIMIT ]; then
    echo "❌ HOT-limit exceeded by $((hot_lines - HOT_LIMIT)) lines — move files to WARM"
fi
if [ $orphans -eq 0 ] && [ $hot_lines -le $HOT_LIMIT ]; then
    echo "✅ All metrics are within normal range"
fi
