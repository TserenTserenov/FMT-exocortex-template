#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# memory-bleed.sh — violation detector memory/ (WP-217 Phase10.2)
#
# Detects: files without frontmatter, HOT-overflow,
# missing superseded_by, candidates for horizon demotion.
# Does NOT apply fixes — report only (R23-detector, not R8-operator).
#
# Usage:
#   bash scripts/memory-bleed.sh              # all checks
#   bash scripts/memory-bleed.sh --hot-only   # only HOT-limit
#   bash scripts/memory-bleed.sh --dir PATH   # different directory
#
# Exit code: 0 = no violations, 1 = violations found.
# Spec: memory/memory-lifecycle-spec.md §5 (WP-217 Phase10.1)

set -eu

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
MEMORY_DIR="$IWE_ROOT/memory"
HOT_LIMIT=150
HOT_DOWNGRADE_DAYS=14   # HOT → WARM if not referenced for N N days
WARM_DOWNGRADE_DAYS=30  # WARM → COLD
COLD_ARCHIVE_DAYS=90    # COLD → archive
HOT_ONLY=0
EXCLUDE="MEMORY.md"

while [ $# -gt 0 ]; do
    case "$1" in
        --hot-only) HOT_ONLY=1; shift ;;
        --dir)      MEMORY_DIR="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -14
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# #513: unified reader instead of a local copy — shared .claude/lib/frontmatter.sh
# already normalizes both forms (flat and nested metadata:), local awk saw
# only the flat form and silently returned empty output for files, written by the harness.
_MEMORY_BLEED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../.claude/lib/frontmatter.sh
source "$_MEMORY_BLEED_DIR/../.claude/lib/frontmatter.sh"

# #515: file mtime, portable. GNU stat (Linux) first, BSD (macOS) as fallback;
# stderr stderr of the first form is suppressed — on macOS it was emitting errors into the report.
file_mtime_ymd() {
    # epoch two forms of stat (GNU/BSD), date — python'via: mixed toolchain
    # macOS (brew GNU stat + system BSD date) broke the paired combination
    # stat+date (review Phase14, Medium-6)
    local f="$1" e
    e=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
    [ -n "$e" ] || return 1
    python3 -c "import datetime,sys; print(datetime.date.fromtimestamp(int(sys.argv[1])))" "$e" 2>/dev/null
}

has_frontmatter() {
    head -1 "$1" | grep -q '^---$'
}

today=$(date +%Y-%m-%d)
days_since() {
    local d="$1"
    [ -z "$d" ] && echo "999" && return
    python3 -c "from datetime import date; print((date.today()-date.fromisoformat('$d')).days)" 2>/dev/null || echo "999"
}

violations=0

echo "## Memory Bleed Report — $today"
echo ""

# ── Violation 1: files without frontmatter ──────────────────────────────────────
orphans=""
for f in $(find "$MEMORY_DIR/" -maxdepth 1 -name "*.md" | sort); do
    [ -f "$f" ] || continue
    n=$(basename "$f"); skip=0
    for exc in $EXCLUDE; do [ "$n" = "$exc" ] && skip=1 && break; done
    [ $skip -eq 1 ] && continue
    has_frontmatter "$f" || orphans="$orphans\n- $n"
done

if [ -n "$orphans" ]; then
    echo "### ❌ Files without frontmatter (violation WP-217 Phase10.1)"
    printf "%b\n" "$orphans"
    violations=$((violations + 1))
    echo ""
fi

[ $HOT_ONLY -eq 1 ] && {
    # ── HOT-limit ────────────────────────────────────────────────────────────
    hot_lines=0
    hot_list=""
    for f in $(find "$MEMORY_DIR/" -maxdepth 1 -name "*.md" | sort); do
        [ -f "$f" ] || continue
        has_frontmatter "$f" || continue
        h=$(get_field "$f" "horizon")
        [ "$h" = "hot" ] || continue
        lines=$(awk '/^---/{f++; next} f>=2{print}' "$f" | wc -l | tr -d ' ')
        hot_lines=$((hot_lines + lines))
        hot_list="$hot_list\n- $(basename $f): $lines lines"
    done
    if [ $hot_lines -gt $HOT_LIMIT ]; then
        echo "### ❌ HOT-limit exceeded: ${hot_lines}/${HOT_LIMIT} lines"
        printf "%b\n" "$hot_list"
        violations=$((violations + 1))
    else
        echo "### ✅ HOT-limit: ${hot_lines}/${HOT_LIMIT} lines"
    fi
    echo ""
    [ $violations -eq 0 ] && exit 0 || exit 1
}

