---
# see DP.SC.153, DP.ROLE.057
# SKILL.md v2 — обязательные поля (без них validate-skill.sh провалится)
name: skill-id                    # kebab-case, уникален в skills-catalog.yaml
description: "One line — used in CLAUDE.md system-reminder and the skill catalog."
version: 1.0.0                    # semver; увеличивать при изменении обещания
layer: L3                         # L1 = платформенный (FMT); L3 = авторский (личный)
status: active                    # active | experimental | deprecated
triggers:
  slash: [/skill-id]              # slash-команды (/skill-id)
  phrases: []                     # фразы для авто-детекции (опционально)

# Опциональные поля — заполнять если применимо
# depends_on: []                  # id других скиллов (прямые зависимости)
# owner_role: R6                  # роль-носитель (R6 Кодировщик, R1 Стратег, …)
# argument-hint: "[аргумент]"     # подсказка для $ARGUMENTS (backward compat)
# inputs:
#   - name: param
#     description: "Что это"
#     required: false
# outputs:
#   - name: result
#     description: "Что возвращает"
# annotations:
#   destructive: false            # скилл удаляет/изменяет данные без возможности откатиться?
#   interactive: true             # требует диалога с пользователем?
# related: []                     # РП, DP.SC, роли (информационная связь, не зависимость)
# sunset: ""                      # когда планируется удалить (для experimental)
---

# /skill-id — Название скилла

> **Роль:** [R# Название]
> **Триггер:** [когда вызывается]
> **Service Clause:** [DP.SC.NNN или DP.SC.153 (родительский)]

## Обещание (контракт)

**Вход:** [что принимает]
**Выход:** [что возвращает]
**Инвариант:** [что гарантируется всегда]

## Алгоритм

### Шаг 1. [Название]

[Описание шага]

### Шаг 2. [Название]

[Описание шага]

## Режим отказа

| Сценарий | Поведение |
|---------|-----------|
| [условие] | [что делать] |
