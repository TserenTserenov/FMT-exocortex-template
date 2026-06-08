#!/usr/bin/env bash
# response-clarity-hook.sh — детектор нарушений разговорного стиля (WP-388 Ф5/Ф9)
#
# Тип: Stop hook (проверяет ответы агента в ЗАВЕРШЁННОМ ходу)
# Уровень: warning (nudge), не блокирует — всегда exit 0
# Лог: ~/.claude/logs/style-violations.log
# Формат строки (контракт WP-388): TIMESTAMP | agent | A-rule | description | context(redacted)
#
# Детерминированные правила (консенсус peer-session 2026-06-04-56):
#   A1   путь к файлу как подлежащее предложения
#   A8   журнал процесса в начале ответа (Reading…, Проверяю…)
#   A10  голые английские маркеры статуса (exit 0, PASS, SHA, status: done)
#   BASE5 длинное тире вне конструкции «— это» (базовое правило стиля #5)
#
# A11 (пассивный залог) — НЕ ловится: высокий риск ложных срабатываний,
# отложен до ручной калибровки на данных недели обкатки (см. WP-388 Ф6).
#
# Вход: Stop-хук Claude Code передаёт JSON со stdin, поле transcript_path
# указывает на JSONL-стенограмму. assistant_response в Stop НЕ передаётся —
# поэтому извлекаем текст ассистента текущего хода из стенограммы.

set -euo pipefail

AGENT="claude-code"
INPUT=$(cat)
if [ -z "$INPUT" ]; then exit 0; fi

# Guard от рекурсии: если хук уже активен — выходим
STOP_HOOK_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then exit 0; fi

TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then exit 0; fi

# session_id для счётчика нарушений за сессию (peer-session 2026-06-08-23)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo unknown)
SESSION_ID=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-'); [ -n "$SESSION_ID" ] || SESSION_ID="unknown"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
COUNT_DIR="$PROJECT_DIR/.claude/state"
COUNT_FILE="$COUNT_DIR/style-violations-count-$SESSION_ID"

