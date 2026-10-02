#!/usr/bin/env bash
# issue #982: table_to_list() in the strategist Telegram template mapped plan columns by
# fixed position (DayPlan layout hardcoded, WeekPlan layout guessed), printed `#` before
# the number (Telegram renders `#WP-17` as the hashtag `#WP`) and showed ⬜ for every
# not-started item instead of the plan's traffic light. Columns are now found by header.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/roles/synchronizer/scripts/templates/strategist.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# Load only table_to_list (the template sources env/paths at top level).
eval "$(sed -n '/^table_to_list() {/,/^}/p' "$SRC")"

cat > "$T/DayPlan.md" <<'EOF'
# День

## План на сегодня

| 🚦 | ТВС | # | РП | h | Статус |
|----|-----|---|----|---|--------|
| ✅ | В | — | Day Open — сверка платформы | 0.5 | done |
| ⚫ | В | — | Календарь — договор | 2 | pending |
| 🔴 | Т | WP-17 | BMX Race Hub — Ф58а | 1 | pending |
| 🟡 | С | WP-18 | **Поиск трудоустройства** | 2-3 | in_progress |
| 🟢 | В | WP-4 | Марафон МИМ | встроен | pending |

---
EOF

cat > "$T/WeekPlan.md" <<'EOF'
# Неделя

## Рабочие продукты

| 🚦 | # | РП | h | Статус | Дедлайн |
|----|---|----|---|--------|---------|
| 🔴 | WP-17 | BMX Race Hub | 6 | pending | пт |
| 🟢 | WP-4 | Марафон МИМ | 3 | done | вс |

---
EOF

cat > "$T/WeekPlanOld.md" <<'EOF'
# Неделя

## Рабочие продукты

| # | РП | Бюджет | Статус | Дедлайн |
|---|----|--------|--------|---------|
| WP-9 | Старый формат | 4h | in_progress | пт |
| WP-10 | Ещё | 2h | pending | сб |

---
EOF

fail=0
expect() { # name file section expected
    local got
    got="$(table_to_list "$2" "$3")"
    if [ "$got" = "$4" ]; then
        echo "  ✅ $1"
    else
        echo "  ❌ $1"; echo "--- ожидалось"; echo "$4"; echo "--- получено"; echo "$got"
        fail=1
    fi
}

expect "DayPlan: светофор вместо ⬜, без #, без номера для —" "$T/DayPlan.md" "План на сегодня" \
"✅ Day Open — сверка платформы (0.5)
⚫ Календарь — договор (2)
🔴 WP-17 BMX Race Hub — Ф58а (1)
🔄 WP-18 Поиск трудоустройства (2-3)
🟢 WP-4 Марафон МИМ (встроен)"

expect "WeekPlan: колонки по заголовку" "$T/WeekPlan.md" "Рабочие продукты" \
"🔴 WP-17 BMX Race Hub (6)
✅ WP-4 Марафон МИМ (3)"

expect "WeekPlan старого формата без 🚦: ⬜ для не начатых" "$T/WeekPlanOld.md" "Рабочие продукты" \
"🔄 WP-9 Старый формат (4h)
⬜ WP-10 Ещё (2h)"

if table_to_list "$T/DayPlan.md" "План на сегодня" | grep -q '#'; then
    echo "  ❌ в выводе есть #"; fail=1
fi
exit $fail
