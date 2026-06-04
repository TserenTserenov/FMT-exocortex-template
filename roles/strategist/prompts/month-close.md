Выполни сценарий Month Close для роли Стратег (R1).

> **Триггер:** Автоматический — первый понедельник месяца, 00:00 (launchd) или по запросу пользователя.
> **Вход:** WeekPlans месяца + MEMORY.md + Strategy.md + Dissatisfactions.md.
> **Выход:** Обновлённый Strategy.md (архивация фокуса месяца) + новые R1-R6 + отчёт Month Close.

## ВДВ-шаг

| Шаг | Вход | Действие | Выход |
|-----|------|----------|-------|
| 1 | Триггер (начало месяца) | Вызвать `skills/month-close/SKILL.md` | Результат skill или fallback |

## Алгоритм

### 1. Делегировать в skill

```bash
# Проверить наличие skill
SKILL="${IWE_WORKSPACE:-$HOME/IWE}/.claude/skills/month-close/SKILL.md"
if [ -f "$SKILL" ]; then
  # Делегировать выполнение skill /month-close
  echo "Делегирую в skills/month-close/SKILL.md"
  # LLM-агент: прочитай SKILL.md и выполни его алгоритм целиком
else
  echo "WARN: skills/month-close/SKILL.md не найден — выполняю fallback (inline-чеклист)"
fi
```

### 2. Fallback (если skill недоступен)

Если `skills/month-close/SKILL.md` не найден:

1. **Ретро месяца** — сравнить R1-R6 (факт vs план) из WeekPlans
2. **Архивация фокуса** — перенести достижения месяца в `Strategy.md`
3. **Новые R1-R6** — сформулировать цели нового месяца
4. **ТОС и гипотеза** — определить топ-3 приоритета и гипотезу роста
5. **Red line проверка** — D7, runway, WakaTime, блокеры
6. **MEMORY аудит** — ротация уроков, свежая таблица РП, проверка лимитов
7. **Commit и push** — `git add` → commit → push

```
📋 Month Close: Месяц YYYY-MM

R1-R6 ретро:
- R1: <факт> / <план> → <статус>
- ...

Фокус месяца: <главное достижение>
ТОС следующего месяца: <топ-3>
Гипотеза: <гипотеза роста>

Red lines: <проверка>
Memory: <аудит>

Git: закоммичен и запушен ✅
```

## Правила

- **Month Close — не Strategy Session.** Он готовит входные данные для Strategy Session (если она запланирована).
- **Не принимать стратегических решений** без пилота — только фиксация фактов и формирование предложений.
- **Архивировать, не удалять** — все WeekPlans месяца остаются в `archive/week-plans/`.

## Источники

- **Skill (primary):** `{{WORKSPACE_DIR}}/.claude/skills/month-close/SKILL.md`
- **WeekPlans:** `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/archive/week-plans/WeekPlan W*.md`
- **Strategy:** `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/docs/Strategy.md`
- **MEMORY:** `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/memory/MEMORY.md`
- **Protocol:** `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/memory/protocol-month-close.md` (если есть)
