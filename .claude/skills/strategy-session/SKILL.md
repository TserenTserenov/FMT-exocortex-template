---
name: strategy-session
description: Стратегическая сессия — диспетчер. День-0 (skeleton-marker в Strategy.md ИЛИ явный intent «первая/initial/c нуля» ИЛИ нет файлов) → initial flow (цели, неудовлетворённости, первый WeekPlan). День-1+ → weekly flow (требует черновик от session-prep). Триггеры вызова skill — «проведём/запустим/начнём/откроем стратегическую сессию», «стратсессия», «strategy session», «strategy planning», «давай стратегировать», «помоги со стратегией», «постратегируем». Initial-режим внутри skill включается отдельно (см. Шаг 1).
---

# Strategy Session — диспетчер

> Один skill, два режима. Выбор по факту наличия артефактов в `{{GOVERNANCE_REPO}}/`.

## Шаг 1. Определить режим

Проверь:

1. **Skeleton-marker:** есть ли `<!-- IWE-INITIAL-NEEDED -->` в `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/docs/Strategy.md`? Маркер ставится seed-шаблоном при первом setup и удаляется после initial-сессии. Его наличие = Strategy.md ещё не наполнена реальным содержимым.
2. **Явный intent пользователя:** в сообщении есть «первая», «начальная», «initial», «day-0», «c нуля»?
3. **Файлы:** существует ли `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/docs/Strategy.md` и/или хотя бы один `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/current/WeekPlan W*.md`?

| Условие | Режим | Куда дальше |
|---------|-------|-------------|
| Skeleton-marker присутствует ИЛИ явный intent ИЛИ нет ни Strategy.md, ни WeekPlan | **initial** (день-0) | §2 этого файла |
| Файлы есть, маркера нет, intent не указан, есть WeekPlan со `status: draft` | **weekly** | `{{IWE_TEMPLATE}}/roles/strategist/prompts/strategy-session-weekly.md` |
| Файлы есть, маркера нет, intent не указан, нет draft WeekPlan | weekly без draft | сообщи пользователю: «нет черновика, запустить session-prep?» |

---

## Шаг 2. Initial flow (день-0)

> Цель: запустить пользователя со старта. Никакого session-prep, никакого ревью прошлой недели — их ещё нет.

Скажи пользователю:

> «Это первая стратегическая сессия. Пройдём 4 шага: цели → неудовлетворённости → первый WeekPlan → MEMORY.md.»

### 2.1. Цели (5 мин)

Спроси:
- «Кем хочешь быть через год?»
- «Чему хочешь научиться?»
- «Какие 2-3 крупные цели на ближайшие 3-6 месяцев?»

Запиши ответы в `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/docs/Strategy.md` по структуре:
- Видение (1 год)
- Цели на горизонт (3-6 месяцев)
- Принципы (что для меня важно)

### 2.2. Неудовлетворённости (5 мин)

Спроси:
- «Что сейчас мешает? Где разрыв между текущим и желаемым?»
- «Что регулярно раздражает или забирает энергию?»

Запиши в `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/docs/Dissatisfactions.md` списком: каждая неудовлетворённость = 1-2 строки.

### 2.3. Первый WeekPlan (10 мин)

На основе целей + неудовлетворённостей предложи 3-5 РП на ближайшую неделю. Для каждого:
- Название (существительное-артефакт)
- Бюджет (часы)
- Артефакт-критерий (что появится по завершении)

Запиши в `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/current/WeekPlan W{N}.md` (где N — номер ISO-недели).

### 2.4. Обновление MEMORY.md (2 мин)

В `~/.claude/projects/{{CLAUDE_PROJECT_SLUG}}/memory/MEMORY.md` добавь раздел «РП текущей недели» со списком из 2.3.

### 2.5. Закрытие initial-сессии

1. **Удали skeleton-marker** из `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/docs/Strategy.md` — строка `<!-- IWE-INITIAL-NEEDED: ... -->`. Без удаления skill будет каждый раз уходить в initial.
2. Скажи: «Готово. Завтра утром можешь сказать "открывай день" — Стратег соберёт DayPlan на сегодня. По понедельникам в 04:00 автоматически готовится session-prep для следующей сессии.»

---

## Шаг 3. Weekly flow

Если режим = weekly: загрузи `{{IWE_TEMPLATE}}/roles/strategist/prompts/strategy-session-weekly.md` и следуй ему.
