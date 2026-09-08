#!/bin/bash
# inject-code-style.sh
# Event: PreToolUse (matcher: Edit|Write)
# see DP.SC.172 (обещание «База инженерного стиля кода»), WP-408 Ф3
#
# Назначение: впрыснуть ядро L0 (P0-P5) + L1-надстройки в контекст агента ПЕРЕД
#   правкой код-файла. Зеркало inject-communication-style.sh, но ось — код и
#   событие — PreToolUse (правится код), а не UserPromptSubmit (любой ответ).
#
# Контракт композиции хуков стиля (delta-ArchGate WP-408, инвариант):
#   1. Хуки стиля не знают друг о друге.
#   2. State-файл с ПРЕФИКСОМ code-style-injected-* (НЕ comm-style-injected-*).
#   3. Контексты аддитивны — только добавляем additionalContext.
#
# Поведение:
# - Фильтр по расширению: только код-файлы (.py/.ts/.js/.tsx/.jsx/.sh/.go/.rs/...).
#   Доки (.md/.txt/.yaml/.json/.toml) → silent skip (echo '{}').
# - Впрыск ТОЛЬКО ядра между маркерами CODE-STYLE-INJECT-START/END (лимит
#   PreToolUse additionalContext = 10000 симв; хард-кап 9500 на склейку L0+L1).
# - Density-reinject: первый code-touch + по росту переписки/ходов (как comm-хук).
# - L0 отсутствует → silent skip. L1 отсутствует → только L0.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

command -v jq >/dev/null 2>&1 || { echo '{}'; exit 0; }

INPUT=$(cat 2>/dev/null || echo '{}')

# Фильтр по расширению: впрыск только при правке КОД-файла
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
case "$FILE_PATH" in
  *.py|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.sh|*.bash|*.go|*.rs|*.rb|*.java|*.kt|*.c|*.h|*.cpp|*.hpp|*.sql) : ;;
  *) echo '{}'; exit 0 ;;   # не код — не впрыскиваем
esac

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"
SESSION_ID=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
STATE_DIR="$PROJECT_DIR/.claude/state"
STATE_FILE="$STATE_DIR/code-style-injected-$SESSION_ID"   # префикс ≠ comm-style

REINJECT_EVERY_TURNS="${CODE_STYLE_REINJECT_TURNS:-12}"
REINJECT_BYTES="${CODE_STYLE_REINJECT_BYTES:-60000}"
HARD_CAP="${CODE_STYLE_INJECT_CAP:-9500}"   # запас под лимит PreToolUse 10000

TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
CUR_BYTES=0
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  CUR_BYTES=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ' || echo 0)
  [ -n "$CUR_BYTES" ] || CUR_BYTES=0
fi

TURN=0; LAST_INJECT_TURN=0; LAST_INJECT_BYTES=0
if [ -f "$STATE_FILE" ]; then
  read -r TURN LAST_INJECT_TURN LAST_INJECT_BYTES < "$STATE_FILE" 2>/dev/null || true
  [ -n "${TURN:-}" ] || TURN=0
  [ -n "${LAST_INJECT_TURN:-}" ] || LAST_INJECT_TURN=0
  [ -n "${LAST_INJECT_BYTES:-}" ] || LAST_INJECT_BYTES=0
  # битый/подделанный state (нечисло) под set -u уронил бы $(( )) с пустым stdout
  case "$TURN$LAST_INJECT_TURN$LAST_INJECT_BYTES" in *[!0-9]*) TURN=0; LAST_INJECT_TURN=0; LAST_INJECT_BYTES=0 ;; esac
fi
TURN=$((TURN + 1))

DO_INJECT=0
if [ ! -f "$STATE_FILE" ]; then
  DO_INJECT=1                                                     # первый code-touch
elif [ $((TURN - LAST_INJECT_TURN)) -ge "$REINJECT_EVERY_TURNS" ]; then
  DO_INJECT=1
