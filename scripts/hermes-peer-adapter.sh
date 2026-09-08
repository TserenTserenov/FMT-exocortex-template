#!/usr/bin/env bash
# hermes-peer-adapter.sh — адаптер Hermes для peer-conversation (роль напарника)
# see DP.SC.154, DP.SC.167 (симметричный аналог claude-peer-adapter.sh)
# WP-392 Ф10, WP-509
#
# Вызывается агентом-ПИСАТЕЛЕМ (Claude, Kimi или другим) когда Hermes выступает НАПАРНИКОМ.
# Читает промпт из stdin, отправляет в Hermes через нативный CLI `hermes chat -q`,
# возвращает ответ в stdout.
#
# Использование (из скрипта агента-писателя):
#   bash scripts/hermes-peer-adapter.sh [--session-id "$HERMES_SESSION_ID"] \
#     < "${SESSION_DIR}/peer-prompt.md" > "$PEER_FILE" 2>/dev/null
# Промпт передаётся файлом, не inline `echo "$peer_prompt" | ...` — иначе текст
# промпта попадает в командную строку и хук B7.7c ложно блокирует повторные
# вызовы (bug-2026-06-30-peer-adapter-b77c-block).
#
# Переменные окружения:
#   HERMES_BIN         — путь к hermes CLI (default: first `hermes` in PATH)
#   HERMES_SESSION_ID  — ID сессии для продолжения диалога (опционально)
#   HERMES_MAX_TURNS   — лимит итераций (default: 1, peer-сессия не использует инструменты)

# Fail-closed: we deliberately inspect nonzero CLI exit codes below and
# normalize them to 1. Keeping `set -e` would abort the script before the
# normalization, so the adapter only runs with `set -uo pipefail`.
set -uo pipefail

HERMES_BIN="${HERMES_BIN:-$(command -v hermes 2>/dev/null || true)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HERMES_START_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

SESSION_ID="${HERMES_SESSION_ID:-}"
MAX_TURNS="${HERMES_MAX_TURNS:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id)
      [ $# -ge 2 ] || { echo "ERROR: --session-id requires a value" >&2; exit 1; }
      SESSION_ID="$2"; shift 2 ;;
    # WP-516 Ф5 (§0в.1): межвендорские флаги, которые hermes не поддерживает
    # (таблица §0в), отклоняются с явной диагностикой, не молчаливым игнором.
    -p|--model|--add-dir|--permission-mode)
      echo "ERROR: flag '$1' is not supported by hermes adapter (see vendor table §0в). Supported: --session-id" >&2
      exit 1
      ;;
    # Неизвестный флаг — явная ошибка (§0в.1).
    *)
      echo "ERROR: unknown flag '$1'. Known: --session-id" >&2
      exit 1
      ;;
  esac
done

if [ -z "$HERMES_BIN" ] || [ ! -x "$HERMES_BIN" ]; then
  echo "ERROR: hermes binary not found. Install Hermes Agent CLI or set HERMES_BIN env var." >&2
  exit 1
fi

# Читаем промпт из stdin
PROMPT=$(cat)

if [ -z "$PROMPT" ]; then
  echo "ERROR: empty prompt from stdin" >&2
  exit 1
fi

# === Запуск Hermes headless: `hermes chat -q ... -Q --max-turns 1` + 5min timeout ===
# -Q (quiet) убирает баннер/спиннер; --max-turns 1 ограничивает рамку одним ответом.
#
# WP-516 Ф5 (peer-session 2026-08-11-22-wp516-f5-contract-adapter): лимит
# транспорта hermes — 4000 символов (симметрия с оригинальным MCP-адаптером).
# Раньше промпт молча обрезался (head -c 4000) — напарник отвечал не на тот
# контекст, который отправил писатель (нарушение сохранности промпта, §0в.1).
# Теперь — явный отказ ДО запуска с диагностикой, без усечения.
# Override через HERMES_PROMPT_LIMIT возможен только ВНИЗ: лимит транспорта
# 4000 — свойство CLI, а не настройка; нечисловое значение → дефолт.
HERMES_PROMPT_LIMIT="${HERMES_PROMPT_LIMIT:-4000}"
case "$HERMES_PROMPT_LIMIT" in
  ''|*[!0-9]*) HERMES_PROMPT_LIMIT=4000 ;;
esac
# Снятие ведущих нулей + проверка длины ДО числового сравнения: огромное
# десятичное значение не должно уронить '[ -gt ]' переполнением (review-02).
HERMES_PROMPT_LIMIT=$(printf '%s' "$HERMES_PROMPT_LIMIT" | sed 's/^0*//')
[ -z "$HERMES_PROMPT_LIMIT" ] && HERMES_PROMPT_LIMIT=0
if [ "${#HERMES_PROMPT_LIMIT}" -gt 4 ] || [ "$HERMES_PROMPT_LIMIT" -gt 4000 ]; then
  HERMES_PROMPT_LIMIT=4000
