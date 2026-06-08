#!/bin/bash
# inject-communication-style.sh
# Event: UserPromptSubmit
# see DP.SC.050 (обещание «Единый разговорный стиль агентов»), WP-388 Ф8
#
# Назначение: доставить L0 базовый разговорный стиль (SoT в Pack) + L1 авторские
#             надстройки в контекст Claude Code ПЕРЕД ответом. Заменяет хрупкую
#             вклейку маркер-блока в генерируемые CLAUDE.md / AGENTS.md (которые
#             перезаписываются template-sync.sh / sync-agent-instructions.sh).
#
# Архитектура (WP-388 Ф8, АрхГейт пройден):
#   L0 = PACK-digital-platform/.../02-domain-entities/communication-style-base.md (read-only)
#   L1 = ${IWE_GOVERNANCE_REPO:-DS-strategy}/memory/communication-style-author.md (additive-only)
#   Доставка = этот хук (UserPromptSubmit). Генерируемые файлы не трогаются.
#
# Поведение (density-based reinjection, peer-session 2026-06-08-23):
# - Освежается по ходу сессии: первый ход + при росте переписки (не один раз)
# - L0-файл отсутствует → silent skip (echo '{}')
# - L1-файл отсутствует → инжектим только L0
# - Пороги: STYLE_REINJECT_TURNS (12), STYLE_REINJECT_BYTES (60000)

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# jq нужен для вывода JSON. Нет jq → тихий валидный '{}', не пустой stdout (иначе Claude Code не распарсит).
command -v jq >/dev/null 2>&1 || { echo '{}'; exit 0; }

INPUT=$(cat 2>/dev/null || echo '{}')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
# Пустой/битый id → unknown; санитизация против path traversal в имени state-файла
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"
SESSION_ID=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
STATE_DIR="$PROJECT_DIR/.claude/state"
STATE_FILE="$STATE_DIR/comm-style-injected-$SESSION_ID"

# Density-based reinjection: впрыск НЕ один раз за сессию, а освежается по ходу.
# Триггер: первый ход ИЛИ прошло >= N ходов ИЛИ выросло >= M байт стенограммы.
REINJECT_EVERY_TURNS="${STYLE_REINJECT_TURNS:-12}"
REINJECT_BYTES="${STYLE_REINJECT_BYTES:-60000}"

# Текущий объём контекста — размер стенограммы (если харнесс её передал)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
CUR_BYTES=0
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  CUR_BYTES=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ' || echo 0)
  [ -n "$CUR_BYTES" ] || CUR_BYTES=0
fi

# Состояние: "turn last_inject_turn last_inject_bytes"
TURN=0; LAST_INJECT_TURN=0; LAST_INJECT_BYTES=0
if [ -f "$STATE_FILE" ]; then
  read -r TURN LAST_INJECT_TURN LAST_INJECT_BYTES < "$STATE_FILE" 2>/dev/null || true
  [ -n "${TURN:-}" ] || TURN=0
  [ -n "${LAST_INJECT_TURN:-}" ] || LAST_INJECT_TURN=0
  [ -n "${LAST_INJECT_BYTES:-}" ] || LAST_INJECT_BYTES=0
fi
TURN=$((TURN + 1))

DO_INJECT=0
if [ ! -f "$STATE_FILE" ]; then
  DO_INJECT=1                                                   # первый ход
elif [ $((TURN - LAST_INJECT_TURN)) -ge "$REINJECT_EVERY_TURNS" ]; then
  DO_INJECT=1                                                   # по числу ходов
elif [ "$CUR_BYTES" -gt 0 ] && [ $((CUR_BYTES - LAST_INJECT_BYTES)) -ge "$REINJECT_BYTES" ]; then
  DO_INJECT=1                                                   # по объёму переписки
fi

# Не пора впрыскивать — обновить счётчик хода и выйти
if [ "$DO_INJECT" -eq 0 ]; then
  mkdir -p "$STATE_DIR"
  echo "$TURN $LAST_INJECT_TURN $LAST_INJECT_BYTES" > "$STATE_FILE"
  echo '{}'
  exit 0
fi

L0_FILE="$PROJECT_DIR/PACK-digital-platform/pack/digital-platform/02-domain-entities/communication-style-base.md"
L1_FILE="$PROJECT_DIR/${IWE_GOVERNANCE_REPO:-DS-strategy}/memory/communication-style-author.md"

if [ ! -f "$L0_FILE" ]; then
  echo '{}'
  exit 0
fi

# Убрать YAML frontmatter (всё до второго '---')
strip_fm() {
  if head -1 "$1" 2>/dev/null | grep -q '^---$'; then
    awk 'NR==1{next} /^---$/ && !d {d=1; next} d{print}' "$1"
  else
    cat "$1"
  fi
}

L0_BODY=$(strip_fm "$L0_FILE")
if [ -z "$L0_BODY" ]; then
  echo '{}'
  exit 0
fi

L1_BODY=""
if [ -f "$L1_FILE" ]; then
  L1_BODY=$(strip_fm "$L1_FILE")
fi

CONTEXT="## 🗣 Разговорный стиль IWE (L0 база + L1 автор) — применять при ответе человеку

Источник истины: \`DP.SC.050\` (Pack). Канал-детектор: технический режим — для стенограмм/commit/PR; «на пальцах» — для чата с пилотом и §1-§4 синтеза report.md.

$L0_BODY"

if [ -n "$L1_BODY" ]; then
  CONTEXT="$CONTEXT

### L1 — авторские надстройки пилота (additive-only, не отменяют L0)

$L1_BODY"
fi

# Записать state: текущий ход = последний впрыск, запомнить байты стенограммы
mkdir -p "$STATE_DIR"
echo "$TURN $TURN $CUR_BYTES" > "$STATE_FILE"

# Cleanup старых state-файлов (>24h)
find "$STATE_DIR" -name "comm-style-injected-*" -mmin +1440 -delete 2>/dev/null || true

# JSON для Claude Code UserPromptSubmit hook
jq -n --arg ctx "$CONTEXT" '{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": $ctx
  }
}'
