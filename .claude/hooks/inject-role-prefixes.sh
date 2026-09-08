#!/bin/bash
# inject-role-prefixes.sh
# Event: UserPromptSubmit
# see DP.SC.154 (Префиксы ролей), WP-445 Ф4
#
# Назначение: lazy-инжекция полного контекста роли ТОЛЬКО когда пользователь
#   начинает сообщение с роль-префикса (Навигатор, / Диагност, / ...).
#   Иначе — пустой ответ (stub уже в rules/role-prefixes.md).
#
# Архитектура (WP-445, ArchGate Ф3 М2-митигация):
#   Hot stub:   .claude/rules/role-prefixes.md (~709 байт, always-loaded)
#   Full:       .claude/rules-lazy/role-prefixes-full.md (~23 KB, lazy)
#   Триггеры:   читаются ДИНАМИЧЕСКИ из §Активация таблицы full-файла — не hardcode.
#
# Savings: ~23 105 байт (~4 620 токенов) при обычном сообщении без роль-префикса.
# Инвариант (ArchGate М2): при добавлении новой роли в role-prefixes-full.md §Активация
#   хук автоматически подхватит новый триггер — ничего не надо менять в хуке.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

command -v jq >/dev/null 2>&1 || { echo '{}'; exit 0; }

INPUT=$(cat 2>/dev/null || echo '{}')

# Extract the UserPromptSubmit prompt (first 100 chars is enough for prefix detection)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null | head -c 100 || echo "")
[ -n "$PROMPT" ] || { echo '{}'; exit 0; }

# Locate the full roles file
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL_FILE="$HOOK_DIR/../rules-lazy/role-prefixes-full.md"
[ -f "$FULL_FILE" ] || { echo '{}'; exit 0; }

# Extract triggers dynamically from §Активация table (М2 mitigation).
# Looks for backtick-quoted strings containing ", ..." in the §Активация section.
# Works with macOS grep/awk — no GNU extensions required.
TRIGGERS=$(awk '/^## Активация/,/^## [^А]/' "$FULL_FILE" 2>/dev/null | \
  grep -o '`[^`]*`' | \
  grep ', \.\.\.' | \
  sed 's/`//g; s/, \.\.\.$//')

[ -n "$TRIGGERS" ] || { echo '{}'; exit 0; }

# Build alternation pattern for grep: each trigger is one line → join with |
PATTERN=$(printf '%s\n' "$TRIGGERS" | tr '\n' '|' | sed 's/|$//')
[ -n "$PATTERN" ] || { echo '{}'; exit 0; }

# Check if prompt starts with any trigger (trigger word + comma at position 0)
# Using grep -iE for case-insensitive match (OrgDev vs orgdev)
if ! printf '%s' "$PROMPT" | grep -qiE "^(${PATTERN}),"; then
  echo '{}'
  exit 0
fi

# Role prefix detected — inject full roles context
FULL_CONTENT=$(awk '/^---$/{n++; if(n==2){found=1; next}} found || n==0' "$FULL_FILE" 2>/dev/null || cat "$FULL_FILE")

CONTEXT="## 🎭 Полный контекст ролей IWE (загружен по роль-префиксу)

${FULL_CONTENT}"

jq -n --arg ctx "$CONTEXT" '{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": $ctx
  }
}'
