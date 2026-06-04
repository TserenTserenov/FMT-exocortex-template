#!/usr/bin/env bash
# style-check-post-run.sh — проверка стиля ответа Kimi после peer-сессии (WP-388 Ф9)
#
# Запуск: вызывается из kimi-peer-adapter.sh или вручную
#   bash scripts/style-check-post-run.sh <report-file>
#
# Проверяет report.md на нарушения L0+L1 правил стиля.
# Пишет нарушения в ~/.iwe/style-violations.log (общий с Claude).
# Уровень: warning, не блокирует commit.

set -euo pipefail

REPORT_FILE="${1:-}"
if [ -z "$REPORT_FILE" ] || [ ! -f "$REPORT_FILE" ]; then
    echo "Usage: style-check-post-run.sh <report-file.md>"
    exit 0
fi

LOG_FILE="${HOME}/.iwe/style-violations.log"
mkdir -p "$(dirname "$LOG_FILE")"

TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
AGENT="kimi"
VIOLATIONS=0

check_and_log() {
    local rule="$1"
    local description="$2"
    local pattern="$3"
    local context

    if context=$(grep -nP "$pattern" "$REPORT_FILE" 2>/dev/null | head -3); then
        if [ -n "$context" ]; then
            VIOLATIONS=$((VIOLATIONS + 1))
            echo "$TIMESTAMP | $AGENT | $rule | $description | $(echo "$context" | head -1 | cut -c1-120)" >> "$LOG_FILE"
            echo "  ⚠️  $rule: $description"
        fi
    fi
}

echo "Проверяю стиль: $(basename "$REPORT_FILE")"

# R3: путь как подлежащее (в секциях §1-§4, не в стенограммах)
check_and_log "R3" "путь как подлежащее" '^\s*`?[a-zA-Z_/.-]+\.(py|md|ts|sh|js|yaml|json)(:[0-9]+)?`?\s+(—|содержит|отвечает|обрабатывает|делает|создаёт|хранит)'

# R4: пассивный залог
check_and_log "R4" "пассивный залог" '(было обнаружено|было найдено|было выявлено|оказалось|выяснилось что|был(а|о)? (обнаружен|найден|выявлен))'

# L0.4: голые английские маркеры
check_and_log "L0.4" "голый английский маркер" '\b(exit\s+0|PASS|FAIL|SHA:\s*[a-f0-9]{7,}|status:\s*done)\b'

# R1: журнал процесса
check_and_log "R1" "журнал процесса" '^(Reading|Checking|Looking|Searching|Let me|Сейчас (посмотрю|проверю|прочитаю)|Читаю файл|Проверяю|Ищу|Смотрю)'

# L0.1: служебные метки в секциях §1-§4
check_and_log "L0.1" "служебная метка в синтезе" '(FORM\.[0-9]+|B7\.[0-9]|WP-[0-9]+ (cutover|Ф[0-9]|done))'

if [ "$VIOLATIONS" -gt 0 ]; then
    echo "Найдено нарушений: $VIOLATIONS (подробности в $LOG_FILE)"
else
    echo "Нарушений стиля не найдено ✅"
fi

exit 0
