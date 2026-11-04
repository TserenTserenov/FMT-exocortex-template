#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# memory-bleed.sh — detector of memory/ violations (WP-217 Phase 10.2)
#
# Detects: files without frontmatter, HOT overflow,
# missing superseded_by, candidates for horizon demotion.
# Does NOT apply fixes — report only (R23 detector, not an R8 operator).
#
# Usage:
#   bash scripts/memory-bleed.sh              # all checks
#   bash scripts/memory-bleed.sh --hot-only   # HOT limit only
#   bash scripts/memory-bleed.sh --dir PATH   # another directory
#
# Exit code: 0 = no violations, 1 = there are violations.
# Spec: memory/memory-lifecycle-spec.md §5 (WP-217 Phase 10.1)

set -eu

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
MEMORY_DIR="$IWE_ROOT/memory"
HOT_LIMIT=150
HOT_DOWNGRADE_DAYS=14   # HOT → WARM if not mentioned for N days
WARM_DOWNGRADE_DAYS=30  # WARM → COLD
COLD_ARCHIVE_DAYS=90    # COLD → archive
HOT_ONLY=0
# Instruction files have no memory frontmatter by design; day-close copies
# CLAUDE.md/AGENTS.md next to memory in the exocortex/ backup (issue #1352).
EXCLUDE="MEMORY.md CLAUDE.md AGENTS.md"

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

# #513: a single reader instead of a local copy — the shared .claude/lib/frontmatter.sh
# already normalizes both forms (flat and nested metadata:), the local awk saw
# only the flat one and silently returned nothing on files written by the harness.
_MEMORY_BLEED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../.claude/lib/frontmatter.sh
source "$_MEMORY_BLEED_DIR/../.claude/lib/frontmatter.sh"

# Age in calendar days since mtime, for every file at once: prints "<age>\t<path>"
# per path read from stdin, age "-" when it cannot be computed (an empty field
# would be eaten by `read`, tab is IFS whitespace; such a file falls back to
# days_since valid_from). One python process for all files whose mtime reads —
# two per file made the run on ~1700 memory files exceed the 180 s handler
# timeout of month-close (WP-529 F248). Same expression as the former per-file
# pair: date.today() - date.fromtimestamp(int(mtime)). Paths are passed as bytes
# so a name that is not valid UTF-8 cannot stop the stream; names containing a
# newline or ending in a tab are not supported (one record per line).
file_ages_days() {
    python3 -c '
import datetime, os, sys
today = datetime.date.today()
for raw in sys.stdin.buffer:
    path = raw.rstrip(b"\n")
    try:
        age = str((today - datetime.date.fromtimestamp(int(os.stat(path).st_mtime))).days).encode()
    except Exception:
        age = b"-"
    sys.stdout.buffer.write(age + b"\t" + path + b"\n")
'
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
    echo "### ❌ Файлы без frontmatter (нарушение WP-217 Ф10.1)"
    printf "%b\n" "$orphans"
    violations=$((violations + 1))
    echo ""
fi

[ $HOT_ONLY -eq 1 ] && {
    # ── HOT limit ────────────────────────────────────────────────────────────
    hot_lines=0
    hot_list=""
    for f in $(find "$MEMORY_DIR/" -maxdepth 1 -name "*.md" | sort); do
        [ -f "$f" ] || continue
        has_frontmatter "$f" || continue
        h=$(get_field "$f" "horizon")
        [ "$h" = "hot" ] || continue
        lines=$(awk '/^---/{f++; next} f>=2{print}' "$f" | wc -l | tr -d ' ')
        hot_lines=$((hot_lines + lines))
        hot_list="$hot_list\n- $(basename $f): $lines строк"
    done
    if [ $hot_lines -gt $HOT_LIMIT ]; then
        echo "### ❌ HOT-лимит превышен: ${hot_lines}/${HOT_LIMIT} строк"
        printf "%b\n" "$hot_list"
        violations=$((violations + 1))
    else
        echo "### ✅ HOT-лимит: ${hot_lines}/${HOT_LIMIT} строк"
    fi
    echo ""
    [ $violations -eq 0 ] && exit 0 || exit 1
}

# ── Violation 2: HOT limit ──────────────────────────────────────────────────
hot_lines=0
hot_files_list=""
for f in $(find "$MEMORY_DIR/" -maxdepth 1 -name "*.md" | sort); do
    [ -f "$f" ] || continue
    has_frontmatter "$f" || continue
    h=$(get_field "$f" "horizon")
    [ "$h" = "hot" ] || continue
    lines=$(awk '/^---/{f++; next} f>=2{print}' "$f" | wc -l | tr -d ' ')
    hot_lines=$((hot_lines + lines))
    hot_files_list="$hot_files_list\n- $(basename $f): $lines строк"
done

if [ $hot_lines -gt $HOT_LIMIT ]; then
    echo "### ❌ HOT-лимит превышен: ${hot_lines}/${HOT_LIMIT} строк"
    printf "%b\n" "$hot_files_list"
    echo "_Действие: перевести часть файлов в WARM (изменить horizon в frontmatter)_"
    violations=$((violations + 1))
    echo ""
else
    echo "### ✅ HOT-лимит: ${hot_lines}/${HOT_LIMIT} строк"
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
    echo "### ❌ status=superseded без superseded_by"
    printf "%b\n" "$missing_sb"
    violations=$((violations + 1))
    echo ""
fi

# ── Warning: candidates for horizon demotion ────────────────────────────────
echo "### Кандидаты на понижение горизонта"
echo ""
echo "| Файл | Горизонт | valid_from | Дней | Рекомендация |"
echo "|------|----------|-----------|------|-------------|"

found_candidates=0
missing_lifecycle=""
missing_lifecycle_count=0
ages_seen=0
while IFS=$'\t' read -r age f; do
    ages_seen=$((ages_seen + 1))
    [ -f "$f" ] || continue
    has_frontmatter "$f" || continue
    h=$(get_field "$f" "horizon")
    vf=$(get_field "$f" "valid_from")

    # #1425: Claude Code auto-memory writes only name/description/metadata.type,
    # so these fields are absent from birth. Report them instead of dropping the
    # file from the demotion cycle.
    missing=""
    for field in horizon valid_from status; do
        [ -n "$(get_field "$f" "$field")" ] || missing="$missing $field"
    done
    if [ -n "$missing" ]; then
        missing_lifecycle="$missing_lifecycle\n- $(basename "$f"): нет${missing}"
        missing_lifecycle_count=$((missing_lifecycle_count + 1))
    fi

    # No horizon: the default for the type from memory-lifecycle-spec.md §4
    # (axis 1). Without a known type the horizon is not guessed.
    h_label="$h"
    if [ -z "$h" ]; then
        case "$(get_field "$f" "type")" in
            user|feedback) h="hot" ;;
            project|reference|lesson|protocol) h="warm" ;;
        esac
        [ -n "$h" ] && h_label="$h (по умолч.)"
    fi

    # We use mtime as a proxy for "last access"; valid_from is only a fallback
    [ "$age" != "-" ] || age=$(days_since "$vf")

    rec=""
    case "$h" in
        hot)
            if [ "$age" -ge $HOT_DOWNGRADE_DAYS ]; then
                rec="→ WARM (${age}d без изменений)"
                found_candidates=$((found_candidates + 1))
            fi
            ;;
        warm)
            if [ "$age" -ge $WARM_DOWNGRADE_DAYS ]; then
                rec="→ COLD (${age}d без изменений)"
                found_candidates=$((found_candidates + 1))
            fi
            ;;
        cold)
            if [ "$age" -ge $COLD_ARCHIVE_DAYS ]; then
                rec="→ archive (${age}d без изменений)"
                found_candidates=$((found_candidates + 1))
            fi
            ;;
    esac

    [ -n "$rec" ] && echo "| $(basename "$f") | $h_label | ${vf:-—} | $age | $rec |"
