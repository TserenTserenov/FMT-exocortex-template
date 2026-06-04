---
step: "08"
title: "Утверждение и синхронизация"
gate: user
---

# Step 08: Утверждение и синхронизация

## ВДВ

| | |
|---|---|
| **Вход** | WeekPlan draft, обновлённые Strategy.md, Dissatisfactions.md |
| **Действие** | Пилот подтверждает план → синхронизировать все артефакты |
| **Выход** | Утверждённый WeekPlan (`status: confirmed`), обновлённые MEMORY, MAPSTRATEGIC, очищенный inbox |

## Инструкция для Claude

1. **Утверждение:**
   - Пилот подтверждает план
   - Смени `status: draft` → `status: confirmed` в WeekPlan

2. **Синхронизация (ОБЯЗАТЕЛЬНО):**
   - **MEMORY.md** → секция «РП текущей недели» через `bash scripts/memory-active-wp-update.sh`
   - **Strategy.md** — если добавлена работа, не отражённая в стратегии
   - **MAPSTRATEGIC.md** — если элемент из MAPSTRATEGIC взят в работу → `in-progress`; если фаза завершена → `done`
   - **Очисти** обработанные из `fleeting-notes.md` и `inbox/`

3. **Commit:**
   - Закоммить изменения в governance-репо и затронутые репо

4. **Результат:**
   - Утверждённый WeekPlan W{N} (`status: confirmed`)
   - Обновлённые Strategy.md, MEMORY.md, MAPSTRATEGIC.md
   - Очищенный inbox

---

Сессия завершена.
