#!/usr/bin/env bash
# Regression coverage for issue #532: session-open must resolve strategy_day
# before touching DayPlan.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROTOCOL="$ROOT/memory/protocol-open.md"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

config_line=$(grep -n 'day_open\.strategy_day' "$PROTOCOL" | head -1 | cut -d: -f1)
dayplan_line=$(grep -n 'только тогда проверить DayPlan' "$PROTOCOL" | head -1 | cut -d: -f1)

[ -n "$config_line" ] || fail "DayPlan Gate не читает day_open.strategy_day"
[ -n "$dayplan_line" ] || fail "DayPlan Gate не отделяет проверку DayPlan"
[ "$config_line" -lt "$dayplan_line" ] || fail "DayPlan проверяется до strategy_day"
grep -q 'date +%u' "$PROTOCOL" || fail "нет локале-независимого дня недели"
grep -Fq "\${IWE_WORKSPACE:-\$HOME/IWE}/\${IWE_GOVERNANCE_REPO:-DS-strategy}/exocortex/day-rhythm-config.yaml" "$PROTOCOL" \
    || fail "нет канонического пути governance-конфига"
grep -q 'monday=1, tuesday=2, wednesday=3, thursday=4, friday=5,' "$PROTOCOL" \
    || fail "нет карты дней monday–friday"
grep -q 'saturday=6, sunday=7' "$PROTOCOL" || fail "нет ISO-границы weekend=6/7"
grep -Fq "Только отсутствующий ключ имеет безопасный default \`monday\`" "$PROTOCOL" \
    || fail "default monday не ограничен отсутствующим ключом"
grep -q 'inventory/STOP только для' "$PROTOCOL" \
    || fail "битый или отсутствующий конфиг не блокирует DayPlan fail-closed"
grep -q 'значение не входит в карту' "$PROTOCOL" \
    || fail "неизвестный strategy_day не обрабатывается fail-closed"
grep -q 'DayPlan не искать и не' "$PROTOCOL" || fail "strategy_day не запрещает поиск DayPlan"
grep -q 'создавать' "$PROTOCOL" || fail "strategy_day не запрещает создание DayPlan"

echo "PASS: DayPlan Gate вычисляет strategy_day до поиска или создания DayPlan"