done < <(find "$MEMORY_DIR/" -maxdepth 1 -name "*.md" | sort | file_ages_days)

[ $found_candidates -eq 0 ] && echo "| — | — | — | — | нет кандидатов |"
# The ages come from one python process: if it is missing or dies midway the
# loop just ends early, so a short count must not read as a clean report.
ages_expected=$(find "$MEMORY_DIR/" -maxdepth 1 -name "*.md" | wc -l | tr -d ' ')
if [ "$ages_seen" -ne "$ages_expected" ]; then
    echo ""
    echo "❌ Возраст посчитан для $ages_seen из $ages_expected файлов (python3 недоступен или прервался) — таблица выше неполная"
    violations=$((violations + 1))
fi
echo ""
echo "_Действие: агент предлагает — пользователь подтверждает. Не выполнять автономно._"
echo ""

# ── Warning: files without lifecycle fields (#1425) ──────────────────────────
# A warning, not a violation: these files are usually written by the harness,
# and failing every close on them would hide real violations behind noise.
MISSING_LIST_LIMIT=20  # the close protocols hand the whole report to the agent
if [ $missing_lifecycle_count -gt 0 ]; then
    echo "### ⚠️ Файлы без полей жизненного цикла (memory-lifecycle-spec.md §3, §6)"
    printf "%b\n" "$missing_lifecycle" | sed '/^$/d' | head -n "$MISSING_LIST_LIMIT"
    [ $missing_lifecycle_count -gt $MISSING_LIST_LIMIT ] \
        && echo "- … и ещё $((missing_lifecycle_count - MISSING_LIST_LIMIT)) (всего $missing_lifecycle_count)"
    echo ""
    echo "_Горизонт для понижения взят по type (§4); HOT-лимит такие файлы пока не учитывает. Дописать поля — с подтверждения пользователя._"
    echo ""
fi

# ── Summary ─────────────────────────────────────────────────────────────────────
if [ $violations -eq 0 ]; then
    if [ $missing_lifecycle_count -gt 0 ]; then
        echo "⚠️ Предупреждений: $missing_lifecycle_count файлов без полей жизненного цикла (см. секцию выше) — нарушением не считается"
    else
        echo "✅ Нарушений не найдено"
    fi
    exit 0
else
    echo "❌ Нарушений: $violations — исправить перед следующим коммитом"
    exit 1
fi
