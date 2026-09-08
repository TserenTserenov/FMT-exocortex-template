#!/usr/bin/env bash
# test_issue_581_calendar_single_source.sh — regression for issue #581.
#
# The Day Open calendar section was empty for users with a working calendar
# connector: the protocol demanded server-calendar.sh (which needs its own
# key file), the scaffold's PENDING comment named outdated MCP tools
# (mcp__ext-google-calendar__*), and the morning run's --allowedTools had no
# MCP at all. Fix (cheap parts, per WP-484 AC triage): connector-first single
# source in protocol + scaffold, script demoted to documented fallback,
# calendar server in the morning run's whitelist. This test pins the
# observable contract of the delivered text.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fail=0
check_grep() { # <desc> <pattern> <file>
    if grep -qF "$2" "$3"; then echo "PASS: $1"; else echo "FAIL: $1 — нет строки: $2"; fail=$((fail + 1)); fi
}
check_grep_absent() {
    if grep -qF "$2" "$3"; then echo "FAIL: $1 — строки не должно быть: $2"; fail=$((fail + 1)); else echo "PASS: $1"; fi
}

# 1. Устаревших имён инструментов нет ни в скелете, ни в seed-снимке.
check_grep_absent "scaffold: нет mcp__ext-google-calendar" \
    'mcp__ext-google-calendar' "$ROOT/scripts/day-open-scaffold.sh"
check_grep_absent "seed scaffold: нет mcp__ext-google-calendar" \
    'mcp__ext-google-calendar' "$ROOT/seed/strategy/scripts/day-open-scaffold.sh"

# 2. Протокол: коннектор — единый источник, скрипт — задокументированный фоллбэк.
check_grep "SKILL 4c: коннектор первичен" \
    'Единый источник — подключённый календарный коннектор' \
    "$ROOT/.claude/skills/day-open/SKILL.md"
check_grep "SKILL 4c: регистр имени коннектора оговорён" \
    'без учёта регистра' "$ROOT/.claude/skills/day-open/SKILL.md"
check_grep "SKILL 4c: скрипт — фоллбэк" \
    'фоллбэк' "$ROOT/.claude/skills/day-open/SKILL.md"
check_grep "details 4c: скрипт помечен фоллбэком" \
    'фоллбэк для установок без коннектора' \
    "$ROOT/.claude/skills/day-open/day-open-details.md"
check_grep "details 4c: «credentials не настроены» честно атрибутировано скрипту" \
    'не пустой календарь' \
    "$ROOT/.claude/skills/day-open/day-open-details.md"

# 3. Скелет согласован с протоколом (коннектор первичен, фоллбэк назван).
check_grep "scaffold PENDING: коннектор первичен" \
    'единый источник: календарный коннектор' "$ROOT/scripts/day-open-scaffold.sh"
check_grep "scaffold PENDING: фоллбэк назван" \
    'server-calendar.sh' "$ROOT/scripts/day-open-scaffold.sh"

# 3b. Morning-сценарий day-plan.md: календарь — явный шаг, коннектор первичен,
# атрибуция «credentials» скрипту сохранена.
check_grep "day-plan.md: шаг календаря через коннектор" \
    'mcp__claude_ai_Google_Calendar__*' "$ROOT/roles/strategist/prompts/day-plan.md"
check_grep "day-plan.md: регистр имени коннектора оговорён" \
    'без учёта регистра' "$ROOT/roles/strategist/prompts/day-plan.md"
check_grep "day-plan.md: «credentials не настроены» — факт о скрипте" \
    'факт об отсутствии файла ключей у СКРИПТА' "$ROOT/roles/strategist/prompts/day-plan.md"
check_grep "day-plan.md: честный маркер недоступности" \
    'ни коннектор, ни файл ключей' "$ROOT/roles/strategist/prompts/day-plan.md"

# 4. Morning-прогон: календарный сервер в whitelist, имя конфигурируемо.
check_grep "strategist: календарный коннектор в --allowedTools" \
    'mcp__claude_ai_Google_Calendar' "$ROOT/roles/strategist/scripts/strategist.sh"
check_grep "strategist: имя сервера конфигурируемо (IWE_CALENDAR_MCP_SERVERS)" \
    'IWE_CALENDAR_MCP_SERVERS' "$ROOT/roles/strategist/scripts/strategist.sh"

if [ "$fail" -gt 0 ]; then
    echo "FAIL: $fail проверок упало"
    exit 1
fi
echo "PASS: calendar section has a single connector-first source with a documented fallback (issue #581)"
