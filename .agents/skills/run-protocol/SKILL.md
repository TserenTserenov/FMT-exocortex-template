---
name: run-protocol
description: Step-by-step execution of the OWC protocol with mandatory checkpoint at each step. Prevents skipping steps (including verification).
argument-hint: "[open|close] [day|session]"
routing:
  executor: agent
  deterministic: false
---

# Выполнение протокола

> **Принцип:** Протокол = последовательность шагов. Каждый шаг отмечается ДО перехода к следующему. Пропустить шаг нельзя.
> **Проблема, которую решает:** Агент «забывает» финальные шаги (верификация, backup) из-за загрязнения контекста (SOTA.002).

**Аргументы:** $ARGUMENTS

## Шаг 1. Определить протокол

| Аргумент | Маршрутизация (краткая) | Полный алгоритм |
|----------|------------------------|-----------------|
| `day-open` / `open day` | `memory/protocol-open.md` (§ Масштаб: День) | `.agents/skills/day-open/SKILL.md` |
| `open session` или задание | `memory/protocol-open.md` (§ Масштаб: Сессия) | — (inline в protocol-open.md) |
| `day-close` / `close day` | `memory/protocol-close.md` (§ Маршрутизация) | `.agents/skills/day-close/SKILL.md` |
| `close session` | `memory/protocol-close.md` (§ Quick Close) | — (inline в protocol-close.md) |
| `week-close` | `memory/protocol-close.md` (§ Маршрутизация) | `.agents/skills/week-close/SKILL.md` |

> Если у аргумента есть Skill-файл → читай его (содержит полный алгоритм + чеклист). Protocol-файл = слим-маршрутизатор + Quick Close inline.

## Шаг 1b. Загрузить extensions (БЛОКИРУЮЩЕЕ)

Определи имя протокола: `day-open`, `day-close`, `week-close`, `protocol-close`, `protocol-open`.

Проверь и прочитай (если существуют):
1. `extensions/{protocol}.before.md` → добавить как **первые** шаги в update_plan
2. `extensions/{protocol}.after.md` → добавить как шаги **после** основного алгоритма, **перед** верификацией
3. `extensions/{protocol}.checks.md` → добавить как шаг **перед git commit** (БЛОКИРУЮЩЕЕ: commit запрещён до прохождения checks)

Не существует → пропустить молча. Существует → прочитать и включить в план.

## Шаг 2. Извлечь шаги

Из алгоритма протокола (Skill-файл или protocol-файл) и extensions извлеки пронумерованный список шагов. Запиши их как задачи (update_plan):

Порядок задач:
1. Extensions `.before.md` (если есть)
2. Основные шаги из алгоритма
3. Extensions `.after.md` (если есть)
4. Extensions `.checks.md` + git commit (если есть артефакт для коммита)
5. Верификация по чеклисту (`/verify`)

- Каждый основной шаг = отдельная задача
- Последняя задача ВСЕГДА = «Верификация по чеклисту (/verify)»
- Статус: pending

## Шаг 3. Выполнять последовательно

Для каждого шага:
1. Отметь шаг как `in_progress`
2. Выполни его
3. Отметь как `completed`
4. Перейди к следующему

**БЛОКИРУЮЩЕЕ:** НЕ пропускай шаги. Если шаг невозможен — отметь как blocked и спроси пользователя.

## Шаг 4. Верификация (финальный шаг)

После выполнения всех шагов:
1. Вызови `/verify` с указанием артефактов протокола
2. Верификатор (лёгкий субагент R23) пройдёт чеклист
3. По ❌ — исправить ДО показа результата пользователю

## Правила

- Один шаг `in_progress` одновременно
- Не забегай вперёд — контекст загрязняется (SOTA.002)
- При PreCompact — запиши в `.claude/checkpoint.md` на каком шаге остановился
- Если протокол прерван пользователем — запиши оставшиеся шаги в checkpoint
