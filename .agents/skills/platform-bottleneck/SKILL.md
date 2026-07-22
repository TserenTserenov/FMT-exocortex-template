---
name: platform-bottleneck
description: "Скилл IWE — см. тело файла"
version: 1.0.0
layer: L1
status: active
triggers:
  slash: [/platform-bottleneck]
  phrases: []
routing:
  executor: agent
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

Извлечь `--horizon` и `--subsystem` из аргументов вызова.

### Шаг 2. Делегировать в /bottleneck-pick

Без `--subsystem`:

```
/bottleneck-pick --target c2:platform --layer platform [--horizon <h>]
```

С `--subsystem`:

```
/bottleneck-pick --target c2:platform --layer platform --subsystem <s> [--horizon <h>]
```

### Шаг 3. Вернуть результат

Результат `/bottleneck-pick` передаётся пилоту без изменений.

## Полная документация

→ `/bottleneck-pick` SKILL.md (секция `--layer=platform`)
→ DP.SC.152 (обещание платформо-специфичного анализа)

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
