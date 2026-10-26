---
id: DP.SC.NNN
name: External Session Request
name_ru: Внешняя рабочая сессия
name_en: External Working Session
type: sc
status: draft
layer: L4-Platform
summary: "Пилот ведёт полноценную multi-turn рабочую сессию через Telegram — эквивалент окна VS Code, но асинхронно. Поддерживаются: диалог вопрос→ответ→вопрос, работа по РП, операции с календарём, создание РП, поиск по IWE. Все действия трекаются."
consumer: R14 Заказчик — пилот вне рабочего стола
created: 2026-05-27
updated: 2026-05-27
related:
  differs_from: DP.SC.135   # Agent Inbox — batch, due/template/acceptance, single-shot
  differs_from_2: DP.SC.013  # Work Session — in-IDE, синхронный, разный потребитель
  uses:
    - DP.ROLE.NNN             # External Session Adapter (исполнитель)
    - DP.SC.135               # Agent Inbox — НЕ нарушать (отдельная папка sessions/)
  see_also:
    - DP.SC.161               # Session Memory Injector — вызывается при старте каждого хода
wp: WP-358
---

# [DP.SC.NNN] Внешняя рабочая сессия

## Правило (инвариант)

> Нарушение любого = провал SC.

1. **Идемпотентность.** Composite key `(tg_chat_id, message_id)` — один Telegram-message создаёт ровно один ход. Повторный retry при сбое не порождает дубликат хода.

2. **Acknowledgment SLA.** Бот отвечает «Работаю…» в Telegram за P95 ≤10с с момента отправки сообщения. Acknowledgment не зависит от длительности обработки.

3. **Completion SLA.** P95 ≤45с для ходов `category: light` (ожидаемый ответ ≤200 токенов). Для `category: heavy` — async-режим: прогресс-нотификации каждые 15с, финальный ответ без гарантии SLA.

4. **PII guard.** Флаг `--private` → thread-файл не коммитится в git, хранится только в локальной SQLite (`~/.iwe/sessions.db`). В SESSION-файл пишутся только метаданные (session_id, status, timestamps).

5. **Timeout + Heartbeat.** `max_session_duration = 60 минут` с момента последнего хода (сессия закрывается после 60 мин тишины). Hard cut-off отдельного хода — 15 минут. Heartbeat диспетчера (self-check): ping в SQLite каждые 30с; miss >90с → статус `failed` + TG alert. Cancellation contract: `/cancel` от пилота → SIGTERM диспетчеру → partial transcript сохраняется → статус `cancelled`.

6. **Cleanup.** SESSION-файл и thread-файл архивируются в `inbox/agent/sessions/archive/` через 24ч после последнего хода или немедленно при `/close`. Папка `sessions/` не является постоянным хранилищем.

7. **Multi-turn continuity.** Каждое последующее сообщение пилота в том же Telegram-чате (без явного `/close`) считается следующим ходом той же сессии и дописывается в `SESSION-<id>-thread.md`. Claude Code запускается с полным контекстом thread. Идентификация сессии: `(tg_chat_id, active_session_id)` из SQLite.

**Failure mode:** VS Code не открыт или диспетчер не запущен → TG уведомление «Среда не запущена, запустите VS Code». Тихий fail запрещён.

---

## Обещание

**Кому:** Пилот (Заказчик, R14) — вне рабочего стола (метро, обед, прогулка, разъезды).

**Зачем:** Telegram становится полноценным рабочим окном наравне с VS Code. Работа не прерывается при отрыве от компьютера. Фикс требует нескольких итераций? Идёт диалог вопрос→ответ→вопрос без потери контекста. Нужно создать РП, поставить встречу или найти знание из IWE? Всё через один интерфейс.

**Что получит:**
- Acknowledgment в Telegram ≤10с (подтверждение, что ход принят)
- Ответ Claude Code — в том же Telegram-чате, с сохранением контекста предыдущих ходов
- Поддержка capability-запросов: `→ Календарь`, `→ РП`, `→ IWE-знания` (см. §Capability scope)
- Трекинг активности: все ходы пишутся как domain events (WakaTime + activity_log)
- Audit trail — SESSION-thread в git (если не `--private`)
- Graceful failure — явное сообщение если среда недоступна

**Критерий приёмки:** end-to-end от первого сообщения до ответа, P95 ≤45с для light-ходов, 5-ходовой smoke-диалог зелёный 5/5, трекинг активности зафиксирован.

---

## Сценарии использования

### Сценарий 1: Срочный фикс в multi-turn диалоге

**Потребитель:** Пилот в дороге, обнаружил баг в боте по алерту.

```
Пилот:  /claude разберись почему падает activity_emitter
Claude: Посмотрел логи Railway. Вижу ConnectionDoesNotExistError в строке 47.
        Это pooler маскирует FATAL. Переключить на unpooled endpoint?
Пилот:  да, переключи
Claude: Обновил DATABASE_URL в Railway env на unpooled. Нужен редеплой.
        Задеплоить?
Пилот:  да
Claude: Задеплоил. Smoke-тест: 3/3 PASS. Activity emitter работает.
```

