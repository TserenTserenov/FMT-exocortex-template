#!/usr/bin/env bash
# iwe-drift.sh — MVP drift-отчёт по .claude/sync-manifest.yaml
#
# WP-217 Ф3b, черновик 2026-04-10.
# НЕ переносить в scripts/ до ревью владельца.
#
# РОЛЬ (уточнение 10 апр): R23-детектор для пар (A(pair), M1 compliance
# «синхронны ли источник и производное»). Только ДЕТЕКЦИЯ, не применяет fix.
# Fix — отдельные операторные скрипты (R8 Синхронизатор):
#   template-sync.sh, update.sh, dt_sync.py.
# Правило: детектор отчитывается, оператор делает. Не смешивать.
#
# Usage:
#   bash iwe-drift.sh                  # полный отчёт
#   bash iwe-drift.sh --critical       # только critical
#   bash iwe-drift.sh --top N          # топ N по lag
#   bash iwe-drift.sh --manifest PATH  # указать путь к манифесту
#
# Требования: bash, git, stat, awk (POSIX). Без внешних зависимостей.
# Формат вывода: markdown-таблица, пригодная для вставки в DayPlan/Week Report.

set -eu

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
MANIFEST="${MANIFEST:-$IWE_ROOT/.claude/sync-manifest.yaml}"
MODE="all"
TOP_N=0

while [ $# -gt 0 ]; do
    case "$1" in
        --critical) MODE="critical"; shift ;;
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

# Получить mtime файла в днях от сегодня (macOS stat -f, Linux stat -c)
mtime_days_ago() {
    local path="$1"
    if [ ! -e "$path" ]; then
        echo "-1"
        return
    fi
    local mtime
    if stat -f %m "$path" >/dev/null 2>&1; then
        mtime=$(stat -f %m "$path")
    else
        mtime=$(stat -c %Y "$path")
    fi
    local now
    now=$(date +%s)
    echo $(( (now - mtime) / 86400 ))
}

# Получить самый свежий mtime в директории (рекурсивно)
dir_newest_mtime_days_ago() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        mtime_days_ago "$dir"
        return
    fi
    local newest
    newest=$(find "$dir" -type f -not -path '*/.git/*' -print0 2>/dev/null \
        | xargs -0 stat -f %m 2>/dev/null \
        | sort -nr | head -1)
    if [ -z "${newest:-}" ]; then
        echo "-1"
        return
    fi
    local now
    now=$(date +%s)
    echo $(( (now - newest) / 86400 ))
}

# Парсинг YAML (наивный, только для фиксированного формата этого манифеста)
parse_manifest() {
    local manifest="$1"
    awk '
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

# Собрать записи → строки markdown
collect() {
    local records_file="$1"

    while IFS=$'\t' read -r id source derived relation check thresh crit owner symptom; do
        [ -z "$id" ] && continue

        local src_path="$source"
        local dst_path="$derived"
        case "$src_path" in /*) ;; *) src_path="$IWE_ROOT/$src_path" ;; esac
        case "$dst_path" in /*) ;; *) dst_path="$IWE_ROOT/$dst_path" ;; esac

        local src_age dst_age lag status
        src_age=$(dir_newest_mtime_days_ago "$src_path")
        dst_age=$(dir_newest_mtime_days_ago "$dst_path")

        if [ "$src_age" -lt 0 ] || [ "$dst_age" -lt 0 ]; then
            lag="?"
            status="missing"
        else
            # lag = dst_age - src_age (положительный = derived отстаёт)
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

# Фильтрация
if [ "$MODE" = "critical" ]; then
    awk -F'\t' '$4 == "critical"' "$TMP_ROWS" > "$TMP_ROWS.filtered"
    mv "$TMP_ROWS.filtered" "$TMP_ROWS"
fi

# Сортировка по lag (numeric descending, '?' в конец)
sort -t$'\t' -k1,1 -rn "$TMP_ROWS" > "$TMP_ROWS.sorted"
mv "$TMP_ROWS.sorted" "$TMP_ROWS"

# Top-N
if [ "$TOP_N" -gt 0 ]; then
    head -n "$TOP_N" "$TMP_ROWS" > "$TMP_ROWS.top"
    mv "$TMP_ROWS.top" "$TMP_ROWS"
fi

# Вывод markdown-таблицы
echo "## Drift-отчёт ($(date +%Y-%m-%d))"
echo ""
if [ ! -s "$TMP_ROWS" ]; then
    echo "_Нет drift'а по выбранному фильтру._"
    exit 0
fi
echo "| lag (дней) | ID | relation | статус | владелец | симптом |"
echo "|---:|---|---|---|---|---|"
while IFS=$'\t' read -r lag id relation status owner symptom; do
    # иконка
    case "$status" in
        critical) icon="critical" ;;
        warn)     icon="warn" ;;
        ok)       icon="ok" ;;
        missing)  icon="missing" ;;
        *)        icon="$status" ;;
    esac
    printf "| %s | %s | %s | %s | %s | %s |\n" "$lag" "$id" "$relation" "$icon" "$owner" "$symptom"
done < "$TMP_ROWS"
