# Peer Conversation — Режимы interrupt / finalize / верификация

> Загружается из Шага 0 при `--interrupt` или `--finalize` (`.claude/skills/peer-conversation/SKILL.md`).

## Шаг 5. Interrupt-режим

При `--interrupt <session_id>`:

1. Извлечь месяц из id: `MONTH=$(echo "$session_id" | cut -c1-7)` → найти `sessions/$MONTH/$session_id/meta.yaml`.
2. Обновить (Bash sed): `status: interrupted`, `end_time: <now>`, `turns_count: <число файлов>`.
3. Найти строку с `<session_id>` в `sessions/00-index.md` и заменить: статус → `interrupted`, report → `—`.
4. Commit + push.

---

## Шаг 6. Finalize-режим

При `--finalize <session_id>`:

1. Извлечь месяц: `MONTH=$(echo "$session_id" | cut -c1-7)`. Проверить что папка `sessions/$MONTH/$session_id` существует и содержит хотя бы `00-writer.md`.
2. Прочитать `meta.yaml` — взять `task_description`, `start_time`, `escalations_count`.
3. Выполнить **Шаг 4.2** (синтез report.md через Agent tool) с теми же инвариантами и fallback.
4. Обновить `meta.yaml` (Bash sed): `status: completed`, `end_time: <now>`, `turns_count: <число файлов>`.
5. Обновить строку в `sessions/00-index.md`: статус → `completed`, report → ссылка.
6. Commit + push.

Используется для восстановления прерванных сессий без перезапуска turn-loop.

---

## Верификация отчёта

Для проверки любого существующего report.md написать в чат:
«проверь отчёт сессии `<session_id>`»

Запустить субагент (Sonnet, context isolation): прочитать все файлы сессии + report.md, сверить с инвариантами schema_version=1 (frontmatter, §4 непустой при agreed, verify-якоря).
