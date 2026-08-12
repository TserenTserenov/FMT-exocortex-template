#!/usr/bin/env bash
# check-status-legend.sh — детектор рассогласования легенды статусов WP и format compliance в REGISTRY
# Owner: WP-217 (механизм sync). Активирован WP-267 (child) после bug в linear-sync.sh 25 апр.
# Принцип: детектор отчитывается, не правит (см. iwe-drift.sh:11).
#
# Что проверяет (3 invariant'а):
#   I1. **Legend completeness:** все статус-эмодзи, встречающиеся в таблице WP-REGISTRY.md,
#       задокументированы в легенде вверху файла. Новый эмодзи без записи в легенде → DRIFT.
#   I2. **Format compliance — active id:** строки с plain id `| <num> |` имеют active статус
#       (НЕ из терминального множества {✅, 📦, ↗️, ❌}).
#   I3. **Format compliance — terminal id:** строки с crossed id `| ~~<num>~~ |` имеют
#       терминальный статус из {✅, 📦, ↗️, ❌}.
#
# I2 + I3 — invariant id-format ↔ status (см. .claude/rules/formatting.md «Таблицы с РП»).
# Сломан = расхождение row-format и status, что ломает счётчики (linear-sync.sh, day-close.sh).
#
# Usage:
#   bash check-status-legend.sh                 # полный отчёт
#   bash check-status-legend.sh --critical-only # только нарушения
#   IWE_ROOT=/path bash check-status-legend.sh
#
# Не зависит от iwe-drift.sh — может быть запущен отдельно. Когда iwe-drift.sh научится
# диспатчить `check: script:...` пары, он будет вызывать этот скрипт автоматически.

set -eu

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.claude/lib/iwe-env-bootstrap.sh" || exit 1
REGISTRY="${REGISTRY:-$IWE_ROOT/${IWE_GOVERNANCE_REPO:-}/docs/WP-REGISTRY.md}"
MODE="${MODE:-all}"

# Терминальные статусы — закрытие РП. Источник: легенда WP-REGISTRY.md.
# Изменение этого списка = архитектурное решение об эволюции lifecycle РП.
TERMINAL_STATUSES=("✅" "📦" "↗️" "❌")

while [ $# -gt 0 ]; do
    case "$1" in
        --critical-only) MODE="critical"; shift ;;
        --registry) REGISTRY="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# //; s/^#//' | head -30
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ ! -f "$REGISTRY" ]; then
    echo "REGISTRY not found: $REGISTRY" >&2
    exit 1
fi

# Извлечь множество эмодзи из легенды.
# Поддерживаются обе поставляемые формы: «Статус | Расшифровка» и
# «Эмодзи | Статус | Что значит». Заголовок определяет колонку с emoji.
# Возвращает по одному эмодзи на строку.
extract_legend_emojis() {
    awk '
        function trim(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }
        /^\|/ {
            n = split($0, fields, "|")
            if (in_legend == 0) {
                for (i = 2; i < n; i++) {
                    header = trim(fields[i])
                    if (header == "Эмодзи") emoji_col = i
                    if (header == "Расшифровка") has_description = 1
                    if (header == "Статус") status_col = i
                }
                if (emoji_col > 0 || (status_col > 0 && has_description)) {
                    if (emoji_col == 0) emoji_col = status_col
                    in_legend = 1
                    next
                }
            }
        }
        in_legend && /^\|---/ { next }
        in_legend && /^\|/ {
            n = split($0, fields, "|")
            if (n >= emoji_col) {
                emoji = trim(fields[emoji_col])
                if (emoji != "") print emoji
            }
            next
        }
        in_legend && /^[^|]/ { in_legend = 0 }
    ' "$REGISTRY"
}

# Извлечь множество эмодзи из колонки «Ст»/«Статус» в таблице WP.
# Колонка определяется по заголовку: порядок колонок — настраиваемая часть
# реестра, поэтому фиксированный индекс здесь давал ложные нарушения.
# Возвращает по одному эмодзи на строку (с дубликатами — кому надо, тот фильтрует sort -u).
extract_table_emojis() {
    awk '
        function trim(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }
        /^\|/ {
            n = split($0, fields, "|")
            if (trim(fields[2]) == "#") status_col = 0
            if (status_col == 0) {
                for (i = 2; i < n; i++) {
                    header = trim(fields[i])
                    if (header == "Ст" || header == "Статус") {
                        status_col = i
                        next
                    }
                }
            }
        }
        /^\|[[:space:]]*(~~)?[0-9]+/ {
            n = split($0, fields, "|")
            if (status_col > 0 && n >= status_col) {
                status = trim(fields[status_col])
                gsub(/~~/, "", status)
                if (status != "") print status
            }
        }
    ' "$REGISTRY"
}

