#!/bin/bash
# Protocol Completion Reminder Hook
# Event: PostToolUse (matcher: Read | Skill)
# Ф2 WP-229: расширен на Skill tool (day-open, day-close, run-protocol, wp-new)
# После чтения протокола или вызова скилла напоминает: выполни ВСЕ шаги.
# Read-only: только возвращает JSON.

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
SKILL_NAME=$(echo "$INPUT" | jq -r '.tool_input.skill // empty')

# Срабатываем на чтение протоколов (Read protocol-*.md)
if [ "$TOOL" = "Read" ] && echo "$FILE_PATH" | grep -q "protocol-"; then
  PROTOCOL_NAME=$(basename "$FILE_PATH" .md)
  CTX="📝 ПРОТОКОЛ ЗАГРУЖЕН: $PROTOCOL_NAME. ОБЯЗАТЕЛЬНО: (1) Выполни ВСЕ шаги алгоритма. (2) После завершения запусти /verify для верификации по чеклисту (Haiku R23). НЕ пропускай верификацию."
  jq -n --arg ctx "$CTX" '{"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": $ctx}}'

# Срабатываем на вызов протокольных скиллов (Skill tool)
elif [ "$TOOL" = "Skill" ] && echo "$SKILL_NAME" | grep -qE '^(day-open|day-close|run-protocol|wp-new)$'; then
  CTX="📝 СКИЛЛ ЗАГРУЖЕН: $SKILL_NAME. ОБЯЗАТЕЛЬНО: (1) Используй TodoWrite — создай таск-лист ВСЕХ шагов скилла ДО начала исполнения. (2) Выполни ВСЕ шаги последовательно, отмечая каждый. (3) После завершения запусти /verify (Haiku R23). НЕ пропускай шаги и верификацию."
  jq -n --arg ctx "$CTX" '{"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": $ctx}}'

else
  echo '{}'
fi
exit 0