# --- Текст ассистента ТЕКУЩЕГО хода ---
# Один ход = несколько JSONL-записей (text / tool_use / text). Берём все
# assistant text-блоки после последнего user-сообщения, склеиваем. Разбор —
# одним проходом на Python (надёжнее поэлементного shell + jq под set -e).
RESPONSE=$(TRANSCRIPT_PATH="$TRANSCRIPT_PATH" python3 <<'PY' 2>/dev/null || echo ""
import json, os
path = os.environ["TRANSCRIPT_PATH"]
rows = []
with open(path, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except Exception:
            continue

def role_of(r):
    return r.get("type") or r.get("role") or ""

# индекс последнего user-сообщения; всё после — текущий ход
last_user = -1
for i, r in enumerate(rows):
    if role_of(r) == "user":
        last_user = i

out = []
for r in rows[last_user + 1:]:
    if role_of(r) != "assistant":
        continue
    content = r.get("message", {}).get("content", r.get("content", []))
    if isinstance(content, str):
        out.append(content)
    elif isinstance(content, list):
        for blk in content:
            if isinstance(blk, dict) and blk.get("type") == "text":
                out.append(blk.get("text", ""))
print("\n".join(out))
PY
)

if [ -z "$RESPONSE" ]; then exit 0; fi

LOG_FILE="${HOME}/.claude/logs/style-violations.log"
mkdir -p "$(dirname "$LOG_FILE")"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
VIOLATIONS=""

# redact: обрезать до 100 символов, замаскировать токены (в т.ч. короткие
# провайдерские), заменить разделитель | чтобы не ломать парсер агрегатора
redact() {
  printf '%s' "$1" | tr '\n' ' ' | cut -c1-100 \
    | sed -E 's/(gh[pousr]_|sk-|xox[baprs]-|AKIA)[A-Za-z0-9_-]+/<REDACTED>/g; s/[A-Za-z0-9_-]{32,}/<REDACTED>/g; s/[a-f0-9]{16,}/<REDACTED>/g; s/\|/¦/g'
}

log_violation() {
  local rule="$1" desc="$2" example="$3"
  VIOLATIONS="${VIOLATIONS}${rule} "
  echo "$TIMESTAMP | $AGENT | $rule | $desc | $(redact "$example")" >> "$LOG_FILE"
}

# --- A1: путь к файлу как подлежащее ---
A1_MATCH=$(printf '%s\n' "$RESPONSE" | grep -E '^\s*`?[A-Za-z0-9_/.-]+\.(py|md|ts|sh|js|yaml|json)(:[0-9]+)?`?\s+(—|is|was|has|содержит|отвечает|обрабатывает|делает|создаёт|хранит|возвращает|пишет|читает)' | head -1 || true)
[ -n "$A1_MATCH" ] && log_violation "A1" "path-as-subject" "$A1_MATCH"

# --- A10: голые английские маркеры статуса ---
# exit 0 / SHA: / status: done — детерминированы. PASS/FAIL ловим только в
# тест-контексте (рядом тест/smoke/проверка/G-гейт) — иначе ложный позитив
# на обычное слово («полный FAIL»).
A10_MATCH=$(printf '%s\n' "$RESPONSE" | grep -E '(\bexit\s+0\b|SHA:\s*[a-f0-9]{7,}|status:\s*(done|success)|\bG[0-9]\s+(PASS|FAIL)\b|(smoke|тест[а-я]*|проверк[а-я]*)\s*:\s*(PASS|FAIL)\b|`(PASS|FAIL)`)' | head -1 || true)
[ -n "$A10_MATCH" ] && log_violation "A10" "bare-english-marker" "$A10_MATCH"

# --- A8: журнал процесса в начале строки ответа ---
# Проверяем начало КАЖДОЙ строки склейки: один ход = несколько text-блоков,
# каждый начинается с новой строки; промежуточное «Проверяю…» перед tool-call
# попадёт в начало своей строки (кейс, важный по консенсусу с Kimi).
A8_MATCH=$(printf '%s\n' "$RESPONSE" | grep -iE '^(Reading|Checking|Looking|Searching|Let me|Сейчас (посмотрю|проверю|прочитаю)|Читаю|Проверяю|Ищу|Смотрю)' | head -1 || true)
[ -n "$A8_MATCH" ] && log_violation "A8" "process-journal" "$A8_MATCH"

# --- BASE5: длинное тире вне конструкции «— это» ---
if printf '%s' "$RESPONSE" | grep -q '—'; then
  if printf '%s' "$RESPONSE" | perl -CSD -Mutf8 -0777 -ne 'exit(/—(?!\s*это)/ ? 1 : 0)' 2>/dev/null; then
    : # все тире в конструкции «— это»
  else
    BASE5_MATCH=$(printf '%s\n' "$RESPONSE" | grep '—' | head -1 || true)
    [ -n "$BASE5_MATCH" ] && log_violation "BASE5" "em-dash-outside-eto" "$BASE5_MATCH"
  fi
fi

# --- Реакция на нарушения (peer-session 2026-06-08-23) ---
# Два режима. По умолчанию warning (как было). STYLE_ENFORCE_BLOCK=1 включает
# блокирующий режим для правил высокой уверенности (A1/A10): Stop-хук просит
# переписать ответ со строкой-исправлением STYLE_FIX. BASE5/A8 НЕ блокируют
# (BASE5 слишком частое; «авто-фикс» уже показанного текста невозможен).
# В шаблоне флаг по умолчанию выключен — у нового пользователя ещё нет лога
# для калибровки точности (гейт промоции ≥90% precision).
if [ -z "$VIOLATIONS" ]; then exit 0; fi

# Счётчик нарушений за сессию
mkdir -p "$COUNT_DIR"
COUNT=0; [ -f "$COUNT_FILE" ] && COUNT=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1)); echo "$COUNT" > "$COUNT_FILE"
# Cleanup старых счётчиков (>24h)
find "$COUNT_DIR" -name "style-violations-count-*" -mmin +1440 -delete 2>/dev/null || true

# Блокируемые правила высокой уверенности
BLOCKABLE=""
printf '%s' "$VIOLATIONS" | grep -qE '\bA1\b'  && BLOCKABLE="$BLOCKABLE A1"
printf '%s' "$VIOLATIONS" | grep -qE '\bA10\b' && BLOCKABLE="$BLOCKABLE A10"

ESC_NOTE=""
[ "$COUNT" -ge 3 ] && ESC_NOTE=" | 3+ нарушений стиля за сессию (сигнал пилоту)"

if [ "${STYLE_ENFORCE_BLOCK:-0}" = "1" ] && [ -n "$BLOCKABLE" ]; then
  REASON="Стиль нарушен (правила:${BLOCKABLE} ). Перепиши ответ для пилота. Начни СЛЕДУЮЩЕЕ сообщение со строки коррекции — STYLE_FIX:${BLOCKABLE} «было» → «стало» — затем полезный текст. Правила: A1 путь не подлежащее; A10 без голых маркеров (exit/PASS/SHA).${ESC_NOTE}"
  jq -n --arg r "$REASON" '{"decision":"block","reason":$r}'
  exit 0
fi

# Warning-режим (не блокирует)
echo "⚠️ Стиль: нарушения [${VIOLATIONS}]${ESC_NOTE} — подробности в ~/.claude/logs/style-violations.log"
exit 0
