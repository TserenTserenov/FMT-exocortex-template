---
name: day-close
description: "Протокол закрытия дня (Day Close). Алиас для /run-protocol close day -- симметрия с /day-open."
argument-hint: ""
version: 1.0.0
---

# Day Close (алиас)

> **Симметрия:** `/day-open` открывает день, `/day-close` закрывает.
> **Реализация:** делегирует в `/run-protocol close day`.

Выполни `/run-protocol close day` с полным алгоритмом из `memory/protocol-close.md § День`.

### T-чеклист

> См. [memory/t-checklist.md](../../../../memory/t-checklist.md) раздел Day Close (T6-T14). Пункты должны быть выполнены перед close.