# ── Violation 2: HOT-limit ──────────────────────────────────────────────────
hot_lines=0
hot_files_list=""
for f in $(find "$MEMORY_DIR/" -maxdepth 1 -name "*.md" | sort); do
    [ -f "$f" ] || continue
    has_frontmatter "$f" || continue
    h=$(get_field "$f" "horizon")
    [ "$h" = "hot" ] || continue
    lines=$(awk '/^---/{f++; next} f>=2{print}' "$f" | wc -l | tr -d ' ')
    hot_lines=$((hot_lines + lines))
    hot_files_list="$hot_files_list\n- $(basename $f): $lines lines"
done

if [ $hot_lines -gt $HOT_LIMIT ]; then
    echo "### ❌ HOT-limit exceeded: ${hot_lines}/${HOT_LIMIT} lines"
    printf "%b\n" "$hot_files_list"
    echo "_Action: move some files to WARM (change horizon in frontmatter)_"
    violations=$((violations + 1))
    echo ""
else
    echo "### ✅ HOT-limit: ${hot_lines}/${HOT_LIMIT} lines"
    echo ""
fi

# ── Violation 3: superseded without superseded_by ────────────────────────────────
missing_sb=""
for f in $(find "$MEMORY_DIR/" -maxdepth 1 -name "*.md" | sort); do
    [ -f "$f" ] || continue
    has_frontmatter "$f" || continue
    status=$(get_field "$f" "status")
    [ "$status" = "superseded" ] || continue
    sb=$(get_field "$f" "superseded_by")
    [ -z "$sb" ] && missing_sb="$missing_sb\n- $(basename $f)"
done

if [ -n "$missing_sb" ]; then
    echo "### ❌ status=superseded without superseded_by"
    printf "%b\n" "$missing_sb"
    violations=$((violations + 1))
    echo ""
fi

# ── Warning: candidates for horizon demotion ────────────────────────
echo "### Candidates for horizon demotion"
echo ""
echo "| File | Horizon | valid_from | Days | Recommendation |"
echo "|------|----------|-----------|------|-------------|"

found_candidates=0
for f in $(find "$MEMORY_DIR/" -maxdepth 1 -name "*.md" | sort); do
    [ -f "$f" ] || continue
    has_frontmatter "$f" || continue
    h=$(get_field "$f" "horizon")
    vf=$(get_field "$f" "valid_from")
    [ -z "$vf" ] && continue

    # Using mtime as a proxy for "last access"
    mtime=$(file_mtime_ymd "$f" || true); [ -n "$mtime" ] || mtime="$vf"
    age=$(days_since "$mtime")

    rec=""
    case "$h" in
        hot)
            if [ "$age" -ge $HOT_DOWNGRADE_DAYS ]; then
                rec="→ WARM (${age}d without changes)"
                found_candidates=$((found_candidates + 1))
            fi
            ;;
        warm)
            if [ "$age" -ge $WARM_DOWNGRADE_DAYS ]; then
                rec="→ COLD (${age}d without changes)"
                found_candidates=$((found_candidates + 1))
            fi
            ;;
        cold)
            if [ "$age" -ge $COLD_ARCHIVE_DAYS ]; then
                rec="→ archive (${age}d without changes)"
                found_candidates=$((found_candidates + 1))
            fi
            ;;
    esac

    [ -n "$rec" ] && echo "| $(basename $f) | $h | $vf | $age | $rec |"
done

[ $found_candidates -eq 0 ] && echo "| — | — | — | — | no candidates |"
echo ""
echo "_Action: agent proposes, user confirms. Do not execute autonomously. — user confirms. Do not execute autonomously._"
echo ""

# ── Summary ─────────────────────────────────────────────────────────────────────
if [ $violations -eq 0 ]; then
    echo "✅ No violations found"
    exit 0
else
    echo "❌ Violations: $violations — fix before the next commit"
    exit 1
fi
