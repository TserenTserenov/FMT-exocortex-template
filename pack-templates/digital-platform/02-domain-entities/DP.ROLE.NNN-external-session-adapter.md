---
id: DP.ROLE.NNN
name: External Session Adapter
name_ru: Адаптер внешних сессий
name_en: External Session Adapter
type: role
status: draft
layer: L4-Platform
summary: "Мост между внешним каналом (Telegram) и локальным исполнителем (Claude Code). Поддерживает multi-turn диалог: каждый ход дописывается в SESSION-thread, Egress запускает Claude Code с полным контекстом. Capability scope: код+git, calendar, WP, IWE-знания. Две sub-responsibility: Ingress (cloud) и Egress (local)."
owner_role: R14 Заказчик (пилот) — как потребитель; DP.ROLE.045 Диспетчер — как смежная роль в inbox
created: 2026-05-27
updated: 2026-05-27
related:
  realizes: DP.SC.NNN           # External Working Session
  uses:
    - DP.SC.135                 # Agent Inbox — смежный, не путать (разные папки)
    - DP.SC.161                 # Session Memory Injector — вызывается при каждом ходе
  see_also:
    - DP.ROLE.045               # Диспетчер (batch-режим, отдельный контракт)
    - DP.ROLE.059               # Маршрутизатор (routing-layer)
wp: WP-358
---

# [DP.ROLE.NNN] Адаптер внешних сессий

## Назначение

Мост между внешним каналом (Telegram) и локальным исполнителем (Claude Code).

**Ключевые принципы:**
- Не выполняет задачу — только маршрутизирует ходы сессии между каналами
- Поддерживает multi-turn: накапливает thread, передаёт полный контекст каждому ходу
- Распределённая роль: два deployment-endpoint с разными auth-границами
- Один logical owner — оба endpoint реализуют контракт DP.SC.NNN

---

## Sub-responsibilities

### Ingress Adapter (облачный, `aist-bot`, cloud-side)

**Кто:** компонент Telegram-бота (`@<ваш_бот>`), деплоится в cloud.

**Обязанности (первый ход — открытие сессии):**
1. Принять первое сообщение `/claude [--private] <текст>` из разрешённого чата
2. Авторизовать: `tg_chat_id ∈ allowed_list` (config-based, MVP)
3. Создать `inbox/agent/sessions/SESSION-<id>.md` через GitHub API с frontmatter:
   - `session_id`, `tg_chat_id`, `created_at`, `private`, `status: active`
4. Записать первый ход в `SESSION-<id>-thread.md`:
   ```
   [turn:1, tg_msg_id:<N>, ts:<ISO>] Пилот: <текст>
   ```
5. Отправить acknowledgment «Работаю…» в Telegram ≤10с

**Обязанности (последующие ходы):**
1. Найти активную сессию по `tg_chat_id` в SQLite Ingress (или через GitHub API lookup)
2. Проверить idempotency: `(tg_chat_id, message_id)` — не обрабатывать дважды
3. Дописать ход в `SESSION-<id>-thread.md` через GitHub API
4. Отправить «Работаю…» ≤10с

**Обязанности (закрытие):**
- `/close` от пилота → обновить `SESSION-<id>.md`: `status: closed`

**Полномочия:** read `allowed_list`, GitHub API read/write `inbox/agent/sessions/`, `send_telegram_message`.

**НЕ делает:** не запускает сессию, не ждёт результата.

---

### Egress Adapter (локальный, `iwe-agent-dispatcher.py --mode session`, local-side)

**Кто:** расширение `iwe-agent-dispatcher.py`, деплоится на машине пилота (или на удалённом сервере).

**Обязанности (на каждый новый ход):**
1. Обнаружить новый ход в thread (launchd/systemd poll каждые 15с через `git pull`)
2. Проверить: уже обработан этот `turn_n` по SQLite (`~/.iwe/sessions.db`)? → skip
3. Вызвать Session Memory Injector (DP.SC.161) для pre-flight обогащения контекста
4. Запустить `claude -p` с полным `SESSION-<id>-thread.md` + capability-инструкциями как stdin
5. Heartbeat self-check: ping в SQLite каждые 30с; miss >90с → `failed` + TG alert
6. Получить ответ Claude Code (stdout)
7. Дописать ответ в thread: `[turn:N+1-response, ts:<ISO>] Claude: <ответ>`
8. Зафиксировать domain event (activity tracking): `activity_log` + WakaTime heartbeat
9. Отправить ответ в Telegram через `send_telegram_message`
10. Обновить `SESSION-<id>.md`: `last_turn_at`, `turn_count`, статус