Сессия: 5 ходов, ~8 минут. Контекст (Railway logs, файлы) держится через thread.

---

### Сценарий 2: Полноценная работа по РП «в поездке»

**Потребитель:** Пилот едет 40 минут на такси, хочет сдвинуть WP-358 Ф2.

```
Пилот:  /claude работаем по WP-358 Ф2, нужно описать spec inbox/agent/sessions/SPEC.md
Claude: Открываю WP-358 контекст... Вот черновик SPEC.md с frontmatter SESSION-<id>.
        Параметры: session_id, tg_chat_id, message_id, text, private, status.
        Добавить capability_tags?
Пилот:  добавь, и пусть thread_id тоже будет
Claude: Обновил. Создать файл?
Пилот:  да
Claude: Создал inbox/agent/sessions/SPEC.md, коммит готов. Пушить?
Пилот:  да
Claude: Запушил. Ф2 чеклист: ✅ SPEC.md создан. Следующий шаг — расширить dispatcher.
```

Та же мощность что в VS Code, только через Telegram.

---

### Сценарий 3: Структурированные поручения (calendar, РП, IWE)

**Потребитель:** Пилот на обеде, несколько быстрых поручений.

```
Пилот:  поставь встречу с Андреем завтра в 15:00 на 1 час, тема «WP-358 demo»
Claude: ✅ Встреча создана в Google Calendar: 28 мая, 15:00–16:00, «WP-358 demo», участник Андрей.

Пилот:  сформируй новый РП: «Автоматический деплой агентских workers»
Claude: РП создан: WP-361 «Автоматический деплой агентских workers», бюджет 8h.
        Добавлен в REGISTRY.md и WeekPlan W22. Нужен context-файл с фазами?

Пилот:  да, набросай Ф1
Claude: inbox/WP-361.md создан с Ф1 IntegrationGate (~2h): SC + Role + smoke-test. Коммит и пуш?
```

Все 3 поручения — одна сессия, без переключения инструментов.

---

## Capability scope

Сервис поддерживает следующие типы запросов без выхода из Telegram:

| Тип | Инструмент | Примеры |
|-----|-----------|---------|
| **Код и РП** | Claude Code + git | фиксы, коммиты, создание файлов, review |
| **Календарь** | Google Calendar MCP | создание / обновление / удаление событий, поиск свободного окна |
| **Создание РП** | `create-wp.sh` | новый РП в REGISTRY + WeekPlan + inbox + Linear |
| **IWE-знания** | `knowledge_search` MCP | поиск по Pack, CLAUDE.md, memory/ |
| **Telegram** | `send_telegram_message` | отправка ответа обратно пилоту |

Расширение scope через новые MCP-инструменты не требует изменения SC.162 — только обновления DP.ROLE.NNN §Capability.

---

## Реализующие роли и сервисы

| Компонент | Роль | Что делает |
|-----------|------|-----------|
| Ingress Adapter (aist-bot, cloud) | DP.ROLE.NNN §Ingress | Принять сообщение, авторизовать, дописать в SESSION-thread |
| Egress Adapter (dispatcher, local) | DP.ROLE.NNN §Egress | Обнаружить новый ход, запустить Claude Code с полным thread, вернуть ответ |
| Session Memory Injector | DP.SC.161 | Pre-flight каждого хода: инжектировать контекст из iwe_memory.db |
| Agent Inbox | DP.SC.135 | Смежный сервис — НЕ смешивать (разный контракт) |

---

## Пользовательский путь (один ход в multi-turn сессии)

| # | Шаг | Кто | Результат |
|---|-----|-----|----------|
| 1 | Отправить сообщение в `@<ваш_бот>` | Пилот | — |
| 2 | Проверить `tg_chat_id ∈ allowed_list` + найти активную сессию | Ingress Adapter | ack или «не авторизован» |
| 3 | Дописать ход в `SESSION-<id>-thread.md` через GitHub API | Ingress Adapter | Новый ход в thread |
| 4 | Ответить «Работаю…» в Telegram | Ingress Adapter | Acknowledgment ≤10с |
| 5 | git pull каждые 15с → новый ход в thread обнаружен | launchd → Egress Adapter | Trigger хода |
| 6 | Инжектировать Session Memory, запустить Claude Code с полным thread | Egress Adapter | Сессия активна |
| 7 | Claude Code выполняет работу (код/calendar/РП/IWE) | Claude Code | Transcript хода |
| 8 | Записать ответ в thread, отправить в Telegram, трекинг активности | Egress Adapter | Ответ пилоту + domain event |

---

## Финализация сессии (§close) — WP-358 Ф10

> **Проблема, которую закрывает:** SESSION-* файлы оставались в `inbox/agent/sessions/` после завершения разговора. Пилот не находил итог через сутки (только `session_id`-хеш в Telegram). Корень — асимметрия с правилом `sessions/YYYY-MM-DD-*.md` для peer-сессий (DP.SC.154).