fi
PROMPT_LEN=${#PROMPT}
if [ "$PROMPT_LEN" -gt "$HERMES_PROMPT_LIMIT" ]; then
  echo "ERROR: prompt is $PROMPT_LEN chars, exceeds hermes transport limit ($HERMES_PROMPT_LIMIT). Shorten the prompt or use another peer adapter. Refusing to truncate silently." >&2
  exit 1
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hermes-peer-XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

OUT_FILE="$TMP_ROOT/hermes-output.txt"

HERMES_ARGS=(chat -q "$PROMPT" -Q --max-turns "$MAX_TURNS")
if [ -n "$SESSION_ID" ]; then
  HERMES_ARGS+=(--resume "$SESSION_ID")
fi

perl -e 'alarm 300; exec @ARGV' -- "$HERMES_BIN" "${HERMES_ARGS[@]}" > "$OUT_FILE" 2>&1
PERL_EXIT=$?

if [ "$PERL_EXIT" -eq 142 ]; then
  echo "ERROR: Hermes peer call timed out after 5 minutes (SIGALRM)" >&2
  exit 1
fi

# WP-516 Ф5 (§0в.1, находка Codex 12.08): non-timeout ненулевой exit CLI
# обязан нормализоваться в 1 — иначе текст ошибки CLI в OUT_FILE принимался
# за успешный ответ пира.
if [ "$PERL_EXIT" -ne 0 ]; then
  echo "ERROR: Hermes peer call failed with exit code $PERL_EXIT (cli_exit=$PERL_EXIT)" >&2
  tail -20 "$OUT_FILE" >&2 2>/dev/null || true
  exit 1
fi

if [ ! -s "$OUT_FILE" ]; then
  echo "ERROR: hermes returned empty output" >&2
  exit 1
fi

# Убираем служебную строку session_id из начала ответа (hermes -Q всё ещё печатает session_id)
# и ведущие пустые строки, но сохраняем внутренние переносы.
RESPONSE=$(tail -n +2 "$OUT_FILE" | sed -e '/./,$!d')

# WP-516 Ф5 (§0в.1): stdout обязан начинаться с frontmatter; ответ без
# frontmatter = нарушение формата → exit 1 с диагностикой.
# Проверка — для peer-реплик turn-loop. Служебные вызовы писателя
# (review/verify/synth), чей вывод — НЕ peer-реплика, отключают её
# через IWE_PEER_PLAIN=1 (слой IWE-интеграции, §0в.1).
if [ "${IWE_PEER_PLAIN:-0}" != "1" ]; then
  # awk одним процессом: 'sed | head' под pipefail ловит SIGPIPE на длинной
  # валидной реплике и роняет адаптер без диагностики (review-02, WP-516 Ф5).
  _FIRST_LINE=$(printf '%s\n' "$RESPONSE" | awk 'length { print; exit }')
  _FM_FENCES=$(printf '%s\n' "$RESPONSE" | grep -c '^---$' || true)
  if [ "$_FIRST_LINE" != "---" ] || [ "${_FM_FENCES:-0}" -lt 2 ]; then
    echo "ERROR: peer response missing frontmatter (first non-empty line must be '---' with a closing '---')." >&2
    exit 1
  fi

  # WP-484 Ф89: alert-only self-check — доля кириллицы в ответе после
  # вычитания кода/путей/A2-глосс. Никогда не блокирует вывод, только
  # предупреждает в stderr — не peer-реплика (IWE_PEER_PLAIN=1) её не видит.
  _LANG_CHECK="$SCRIPT_DIR/lib/language-check.py"
  if [ -f "$_LANG_CHECK" ]; then
    _LANG_RESULT=$(printf '%s' "$RESPONSE" | python3 "$_LANG_CHECK" 2>/dev/null || true)
    if printf '%s' "$_LANG_RESULT" | grep -q '"alert": true'; then
      echo "WARNING: peer response may not be in Russian (language-check alert) — $_LANG_RESULT" >&2
    fi
  fi
fi

# === WP-454: write to agent-sessions journal (best-effort, non-blocking) ===
# Security: only timestamps and duration written — no content from RESPONSE.
{
  _HERMES_END_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  _SID="${SESSION_ID:-hermes-standalone-$$}"
  python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/lib')
from datetime import datetime
from agent_session_time import write_journal_entry

start_s, end_s, sid = sys.argv[1:4]
fmt = lambda s: datetime.fromisoformat(s.replace('Z', '+00:00'))
try:
    agent_h = round((fmt(end_s) - fmt(start_s)).total_seconds() / 3600, 4)
except ValueError:
    agent_h = 0.0
write_journal_entry('hermes', sid, start_s[:10], start_s, end_s, agent_active_h=agent_h)
" "$_HERMES_START_TIME" "$_HERMES_END_TIME" "$_SID"
} 2>/dev/null &

echo "$RESPONSE"
