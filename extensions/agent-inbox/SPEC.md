---
wp: 324
phase: Ф2
type: architecture-spec
date: 2026-05-17
status: draft
related:
  pack:
    - DP.SC.135-agent-inbox
    - DP.ROLE.045-dispatcher
  wp: [321, 316, 272, 295]
---

# Agent Inbox — спецификация конвейера агентных задач IWE

> **Назначение:** единое место в governance-репо, где пилот ставит задачу агенту «на потом» и забирает результат при открытии дня. Поверх существующей инфраструктуры (claude.ai CCR + systemd на личном сервере), не вместо.

## 1. Проблема

Из Ф1-инвентаризации (18 рутин, 4 канала):
1. **Постановка задачи разбросана** — inline в `RemoteTrigger create`, bash-скрипты на личном сервере, ad-hoc CLI вызовы. Нельзя посмотреть список «что висит для агента» одним местом.
2. **Шаблонов промптов нет** — каждый раз пишется заново. Удачные паттерны не накапливаются.
3. **Куда падает результат — неоднозначно.** Один файл может оказаться на main, на feature branch, в PR, в Gmail, в Neon-таблице или просто в чате. Пилот не знает, где смотреть.
4. **Lifecycle статусов невидимый.** Запустилось / упало / в работе / ждёт ввода — узнаётся только через explicit query (RemoteTrigger get, journalctl).
5. **Audit-trail не масштабируется.** Завершённые рутины оседают в `run_once_fired` без сводки «что было сделано за неделю агентами».

## 2. Решение (короткий нарратив)

`<governance-repo>/inbox/agent/` — единая папка-инбокс агента. Внутри:

```
inbox/agent/
├── tasks/        # активные task-файлы (frontmatter: id, kind, status, agent, due; body: prompt + acceptance)
├── results/      # result-файлы (ссылка на task + артефакт + audit-trail)
├── scout/        # дневные находки (переиспользует существующий scout, но реестром файлов)
├── templates/    # шаблоны промптов (analyze-section, scout-daily, evolution-cron, soak-verify, retro)
└── archive/      # YYYY/ закрытые task'и + результаты
```

**Dispatcher** (часовая рутина) — забирает `tasks/*.md` со `status: pending` и `due ≤ now`, запускает их через выбранный канал с инжекцией промпта из шаблона, записывает `task_id ↔ trigger_id/run_id` mapping.

**Каналы запуска (выбор зависит от потребностей задачи):**

| Канал | Когда | Реализация |
|-------|-------|------------|
| `claude` CLI headless (`claude -p`) | **Референсная (рекомендуемая) реализация** — не зависит от RemoteTrigger API, работает на любой машине с установленным claude CLI | `scripts/iwe-agent-dispatcher.py` в этом extension'е. Запуск через cron / systemd / launchd / GitHub Actions |
| RemoteTrigger (claude.ai CCR) | Когда задаче нужны MCP-коннекторы (Gmail / Calendar / IWE) | Через API claude.ai. Внимание: API в transition v1→v2 (см. WP-324 17 мая) — новые triggers могут отказываться |
| systemd на собственном сервере | Heavy workloads, нужен root/sudo | Wrapper-скрипт + systemd unit |
| local-launchd (mac) | Лёгкие задачи на основной машине | plist в `~/Library/LaunchAgents/` |

**Минимальная конфигурация для одного пилота:** один канал `claude` CLI headless. Покрывает ~80% задач (анализ, summary, retro, разведка).

**Scout CCR-рутина** (дневная) — переиспользует существующий `overnight-scout.sh` паттерн, но кладёт findings в `inbox/agent/scout/YYYY-MM-DD.md` (а не только в DS-agent-workspace).

**Task lifecycle:** `pending → assigned → in_progress → completed | failed | blocked`.

## 3. Формат task-файла

`tasks/TASK-YYYY-MM-DD-<slug>.md`:

