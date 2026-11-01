# current/ — регулярно обновляемые планы

Здесь живут текущие планы:

- **`WeekPlan W{N} YYYY-MM-DD.md`** — план недели (создаётся при `/strategy-session` или `/week-close` следующей)
- **`DayPlan YYYY-MM-DD.md`** — план дня (создаётся при `/day-open`)

## Состояния и переходы

| Файл | Создаётся | Закрывается |
|------|-----------|-------------|
| WeekPlan | `/strategy-session` (Пн утром) | `/week-close` (Пт-Вс) → переезжает в `archive/` |
| DayPlan | `/day-open` (утром) | `/day-close` (вечером) → переезжает в `archive/` |

## Шаблоны

Шаблоны лежат в `~/IWE/.claude/skills/day-open/` и `.../strategy-session/` — не дублируем здесь.

---

*Этот README удалить можно после первого WeekPlan.*