### Триггер финализации

Один из:
- **Явно:** пилот пишет `/close` в Telegram-сессии
- **Неявно (TTL):** mtime сессии ≥ `inactivity_close_ttl` (по умолчанию 60 мин тишины)
- **Cron:** Day Open детектор обнаруживает `status: completed` И age≥24ч → флаг финализации (Эгресс выполняет в фоне)

### Шаги финализации (Egress-сторона)

| # | Шаг | Артефакт |
|---|-----|----------|
| 1 | Сгенерировать topic-slug из первой содержательной строки `SESSION-<id>-thread.md` (turn:1 role:pilot, ≤60 символов, kebab-case) | `<topic-slug>` |
| 2 | Создать `{{IWE_GOVERNANCE_REPO}}/sessions/external/YYYY-MM/SESSION-<id>/` | директория |
| 3 | Сформировать `report.md`: frontmatter (`session_id`, `date`, `topic`, `outcome`, `wp`, `turns`) + 5-10 строк итога | `report.md` |
| 4 | `git mv inbox/agent/sessions/SESSION-<id>{.md,-thread.md}` → `sessions/external/YYYY-MM/SESSION-<id>/{session.md,thread.md}` | перемещённое сырьё |
| 5 | Дописать строку в `sessions/external/00-index.md`: date, session_id, topic, status, ссылка на report | обновлённый индекс |
| 6 | Push в git | коммит |
| 7 | Telegram: прислать пилоту ссылку на `report.md` (не `session_id`) | сообщение |

### Frontmatter report.md (минимум)

```yaml
---
session_id: SESSION-<id>
date: YYYY-MM-DD
topic: "<one-line summary>"
outcome: consensus | abandoned | escalated | utility
wp: NNN | null              # связь с РП если упомянут в thread
turns: N
finalized_at: ISO8601
---
```

### Инвариант после финализации

- `inbox/agent/sessions/SESSION-<id>.md` НЕ существует
- `sessions/external/YYYY-MM/SESSION-<id>/{report,session,thread}.md` существуют
- Скрипт `check-open-sessions.sh` НЕ возвращает эту сессию

### Failure mode и компенсация

- **Пилот не пишет `/close`, TTL не сработал** → Day Open детектор показывает в DayPlan секцию «🔴 Незакрытые сессии». Пилот решает: финализировать вручную или продолжить.
- **`git mv` fail (rebase/conflict)** → оставить файлы на месте, отметить `status: completed`, повторить финализацию при следующем `/close` или вручную.
- **Backfill 52 pre-cutover файлов** — НЕ выполняется. Cutover-дата зашита в детектор (`SESSION_CUTOVER_DATE`).

### Артефакты-реализация

- Скрипт-детектор: `{{IWE_GOVERNANCE_REPO}}/scripts/check-open-sessions.sh`
- Day Open hook: `~/IWE/extensions/day-open.after.md § 7c`
- Day Close hook: `~/IWE/extensions/day-close.checks.md § Незакрытые external-сессии`
- Bot Telegram-ответ: `handlers/external_session.py` (формирование report-URL)

---

## Mac-зависимость и deployment options

| Вариант | Где запускается Egress | Подходит для | Ограничение |
|---------|----------------------|-------------|------------|
| **Mac-local (MVP)** | launchd на машине пилота | Пилот за компьютером | Требует открытый Mac |
| **Удалённый сервер (пилот, Post-MVP)** | systemd на сервере пилота (всегда включён) | Пилот в дороге без Mac | `claude -p` (headless, без VS Code Local Gateway) |
| **Per-machine (community)** | launchd/systemd на машине пользователя | Каждый пользователь IWE | Инсталляция per-machine |

**Примечание:** вариант с удалённым сервером теряет Local Gateway (открытые файлы, peer-координация) — только headless `claude -p`. Для пилота это приемлемо (полная среда — на Mac). ArchGate при переходе к community-tier.

---

## Post-MVP (Future)

- **Eager-pull:** GitHub webhook → tailscale funnel → локальный HTTP endpoint. Снижает git-sync latency с avg 7.5с до <1с.
- **Удалённый always-on Egress** для пилота: systemd unit вместо launchd, без зависимости от включённого Mac.
- **Голосовые ходы:** Telegram voice message → STT → ход в thread.

---

## Различения

- **Session request ≠ Task (DP.SC.135):** Task имеет `due/template/acceptance/result_location`, SLA ≤1ч, batch. Session — real-time без `due` и `template`, multi-turn. Тест: «есть `due` и `acceptance`?» Нет → session request. Отдельная папка `inbox/agent/sessions/`.
- **Session: light ≠ heavy:** light ≤200 токенов, sync SLA ≤45с. heavy >200 токенов или неопределённая длительность, async + прогресс-нотификации.
- **Ход (turn) ≠ Сессия:** Сессия = весь диалог (1..N ходов), идентифицируется `session_id`. Ход = одна пара запрос+ответ, идентифицируется `(session_id, turn_n)`.
