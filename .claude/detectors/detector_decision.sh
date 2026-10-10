#!/bin/bash
# detector_decision.sh
# see DP.SC.025 (capture-bus service clause), DP.ROLE.001#R47 (Детектор)
# event_type: decision_user
# cost_class: free (rule-based, regex на транскрипт)
# runtime: shell
# triggers: Stop
#
# WP-109 Ф7b. Детектирует решения пользователя в сессии.
# Читает transcript_path из Stop-события, ищет human-сообщения с паттернами
# решений (approve/reject/redirect/architectural/strategic).
# Эмитит по одному decision_user event на каждое найденное решение.
#
# ВАЖНО — инварианты (WP-206 Ф7 §2a):
#   1. ТОЛЬКО решения пользователя, не агента.
#   2. Фильтр консервативный: лучше пропустить, чем ложно сработать.
#   3. Timestamp = время из транскрипта (поле .timestamp), не NOW().
#   4. Каждая эмиссия содержит user_utterance — цитату (≤150 символов).
#   5. Типовые НЕ-решения (не писать): согласие запустить команду,
#      ответ «делай», одобрение автономного действия агента,
#      технические выборы агента (имя файла, структура теста и т.п.).
#
# v1: emit только approved-решений (тип decision_approve).
# Расширение v2: распознавание reject/redirect/architectural/strategic.
# Принцип warn-before-block: детектор НИКОГДА не блокирует (exit 0).
#
# Лимит: не более MAX_DECISIONS решений за одну Stop-сессию (защита от шума).

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

MAX_DECISIONS=5  # warn-before-block: консервативный лимит v1

INPUT=$(cat)
if [ -z "$INPUT" ]; then
  exit 0
fi

HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Только Stop
[ "$HOOK_EVENT" != "Stop" ] && exit 0

# Нет транскрипта — пропустить (graceful degradation)
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  exit 0
fi

# Определяем target_repo: cwd → IWE repo
# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
DETECTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$DETECTOR_DIR/.." && pwd)"
# shellcheck source=../lib/iwe-env-bootstrap.sh
source "$CLAUDE_DIR/lib/iwe-env-bootstrap.sh" || exit 1

TARGET_REPO_HINT=""
if [ -n "$CWD" ] && [[ "$CWD" == "$IWE_ROOT"/* ]]; then
  REL="${CWD#$IWE_ROOT/}"
  FIRST_SEG="${REL%%/*}"
  if [ -n "$FIRST_SEG" ] && [ -d "$IWE_ROOT/$FIRST_SEG" ]; then
    TARGET_REPO_HINT="$IWE_ROOT/$FIRST_SEG"
  fi
fi

# Fallback: governance-репо из env IWE_GOVERNANCE_REPO
if [ -z "$TARGET_REPO_HINT" ]; then
  if [ -n "${IWE_GOVERNANCE_REPO:-}" ] && [ -d "$IWE_ROOT/$IWE_GOVERNANCE_REPO" ]; then
    TARGET_REPO_HINT="$IWE_ROOT/$IWE_GOVERNANCE_REPO"
  else
    exit 0
  fi
fi

# ── Извлечь human-сообщения из транскрипта ───────────────────────────────
# Транскрипт — JSONL. Реплика пользователя в Claude Code: type="user" и
# .message.role="user", текст в .message.content (строка или массив блоков).
# Старые формы (.role="user", type="human", .content) оставлены для совместимости.
# Отбрасываются: tool_result-блоки (берём только type="text"), записи isMeta,
# служебные вставки (<system-reminder>, <command-...>, тело загруженного скилла).
# issue #1174: прежний фильтр искал .role на верхнем уровне и не находил ничего.
# HUMAN_JQ_BEGIN
HUMAN_JQ='
  def body: if type == "string" then .
            elif type == "array" then (map(select(.type == "text") | .text) | join("\n"))
            else empty end;
  select((.type == "user" and (.isMeta != true)) or .role == "user" or .type == "human")
  | ((.message.content // .content) | body)
  | select(length > 0)
  | select(test("^\\s*<(system-reminder|command-|local-command|user-prompt-submit-hook)") | not)
  | select(test("^\\s*Base directory for this skill:") | not)
'
# HUMAN_JQ_END
HUMAN_MSGS=$(jq -r "$HUMAN_JQ" "$TRANSCRIPT_PATH" 2>/dev/null || true)

if [ -z "$HUMAN_MSGS" ]; then
  exit 0
fi

# ── Паттерны решений пользователя ───────────────────────────────────────────
# Консервативный фильтр v1: только явные развилки + выборы.
# Каждый паттерн: (regex, event_type, cognitive_weight)
#
# НЕ попадают: "делай", "ok", "да" без контекста (слишком шумно для v1).
# Попадают: "выбираю X", "принято", "решение: X", "берём вариант X",
#            "да, [конкретное решение]", "нет, [конкретный reject]".

detect_decisions() {
  local msg="$1"
  local msg_lower
  msg_lower=$(echo "$msg" | tr '[:upper:]' '[:lower:]')

  # decision_approve — пользователь явно принял архитектурное/стратегическое решение
  if echo "$msg_lower" | grep -qE \
    '(выбираю|принято|берём|берем|решение:|решили|выбрали|остановились на|берём вариант|варианте [a-zа-я]|stop-list|в план|добавь в план|закрываем|делать не будем|откладываем|заморозим)'; then
    echo "decision_approve|1"
    return
  fi

  # decision_reject — явный отказ от предложения
  if echo "$msg_lower" | grep -qE \
    '(нет, не (надо|нужно|делай)|отклоняем|отклони|отвергаем|не берём|не берем|откажемся|убираем это|дроп|drop)'; then
    echo "decision_reject|3"
    return
  fi

  # decision_redirect — смена направления
  if echo "$msg_lower" | grep -qE \
    '(переформулируем|меняем подход|другой путь|иначе|переделай|перепиши концепцию|пересмотрим)'; then
    echo "decision_redirect|3"
    return
  fi
}

# ── Обработка сообщений ──────────────────────────────────────────────────────
count=0
while IFS= read -r msg; do
  [ -z "$msg" ] && continue
  [ ${#msg} -lt 10 ] && continue  # слишком короткое — не решение
  [ "$count" -ge "$MAX_DECISIONS" ] && break

  result=$(detect_decisions "$msg")
  [ -z "$result" ] && continue

  event_type="${result%%|*}"
  cognitive_weight="${result##*|}"

  # Цитата: первые 150 символов сообщения (schema-фильтр WP-206 Ф7 §4a)
  utterance="${msg:0:150}"

  # Timestamp: NOW() (v1 — идеально брать из транскрипта, но требует jq по line)
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Эмитим событие (capture_writer получит его через stdout dispatcher)
  jq -n \
    --arg event_type "$event_type" \
    --arg session_id "$SESSION_ID" \
    --arg user_utterance "$utterance" \
    --arg ts "$TS" \
    --argjson cognitive_weight "$cognitive_weight" \
    --arg hint "$TARGET_REPO_HINT" \
    '{
      event_type: $event_type,
      payload: {
        session_id: $session_id,
        user_utterance: $user_utterance,
        cognitive_weight: $cognitive_weight,
        source: "iwe",
        ts: $ts
      },
      repo_ctx: {
        target_repo_hint: $hint
      }
    }'

  count=$((count + 1))

done <<< "$HUMAN_MSGS"

exit 0
