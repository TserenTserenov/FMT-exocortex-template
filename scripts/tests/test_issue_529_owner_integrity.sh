#!/usr/bin/env bash
# Regression for issue #529: OwnerIntegrity distinguishes authority from copies.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOT="$ROOT/.claude/rules/distinctions.md"
FULL="$ROOT/memory/hard-distinctions.md"

fail() {
    echo "❌ issue-529: $*" >&2
    exit 1
}

grep -Fq -- '**OwnerIntegrity** (HD #35): Один факт — один **авторитетный** владелец.' "$HOT" \
    || fail "hot-правило не ссылается на HD #35"
grep -Fq -- 'Неуправляемый дубль = ошибка синхронизации' "$HOT" \
    || fail "hot-правило не запрещает независимый дубль"
grep -Fq -- 'производная копия — только с автосинком' "$HOT" \
    || fail "hot-правило не определяет производную копию"
grep -Fq -- 'неполный пересказ — только с явной ссылкой на первоисточник' "$HOT" \
    || fail "hot-правило не определяет пересказ"

grep -Fq -- '## 35. Один авторитетный владелец ≠ одно буквальное место (OwnerIntegrity)' "$FULL" \
    || fail "развёрнутое различение #35 отсутствует"
for carrier in 'Авторитетный носитель' 'Производная копия' 'Неполный пересказ'; do
    grep -Fq -- "$carrier" "$FULL" || fail "нет класса носителя: $carrier"
done
grep -Fq -- 'сколько мест нужно исправить руками?' "$FULL" \
    || fail "операционный тест OwnerIntegrity отсутствует"
grep -Fq -- 'Неуправляемый дубль — не четвёртый класс носителя, а состояние нарушения' "$FULL" \
    || fail "неуправляемый дубль не отделён от трёх легитимных классов"

echo "✅ issue-529: авторитетный носитель, производная копия и пересказ различены"
