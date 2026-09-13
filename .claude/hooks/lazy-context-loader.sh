#!/bin/bash
# Lazy Context Loader — WP-16 Токенная диета сессии
# Event: UserPromptSubmit
# Загружает warm memory-файлы в контекст по ключевым словам промпта.
# Правило: не более 1 файла на промпт (не перегружать контекст).
# Добавлено: 2026-06-23

set -uo pipefail

MEM_DIR="${CLAUDE_PROJECT_DIR}/memory"
INPUT=$(cat)
SANITIZED=$(printf '%s' "$INPUT" | LC_ALL=C tr '\n\r\t' '   ')
PROMPT=$(printf '%s' "$SANITIZED" | jq -r '.prompt // empty' 2>/dev/null || echo "")
PROMPT_LOWER=$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')

inject() {
  local file="$1" label="$2"
  if [[ ! -f "$file" ]]; then
    echo '{}'
    return
  fi
  python3 -c "
import sys, json
file, label = sys.argv[1], sys.argv[2]
with open(file) as f:
    content = f.read()
ctx = '[Lazy-load: ' + label + ']\n' + content
print(json.dumps({'hookSpecificOutput': {'hookEventName': 'UserPromptSubmit', 'additionalContext': ctx}}))
" "$file" "$label"
}

# Security audit cadence
if echo "$PROMPT_LOWER" | grep -qE '(security audit|secaudit|b7\.|stride|аудит безопасн|audit cadence|security.posture|security.cadence)'; then
  inject "${MEM_DIR}/security-audit-cadence.md" "security-audit-cadence"
  exit 0
fi

# Systemd timers & scheduler
if echo "$PROMPT_LOWER" | grep -qE '(systemctl|iwe-.*timer|systemd user unit|iwe-strategist|iwe-extractor|iwe-exocortex|secaudit.*timer|systemd-scheduler)'; then
  inject "${MEM_DIR}/systemd-scheduler-reference.md" "systemd-scheduler-reference"
  exit 0
fi

# FPF/Platform distinctions (warm tier)
if echo "$PROMPT_LOWER" | grep -qE '(система-в-роли|целевая система проект|носитель.*персон|персон.*декларац|мастерство.*роль|экзоскелет.*автопилот|fpf a\.[0-9]|лог.*инцидент.*state|скрипт.*агент.*(тест|различени)|проектировать роль агента)'; then
  inject "${MEM_DIR}/distinctions-warm.md" "distinctions-warm"
  exit 0
fi

echo '{}'
exit 0
