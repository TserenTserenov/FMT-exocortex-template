#!/bin/bash
# Close Gate Reminder Hook (v2 — compact Session Close)
# Event: UserPromptSubmit
# При триггерах Close инжектит compact-алгоритм Session Close.
# Day Close → полный протокол (Read protocol-close.md).
# Session Close → compact-чеклист ниже.
# Read-only: только JSON additionalContext.
# Версия чеклиста: 2026-03-18. При изменении protocol-close.md → обновить здесь.

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' | tr '[:upper:]' '[:lower:]')

# Day Close → полный протокол
if echo "$PROMPT" | grep -qE '(итоги дня|закрываю день)'; then
  cat <<'EOF'
{"additionalContext": "⛔ DAY CLOSE: Read memory/protocol-close.md § День → ПОЛНЫЙ алгоритм Day Close (сбор коммитов, черновик итогов, governance, видео, задел на завтра). НЕ использовать compact-версию."}
EOF

# Session Close → compact-чеклист
elif echo "$PROMPT" | grep -qE '(закрывай|закрываю|заливай|запуши|закрывай сессию)'; then
  cat <<'EOF'
{"additionalContext": "⛔ SESSION CLOSE (compact v2026-03-18). Выполняй по порядку:\n0. git pull --rebase в DS-strategy\n1. KE: есть отложенные captures? Собрать → классифицировать → показать. 0 = ок, но ПРОВЕРИТЬ явно\n2. Статусы: обновить MEMORY.md + WP-REGISTRY.md (статусы РП, даты)\n3. Push: git add + commit + push (все затронутые репо)\n4. WeekPlan: grep по номеру РП → обновить ВСЕ упоминания\n5. DayPlan: статусы ВСЕХ строк (РП + ad-hoc). Done → зачеркнуть\n6. Backup: memory/ + CLAUDE.md → DS-strategy/exocortex/\n7. WP context: done → mv archive/. in_progress → обновить\n8. Условные (skip если N/A): knowledge-mcp reindex (коммиты в Pack?), governance sync (новые репо/сервисы?), repo CLAUDE.md (новые правила?), draft-list (captures в Pack → черновик?)\n9. Отчёт Close по шаблону (РП, статус, роли, сделано, captures, осталось)\nНЕ оценивать масштаб сессии. НЕ пропускать шаги."}
EOF

else
  echo '{}'
fi
exit 0
