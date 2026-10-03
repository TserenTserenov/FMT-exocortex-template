---
name: platform-bottleneck
description: "Скилл IWE — см. тело файла"
version: 1.0.0
layer: L1
status: active
browser_safe: false
triggers:
  slash: [/platform-bottleneck]
  phrases: []
routing:
  executor: sonnet
  deterministic: false
agents: single
interaction: multi-step
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл; WP Gate применим только при создании нового РП, не для операционных вызовов"
---

# Skill: /platform-bottleneck

> **Алиас.** Делегирует в `/bottleneck-pick --layer platform`.
>
> Решение (S-46, 2026-05-21): два скилла (intra + platform) объединены в один через `--layer` параметр. Отдельный скилл — избыточен. Оставлен как удобный триггер.
>
> SC: DP.SC.152. Носитель: DP.ROLE.054.

## When to use

Скилл IWE — см. тело файла

## Algorithm

### Шаг 1. Разобрать аргументы

Извлечь `--horizon`, `--subsystem` и необязательный `--systems-map <путь>` из аргументов вызова. Путь к карте — пользовательские данные, не часть публичного шаблона.

### Шаг 2. Проверить карту систем

До делегирования определить корень установленной рабочей области (`WS="${IWE_WORKSPACE:-$PWD}"`) и загрузить его `.iwe-paths`: `. "$WS/.iwe-paths"`. Если файла нет или `IWE_TEMPLATE`/`IWE_WORKSPACE` пусты — сообщить, что установка путей не завершена, и **остановиться**. Скрипт живёт во вложенном шаблоне, а не в `workspace/scripts`: выполнить `bash "$IWE_TEMPLATE/scripts/check-platform-systems-map.sh"`; если задан `--systems-map`, добавить `--map "<путь>"`. Код выхода 2: передать пользователю диагностику скрипта и **остановиться**, не строить анализ по неполной карте. Успешный вызов печатает проверенный путь из рабочей области; передать именно его в следующий шаг как один аргумент.

### Шаг 3. Делегировать в /bottleneck-pick

Без `--subsystem`:

```
/bottleneck-pick --target c2:platform --layer platform --systems-map "<проверенный_путь>" [--horizon <h>]
```

С `--subsystem`:

```
/bottleneck-pick --target c2:platform --layer platform --subsystem <s> --systems-map "<проверенный_путь>" [--horizon <h>]
```

### Шаг 4. Вернуть результат

Результат `/bottleneck-pick` передаётся пилоту без изменений.

## Полная документация

→ `/bottleneck-pick` SKILL.md (секция `--layer=platform`)
→ DP.SC.152 (обещание платформо-специфичного анализа)

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