```yaml
---
id: TASK-2026-05-17-analyze-section-11
kind: analyze | scout | evolution | soak | retro | research | publish
status: pending           # pending → assigned → in_progress → completed | failed | blocked
priority: P0 | P1 | P2 | P3
agent: ccr-opus | ccr-sonnet | remote-systemd | local-launchd
template: analyze-section # ссылка на templates/<name>.md
created: 2026-05-17T14:30:00+03:00
due: 2026-05-17T22:00:00+03:00       # когда должно быть запущено
wp: 321                              # связь с РП (опционально)
result_location:                     # ОБЯЗАТЕЛЬНО — единственная точка истины
  repo: DS-principles-curriculum
  branch: main                       # ИЛИ "PR: ccr-section-11"
  path: specs/v4-reference/Проверка/раздел-11-замечания.md
trigger_id:                           # заполняет dispatcher после запуска
  ccr: trig_NNNN
acceptance:
  - файл по result_location.path существует на result_location.branch
  - score ≥6/10 по WRITING-PIPELINE
  - audit-trail в results/RESULT-<id>.md записан
---

# Задача: <человекочитаемое название>

## Контекст
<краткое объяснение, зачем>

## Промпт (либо ссылка на template)
<содержательная часть, передаётся агенту>

## Параметры (для template)
- section_number: 11
- review_branch: main
```

## 4. Формат result-файла

`results/RESULT-<task-id>.md`:

```yaml
---
task_id: TASK-2026-05-17-analyze-section-11
trigger_id: trig_NNNN
status: completed | failed | partial
started_at: 2026-05-17T22:01:13+03:00
completed_at: 2026-05-17T22:24:55+03:00
model: claude-opus-4-7
cost_usd: 0.42
artifact_url: https://github.com/MimEcoSys/DS-principles-curriculum/blob/main/specs/v4-reference/Проверка/раздел-11-замечания.md
---

# Result для TASK-2026-05-17-analyze-section-11

## Артефакт
- Файл: `specs/v4-reference/Проверка/раздел-11-замечания.md` на `main`
- Commit: `abc1234`
- Score: 7/10 (по WRITING-PIPELINE)

## Audit-trail
- Запущен: dispatcher #N, 17 мая 22:01
- Шаги: clone → read → analyze → commit → push
- Ошибки: нет

## Капсула для пилота
Раздел 11 готов к ревью. Главные замечания: ...
```

## 5. Dispatcher — алгоритм

**Триггер:** CCR-рутина с `cron_expression: "0 * * * *"` (каждый час).

**Шаги при запуске:**
1. `git clone <governance-repo> --depth 50` → `cd inbox/agent/`
2. Найти `tasks/*.md` с `status: pending` и `due ≤ now()`.
3. Для каждого:
   a. Прочитать template из `templates/<task.template>.md`.
   b. Подставить параметры из task в шаблон.
   c. Вызвать `RemoteTrigger create` с собранным промптом + `result_location` встроен в инструкции.
   d. Записать `trigger_id` в task frontmatter.
   e. Изменить `status: pending → assigned`.
4. Для каждой задачи в `status: assigned`:
   a. `RemoteTrigger get <trigger_id>` — проверить `ended_reason`.
   b. Если `run_once_fired` → проверить acceptance (например, файл на ветке) → `completed | failed`, записать result-файл.
5. Закоммитить + push <governance-repo>.