elif [ "$CUR_BYTES" -gt 0 ] && [ $((CUR_BYTES - LAST_INJECT_BYTES)) -ge "$REINJECT_BYTES" ]; then
  DO_INJECT=1
fi

if [ "$DO_INJECT" -eq 0 ]; then
  mkdir -p "$STATE_DIR"
  echo "$TURN $LAST_INJECT_TURN $LAST_INJECT_BYTES" > "$STATE_FILE"
  echo '{}'
  exit 0
fi

# Контент: диспетчер реестра (если доступен) → файл-снимок p05-core.md → пропуск.
# Диспетчер: WP-412 Ф6 (тонкий хук с каскадом L0+L1). Путь к нему через PROJECT_DIR.
# Файл-снимок: WP-412 Ф11 (FMT-fallback, самодостаточен). Путь через BASH_SOURCE — работает в env -i.
# Рантайм-механика (переинъекция, кап, state, silent-skip) остаётся в хуке. Откат: git revert.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P05_CORE="$HOOK_DIR/../styles/p05-core.md"

DISPATCHER="$PROJECT_DIR/PACK-rhetoric/pack/language-style/registry/dispatcher.py"
if [ -f "$DISPATCHER" ]; then
  FRAGMENT=$(python3 "$DISPATCHER" --event pretooluse-edit --quiet --no-cache 2>/dev/null)
fi

# Если диспетчер не дал контент — читаем файл-снимок (обрезаем frontmatter между --- --- )
if [ -z "${FRAGMENT:-}" ] && [ -f "$P05_CORE" ]; then
  FRAGMENT=$(awk '/^---/{n++; if(n==2){found=1; next}} found' "$P05_CORE" 2>/dev/null)
fi

[ -n "${FRAGMENT:-}" ] || { echo '{}'; exit 0; }   # оба источника пусты/упали → пропуск (safe)

CONTEXT="## 🔧 Инженерный стиль кода IWE (L0 база + L1 автор) — применять при написании/правке кода

Источник истины: \`DP.SC.172\` (Pack). Перечень запахов с «было/стало». Вкус = отсутствие запахов. Детектор контекста: «есть ли у кода будущий читатель?» Да → P1-P5 обязательны.

$FRAGMENT"

# Хард-кап: считаем и обрезаем в Unicode-символах. `wc -c` считал байты,
# тогда как Python ниже срезает символы: на кириллице это давало ложное
# превышение капа и добавляло маркер обрезки к уже допустимому контексту.
# (За пределами этого блока CUR_BYTES намеренно остаётся байтовым счётчиком:
# это отдельный порог роста transcript для переинъекции.)
if ! CTX_LEN=$(printf '%s' "$CONTEXT" | python3 -c 'import sys; print(len(sys.stdin.read()))'); then
  echo '{}'
  exit 0
fi
if [ "$CTX_LEN" -gt "$HARD_CAP" ]; then
  echo "inject-code-style: context $CTX_LEN > cap $HARD_CAP — обрезаю по предложению" >&2
  CONTEXT=$(CTX="$CONTEXT" CAP="$HARD_CAP" python3 - <<'PY'
import os
ctx = os.environ["CTX"]
cap = int(os.environ["CAP"])
clipped = ctx[:cap]
# откатиться к последней границе предложения/абзаца, чтобы не рвать правило
fence = chr(96) * 3 + "\n"   # тройная обратная кавычка без литерала (ломает парсер bash в $())
m = max(clipped.rfind(". "), clipped.rfind(".\n"), clipped.rfind("\n\n"), clipped.rfind(fence))
if m > 0:
    clipped = clipped[:m + 1]
print(clipped.rstrip() + "\n\n[…обрезано до лимита; полный текст — DP.SC.172 в Pack]")
PY
)
fi

mkdir -p "$STATE_DIR"
echo "$TURN $TURN $CUR_BYTES" > "$STATE_FILE"
find "$STATE_DIR" -name "code-style-injected-*" -mmin +1440 -delete 2>/dev/null || true

jq -n --arg ctx "$CONTEXT" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": $ctx
  }
}'
