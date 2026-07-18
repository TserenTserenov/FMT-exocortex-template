---
name: lesson-close
description: Закрыть занятие, открытое скиллом /lesson. Финализирует lesson/YYYY-MM-DD.md (frontmatter status, метаданные времени, длительность), делает commit + push в репо personal-guide. Триггерит замкнутый контур доставки — после push → GitHub webhook → bot oauth_server.py:/webhook/github/workbook → sync_one_user_to_dt → ЦД обновляется в Neon. Используй когда пилот говорит «закрываем», «всё», «закончили», «закрой урок» — или после явного завершения задания в /lesson.
argument-hint: "[необязательно: дата урока YYYY-MM-DD; по умолчанию сегодня; либо --skipped если урок был пропущен; --no-push для локального commit без push]"
experimental: true
sunset: "после WP-301 Ф6 (E2E smoke) и WP-149 Block D (ИИ-агент-носитель Портного)"
related: [WP-149, WP-175, WP-245, WP-301, lesson, PD.METHOD.008]
version: 1.0.0
layer: L1
status: active
triggers:
  slash: [/lesson-close]
  phrases: []
routing:
  executor: script
  deterministic: true
  script_path: "scripts/lesson-close.sh"
  optimization_priority: 2
agents: none
interaction: one-shot
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл; WP Gate применим только при создании нового РП, не для операционных вызовов"
---

# /lesson-close — закрыть занятие и замкнуть контур доставки

> ⚡ **Алгоритм, не диалог.** Шаги 1-5 последовательно. Без вопросов.

## When to use

Закрыть занятие, открытое скиллом /lesson. Финализирует lesson/YYYY-MM-DD.md (frontmatter status, метаданные времени, длительность), делает commit + push в репо personal-guide. Триггерит замкнутый контур доставки — после push → GitHub webhook → bot oauth_server.py:/webhook/github/workbook → sync_one_user_to_dt → ЦД обновляется в Neon. Используй когда пилот говорит «закрываем», «всё», «закончили», «закрой урок» — или после явного завершения задания в /lesson.

## Контракт скилла

- **Вход:** существующий `lesson/YYYY-MM-DD.md` в репо `personal-guide` со статусом `status: in_progress` (создан скиллом `/lesson`). Активный git remote с правом push.
- **Выход:** lesson-файл с финализированным frontmatter (`status: done|partial|skipped`, `finished_at`, `duration_min`) + git commit + git push. На сервере: webhook triggered → `sync_one_user_to_dt(user_id)` → Neon `digital_twins.data['2_collected']` обновлён + событие в `public.domain_event`.
- **Время:** ≤2 мин (быстрая финализация после `/lesson`).
- **Не делает:** не оценивает качество ответа (Оценщик R12 — отдельно, асинхронно); не генерирует assignment на завтра (Портной, ночной рендер).

## Algorithm

## Шаг 1. Вызов через Маршрутизатор

```bash
bash "$IWE_SCRIPTS/route-task.sh" --skill lesson-close --args "<YYYY-MM-DD> [--no-push]"
```

Скрипт `lesson-close.sh` выполняет:
1. Находит lesson/YYYY-MM-DD.md
2. Обновляет frontmatter (`status: done`, `finished_at`, `duration_min`)
3. `git add`, `git commit`, `git push`

**Если `--no-push` передан** — push пропускается.

**Если push fails** — скрипт сообщает ошибку; контур замкнётся при ручном `git push`.

## Шаг 2. Сообщить пилоту о замыкании контура

После успешного выполнения:

```
✅ Урок закрыт.
Статус: <status>
Длительность: <duration_min> мин
Коммит: <short_sha>

Контур замкнут:
  lesson/<date>.md → git push → GitHub webhook → Activity Hub → Neon (ЦД)
  Завтрашний assignment Портной отрендерит на свежих данных.
```

Не нужно ждать или проверять, что webhook реально сработал. Он асинхронный, факт push — единственное, что от тебя требуется. Если интересно: проверь логи `[WorkbookWebhook]` в Railway аист-боте.

## Шаг 3. Граничные случаи

| Ситуация | Действие |
|---|---|
| Урок со статусом `done` уже (повторный close) | Сообщи: «Урок уже закрыт. Если нужно переоткрыть — измени status: in_progress вручную или удали finished_at.» |
| Нет git remote / нет прав push | Сообщи и предложи проверить `git remote -v` и `gh auth status`. Финальный коммит локально остаётся. |
| Merge-conflict при push | НЕ разрешать автоматически. Сообщи пилоту: «Кто-то ещё пушил в этот репо. Проверь: `git pull --rebase` и реши конфликт.» |
| Очень короткое занятие (<3 мин) | Записать как обычно, не оценивать. Поле `duration_min` уйдёт в метрику. |
| Длинное занятие (>60 мин) | То же. Метрика покажет реальное время. |
| Пилот хочет сменить тему текущего занятия задним числом | Не редактируй `theme` или `element_id` — это нарушает соответствие assignment ↔ lesson. Если нужно — открой новый lesson вручную. |

## Связь с другими механизмами

- **`/lesson`** — парный скилл, открывает занятие, создаёт lesson-скелет.
- **GitHub webhook** — handler в бот-репозитории (`oauth_server.py`, роут `POST /webhook/github/workbook`). HMAC-секрет = `GITHUB_WORKBOOK_WEBHOOK_SECRET` в env. Регистрируется один раз в `personal-guide` репо: Settings → Webhooks.
- **Активность в Neon:** webhook записывает событие в `public.domain_event` (source=`iwe`, event_type=`lesson_closed`) и триггерит `sync_one_user_to_dt(user_id)` → пишет в `digital_twins.data['2_collected']`.
- **Профайлер (асинхронно):** отдельный сервис пересчитывает `3_derived` на основе обновлённого `2_collected`. Запускается отдельным cron.
- **Портной (следующий рендер):** утром скилл `/personal-guide-render` (или ИИ-агент-носитель WP-149 Block D) читает свежий ЦД → новый `daily/<завтра>.md`.

## Антипаттерны

- ❌ Не делать commit без push, если `--no-push` не передан — контур не замкнётся
- ❌ Не редактировать тело lesson-файла (только frontmatter) — ответы пилота неприкосновенны
- ❌ Не пересоздавать lesson при повторном close — выйдет дубликат истории
- ❌ Не разрешать merge-conflict автоматически — может затереть незакоммиченные ответы
- ❌ Не «ждать ответ webhook» — он асинхронный, неблокирующий

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