**Stop-conditions:**
- Если `tasks/` пуст → завершить (0 RemoteTrigger вызовов).
- Если >5 pending за один час → запускать только top-5 по `priority`, остальные оставлять на следующий час.
- Lock: `inbox/agent/.dispatcher.lock` файл с PID и timestamp; если lock моложе 50 мин — пропустить запуск (защита от параллельных dispatcher'ов).

## 6. Scout — алгоритм

**Триггер:** CCR-рутина с `cron_expression: "0 4 * * *"` (04:00 UTC — после локального `overnight-scout.timer`, если он настроен на сервере пилота).

**Шаги:**
1. Прочитать sources (заданы в trigger config): пилотные репо, ключевые dashboards, Issue-трекеры.
2. Применить шаблон `templates/scout-daily.md` — поиск findings по 5 категориям (платформа/контент/команда/мир/IWE).
3. Записать в `inbox/agent/scout/YYYY-MM-DD.md`.
4. Если есть findings с `priority: P0` → создать `tasks/` файл со `status: pending` (auto-promote).
5. git push.

**Связь с existing overnight-scout (B1):** существующий систем-таймер продолжает работать (читает discord/twitter/hn fast-changing). CCR-Scout — другой профиль (читает медленные источники, требующие LLM-анализа: PR'ы Repo'ев, длинные posts, GitHub Issues с обсуждением). Не дублируют — комплементарны.

## 7. Шаблоны промптов (templates/)

| Шаблон | Назначение | Параметры | Кто использует |
|--------|-----------|-----------|----------------|
| `_template.md` | Skeleton с placeholder'ами | — | как база для новых |
| `analyze-section.md` | Анализ раздела руководства по WRITING-PIPELINE v4 | section_number, repo, branch | WP-321, WP-300 |
| `scout-daily.md` | Дневная разведка медленных источников | sources, focus_areas | Scout CCR |
| `evolution-cron.md` | Еженедельная ревизия одного правила Pack | pack_repo, rule_glob | WP-272 weekly |
| `soak-verify.md` | Verify устойчивости сервиса за N часов | service_name, since, metrics | WP-277 паттерн |
| `retro.md` | Ретроспектива N инцидентов за период | period, source | Week Close доп. |

Каждый template:
- Содержит `{{placeholder}}` параметры.
- Имеет секцию «Acceptance criteria» (что вписывается в task.acceptance).
- Имеет секцию «Result location» (куда писать результат — задаёт invariant для агента).
- Имеет секцию «Failure modes» (что считать failure, не silently succeed).

## 8. Идемпотентность и однозначность места

**Инвариант (главное правило, выросло из Ф1 root cause):**
> Каждая task имеет ровно один `result_location` (repo + branch + path). Агенту запрещено самостоятельно выбирать branch/PR через fallback. Если place недоступен → status: failed, не silent push в другое место.

**Защита от навигационной потери:**
- result_location в task ⇒ dispatcher проверяет на acceptance ⇒ если файл не в указанной точке = failed
- Никаких `gh pr create` через if-else в промпте. Если решение «через PR» — task явно говорит `branch: PR:<name>`, и acceptance проверяет PR-existence.

## 9. ArchGate — ЭМОГССБ (conjunctive screening)

> DP.ARCH.001 §7. Один ❌ → пересмотр архитектуры. CLAUDE.md §5: блокирующее.

| Характеристика | Оценка | Обоснование |
|----------------|--------|-------------|
| **Э — Эволюционируемость** | ✅ | Task-файлы — markdown с frontmatter. Новый kind / template добавляется через файл, не через релиз. Lifecycle статусов расширяется через схему frontmatter (semver). |
| **М — Модульность** | ✅ | Чёткие границы: dispatcher не знает про специфику task'ов (читает template), templates не знают про dispatcher, result_location task'а не знает про реализацию push. Connascence — только по schema task-файла. |
| **О — Открытость** | ✅ | Templates — пользовательский слой. Любой пилот добавляет свой template без изменения dispatcher-кода. Promotion в FMT-extensions — стандартный канал шаринга. |
| **Г — Гомеостаз** | ⚠️ | Dispatcher lock защищает от параллельных запусков, retry-логика есть. **Слабое место:** если dispatcher CCR падает (timeout), задачи остаются в `assigned` без cleanup. Митигация — отдельный «sweeper» в Scout daily: задачи в `assigned` >2 часов → возвращаются в `pending` или помечаются `failed`. |
| **С — Сохранность** | ✅ | Все артефакты в git: task-файлы, result-файлы, archive. Backup сервера пилота (если настроен) покрывает <governance-repo>. Idempotency через `task_id` в RemoteTrigger metadata. |
| **С — Скорость** | ✅ | Часовой dispatcher — приемлемо для async-задач. Полу-реалтайм можно через `due: now()` + manual `RemoteTrigger run`. Latency dispatcher cycle ≤5 мин (clone + parse + N×RemoteTrigger create). |
| **Б — Безопасность** | ⚠️ | Промпты в task-файлах коммитятся в git → возможен secret leak (если кто-то напишет токен в задаче). **Митигация:** (1) `.gitignore` для `inbox/agent/tasks/*-secrets-*.md`; (2) pre-commit hook grep на API_KEY/TOKEN; (3) явное правило в README «секреты — через env, не в задаче». Также: dispatcher не должен выполнять произвольный bash из task'а — только через template-обвязку. |

**Verdict:** **2× ⚠️, 0× ❌ → PASS.** Реализация может стартовать. Митигации Г и Б включены в Ф3 (sweeper-функция в Scout + .gitignore + pre-commit hook + README warning).

## 10. IntegrationGate — шаги 1-3

> CLAUDE.md §2. Перед реализацией — обещание (DP.SC), сценарии, роль (DP.ROLE).

### Шаг 1. Обещание

`DP.SC.135-agent-inbox` (отдельный файл в PACK-digital-platform). См. §11 ниже.

### Шаг 2. Сценарии (≥3)

**Сценарий А: Анализ раздела руководства WP-321 (delayed batch).**
- Кто: пилот ставит task'и для разделов 11-15.
- Когда: вечер выходного, не хочет ждать N часов до завершения 5 анализов.
- Что делает: `Write inbox/agent/tasks/TASK-...-analyze-section-N.md` × 5, `git push`.
- Что происходит: dispatcher в ближайший час забирает все 5, запускает 5 RemoteTrigger'ов параллельно.
- Утром забирает: 5 result-файлов в `results/`, 5 файлов замечаний на main.

**Сценарий Б: Soak-verify сервиса (отложенный one-shot).**
- Кто: пилот (dev-роль) после deploy.
- Когда: deploy commit `abc1234`, хочет проверить через 24h.
- Что делает: task с `due: 2026-05-18T11:00`, `template: soak-verify`, `service_name: multi-domain-projection-worker`.
- Что происходит: dispatcher в указанный час запускает CCR, агент проверяет git log + посылает email-чеклист пилоту (паттерн WP-277).

**Сценарий В: Scout-finding auto-promote.**
- Кто: Scout CCR-рутина (она же агент).
- Когда: дневная разведка нашла критический сигнал (например, безопасность в pip-зависимости).
- Что делает: Scout пишет `inbox/agent/scout/2026-05-17.md` + auto-создаёт `inbox/agent/tasks/TASK-2026-05-17-cve-patch.md` со `status: pending, priority: P0`.
- Что происходит: dispatcher в ближайший час подхватывает, агент решает задачу или эскалирует в TG, если task требует human-input.

### Шаг 3. Роль

`DP.ROLE.045-dispatcher` (Диспетчер агентных задач) — см. §12.

## 11. DP.SC.135 — Agent Inbox обещание (черновик)

**Кому:** Создатель IWE (пилот) — DP.ROLE.001.

**Что обещает:** Поставленная в `inbox/agent/tasks/` задача со `status: pending` и `due ≤ NOW + 2h` будет запущена агентом не позднее чем через 1 час после `due`. Результат окажется ровно в `result_location` или task будет помечен `status: failed` с явной причиной.

**Триггер:** Появление в git нового `tasks/*.md` со `status: pending` + наступление `due`.

**Время отклика:** ≤1 час после `due`.

**Инвариант:** Каждая task в финальном статусе (completed/failed/blocked) имеет result-файл в `results/`. Никаких «висящих» assigned >2 часов (Scout sweeper возвращает в pending).

**Режим отказа:**
- Dispatcher CCR упал → следующий запуск через час подхватит зависшие assigned (lock cleanup).
- RemoteTrigger create вернул 5xx → task остаётся в pending, retry через час, после 3 неудач → failed с причиной.
- result_location недоступен → status: failed, артефакт сохранён в результе как fallback.

**Контрол-обещания:**
- Если pending >5 → задачи >P1 ждут на следующий час, P0-P1 запускаются сразу.
- Если cost_total за день >$X → throttle (TBD после первой недели реальных метрик).

## 12. DP.ROLE.045 — Dispatcher (черновик)

**Kind:** Coordinator Role — управляет очередью, не выполняет содержательную работу.
**Owner Role:** IWE Platform.

**Миссия:** Гарантировать, что pending task'и из `inbox/agent/` запускаются вовремя через подходящий канал (CCR / remote-systemd / local), и что результат фиксируется однозначно.

**Обязанности:**
- Читать `inbox/agent/tasks/*.md` каждый час.
- Сопоставлять `agent` → канал (ccr-opus → RemoteTrigger create, remote-systemd → SSH+systemd-run, local-launchd → osascript).
- Применять template (substitution параметров).
- Возвращать lifecycle: pending → assigned → in_progress → completed/failed/blocked.
- Писать result-файл и audit-trail.

**Полномочия:**
- Запускать `RemoteTrigger create` от своего account.
- Коммитить в `inbox/agent/` (через git push <governance-repo>).
- НЕ запускать произвольный bash из task body (только через template).
- НЕ менять `result_location` task'а (только записывать `trigger_id` + `status`).

**Связи:**
- DP.ROLE.001 IWE Creator — постановщик task'ов.
- DP.ROLE.039 Peer Agent — sibling (peer-агент может писать task для другого peer).
- DP.ROLE.044 Notification Dispatcher — потребитель: dispatcher уведомляет пилота через NotificationDispatcher если P0-task failed.

**Граница:** Не разбирает содержание task'а. Не интерпретирует промпт. Не выбирает branch.
