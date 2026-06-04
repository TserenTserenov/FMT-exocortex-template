#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# memory-bleed.sh — детектор нарушений memory/ (WP-217 Ф10.2)
#
# Обнаруживает: файлы без frontmatter, HOT-переполнение,
# missing superseded_by, кандидаты на понижение горизонта.
# НЕ применяет исправления — только отчёт (R23-детектор, не R8-оператор).
#
# Usage:
#   bash scripts/memory-bleed.sh              # все проверки
#   bash scripts/memory-bleed.sh --hot-only   # только HOT-лимит
#   bash scripts/memory-bleed.sh --dir PATH   # другая директория
#
# Exit code: 0 = нет нарушений, 1 = есть нарушения.
# Spec: memory/memory-lifecycle-spec.md §5 (WP-217 Ф10.1)

set -eu

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.claude/lib/iwe-env-bootstrap.sh" || exit 1
MEMORY_DIR="$IWE_ROOT/memory"
HOT_LIMIT=150
HOT_DOWNGRADE_DAYS=14   # HOT → WARM если не упоминался N дней
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

get_field() {
    local file="$1" field="$2"
    awk '/^---/{f++} f==1 && /^'"$field"':/{gsub(/^[^:]+: */,""); gsub(/^["'"'"']|["'"'"']$/,""); print; exit}' "$file"
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

# ── Нарушение 1: файлы без frontmatter ──────────────────────────────────────
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
    # ── HOT-лимит ────────────────────────────────────────────────────────────
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

# ── Нарушение 2: HOT-лимит ──────────────────────────────────────────────────
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

# ── Нарушение 3: superseded без superseded_by ────────────────────────────────
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

# ── Предупреждение: кандидаты на понижение горизонта ────────────────────────
echo "### Кандидаты на понижение горизонта"
echo ""
echo "| Файл | Горизонт | valid_from | Дней | Рекомендация |"
echo "|------|----------|-----------|------|-------------|"

found_candidates=0
for f in $(find "$MEMORY_DIR/" -maxdepth 1 -name "*.md" | sort); do
    [ -f "$f" ] || continue
    has_frontmatter "$f" || continue
    h=$(get_field "$f" "horizon")
    vf=$(get_field "$f" "valid_from")
    [ -z "$vf" ] && continue

    # Используем mtime как прокси для "последнего обращения"
    mtime=$(stat -f "%Sm" -t "%Y-%m-%d" "$f" 2>/dev/null || date -r "$f" +%Y-%m-%d 2>/dev/null || echo "$vf")
    age=$(days_since "$mtime")

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

    [ -n "$rec" ] && echo "| $(basename $f) | $h | $vf | $age | $rec |"
done

[ $found_candidates -eq 0 ] && echo "| — | — | — | — | нет кандидатов |"
echo ""
echo "_Действие: агент предлагает — пользователь подтверждает. Не выполнять автономно._"
echo ""

# ── Итог ─────────────────────────────────────────────────────────────────────
if [ $violations -eq 0 ]; then
    echo "✅ Нарушений не найдено"
    exit 0
else
    echo "❌ Нарушений: $violations — исправить перед следующим коммитом"
    exit 1
fi