**Полномочия:** read/write `inbox/agent/sessions/`, read/write `~/.iwe/sessions.db`, запуск `claude -p` CLI, использовать `send_telegram_message`, доступ к capability-инструментам (calendar MCP, `create-wp.sh`, `knowledge_search`).

**НЕ делает:** не выбирает содержание ответа — это задача Claude Code.

---

## Capability scope

Egress передаёт Claude Code доступ к следующим инструментам:

| Capability | Инструмент | Примеры запросов |
|-----------|-----------|-----------------|
| Код + git | Claude Code native | фиксы, коммиты, создание файлов |
| Календарь | Google Calendar MCP | «поставь встречу с Андреем завтра в 15:00» |
| Создание РП | `create-wp.sh` | «сформируй новый РП: ...» |
| IWE-знания | `knowledge_search` MCP | «найди в IWE информацию про ...» |
| Telegram | `send_telegram_message` | возврат ответа пилоту |

Расширение scope: добавить capability в этот раздел + передать инструмент в `--mode session` конфигурацию диспетчера.

---

## Deployment options для Egress

| Вариант | Где | Триггер | Ограничение |
|---------|-----|---------|------------|
| **Mac-local (MVP)** | Машина пилота | launchd plist | Требует включённый Mac + VS Code |
| **Удалённый сервер (пилот, Post-MVP)** | Linux-сервер пилота (всегда включён) | systemd unit | Headless `claude -p`, без Local Gateway |
| **Per-machine (community)** | Машина пользователя | launchd/systemd | Инсталляция per-machine |

Примечание: удалённый сервер лишается Local Gateway (открытые файлы, peer-координация) — только `claude -p`. Для пилота это компромисс для «в дороге без Mac». ArchGate при введении community-tier.

---

## Инварианты роли

1. **Идемпотентность через composite key.** `(tg_chat_id, message_id)` проверяется до записи хода (Ingress) и до запуска обработки (Egress). Повторный запрос с тем же key — no-op с возвратом текущего статуса.

2. **Atomicity acknowledgment.** Ingress НЕ возвращает ответ до записи хода в thread. Если GitHub API упал → пользователь получает «Не удалось принять ход», не acknowledgment.

3. **Heartbeat ≠ session signal.** Heartbeat Egress — self-healthcheck диспетчера (ping в SQLite), не сигнал от активной сессии. Длительный heavy-запрос не должен ложно тригеррить `failed` из-за отсутствия activity.

4. **Private audit trail.** Для `--private` сессий: thread-файл хранится ТОЛЬКО в `~/.iwe/sessions.db` (никогда не в git). SESSION-файл содержит только метаданные.

5. **Graceful degradation.** VS Code / `claude -p` не запустились → Egress фиксирует timeout → TG «Среда не запущена». Тихий fail запрещён.

6. **Activity tracking.** Каждый обработанный ход пишет domain event `external_session_turn` в `activity_log` и WakaTime heartbeat. Пропуск трекинга = нарушение инварианта.

---

## Масштабирование (Multi-pilot future, Q4 WP-358)

| Компонент | MVP | Multi-pilot |
|-----------|-----|------------|
| Ingress Adapter | один экземпляр (один пилот) | горизонтальное масштабирование (cloud stateless) |
| Egress Adapter | привязан к машине пилота | per-pilot инстанс (Mac/Linux) |
| SESSION-файлы | один репозиторий | per-pilot namespace или multi-tenant repo |
| Authorization | tg_chat_id allowlist | Ory OAuth2 (пост-MVP, ArchGate) |

---

## Отличие от DP.ROLE.045 (Диспетчер)

| Аспект | DP.ROLE.045 Диспетчер | DP.ROLE.NNN Адаптер |
|--------|----------------------|---------------------|
| Контракт входа | Task с `due/template/acceptance` | Session thread (real-time, multi-turn) |
| Папка | `inbox/agent/tasks/` | `inbox/agent/sessions/` |
| SLA | ≤1ч (batch) | acknowledgment ≤10с per ход |
| Capability | выполняет task по шаблону | полный capability scope (calendar, WP, IWE) |
| Failure mode | retry с exponential backoff | TG alert + graceful fail |
| Trigger | cron/systemd | launchd/systemd poll 15с |
| Deployment | headless, без VS Code | primary: VS Code; fallback: headless на удалённом сервере |

---

## Kind и Owner

- **Kind:** Bridge Role (соединяет два runtime — cloud и local, накапливает multi-turn state)
- **Owner Role в надсистеме:** Заказчик (R14) как потребитель сервиса; Infrastructure как operator
