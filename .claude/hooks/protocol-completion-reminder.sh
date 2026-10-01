#!/bin/bash
# Protocol Completion Reminder Hook
# Event: PostToolUse (matcher: Read | Skill)
# Ф2 WP-229: расширен на Skill tool (day-open, day-close, run-protocol, wp-new)
# После чтения протокола или вызова скилла напоминает: выполни ВСЕ шаги.
# Read-only: только возвращает JSON.
#
# R23 (issue #975). The verification item belongs to closings only: R23 is the
# Haiku sub-agent that checks a closing against its checklist (Quick Close in
# memory/protocol-close.md, Day Close in day-close/SKILL.md step 11, Month Close in
# memory/protocol-month-close.md). It is NOT the /verify skill, which checks an
# artifact against a Pack standard. The item is added for: skill day-close, skill
# run-protocol whose args name a close, reading memory/protocol-close.md or
# memory/protocol-month-close.md. `verify_quick_close: false` in the workspace
# params.yaml silences the Quick Close case only; Day, Week and Month Close do not
# obey that key (the docs call it a Quick Close parameter).

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
SKILL_NAME=$(echo "$INPUT" | jq -r '.tool_input.skill // empty')
SKILL_ARGS=$(echo "$INPUT" | jq -r '.tool_input.args // empty')

# params.yaml of the WORKSPACE root: IWE_WORKSPACE when set (the variable the other
# params readers use); otherwise the nearest params.yaml from the project directory
# up, at most 4 levels, so a session started inside a governance repository still
# finds the workspace root. Prints nothing when there is no file.
find_params_file() {
  local dir
  if [ -n "${IWE_WORKSPACE:-}" ]; then
    [ -f "$IWE_WORKSPACE/params.yaml" ] && printf '%s\n' "$IWE_WORKSPACE/params.yaml"
    return 0
  fi
  dir="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
  for _ in 0 1 2 3 4; do
    [ -n "$dir" ] || break
    if [ -f "$dir/params.yaml" ]; then
      printf '%s\n' "$dir/params.yaml"
      return 0
    fi
    [ "$dir" = "/" ] && break
    dir=$(dirname "$dir")
  done
  return 0
}

# Succeeds unless verify_quick_close is an explicit `false`: case-insensitive,
# quotes, spaces and a trailing " # comment" tolerated. No file or key = enabled.
verify_enabled() {
  local file value
  file=$(find_params_file)
  [ -n "$file" ] || return 0
  value=$(grep -E '^verify_quick_close:' "$file" 2>/dev/null | head -1 \
    | sed -E 's/^verify_quick_close:[[:space:]]*//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//; s/^["'"'"']//; s/["'"'"']$//' \
    | tr '[:upper:]' '[:lower:]')
  [ "$value" != "false" ]
}

# Closing kind of a run-protocol call, from its args "[open|close] [day|session]"
# or day-close / week-close (.claude/skills/run-protocol/SKILL.md) or month-close
# (not in that table, but this hook always reminded R23 for it): prints
# quick | day | week | month, nothing when the call is not a closing. Only the
# leading words count: a free-form task text may mention "close" without being one.
run_protocol_close_kind() {
  local first second
  read -r first second _ <<< "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$first" in
    day-close) echo day ;;
    week-close) echo week ;;
    month-close) echo month ;;
    close)
      case "$second" in
        day) echo day ;;
        *) echo quick ;;
      esac
      ;;
  esac
}

# Succeeds when the R23 item applies to a closing of the given kind
# (quick | day | week | month | empty = not a closing). Only Quick Close obeys the key.
r23_applies() {
  case "$1" in
    quick) verify_enabled ;;
    day | week | month) return 0 ;;
    *) return 1 ;;
  esac
}

# Reading memory/protocol-*.md; hooks such as protocol-stop-gate.sh do not count.
is_protocol_file() {
  case "$(basename "$(dirname "$1")")/$(basename "$1")" in
    memory/protocol-*.md) return 0 ;;
    *) return 1 ;;
  esac
}

R23_ITEM="После завершения запусти sub-agent Haiku в роли R23 (изоляция контекста): он сверяет выполнение с чеклистом закрытия."

# Срабатываем на чтение протоколов (Read memory/protocol-*.md)
if [ "$TOOL" = "Read" ] && is_protocol_file "$FILE_PATH"; then
  PROTOCOL_NAME=$(basename "$FILE_PATH" .md)
  ITEMS="(1) Выполни ВСЕ шаги алгоритма."
  WARN="НЕ пропускай шаги."
  case "$PROTOCOL_NAME" in
    protocol-close) KIND=quick ;;
    protocol-month-close) KIND=month ;;
    *) KIND="" ;;
  esac
  if r23_applies "$KIND"; then
    ITEMS="$ITEMS (2) $R23_ITEM"
    WARN="НЕ пропускай шаги и верификацию."
  fi
  CTX="📝 ПРОТОКОЛ ЗАГРУЖЕН: $PROTOCOL_NAME. ОБЯЗАТЕЛЬНО: $ITEMS $WARN"
  jq -n --arg ctx "$CTX" '{"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": $ctx}}'

# Срабатываем на вызов протокольных скиллов (Skill tool)
elif [ "$TOOL" = "Skill" ] && echo "$SKILL_NAME" | grep -qE '^(day-open|day-close|run-protocol|wp-new)$'; then
  ITEMS="(1) Создай таск-лист ВСЕХ шагов скилла ДО начала исполнения — TodoWrite, TaskCreate/TaskUpdate или явная нумерация шагов в ответах, если Task-инструменты недоступны. (2) Выполни ВСЕ шаги последовательно, отмечая каждый."
  WARN="НЕ пропускай шаги."
  case "$SKILL_NAME" in
    day-close) KIND=day ;;
    run-protocol) KIND=$(run_protocol_close_kind "$SKILL_ARGS") ;;
    *) KIND="" ;;
  esac
  if r23_applies "$KIND"; then
    ITEMS="$ITEMS (3) $R23_ITEM"
    WARN="НЕ пропускай шаги и верификацию."
  fi
  CTX="📝 СКИЛЛ ЗАГРУЖЕН: $SKILL_NAME. ОБЯЗАТЕЛЬНО: $ITEMS $WARN"
  jq -n --arg ctx "$CTX" '{"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": $ctx}}'

else
  echo '{}'
fi
exit 0