# Извлечь пары (id_format, status) для format compliance check.
# id_format: "active" если plain `| 263 |`, "terminal" если crossed `| ~~263~~ |`.
extract_id_status_pairs() {
    awk '
        function trim(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }
        /^\|/ {
            n = split($0, fields, "|")
            if (trim(fields[2]) == "#") status_col = 0
            if (status_col == 0) {
                for (i = 2; i < n; i++) {
                    header = trim(fields[i])
                    if (header == "Ст" || header == "Статус") {
                        status_col = i
                        next
                    }
                }
            }
        }
        /^\|[[:space:]]*(~~)?[0-9]+/ {
            n = split($0, fields, "|")
            if (status_col == 0 || n < status_col) next
            id_field = fields[2]
            status_field = fields[status_col]
            id_field = trim(id_field)
            status_field = trim(status_field)
            gsub(/~~/, "", status_field)

            if (match(id_field, /^~~[0-9]+~~$/)) {
                id_format = "terminal"
                gsub(/~~/, "", id_field)
            } else if (match(id_field, /^[0-9]+$/)) {
                id_format = "active"
            } else {
                next  # некорректный формат, пропускаем
            }

            print id_field "\t" id_format "\t" status_field
        }
    ' "$REGISTRY"
}

# Множество терминальных статусов как regex
is_terminal_status() {
    local s="$1"
    for t in "${TERMINAL_STATUSES[@]}"; do
        if [ "$s" = "$t" ]; then
            return 0
        fi
    done
    return 1
}

# Шаг 1: Legend completeness (I1)
TMP_LEGEND=$(mktemp)
TMP_TABLE=$(mktemp)
TMP_VIOLATIONS=$(mktemp)
trap 'rm -f "$TMP_LEGEND" "$TMP_TABLE" "$TMP_VIOLATIONS"' EXIT

extract_legend_emojis > "$TMP_LEGEND"
extract_table_emojis | sort -u > "$TMP_TABLE"

undocumented_count=0
while IFS= read -r emoji; do
    [ -z "$emoji" ] && continue
    if ! grep -qxF "$emoji" "$TMP_LEGEND"; then
        printf "| I1 | undocumented-status | %s | Эмодзи встречается в таблице, но отсутствует в легенде |\n" "$emoji" >> "$TMP_VIOLATIONS"
        undocumented_count=$((undocumented_count + 1))
    fi
done < "$TMP_TABLE"

# Шаг 2 & 3: Format compliance (I2, I3)
mismatch_count=0
ok_count=0
while IFS=$'\t' read -r wp_id id_format status; do
    [ -z "$wp_id" ] && continue
    if [ "$id_format" = "active" ]; then
        # active id → status НЕ должен быть terminal
        if is_terminal_status "$status"; then
            printf "| I2 | active-id-with-terminal-status | WP-%s | id=plain но status=%s (terminal). Должно быть ~~%s~~ |\n" "$wp_id" "$status" "$wp_id" >> "$TMP_VIOLATIONS"
            mismatch_count=$((mismatch_count + 1))
        else
            ok_count=$((ok_count + 1))
        fi
    elif [ "$id_format" = "terminal" ]; then
        # terminal id → status ДОЛЖЕН быть terminal
        if ! is_terminal_status "$status"; then
            printf "| I3 | terminal-id-with-active-status | WP-%s | id=~~%s~~ но status=%s (active). Раскрестить или сменить статус |\n" "$wp_id" "$wp_id" "$status" >> "$TMP_VIOLATIONS"
            mismatch_count=$((mismatch_count + 1))
        else
            ok_count=$((ok_count + 1))
        fi
    fi
done < <(extract_id_status_pairs)

# Шаг 4: вывод
echo "## WP-status legend drift report ($(date +%Y-%m-%d))"
echo ""
echo "Source: WP-267 child WP-217. Manifest pair: \`wp-status-legend-drift\`."
echo "REGISTRY: $REGISTRY"
echo ""

if [ "$MODE" != "critical" ]; then
    echo "### Легенда (источник истины)"
    echo ""
    echo '```'
    cat "$TMP_LEGEND"
    echo '```'
    echo ""
    echo "Терминальные статусы (hardcoded в скрипте): ${TERMINAL_STATUSES[*]}"
    echo "Active = всё остальное из легенды. Любой новый статус по умолчанию active."
    echo ""
fi

if [ -s "$TMP_VIOLATIONS" ]; then
    echo "### Нарушения"
    echo ""
    echo "| invariant | тип | объект | детали |"
    echo "|---|---|---|---|"
    cat "$TMP_VIOLATIONS"
    echo ""
fi

# Сводка
echo "### Сводка"
echo ""
echo "- ✅ format-compliance OK: $ok_count"
echo "- ⚠️ undocumented status emoji (I1): $undocumented_count"
echo "- ⚠️ format-compliance violations (I2+I3): $mismatch_count"

if [ "$undocumented_count" -gt 0 ] || [ "$mismatch_count" -gt 0 ]; then
    exit 2
fi
