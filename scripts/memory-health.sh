#!/usr/bin/env bash
# routing: helper  skill=audit-installation  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# memory-health.sh — метрики здоровья memory/ (WP-217 Ф10.2)
#
# Показывает: распределение по горизонтам, HOT-лимит, orphans, age-distribution.
# Вывод: markdown-таблица для вставки в DayPlan/Week Report.
#
# Usage:
#   bash scripts/memory-health.sh             # полный отчёт
#   bash scripts/memory-health.sh --summary   # только ключевые метрики
#   bash scripts/memory-health.sh --dir PATH  # другая директория
#
# Spec: memory/memory-lifecycle-spec.md §2 (WP-217 Ф10.1)

set -eu

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
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

get_field() {
    local file="$1" field="$2"
    awk '/^---/{f++} f==1 && /^'"$field"':/{gsub(/^[^:]+: */,""); gsub(/^["'"'"']|["'"'"']$/,""); print; exit}' "$file"
}

has_frontmatter() {
    head -1 "$1" | grep -q '^---$'
}

# Счётчики
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

    # Подсчёт строк файла без frontmatter (убрать блок ---)
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

# HOT-статус
if [ $hot_lines -le $HOT_LIMIT ]; then
    hot_status="✅ ${hot_lines}/${HOT_LIMIT} строк"
else
    hot_status="❌ ${hot_lines}/${HOT_LIMIT} строк — ПРЕВЫШЕН"
fi

orphans_pct=0
[ $total -gt 0 ] && orphans_pct=$((orphans * 100 / total))

echo "## Memory Health Report"
echo ""
echo "| Метрика | Значение |"
echo "|---------|----------|"
echo "| Всего файлов memory/ | $total |"
echo "| Без frontmatter (orphans) | $orphans (${orphans_pct}%) |"
echo "| HOT | $hot_files файлов — $hot_status |"
echo "| WARM | $warm_files файлов |"
echo "| COLD | $cold_files файлов |"
echo "| archive | $archive_files файлов |"
echo "| status: superseded | $superseded |"
echo "| status: dormant | $dormant |"
echo "| Старейший (valid_from) | ${oldest_date} — ${oldest_file} |"
echo "| Новейший (valid_from) | ${newest_date} — ${newest_file} |"

if [ "$MODE" = "full" ]; then
    echo ""
    echo "### HOT-файлы (лимит ${HOT_LIMIT} строк)"
    echo ""
    echo "| Файл | Строк | Горизонт | Статус |"
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
    echo "⚠️  $orphans файлов без frontmatter — запустить \`memory-validate.sh\` для деталей"
fi
if [ $hot_lines -gt $HOT_LIMIT ]; then
    echo "❌ HOT-лимит превышен на $((hot_lines - HOT_LIMIT)) строк — перевести файлы в WARM"
fi
if [ $orphans -eq 0 ] && [ $hot_lines -le $HOT_LIMIT ]; then
    echo "✅ Все метрики в норме"
fi
