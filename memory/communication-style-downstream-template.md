---
name: communication-style-downstream-template
description: Шаблон для оформления downstream-файлов, которые наследуют базовый разговорный стиль IWE
type: reference
horizon: warm
domains: [communication, ux, template]
status: active
valid_from: 2026-06-01
owner: platform
schema_version: 1
---

# Шаблон downstream-файла для разговорного стиля

> Используй этот шаблон в любом промпте, инструкции или system prompt, где агент общается с людьми.
> Скопируй блок ниже и дополни channel-specific правилами.

---

## Стиль общения

Стиль общения - по `communication-style-base.md`.
Базовые правила inline ниже (синхронизируются скриптом `scripts/sync-communication-style.sh`).
Дополнительные правила этого канала или роли - ниже.

<!-- COMMUNICATION-STYLE-BASE-START -->
[Сюда скрипт вставляет базовые правила из communication-style-base.md автоматически.
Не редактируй вручную - правки затрутся при следующей синхронизации.]
<!-- COMMUNICATION-STYLE-BASE-END -->

---

## Дополнительные правила (channel-specific или role-specific)

[Здесь пиши правила, которые специфичны только для этого канала или роли.
Например: форматирование Telegram, онбординг новичка, ролевые ограничения Навигатора.]

**Примеры для разных downstream:**

**Telegram-бот:**
- Команды (`/start`, `/help`) - только plain text, не в `<code>`.
- Заголовки markdown (`#`, `##`) - не работают. Вместо них - `*жирный текст*`.
- Таблицы - не рендерятся. Вместо них - списки с `*жирным*` для заголовков.
- Стандартный ответ - до 80 слов.

**Браузер (claude.ai):**
- До 7 пунктов, помещается в один экран.
- Не упоминай технические детали подключения (URL, OAuth flow), если пользователь не спрашивает.

**Чат с пилотом (Claude Code, Kimi):**
- Режим «на пальцах» по умолчанию.
- Технический режим - только если пилот сам пишет `grep`, `git`, пути, SHA.

---

## Как добавить новый downstream

1. Скопируй блок «Стиль общения» выше в свой файл.
2. Не трогай содержимое между `<!-- COMMUNICATION-STYLE-BASE-START -->` и `<!-- COMMUNICATION-STYLE-BASE-END -->`.
3. Допиши свои channel-specific правила ниже.
4. Зарегистрируй путь в `scripts/sync-communication-style.sh`.
