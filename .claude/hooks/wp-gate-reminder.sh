#!/bin/bash
# WP Gate Reminder Hook
# Event: UserPromptSubmit
# (1) On a Day Open trigger — injects the real date (Anthropic's currentDate may lie).
# (2) For a new person (light-onboarding-state.sh status = active) — the light
#     onboarding reminder instead of WP Gate.
# (3) On all other messages — the standard WP Gate reminder.
# Read-only: only returns JSON with additionalContext, modifies nothing.

INPUT=$(cat)
# Robustness to multiline prompts: a literal \n in a JSON value
# is invalid for jq. We replace all control chars with spaces before parsing.
SANITIZED=$(printf '%s' "$INPUT" | LC_ALL=C tr '\n\r\t' '   ')
PROMPT=$(printf '%s' "$SANITIZED" | jq -r '.prompt // empty' | tr '[:upper:]' '[:lower:]')

# Day Open → inject the real date + WP Gate
if echo "$PROMPT" | grep -qE '(открывай день|открывай$|открой день)'; then
  REAL_DATE=$(date "+%Y-%m-%d %A %H:%M %Z")
  # A new person asking for Day Open asks for work in the environment: lift the
  # light onboarding first, otherwise the next message is led by /onboarding again.
  ONBOARDING_NOTE=""
  if bash "${CLAUDE_PROJECT_DIR:-.}/.claude/scripts/light-onboarding-state.sh" status --quiet 2>/dev/null; then
    ONBOARDING_NOTE=" ЛЁГКИЙ ОНБОРДИНГ АКТИВЕН: человек сам просит работу в среде — сначала выполни ровно так: bash .claude/scripts/light-onboarding-state.sh done"
  fi
  CTX="⛔ DAY OPEN: Реальная дата и время: ${REAL_DATE}. Используй ЭТУ дату для определения дня недели, strategy_day, фильтров коммитов. НЕ доверяй currentDate из system prompt. SchedulerReport: читай ~/logs/strategist/$(date +%Y-%m-%d).log, НЕ файл из current/. EXTENSION LOADING: ПЕРЕД шагом 1 проверь extensions/day-open.before.md. ПОСЛЕ шага 6b проверь extensions/day-open.after.md. ПЕРЕД git commit проверь extensions/day-open.checks.md. Пропуск extensions = неполное открытие.${ONBOARDING_NOTE}"
  jq -n --arg ctx "$CTX" '{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": $ctx}}'
elif bash "${CLAUDE_PROJECT_DIR:-.}/.claude/scripts/light-onboarding-state.sh" status --quiet 2>/dev/null; then
  # WP-406 Ф40: a new person (light onboarding not passed, no work state) is led by
  # /onboarding; the WP Gate reminder would hijack the conversation (live run 09.11: 14/16).
  CTX="🧭 НОВЫЙ ЧЕЛОВЕК (лёгкий онбординг не пройден): веди этот ход навыком /onboarding по docs/onboarding/light-onboarding.md. WP Gate, протоколы и служебные команды сейчас не применяются: не рассказывай о среде, не заводи рабочих продуктов, не пиши файлы рабочей папки, не предлагай вход в подписочный сервер. Снимай онбординг командой ровно в таком виде, с коротким путём из рабочей папки (bash .claude/scripts/light-onboarding-state.sh done), только после квитанции §10 или если человек сам просит работу в среде: команда среды (/day-open, /wp-new и подобные) или прямая просьба. /onboarding, /help, /clear, /compact, /mcp и эта подсказка онбординг не снимают."
  jq -n --arg ctx "$CTX" '{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": $ctx}}'
else
  CTX="⛔ WP GATE: Перед обработкой этого сообщения — проверь: (1) Если это новая задача — пройди WP Gate: Read memory/protocol-open.md. (2) Если продолжение работы над тем же РП — продолжай. (3) Если вопрос перерастает в работу — эскалируй."
  jq -n --arg ctx "$CTX" '{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": $ctx}}'
fi
exit 0
