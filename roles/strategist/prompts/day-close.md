Выполни сценарий Day Close для роли Стратег (R1).

> **Триггер:** Ручной — по запросу пользователя (`/day-close` или `./scripts/strategist.sh day-close`).
> **Вход:** Текущий день (коммиты, статусы РП, WeekPlan).
> **Выход:** Обновлённый WeekPlan + краткий итог на экран.

## ВДВ-шаг

| Шаг | Вход | Действие | Выход |
|-----|------|----------|-------|
| 1 | Триггер от пользователя | Вызвать `skills/day-close/SKILL.md` | Результат skill или fallback |

## Алгоритм

### 1. Делегировать в skill

```bash
# Проверить наличие skill
SKILL="${IWE_WORKSPACE:-$HOME/IWE}/.claude/skills/day-close/SKILL.md"
if [ -f "$SKILL" ]; then
  # Делегировать выполнение skill /day-close
  # Skill сам обновляет WeekPlan, делает backup, выводит итоги
  echo "Делегирую в skills/day-close/SKILL.md"
  # LLM-агент: прочитай SKILL.md и выполни его алгоритм целиком
else
  echo "WARN: skills/day-close/SKILL.md не найден — выполняю fallback (inline-чеклист)"
fi
```

### 2. Fallback (если skill недоступен)

Если `skills/day-close/SKILL.md` не найден:

1. **Собрать коммиты за сегодня** — `git log --since="today 00:00" --oneline` по всем репо в `{{WORKSPACE_DIR}}/`
2. **Обновить WeekPlan** — пометить done/partial, добавить carry-over
3. **Вывести краткий итог** на экран (шаблон ниже)

```
📋 Day-Close: DD месяца YYYY

Коммиты: N в M репо
- repo-name: N коммитов (краткое описание)

РП обновлены в WeekPlan:
- #N: статус → новый статус

Git: закоммичен и запушен ✅
```

## Правила

- **Ничего не удалять** из WeekPlan — только помечать и дописывать
- **Не создавать отдельный файл отчёта** — итоги дня войдут в DayPlan следующего утра
- Если коммитов за день нет — написать «Нет активности» и всё равно обновить WeekPlan

## Источники

- **Skill (primary):** `{{WORKSPACE_DIR}}/.claude/skills/day-close/SKILL.md`
- **WeekPlan:** `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/current/WeekPlan W*.md`
- **WP-Registry:** `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/docs/WP-REGISTRY.md`
