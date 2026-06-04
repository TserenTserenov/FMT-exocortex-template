#!/usr/bin/env bash
# response-clarity-hook.sh — детектор нарушений разговорного стиля (WP-388 Ф9)
#
# Тип: Stop hook (проверяет финальный ответ агента)
# Уровень: warning (nudge), не блокирует
# Лог: ~/.claude/logs/style-violations.log
#
# 4 проверки:
#   R3: путь к файлу как подлежащее предложения
#   R4: пассивный залог при ошибке/находке
#   L0.4: голые английские маркеры (exit 0, PASS, SHA)
#   R1: журнал процесса в начале ответа (Reading..., Checking..., Let me...)

set -euo pipefail

# Claude Code передаёт ответ через stdin (JSON с полем assistant_response)
# или через переменную окружения. Читаем stdin.
INPUT=$(cat)

# Извлекаем текст ответа (assistant_response из JSON)
RESPONSE=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    # Stop hook получает tool_input с assistant_response
    resp = data.get('assistant_response', '') or data.get('tool_input', {}).get('content', '') or ''
    print(resp)
except:
    print('')
" 2>/dev/null || echo "")

if [ -z "$RESPONSE" ]; then
    exit 0
fi

LOG_FILE="${HOME}/.claude/logs/style-violations.log"
mkdir -p "$(dirname "$LOG_FILE")"

VIOLATIONS=""
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

# --- R3: путь как подлежащее ---
# Паттерн: строка начинается с пути к файлу (backtick или без) + глагол
if echo "$RESPONSE" | grep -qE '^\s*`?[a-zA-Z_/.-]+\.(py|md|ts|sh|js|yaml|json)(:[0-9]+)?`?\s+(—|is|was|has|содержит|отвечает|обрабатывает|делает|создаёт|хранит|возвращает)'; then
    VIOLATIONS="${VIOLATIONS}R3:path-as-subject "
    echo "$TIMESTAMP | R3 | path-as-subject | $(echo "$RESPONSE" | grep -E '^\s*`?[a-zA-Z_/.-]+\.(py|md|ts|sh|js|yaml|json)' | head -1 | cut -c1-100)" >> "$LOG_FILE"
fi

# --- R4: пассивный залог при ошибке ---
if echo "$RESPONSE" | grep -qiE '(было обнаружено|было найдено|было выявлено|оказалось|выяснилось что|был(а|о)? (обнаружен|найден|выявлен|зафиксирован))'; then
    VIOLATIONS="${VIOLATIONS}R4:passive-voice "
    echo "$TIMESTAMP | R4 | passive-voice | $(echo "$RESPONSE" | grep -iE '(было обнаружено|было найдено|оказалось|выяснилось)' | head -1 | cut -c1-100)" >> "$LOG_FILE"
fi

# --- L0.4: голые английские маркеры ---
if echo "$RESPONSE" | grep -qE '(exit\s+0|\bPASS\b|\bFAIL\b|SHA:\s*[a-f0-9]{7,}|status:\s*done|status:\s*success)'; then
    VIOLATIONS="${VIOLATIONS}L0.4:bare-english-marker "
    echo "$TIMESTAMP | L0.4 | bare-english-marker | $(echo "$RESPONSE" | grep -E '\b(exit\s+0|PASS|FAIL|SHA:)' | head -1 | cut -c1-100)" >> "$LOG_FILE"
fi

# --- R1: журнал процесса ---
# Проверяем первые 3 строки ответа
FIRST_LINES=$(echo "$RESPONSE" | head -3)
if echo "$FIRST_LINES" | grep -qiE '(^(Reading|Checking|Looking|Searching|Let me|Сейчас (посмотрю|проверю|прочитаю)|Читаю|Проверяю|Ищу|Смотрю))'; then
    VIOLATIONS="${VIOLATIONS}R1:process-journal "
    echo "$TIMESTAMP | R1 | process-journal | $(echo "$FIRST_LINES" | grep -iE '(Reading|Checking|Let me|Сейчас|Читаю|Проверяю)' | head -1 | cut -c1-100)" >> "$LOG_FILE"
fi

# Если есть нарушения — вывести nudge (не блокировать)
if [ -n "$VIOLATIONS" ]; then
    echo "⚠️ Стиль: нарушения [${VIOLATIONS}] — подробности в ~/.claude/logs/style-violations.log"
fi

# Всегда выходим с 0 — это warning, не блок
exit 0
