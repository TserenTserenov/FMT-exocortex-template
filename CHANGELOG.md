# Changelog

All notable changes to FMT-exocortex-template will be documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/).

## [0.28.2] — 2026-04-25

### Added
- **`memory/t-checklist.md`** — реестр T-действий ТО IWE: 22 действия в Session/Day/Week/Month Close, owner/trigger/symptom-if-skipped для каждого. Класс T (True maintenance, идемпотентно, автопилот). Verification — Haiku R23 (формальная проверка чеклиста). Источник: WP-217 Ф3 (промотировано из staging S-31, обкатка 14 дней).
- **`memory/r-questionnaire.md`** — R-вопросник Week/Month Close: 3 недельных + 6 месячных вопросов для переосмысления (не yes/no, экзоскелетный режим — агент даёт факты, человек судит). Класс R (Review/judgment). Включает M6 decommission-триаж (active → dormant → archived).
- **`.claude/sync-manifest.yaml`** — реестр пар «источник → производное» для `iwe-drift.sh`. Шаблон с 3 generic-парами (protocols-to-skills, protocol-open-to-day-open-skill, staging-validated-to-fmt) + закомментированные шаблоны для Pack↔DS, root-CLAUDE↔instrument, instrument-docs↔code. Секция `activity_checks:` для decommission-триажа в Month Close.
- **`scripts/iwe-drift.sh`** — R23-детектор drift'а пар (mtime-lag, без LLM). MVP-версия: shell + git + stat + awk, без внешних зависимостей. Usage: `bash scripts/iwe-drift.sh [--critical|--top N|--manifest PATH]`. Markdown-вывод для прямой вставки в DayPlan/Week Report.

### Changed
- Регламент техобслуживания IWE (элемент #15 культуры работы) теперь промотирован в шаблон: пользователи получают T-checklist, R-вопросник, drift-механизм при `update.sh`. Класс T/S/R закреплён в `.claude/rules/distinctions.md` HD «ТО ≠ Sync ≠ Review».

## [0.28.1] — 2026-04-25

### Changed
- **`memory/hard-distinctions.md`** — переписан: 631 → 374 строки (40% сокращение). 23 различения в порядке релевантности (Персона/Скрипт-Агент/MCP-имена/Лог-Инцидент сверху). 15 различений → `hard-distinctions_archive.md` (исторически важные, не используются в текущей работе >1 мес). 8 удалены полностью (тривиальные дубли slim distinctions.md). Для пилотов: новая компактная нумерация 1-23, прежние ссылки на номера >27 устаревают.
- **`memory/navigation.md`** — удалена авторская таблица MCP-исходников (`DS-MCP/knowledge-mcp/...`) и ссылка на authored MCP-search. Эти пути относятся к авторскому workspace, не к шаблону.
- **`memory/checklists.md`** — удалён давний урок про stale knowledge-mcp (фев 2026, не релевантен пилотам).
- **`memory/protocol-open.md`, `memory/repo-type-rules.md`, `roles/strategist/scripts/cleanup-processed-notes.py`** — placeholder-sub: `DS-my-strategy` → `DS-strategy` (унификация с FMT-конвенцией).
- **`CLAUDE.md`** — удалена строка «Бот = интерфейс / engines/tailor» в `### Различения (авторские)` §9 (специфика автора, не шаблон).

### Fixed
- **`template-sync.sh` strip-list расширен** (DS-ai-systems источник): `DS-MCP`, `knowledge-mcp`, `gateway-mcp`, `digital-twin`, `content-pipeline`, `engines/tailor` теперь вычищаются. Sync был застрял в FAILED state с ~21 апр (validation abort на этих паттернах в hard-distinctions.md HD #27 + #29). Теперь sync проходит validation.

## [0.28.0] — 2026-04-25

### Changed
- **`.claude/settings.json`** — `defaultMode` изменён с `"dontAsk"` на `"acceptEdits"`. Это исправление: `dontAsk` означает «по умолчанию **запрещать** инструменты вне allow-листа», что приводило к скрытым отказам и порождало повторные permission-запросы у пользователей. `acceptEdits` авто-аппрувит файловые операции (`Edit`/`Write`, `cp`/`mv`/`mkdir`/`touch`/`rm`/`rmdir`/`sed`) в рабочих директориях; deny-rules (`Bash(sudo *)`, `Bash(rm -rf *)`) остаются в силе. Для пользователей: меньше ненужных диалогов согласования, особенно при `update.sh`.
- **`memory/hard-distinctions.md` HD #27** переписан: «Бот ≠ Платформа; Neon + DT MCP = один ЦД» → «Персона ≠ Память ≠ Контекст». Новая модель пользовательских данных (DP.D.052, WP-257) с критерием разделения «writer + owner»: Персона = Git пользователя, Память = Neon платформы, Контекст = runtime LLM-вызова. Маппинг старого «ЦД» на новые слои + 5 категорий вне пользовательской модели + расщепление Памяти на Observed/Derived. SoTA: Letta, Mem0, LangMem, Anthropic Memory tool.
- **`memory/checklists.md`** — урок «MCP-индекс может вернуть stale» переформулирован с конкретной датой/документом.
- **`memory/protocol-open.md`, `memory/repo-type-rules.md`, `memory/navigation.md`** — мелкие уточнения формулировок.

### Fixed
- **`roles/strategist/prompts/note-review.md`, `session-prep.md`, `cleanup-processed-notes.py`** — точечные правки.
- **`roles/synchronizer/scripts/dt-collect.sh`** — упрощение (≈36 строк диффа).

### Meta
- **Drift CHANGELOG ↔ update-manifest.json** (5 версий 0.27.3-0.27.7 не имели bump манифеста, `update.sh --check` возвращал 0.26.1 как «актуальную»). Bump манифеста до 0.28.0 закрывает разрыв за один шаг. Системный фикс (pre-commit hook, не дающий закоммитить CHANGELOG без bump'а manifest) — отдельный РП, S-30 в STAGING.

## [0.27.7] — 2026-04-24

### Fixed
- **`roles/extractor/scripts/extractor.sh` + `roles/extractor/prompts/inbox-check.md`** (WP-7 Ф-1) — подсчёт pending captures и дефиниция в промпте. Старая логика `grep -c '\[analyzed'` ловила substring в описаниях/цитатах captures.md (например, в тексте капчи мог быть `[analyzed` как часть описания), не только реальные маркеры-статусы. На реальном файле: 166 заголовков, substring-match ≠ реальному счёту маркеров. Формула `PENDING - PROCESSED - ANALYZED` давала ложные числа → каждые 3 часа LLM запускался «на 80 pending» и отвечал «all marked». Fix: прямой подсчёт заголовков БЕЗ любого из 4 маркеров на той же строке (`grep -E '^### ' | grep -vE '\[(analyzed|processed|duplicate|defer)\b'`). Regex `\b` (word boundary) ловит датированные маркеры типа `[analyzed 2026-04-10]`, которые `\]` пропускал. Промпт обновлён на все 4 маркера. Sync from DS-ai-systems 437048b.

## [0.27.6] — 2026-04-24

### Fixed
- **`roles/synchronizer/scripts/daily-report.sh`** (WP-7 I2) — `mv SchedulerReport → archive/` падал при отсутствующем `archive/`. Под `set -euo pipefail` это прерывало скрипт с non-zero exit → `scheduler.sh` логировал `WARN: daily-report failed` каждые 3 часа. Добавлен `mkdir -p "$ARCHIVE_DIR"` в `archive_old_reports()`.
- **`roles/strategist/scripts/strategist.sh`** (WP-7 I1) — `BOLD_BEFORE=$(grep -c ... || echo 0)` при exit 1 от grep (0 matches) давал мультистрочный `"0\n0"` → `$(( BOLD_BEFORE - BOLD_NEW_BEFORE ))` падал с `line 249: 0: syntax error`, `[ -ge ]` — с `integer expression expected`. Fix: `|| true; VAR=${VAR:-0}` (5 точек: BOLD_BEFORE, BOLD_NEW_BEFORE, BOLD_AFTER, BOLD_NEW_AFTER, NON_BOLD).
- **Тот же антипаттерн `grep -c ... || echo N)` в 11 точках 7 файлов** (субагент-ревью после I1+I2): `setup/validate-template.sh`, `.claude/hooks/protocol-artifact-validate.sh`, `roles/synchronizer/scripts/templates/{synchronizer,extractor}.sh`, `update.sh` (3 точки: DIFF_COUNT, CONFLICT_COUNT, WS_CONFLICTS), `.github/workflows/{cloud-scheduler,validate-template}.yml`. Все использовались в `[ -gt N ]` / арифметике → потенциальные баги того же класса.

Commits: 150be24 (I1+I2 sync из DS-ai-systems), 731471f (I3 sweep 11 точек).

## [0.27.5] — 2026-04-24

### Changed
- **`roles/strategist/scripts/strategist.sh` переименован концептуально (не файл):** context-файл зонтичного WP-7 в авторском governance-репо переехал `archive/wp-contexts/WP-7-bot-tech-debt.md` → `inbox/WP-7-platform-tech-debt.md`. Для шаблона это не blocker (пилоты используют свой `WP-N-*.md`), но в документации `PROCESSES.md` бота обновлена ссылка. Причина: WP-7 давно стал зонтом всей платформы (не только бота) + ошибочно жил в archive/, хотя active (`umbrella: true`). Подтверждено субагентом.

## [0.27.4] — 2026-04-24

### Fixed
- **`roles/synchronizer/scripts/dt-collect.sh`** помечен как author-only (header + raison d'être). Скрипт пишет напрямую в production-БД Neon платформы через `NEON_URL` / `DT_USER_ID`, и эти секреты есть только у автора шаблона. Конечным пользователям IWE не нужно создавать `~/.config/aist/env` с этими переменными.
- **`roles/synchronizer/scripts/scheduler.sh`** добавлен guard: `dt-collect.sh` молча пропускается, если `~/.config/aist/env` не содержит `NEON_URL`+`DT_USER_ID`. У пользователей без секретов автора скрипт не запускается, ошибок не возникает, скачанный код остаётся как маркер будущей фичи.
- **`roles/synchronizer/README.md`** новая секция «Author-only скрипты» объясняет, почему файл есть в шаблоне, но не запускается у пользователей; даёт ссылку на правильный пользовательский путь (MCP-инструмент `dt_write_digital_twin` в IWE Gateway).

Триггер: пользовательский запрос (boberru@gmail.com 24 апр) — шаблон требовал NEON_URL/DT_USER_ID, что является L3-утечкой секретов автора. Системная замена psycopg2-writer → REST endpoint (`POST /hub/events`) через Activity Hub запланирована фазой P2b в `DP.ROADMAP.001-neon-migration.md` (WP-253), активация после P2 (создание #2 journal, ориентир июнь 2026).

## [0.27.3] — 2026-04-24

### Added
- **`setup/validate-template.sh` check 7 + `.github/workflows/validate-template.yml` job «Check hooks cross-ref»** (systemic followup к #13). Проверяет cross-ref в обе стороны: (a) FAIL если hook упомянут в `settings.json*`, но файла нет в `.claude/hooks/`; (b) WARN если hook есть в директории, но не упомянут ни в одном settings.json (может быть direct-call, как `wakatime-heartbeat.sh`). Покрывает оба направления drift'а (settings→hooks и hooks→settings). Предотвращает повторение issue #13.

### Fixed
- **`setup/validate-template.sh` check 2** добавлен `--exclude='CHANGELOG.md'` (зеркально с CI workflow) — CHANGELOG содержит `/Users/...` в описаниях и создавал false-positive.

## [0.27.2] — 2026-04-23

### Fixed
- **`.claude/hooks/extensions-gate.sh`** (closes #13) — добавлен отсутствующий hook. Ссылка на файл жила в `.claude/settings.json:44` (PreToolUse matcher `Edit|Write`) с 7 апр (коммит `af73cd3`, WP-207), но сам скрипт так и не попал в шаблон — у нового пилота первый же `Write`/`Edit` падал с ошибкой «hook file not found». Хук реализует блокирующий Extensions Gate (CLAUDE.md §9): прямое редактирование `.claude/skills/*.md` или `memory/protocol-*.md` блокируется с подсказкой использовать `extensions/*.md`. Исключения: `author_mode: true` в `params.yaml`, путь `FMT-exocortex-template`. Корневая причина: `setup/validate-template.sh` не проверяет соответствие `settings.json` hooks ↔ содержимое `.claude/hooks/` (проверяет 6 других вещей, но не cross-ref). Попутная находка: `wakatime-heartbeat.sh` есть в hooks/, но не упомянут в settings.json (тот же класс drift'а в обратную сторону). Systemic followup (отдельный WP на W18): расширить validate-template.sh проверкой cross-ref + включить в pre-commit/CI FMT, плюс определить судьбу архивированного `template-sync.sh`.

## [0.27.1] — 2026-04-22

### Changed
- **Rollback S-27 «Здоровье платформы»** — секция содержала авторские сервисы (`@aist_me_bot`, `digital-twin`, `gateway-mcp`, `content-pipeline`, `knowledge-mcp`), не применимые обычному пользователю FMT. Перенесена в авторские `extensions/day-open.after.md`. Files: `memory/templates-dayplan.md`, `.claude/skills/day-open/SKILL.md`, `.claude/hooks/protocol-artifact-validate.sh` — удалена секция + step 5b «Бот QA»; SECTIONS хука урезан с 11 до 6. Источник: косяк промоции S-27 — тест «применимо пустому пользователю?» (см. авторский `memory/feedback_post_promote_sync.md`).
- **L3 leak cleanup (параметризация через env-vars):** `.claude/hooks/protocol-artifact-validate.sh`, `scripts/day-close.sh`, `roles/strategist/scripts/cleanup-processed-notes.py`, `roles/synchronizer/scripts/dt-collect.sh`, `roles/strategist/prompts/{note-review,session-prep}.md` — хардкод `DS-my-strategy`, `DS-agent-workspace/scheduler/feedback-triage/`, `~/IWE/DS-my-strategy` заменён на `$IWE_WORKSPACE` + `$IWE_GOVERNANCE_REPO` (fallback: `DS-strategy`) и условные `if настроены агенты-сборщики QA`.
- **`memory/hard-distinctions.md` HD #49:** примеры MCP-именования обобщены (`digital-twin-mcp`, `knowledge-mcp` → `<domain>-mcp`). `memory/checklists.md`: урок «knowledge-mcp stale index» → «MCP-индекс». `memory/navigation.md`: таблица MCP → placeholder'ы. `CLAUDE.md`: удалено правило `engines/tailor` (авторская реализация бота).
- **`.claude/skills/ke/SKILL.md`, `memory/{repo-type-rules,protocol-open}.md`:** `DS-my-strategy` → `<governance-repo>` (env).

### Added
- **CI smoke-test** (`.github/workflows/validate-template.yml`): job «Smoke-test protocol hooks on clean user env» — создаёт tmp-окружение с `DS-strategy` + минимальным DayPlan и прогоняет `protocol-artifact-validate.sh`. Падает, если хук блокирует commit на чистом пользователе. Перехватывает L1→L3 утечки, которые пропускает blacklist.
- **Расширенный blacklist** (два уровня) в `validate-template.yml` + зеркально в локальном `setup/validate-template.sh`: глобальный (запрещено везде: `tserentserenov`, `PACK-MIM`, `aist_bot_newarchitecture`, `DS-Knowledge-Index-Tseren`, `DS-my-strategy`, `engines/tailor`) и protocol-only (запрещено в `.claude/skills|hooks|rules`, `memory`, `CLAUDE.md`, но разрешено в README/docs: `@aist_me_bot`, `digital-twin`, `content-pipeline`, `knowledge-mcp`, `gateway-mcp`, `DS-agent-workspace/scheduler`). Покрытие расширено на `roles/`.

### Fixed
- CI `validate-template.yml` — зеркалирование exclude-логики локального валидатора для путей (`/Users/...`, `/opt/homebrew`) + shellcheck severity: warning→error (0 pred-existing errors, CI зеленеет).

## [0.27.0] — 2026-04-21

### Added
- **seed/strategy/docs/Strategy.md** — секция «Состояние месяца — фаза стратегической позиции» (PD.FORM.078: 4 фазы Развитие/Хаос/Потолок/Пивот, диагностика по 5 сигналам, playbook, сигналы перехода) + секция «Калибр личности» (PD.CHR.007, gap-analysis по 3 направлениям: горизонт / bus factor / публичность) + строка-источник «НЭП-триады» перед таблицей R1-R{N}. Strategy Session теперь начинается с явной декларации фазы и playbook-а под неё, а не с произвольного выбора РП. Источник: WP-196 Ф12.1, S-26 promoted.
- **memory/templates-dayplan.md** (WeekPlan) — блоки «Применённые критерии отбора РП» (PD.METHOD.017 + Time-boxing Shape Up: РП без 50% бюджета к четвергу → пересмотр на следующей сессии) + «ТОС недели + запрос недели» на открытии; секция «## Week Close» с 4 подсекциями (сверка РП↔НЭП, рекомендации изменений в НЭП/Стратегию, carry-over, мультипликатор и метрики) на закрытии. Источник: WP-196 Ф12.1, S-26.
- **memory/templates-dayplan.md** (DayPlan) — секция «Day Close» с 3 подсекциями (три варианта плана на завтра A/B/C, KE-маршрутизация, сверка с НЭП). Day Close теперь имеет видимую структуру весь день, а не появляется «в момент закрытия». Источник: WP-196 Ф12.1, S-26.

### Changed
- **memory/templates-dayplan.md, .claude/skills/day-open/SKILL.md, .claude/hooks/protocol-artifact-validate.sh** — секция `Здоровье бота (QA)` переименована в `Здоровье платформы` (семантически strict superset: старая секция стала подзаголовком `### Бот @aist_me_bot (QA)`, добавлены `### Остальные MCP-сервисы` + `### Operational health`). Хук валидатора обновлён в lockstep (список секций + awk range + сообщение ошибки). Привязка: WP-255 (L3/L4 AI Quality для всех MCP) draft + HD «Internal health ≠ Public status page». Источник: WP-196 Ф12.3 partial, S-27 promoted.

## [0.26.4] — 2026-04-18

### Added
- **.claude/skills/ke/SKILL.md** — блок `## Scope` разграничивает три инструмента знания в IWE: `/ke` (inline capture, R14/R1), `extractor.sh inbox-check` (R2 launchd 3h work hours, создаёт `extraction-reports/*.md` со `status: pending-review`), `/apply-captures` (R15 Валидатор, в разработке). Явно указано что скилл делает и чего НЕ делает. Предотвращает будущий P10-дубликат scope при появлении `/apply-captures`. Источник: WP-247 Ф3.0 — IntegrationGate для скилла разбора extraction-reports.

### Fixed
- **roles/strategist/prompts/session-prep.md** (шаг 6, очистка `extraction-reports/`) — условие удаления учитывает `status` во frontmatter: удаляются только `applied` / `rejected` / `no-pending` (старше 7 дней). Статусы `pending-review` / `partially-applied` / `deferred` защищены — реализация инварианта «capture не исчезает без решения». Инцидент 17 апр: прежнее правило «старше 7 дней → удалить» удалило 6 pending-review отчётов (6-10 апр) вместе с неразобранными кандидатами. Источник: WP-247 Ф5.

## [0.26.3] — 2026-04-18

### Fixed
- **docs/LEARNING-PATH.md** (§5.1b Session Open), **roles/synchronizer/scripts/dt-collect.sh** (collect_sessions) — путь к session log приведён к канону `DS-my-strategy/inbox/open-sessions.log` (вариант для FMT: `<governance-repo>/inbox/open-sessions.log`). Ранее устаревший путь `DS-agent-workspace/scheduler/open-sessions.log` оставался в LEARNING-PATH и dt-collect.sh — агенты/скрипты при чтении документации могли промахнуться. Каноничное место ведения — governance-репо пользователя (там же читает CI workflow `cloud-scheduler.yml`), формат остаётся plain text. Источник: WP-248 drift cleanup (ArchGate PASS, отказ от §5.7/YAML из-за совместимости с CI).

## [0.26.2] — 2026-04-17

### Fixed
- **roles/extractor/prompts/inbox-check.md** — шаг 1.3 «напиши в лог `No pending captures in inbox`» теперь явно запрещает создавать отдельный лог-файл в `DS-strategy/` или где-либо ещё. Сообщение выводится через stdout и попадает в `{{HOME_DIR}}/logs/extractor/YYYY-MM-DD.log` (поток extractor.sh). Причина: у автора накопились 3 runtime-артефакта в `inbox/` (хаотичное размещение `inbox-check.log`, `extraction-reports/inbox-check.log`, `.inbox-check-log` — нарушение OwnerIntegrity: knowledge flow vs runtime).

## [0.26.1] — 2026-04-17

### Fixed
- **update-manifest.json** — синхронизирован с реальным состоянием репо: добавлены пропущенные файлы `scripts/backup-icloud.sh`, `scripts/check-dirty-repos.sh` (0.26.0), `.claude/hooks/protocol-artifact-validate.sh` (0.23.0), `.claude/hooks/protocol-stop-gate.sh` (0.24.0), `docs/QUICK-START.md`. Версия бампнута с 0.23.0 до 0.26.1. Без этого фикса: Day/Week Close у пользователей падал с `No such file or directory` на новые скрипты; хуки `settings.json` ссылались на несуществующие файлы. Источник: issue #5 (Евгений Селиверстов).
- **generate-manifest.sh** — расширены `EXCLUDE_PATTERNS`/`EXCLUDE_EXACT`: `README.en.md`, `CONTRIBUTING.md`, `LICENSE`, `params.yaml`, `extensions/day-close.after.md`, `extensions/mcp-user.json`. Регенерация манифеста больше не захватывает пользовательское пространство, которое `update.sh` обещает не трогать (см. update.sh §«Не затрагивается»).
- **extensions/README.md** — уточнена формулировка: `update.sh` не трогает пользовательские файлы (`*.after.md`, `*.before.md`, `*.checks.md`, `mcp-user.json`), но обновляет сам `README.md` как платформенный справочник. Противоречие «никогда не трогает» vs фактического присутствия `extensions/README.md` в manifest устранено.

## [0.26.0] — 2026-04-17

### Added
- **scripts/backup-icloud.sh** — еженедельный бэкап IWE в iCloud Drive. Архивирует без `.git`/`node_modules`/`.venv`, хранит 4 последних архива с ротацией. macOS only.
- **scripts/check-dirty-repos.sh** — скан всех IWE репо (включая вложенные) на незакоммиченные изменения и незапушенные коммиты. Используется в Day Close (шаг 7г) и Week Close.

### Changed
- **week-close/SKILL.md** v1.1.0 — добавлены платформенные шаги: бэкап iCloud и скан грязных репо.

## [0.25.1] — 2026-04-14

### Changed
- **protocol-close.md** — KE (Knowledge Extraction) добавлен как обязательный шаг 2.5 Quick Close. Знание маршрутизируется в момент сессии (горячий контекст), не откладывается на Day Close. Чеклист Quick Close дополнен строкой KE. Секция Deferred обновлена: KE выведен из отложенных.

## [0.25.0] — 2026-04-13

### Changed
- **protocol-close.md** — сжат 454→97 строк. Остались: маршрутизация, Quick Close inline, формат «Осталось», чеклист Quick Close. Алгоритмы Day Close и Week Close вынесены в отдельные SKILL.md.
- **day-open/SKILL.md** — шаблоны DayPlan/WeekPlan/итогов удалены из файла (→ `memory/templates-dayplan.md`). Файл сокращён с ~343 до 127 строк.
- **update-manifest.json** — добавлены: `day-close/SKILL.md`, `week-close/SKILL.md`, `memory/templates-dayplan.md`.
- **navigation.md** — добавлены строки для `day-close/SKILL.md`, `week-close/SKILL.md`, `templates-dayplan.md`.
- **run-protocol/SKILL.md** — добавлена строка: `close` (без уточнения) → `close session` по умолчанию.

### Added
- **.claude/skills/day-close/SKILL.md** — полный алгоритм Day Close (шаги 0–11) с TodoWrite enforcement. Шаг 0 = «создать список задач прямо сейчас». Главный фикс: агент больше не может пропустить шаги через прямое чтение protocol-close.md.
- **.claude/skills/week-close/SKILL.md** — полный алгоритм Week Close (шаги 0–9) с TodoWrite enforcement.
- **memory/templates-dayplan.md** — единый источник шаблонов DayPlan, compact dashboard, WeekPlan, итогов дня. Используется day-open (создание) и day-close (запись итогов).

## [0.24.1] — 2026-04-13

### Fixed
- **protocol-close.md** — Day Close §3: правило архивации DayPlan (`mv current/DayPlan → archive/day-plans/`) + пункт в чеклист Day Close. Week Close §2: архивация WeekPlan прошлой недели + `git status` перед финальным коммитом (незастейженные deletes).

## [0.24.0] — 2026-04-12

### Added
- **protocol-stop-gate.sh** — Stop hook: если в сессии был вызов протокольного Skill (day-open|day-close|run-protocol|wp-new), проверяет наличие TodoWrite ≥3 items. Нет → блокирует завершение. `action=warn` (warn-before-block, промоция в block после 2 нед обкатки). Логирует в `.claude/logs/gate_log.jsonl`. Guard `STOP_HOOK_ACTIVE` против infinite loop.
- **settings.json** — Stop hook: protocol-stop-gate.sh добавлен первым в Stop-массив (до capture-bus)
- **settings.json** — PostToolUse matcher расширен: `Read` → `Read|Skill`

### Changed
- **protocol-completion-reminder.sh** — расширен на Skill tool: теперь срабатывает при вызове `day-open|day-close|run-protocol|wp-new` и напоминает создать TodoWrite ДО исполнения
- **protocol-artifact-validate.sh** — добавлены структурные проверки DayPlan: (1) `<details>` collapsible ≥3 блоков, (2) непустые секции Календарь/QA/Scout, (3) мультипликатор `~N.Nx`, (4) Carry-over цитата при наличии предыдущего DayPlan

## [0.23.1] — 2026-04-09

### Fixed
- **day-open SKILL.md** — шаблон QA-секции: видео показывает только новые за сегодня (не весь stale-архив), заметки проверяются по git log note-review (не carry-over обработанных)

## [0.23.0] — 2026-04-07

### Added
- **protocol-artifact-validate.sh** — PreToolUse hook (Bash matcher) блокирует `git commit` если DayPlan невалиден: 11 секций, mandatory check, бюджет в формате. Кодовый enforcement вместо промпт-инструкций
- **run-protocol SKILL.md** — шаг 1b Extension Loading: автоматическая загрузка `extensions/{protocol}.before/after/checks.md` при исполнении любого протокола. Маршрутизация: протоколы с Skill-файлом читают полный алгоритм
- **day-open SKILL.md** — шаг 5a2 (видео-сканирование), шаг 7 разбит на 7a-7d (Write → Checks → Commit → Dashboard)

### Changed
- **day-open/protocol-open/protocol-close** — HTML-комментарии `<!-- EXTENSION POINT -->` заменены на видимый markdown `**EXTENSION POINT:**` — агент их читает и исполняет
- **wp-gate-reminder.sh** — при Day Open инжектирует extension loading reminder
- **settings.json** — добавлен PreToolUse Bash matcher для protocol-artifact-validate.sh

### Fixed
- **settings.json** — убрана лишняя строка `.claude/hooks` из `additionalDirectories` (вызывала открытие файлов хуков как вкладок в Cursor/VS Code на Windows)

## [0.22.0] — 2026-04-06

### Added
- **verify SKILL.md** — два новых типа верификации: `chain` (data flow check, CoVe stage 3) и `adversarial` (scope & bias check, pre-mortem). Context isolation sub-agent с чеклистами
- **day-close.sh** — маппинг dir→source из L2 (sources.json) + L4 (sources-personal.json). Раздельные вызовы selective-reindex через SOURCES_CONFIG. Фикс хронического reindex failure с 20 марта

### Changed
- **verify SKILL.md** — обновлена нумерация шагов (0→4), unified verdict формат, автоопределение chain/adversarial по контексту
- **update-manifest.json** → v0.22.0

## [0.21.0] — 2026-03-29

### Added
- **setup.sh v0.5.1** — секция T3+ в `.exocortex.env`: ORY_TOKEN, L4_BACKEND, L4_DATABASE_URL. setup.sh при уровне T3/T4 спрашивает токен и backend (можно пропустить). Единый файл конфигурации для всей IWE — `~/.iwe-env` упразднён
- **update.sh** — исправлен парсер env-файла: `IFS='=' read` заменён на `${line%%=*}` + `${line#*=}` — корректно читает значения с `=` внутри (URL, токены). Добавлен detect `~/.iwe-env`: если файл существует и T3+-ключи отсутствуют в `.exocortex.env` — мигрирует автоматически
- **.githooks/pre-commit** — блокирует коммит если `.exocortex.env` попал в staged files

### Changed
- **update.sh** — ORY_TOKEN/L4_BACKEND/L4_DATABASE_URL читаются из `.exocortex.env` но **не подставляются** в template-файлы (секция secrets, только для Gateway-скриптов)
- **update-manifest.json** → v0.21.0

## [0.20.0] — 2026-03-29

### Added
- **setup.sh v0.5.0** — градиентный вход: флаг `--level=T1/T2/T3/T4` + интерактивный выбор при запуске. T1=минимум (≤15 мин), T2=+ОРЗ+extensions, T3=+Pack+бот, T4=+роли+launchd. Каждый уровень дополняет предыдущий, не заменяет
- **ADR-003** — спецификация платформы-хостинга: два слоя доставки (дистрибутив vs хостинг), скриптуемый API (`--yes`), градиентный вход, экспорт, Vagrant-образ, ЭМОГССБ 60/70

### Changed
- **update-manifest.json** → v0.20.0
- **setup.sh** — INSTALL_LEVEL сохраняется в `.exocortex.env`; шаги 4, 5 зависят от уровня; Next steps адаптированы под уровень

## [0.19.0] — 2026-03-29

### Added
- **skill /extend** — каталог расширяемости IWE. Показывает все extension points, параметры params.yaml, конфиг day-rhythm-config.yaml, инструкции по sharing. Предлагает следующий шаг на основе текущих кастомизаций пользователя
- **update.sh Step 6b** — авто-фикс ссылок при миграции: обновляет абсолютные пути и имя репо в пользовательских файлах extensions/ и MEMORY.md при переименовании/переезде IWE
- **extensions/README.md** — секция «Несколько расширений одного hook» (суффиксы для конфликтов) и «Sharing» (формат bundle-пакетов расширений)

### Changed
- **update-manifest.json** → v0.19.0: добавлен `.claude/skills/extend/SKILL.md`

## [0.18.0] — 2026-03-28

### Added
- **extensions/** — 12 extension points в протоколах (day-open before/after, day-close checks, week-close before/after, protocol-close checks/after). Пользователь добавляет файл `extensions/<protocol>.<hook>.md` — блок вставляется в протокол при исполнении
- **params.yaml** — 8 персистентных параметров управляют условными шагами протоколов: `video_check`, `multiplier_enabled`, `reflection_enabled`, `lesson_rotation`, `auto_verify_code`, `verify_quick_close`, `telegram_notifications`, `extensions_dir`
- **extensions/day-close.after.md** — пример расширения: рефлексия дня (3 вопроса). Управляется `reflection_enabled` в params.yaml
- **update.sh** — 3-way merge для CLAUDE.md через `git merge-file`. Пользовательские правки в §1-7 сохраняются при обновлении платформы. Fallback на USER-SPACE для первого обновления
- **setup.sh** — создаёт `.claude.md.base` при установке (base для 3-way merge)
- **.gitignore** — `.claude.md.base` (служебный файл merge)

### Changed
- **CLAUDE.md §7** — инструкции для Claude по загрузке extensions и чтению params.yaml
- **protocol-close.md** — `<!-- YOUR CUSTOM CHECKS HERE -->` заменены на `<!-- EXTENSION POINT: загрузить extensions/X.md -->` (единый формат)
- **protocol-close.md** — условные шаги привязаны к params.yaml: multiplier_enabled (шаг 5), video_check (шаг 6д), lesson_rotation (week-close шаг 1), auto_verify_code (шаг 4b), verify_quick_close (шаг 7)
- **update.sh** — «Не затрагиваются» обновлён: extensions/, params.yaml, 3-way merge вместо USER-SPACE
- **skill /iwe-update** — агент-обновитель: вызывает update.sh, парсит CHANGELOG, объясняет изменения на человеческом языке, анализирует совместимость с extensions/params, помогает разрешить конфликты 3-way merge
- **day-open шаг 5** — автоматическая проверка обновлений (`update.sh --check`) → «Требует внимания» если доступна новая версия

### Removed
- **AUTHOR-ONLY** — механизм `<!-- AUTHOR-ONLY -->` заменён на extensions/ (авторские блоки мигрированы в extension-файлы)

## [0.17.1] — 2026-03-28

### Added
- **day-open/SKILL.md** — БЛОКИРУЮЩЕЕ: пошаговое исполнение через TodoWrite. Каждый шаг = задача, переход только после отметки. Предотвращает пропуск шагов (carry-over, mandatory, запись) из-за загрязнения контекста (SOTA.002)
- **protocol-open.md** — ссылка на пошаговое исполнение Day Open (аналогично Close)

## [0.17.0] — 2026-03-28

### Changed
- **day-open/SKILL.md v1.1** — carry-over из вчерашнего DayPlan теперь обязательная логика (не конфиг-флаг). Убран `day_close.review_yesterday_close`
- **day-open/SKILL.md** — алгоритм и шаблоны объединены в один файл. Шаг 2: приоритет входов (carry-over → WeekPlan → mandatory)
- **day-open/SKILL.md** — `{{GOVERNANCE_REPO}}` вместо prose-текста (формализация)
- **day-rhythm-config.yaml** — добавлен `calendar_ids: []` (Day Open запрашивает все календари или указанные)
- **day-rhythm-config.yaml** — убран `day_close` (carry-over = часть алгоритма, не настройка)

### Added
- **day-open/SKILL.md §6** — ссылки на источники (URL) обязательны в секции «Мир»

## [0.16.9] — 2026-03-28

### Added
- **scheduler.sh** — `TASK_TIMEOUT_SHORT` (300s) и `TASK_TIMEOUT_LONG` (1800s) для всех задач dispatch
- **scheduler.sh** — macOS perl timeout fallback (нет GNU timeout)
- **scheduler.sh** — AC sleep check (pmset) в dispatch() — предупреждение при sleep≠0 на зарядке

## [0.16.8] — 2026-03-28

### Added
- **day-open/SKILL.md** — механизм `mandatory_daily_wps`: стратег читает из `day-rhythm-config.yaml` обязательные РП для каждого дня. Нет в WeekPlan → «Требует внимания»
- **day-open/SKILL.md** — механизм `review_yesterday_close`: опциональное чтение Close прошлого дня при Day Open (carry-over, незакрытые вопросы)
- **day-rhythm-config.yaml** — секции `mandatory_daily_wps` и `day_close` (закомментированные примеры)

## [0.16.7] — 2026-03-27

### Fixed
- **hooks/close-gate-reminder.sh** — v3: hook теперь инжектирует БЛОКИРУЮЩУЮ инструкцию вызвать `/run-protocol` вместо напоминания «Read protocol-close.md». Устраняет пропуск шагов при ручном исполнении Close (АрхГейт 63/70)

## [0.16.6] — 2026-03-27

### Changed
- **docs/onboarding** — актуализация onboarding-документов: IWE = ОС (не среда/платформа), 4 компонента (Ядро мышления, Культура работы, Модель мастерства, Сообщество), теории (ШСМ) + культура работы (14 элементов), экзотело вместо экзоскелета, инструменты = средства доставки
- **docs/DATA-POLICY** — убраны несуществующие standard/personal, добавлена свобода данных (§6.1), два слоя доставки, актуальная структура (memory/, extensions/, params.yaml)

## [0.16.5] — 2026-03-27

### Changed
- **docs** — синхронизация документации: README сценарии → ссылки на SC.001-SC.015 (USE-CASES.md), FAQ подписки унифицированы («при необходимости»), IWE-HELP роли уточнены (3 в шаблоне / 21 на платформе), CLAUDE.md §2 примечание про первую неделю, SETUP-GUIDE §1.3b пояснение про MCP и Pack-сущности

## [0.16.4] — 2026-03-27

### Changed
- **notify-update.yml** — 3-уровневый фильтр уведомлений: (1) наличие коммитов, (2) наличие changelog с буллет-пунктами, (3) проверка значимости (ключевые слова, значимые файлы, ≥3 пунктов). Незначительные правки (только CLAUDE.md/memory/rules) больше не генерируют уведомления подписчикам

## [0.16.3] — 2026-03-27

### Changed
- **seed/strategy/docs/Strategy.md** — переструктурирование шаблона: Фокус Q{N} (текущий квартал, details open) первым, затем Годовой план (фазы, roadmap, MAPSTRATEGIC, риски, Q итоги внутри). Убрана отдельная секция Q итоги и Риски

## [0.16.2] — 2026-03-25

### Changed
- **skill /iwe-rules-review** — 3 вопроса → 4 вопроса (по актуальному DP.M.008: чему научился? какое правило мешало? какого не хватало? какое обходил?)

## [0.16.1] — 2026-03-25

### Changed
- **skill /archgate** — L2.1 Переносимость данных добавлена, L2.2–L2.7 перенумерованы (7 доменных характеристик). АрхГейт 8.0+ (WP-177)

## [0.16.0] — 2026-03-25

### Changed
- **WeekReport deprecated** — итоги недели теперь записываются в секцию «Итоги W{N}» внутри WeekPlan. Отдельный файл WeekReport больше не создаётся. АрхГейт 8.9 (62/70)
- **week-review.md** — пишет секцию в WeekPlan, не создаёт файл
- **session-prep.md** — читает секцию из WeekPlan, не ищет файл WeekReport

### Added
- **Кроссплатформенное предотвращение сна** — `strategist.sh` и `scheduler.sh` автоматически блокируют засыпание: macOS `caffeinate -diu` / Linux `systemd-inhibit`. Флаг `-s` не используется — он игнорируется когда Optimized Battery Charging переключает профиль на батарею
- **SETUP-GUIDE: инструкции wake+sleep** для macOS, Linux, Windows. Включая `pmset -b sleep 0` для ноутбуков и Charge Limit рекомендацию
- **PLATFORM-COMPAT: sleep prevention** — документация кроссплатформенных ограничений
- **Agent Workspace (optional, WP-176)** — `setup/optional/setup-agent-workspace.sh` создаёт отдельный репо для данных агентов. SETUP-GUIDE Этап 7 с осознанным описанием когда нужен/не нужен
- **daily-report.sh conditional** — если DS-agent-workspace/.git существует → отчёты туда, иначе DS-strategy/current/ (обратная совместимость)

### Updated
- **LEARNING-PATH §11 FAQ** — 3 развёрнутых ответа (Windows+WSL, заметки, бот отвечает не то) + 6 табличных строк (WP-166: feedback_triage кластеры)
- docs/LEARNING-PATH, USE-CASES, SETUP-GUIDE, onboarding-guide — убран WeekReport
- roles/strategist/README, seed/strategy/CLAUDE.md — WeekReport помечен deprecated
- synchronizer/scripts/templates/strategist.sh — ищет WeekPlan вместо WeekReport
- README.md FAQ — обновлён вопрос про сон/выключение
- install.sh — кроссплатформенные подсказки при установке
- session-prep.md, note-review.md — ссылки на QA-отчёт: agent-workspace или DS-strategy
- collectors.d/README.md — unsatisfied → agent-workspace path

## [0.15.2] — 2026-03-24

### Changed
- **«Правила IWE» → «Культура работы IWE»** — переименование в skill /iwe-rules-review и шаблоне отчёта (согласование с DP.M.008)

## [0.15.1] — 2026-03-24

### Fixed
- **Битые ссылки** — исправлено 17 ссылок в 6 файлах: кросс-репо `../../../../PACK-digital-platform/` → абсолютные GitHub URL в onboarding-guide, `LEARNING-PATH.md`/`SETUP-GUIDE.md` → `docs/` в CHANGELOG, лишний `../` в LEARNING-PATH, `Github/` в protocol-work, недостаточная глубина `../` в week-review и setup/optional/README

## [0.15.0] — 2026-03-24

### Changed
- **Context Compression (WP-172)** — входной overhead снижен с ~27K до ~13K токенов (2x сжатие). АрхГейт 8.9
- **CLAUDE.md** — сжат до ~90 строк ядра (было ~280). Убраны детали, дублирующие memory/ и .claude/rules/
- **protocol-open.md** — шаблоны DayPlan/WeekPlan вынесены в skill `/day-open` (lazy loading, ~8K экономия в обычных сессиях)

### Added
- **skill `/day-open`** — `.claude/skills/day-open/SKILL.md`: шаблоны DayPlan, WeekPlan, compact dashboard. Загружаются только при Day Open
- **Lesson Hygiene** в protocol-close.md (Day Close §3b) — симметрия: Open пишет уроки → Close чистит. Предотвращает раздувание MEMORY.md. Цель: ≤8 уроков
- **validate-template.sh** — проверка `.claude/skills/day-open/SKILL.md`
- **skill `/iwe-rules-review`** — еженедельное ревью культуры работы IWE (DP.M.008 #14). Триггер: Week Close
- **HD #43** — различение «Правило ≠ Реализация правила» (DP.M.008)

## [0.14.2] — 2026-03-24

### Changed
- **protocol-open.md § Ритуал (Шаг 1)** — каждый элемент отчёта с новой строки (было: всё в одну строку)
- **LEARNING-PATH.md § Ритуал** — аналогичное форматирование

## [0.14.1] — 2026-03-24

### Changed
- **wp-gate-reminder.sh** — при Day Open триггере инжектит реальную дату через `date` (currentDate от Anthropic может врать из-за timezone). На остальные сообщения — стандартный WP Gate reminder

## [0.14.0] — 2026-03-24

### Added
- **dt-collect.sh plugin-архитектура** — ядро (L3) содержит 11 стандартных коллекторов, `collectors.d/*.sh` — точка расширения для персональных (L4) коллекторов. Plugin loader автоматически source'ит файлы и route'ит JSON по TARGET-секциям
- **collectors.d/README.md** — документация формата плагинов (COLLECTOR/TARGET headers, формат функций)
- **6 новых коллекторов в ядре** — multiplier (DayPlan budget), WP-REGISTRY stats, Pack entities, fleeting notes, scheduler reports health
- **2 новых JSONB-секции** — `2_8_ecosystem`, `2_9_knowledge` (через плагины)
- **portable_date_offset** — кроссплатформенная обёртка для `date -v` (macOS + Linux)

## [0.13.5] — 2026-03-22

### Changed
- **protocol-close.md** — формула мультипликатора: partial РП считаются (% × бюджет), мелкие РП = 0.25h (не 0). Недельный мультипликатор = Σ бюджетов ВСЕХ отработанных РП / WakaTime. Убран плановый бюджет из формулы
- **hard-distinctions** — HD #42: Тир ≠ Квалификация (DP.D.042)

## [0.13.4] — 2026-03-22

### Added
- **Priority Gate** — новый Pre-action Gate в CLAUDE.md: при создании РП ≥3h обязательный вопрос «К какому результату месяца?» (R{N} / поддержка / off-plan)
- **wp-new SKILL** — 5-е место записи: маппинг РП → Результат в `Strategy.md`. Порог ≥3h
- **Strategy template** — секции «Результаты месяца» и «РП → Результаты» с пояснениями допустимых значений

## [0.13.3] — 2026-03-21

### Fixed
- **MCP подключение** — `setup.sh` использовал нерабочий `claude mcp add --transport http` → заменён на инструкцию через claude.ai/settings/connectors. Обновлены: SETUP-GUIDE §1.3b, IWE-HELP, LEARNING-PATH, validate-template.yml, update.sh (6 файлов)

## [0.13.2] — 2026-03-21

### Changed
- **cloud-scheduler.yml** — расширенный IWE Health Check: мульти-репо коммиты (24ч + 7д), проверка свежести backup (>48ч), статус бота (health endpoint), WP-статистика, светофор (🟢/🟡/🔴). Настройка через GitHub Variables: `HEALTH_CHECK_REPOS`, `BOT_HEALTH_URL`
- **LEARNING-PATH §2.6** — практический гайд настройки расширенного Health Check (4 шага)

### Fixed
- **cloud-scheduler.yml** — защита от пустого `STRATEGY_REPO` при `basename`, точный grep для WP-статистики (`| in_progress` вместо `in_progress`)

## [0.13.1] — 2026-03-21

### Fixed
- **inbox-check.md** — `[processed]` → `[analyzed]`: метка при анализе captures, не при записи в Pack. Корневая причина потери 76% captures
- **session-close.md** — добавлен шаг 8a: пометка captures `[processed]` только после подтверждённой записи в Pack
- **extractor.sh** — учёт `[analyzed]` в подсчёте pending captures
- **session-prep.md** — архивация `[processed]` captures в `archive/captures/` вместо удаления

## [0.13.0] — 2026-03-20

### Added
- **generate-post-image.py** (S48) — генерация обложек для постов через OpenAI GPT Image 1 API. SOTA-промпт: полный текст статьи → визуальная метафора. Настроение по аудитории (wide/community/advanced). ~$0.07/картинка
- **COVER-IMAGES.md** — подробная инструкция: API key, промпты, параметры, стоимость, интеграция с публикаторами

## [0.12.0] — 2026-03-20

### Added
- **cloud-scheduler.yml** — GitHub Actions workflow для облачной автоматики IWE. Базовый уровень (без LLM, $0/мес): backup memory → exocortex, health check ночной автоматики, опциональные Telegram-уведомления. DP.SC.019, S61
- **setup-cloud-scheduler.sh** — скрипт настройки: проверка gh CLI, установка GitHub Secrets, тестовый запуск workflow
- **LEARNING-PATH §2.6** — Cloud Scheduler добавлен в таблицу опциональных сервисов
- **README FAQ** — вопрос про работу IWE при выключенном Mac

### Changed
- **CLAUDE.md** — 3-слойная структура: L1 (§1-§7 платформа), L2 (§8 staging), L3 (§9 авторское). `update.sh` обновляет только L1. UC Gate добавлен в Pre-action Gates
- **cloud-scheduler Telegram** — HTML-формат вместо markdown (корректное отображение bold)

## [0.11.1] — 2026-03-20

### Changed
- **Haiku R23 верификатор в Quick Close** — закрытие сессии теперь запускает sub-agent Haiku R23 с context isolation (VR.SOTA.002). Шаг 7 в алгоритме Quick Close. Исключения: сессия ≤15 мин, сессия без изменений файлов
- **roles/verifier/README.md** — таблица «Когда вызывается» уточнена: Quick Close (шаг 7) + Day Close (шаг 10) + Session Close (Verification Gate)
- **CLAUDE.md правило 6** — обновлено: Quick Close + Day Close через Haiku R23

## [0.11.0] — 2026-03-20

### Changed
- **update.sh v2.0.0** — полностью переписан: curl + манифест вместо git merge. Работает с template repos (created via "Use this template"), которые не имеют общей git-истории с upstream. Self-update (bootstrap): скрипт обновляет сам себя перед работой
- **Превью перед обновлением** — показывает новые файлы, обновлённые, не затрагиваемые. Пользователь решает: применить или отменить
- **setup-calendar.sh** — уточнён текст предупреждения Google (название «IWE MIM», пояснение про unverified app)

### Added
- **[update-manifest.json](update-manifest.json)** — манифест всех платформенных файлов (100+ записей) с описаниями. Используется update.sh для доставки обновлений
- **[DP.SC.019](../PACK-digital-platform/pack/digital-platform/08-service-clauses/DP.SC.019-template-update.md)** — сценарий «Обновление экзокортекса» + сервис S50 Template Update в MAP.002
- **Инструкция «настрой календарь»** в CLAUDE.md — при запросе пользователя Claude запускает `setup-calendar.sh`

## [0.10.0] — 2026-03-19

### Changed
- **Трёхуровневый Close** — Session Close (13 шагов) заменён на Quick Close (6 шагов, ~3 мин) + Day Close (13 шагов, ~10 мин) + Week Close (3 шага). Governance перенесён с сессии на конец дня. Экономия ~60% токенов на закрытие сессий
- **Haiku R23** — верификация только при Day Close (≥10 пунктов), не Quick Close (6 пунктов). Экономия N-1 вызовов sub-agent в день
- **MEMORY.md ≤100 строк** — done-РП удаляются при Day Close (были ≤200, копились). Экономия ~30% токенов на авто-загрузку
- **CHANGELOG FMT** перенесён из Day Close в Quick Close (шаг 1b) — пока контекст свежий, не теряется к вечеру

### Added
- **[scripts/day-close.sh](scripts/day-close.sh)** — автоматизация 3 механических шагов Day Close одной командой: backup memory/ → exocortex/, knowledge-mcp reindex (автодетекция изменённых Pack/DS), Linear sync
- **Мультипликатор IWE** — шаг 5 Day Close: расчёт усиления от агента-экзоскелета (Бюджет закрыт / WakaTime). Таблица в итогах дня
- **Week Close** — ротация уроков (≤15 актуальных), свежая таблица РП, аудит memory-файлов

## [0.9.1] — 2026-03-18

### Added
- **Close Gate hook** — `close-gate-reminder.sh`: при триггерах закрытия инжектит compact-чеклист Session Close (10 шагов) или направляет на полный Day Close. Экономия ~5K токенов (не перечитывает protocol-close.md каждый раз)

## [0.9.0] — 2026-03-18

### Added
- **Hooks enforcement** — три автоматических hook'а для надёжности агента: WP Gate (напоминание на каждый prompt), Protocol Completion (верификация после загрузки протокола), PreCompact Checkpoint (сохранение контекста перед компрессией). `.claude/hooks/` + `.claude/settings.json`
- **Скилл `/run-protocol`** — пошаговое выполнение протокола ОРЗ через TodoWrite с обязательной верификацией. `.claude/skills/run-protocol/`
- **Различение `settings.json` ≠ `settings.local.json`** — проектный (hooks, в git) vs персональный (permissions, gitignored). При клонировании hooks работают из коробки
- **Compliance-метрика верификации** — строка «запускался ли /verify» в чеклисте Session Close

## [0.8.8] — 2026-03-18

### Added
- **Google Calendar одной командой** — `bash setup/optional/setup-calendar.sh`: скачивает OAuth credentials с Gist, настраивает MCP, запускает авторизацию в браузере. Пользователю не нужен GCP Console (АрхГейт 61/70, Shared OAuth App)
- **[SETUP-GUIDE](docs/SETUP-GUIDE.md) Этап 5** обновлён: `setup-calendar.sh` вместо ручной настройки GCP

## [0.8.7] — 2026-03-17

### Added
- **Чеклист-верификация (Haiku R23)** — блокирующее правило в [CLAUDE.md](CLAUDE.md) §2: после любого протокола с чеклистом запускается sub-agent Haiku в роли R23 Верификатор для независимой проверки каждого пункта (VR.SOTA.002 context isolation). Добавлена в [Session Close](memory/protocol-close.md) (шаг 10) и Day Close (шаг 5)

## [0.8.6] — 2026-03-17

### Added
- **Роли верификации (R23-R24)** — skill /verify + [hard-distinctions](memory/hard-distinctions.md) #38-40 (WP-122)
- **Governance-синхронизация** в [Day Close](memory/protocol-close.md) — проверка REPOSITORY-REGISTRY, navigation.md, MAP.002↔PROCESSES.md (WP-124)
- **Collapsible sections** в [LEARNING-PATH](docs/LEARNING-PATH.md) и [SETUP-GUIDE](docs/SETUP-GUIDE.md) (details/summary)
- **Онбординг** переработан: пользователь в центре, принципы двусторонние

## [0.8.5] — 2026-03-17

### Added
- **[USE-CASES.md](docs/use-cases/USE-CASES.md)** — каталог всех 15 сценариев использования IWE (WP-116):
  - SC.001–SC.005: планирование, обучение, знания, публикации
  - SC.006–SC.009: обслуживание, триаж, самовосстановление, аналитика
  - SC.010–SC.015: ОРЗ-ритм, стратегирование, онбординг, рабочая сессия, формализация знаний, развитие системы

## [0.8.4] — 2026-03-17

### Added
- **[docs/onboarding/](docs/onboarding/)** — руководство-онбординг IWE для новичков (WP-120):
  - [onboarding-guide.md](docs/onboarding/onboarding-guide.md) — концептуальный обзор (7 разделов: карта IWE, компоненты, проблемы, решения, путь от нуля, «не бойся», системное мышление)
  - [onboarding-slides.md](docs/onboarding/onboarding-slides.md) — Marp-презентация (22 слайда, self-paced, светлая тема)
  - [onboarding-diagrams.md](docs/onboarding/onboarding-diagrams.md) — 6 Mermaid-схем (карта компонентов, путь пользователя, ОРЗ, тиры T1-T4, экзоскелет vs протез, проблема→решение)

## [0.8.3] — 2026-03-17

### Added
- **[LEARNING-PATH.md](docs/LEARNING-PATH.md) §11** — FAQ: cross-device workflow (ноут + десктоп, кросс-ОС)

## [0.8.2] — 2026-03-17

### Added
- **[protocol-open.md](memory/protocol-open.md)** — 4-й класс верификации `trivial` (Haiku): результат очевиден, проверка не нужна
- **[protocol-open.md](memory/protocol-open.md)** — два сценария переключения модели:
  - Сценарий A: вся сессия — Claude рекомендует `/model`, пользователь переключает
  - Сценарий B: отдельная задача внутри сессии — делегирование sub-agent'у (только вниз)
- **[SETUP-GUIDE.md](docs/SETUP-GUIDE.md) §0.5b** — класс верификации в таблице моделей + описание двух сценариев
- **[LEARNING-PATH.md](docs/LEARNING-PATH.md) §5.1b** — trivial в таблице классов + два сценария переключения

## [0.8.1] — 2026-03-16

### Added
- **CLAUDE.md** — различение «Скилл ≠ Роль ≠ Протокол» (WP-104)
- **hard-distinctions.md HD #11** — переработка: обещание (SC) ≠ описание метода ≠ сервис (WP-101, DP.D.039)
- **protocol-open.md** — режим `interactive: false` для Day Open (вывод одним блоком, «Требует внимания» в конце)

## [0.8.0] — 2026-03-16

### Added
- **Видеоинтеграция (WP-102)** — 6 сценариев связи видеозаписей с РП:
  - С1: Авто-триаж при Day Open (шаг 5b) — сканирование папок Zoom, Телемост и др.
  - С2: Предложение РП в план дня из привязанных видео
  - С3: Еженедельный видео-ревью в Strategy Session
  - С4: Транскрипция → Captures (через whisper, опционально)
  - С5: Видео → Посты и контент (через творческий конвейер)
  - С6: Напоминания о необработанных видео (>stale_days)
- **day-rhythm-config.yaml → `video`** — секция конфигурации: directories (массив), extensions, stale_days, auto_transcribe, content
- **video-scan.sh** — скрипт сканирования (`roles/synchronizer/scripts/`): --new, --stale, --dry-run
- **protocol-close.md** — шаг «Видео за день» в Day Close + пункт в чеклисте Session Close
- **protocol-work.md §2b** — сценарии транскрипции и генерации контента из видео

### Changed
- **protocol-open.md** — шаблоны DayPlan и WeekPlan дополнены секцией «Видеозаписи» и «Видео-ревью»
- Повестка Strategy Session — добавлен пункт «Видео-ревью (С3)»

## [0.7.0] — 2026-03-16

### Added
- **Google Calendar MCP** — Этап 5 в SETUP-GUIDE: подключение Google Calendar за 2 мин
- **protocol-open.md шаг 4c** — «Календарь дня»: все календари, локальный timezone, фильтр конфиденциальных, свободные слоты
- **Шаблон DayPlan** — секция «Календарь» с таблицей событий

## [0.6.4] — 2026-03-16

### Fixed
- **gh repo fork:** убран несовместимый флаг `--remote` из SETUP-GUIDE, setup.sh, ADR-001
- **README.md:** `git clone` → `gh repo fork --clone` (согласованность с SETUP-GUIDE)
- **strategist.sh:** `cleanup-processed-notes.py` → `.sh` (файл .py не существовал)
- **strategist.sh:** хардкод авторского пути к notify.sh → относительный через `$SCRIPT_DIR`
- **strategist.sh, dt-collect.sh:** `$HOME/IWE` → `{{WORKSPACE_DIR}}` (подставляется setup.sh)
- **update.sh:** нумерация шагов `[1/4],[2/4]` → `[1/6],[2/6]`
- **setup-wakatime.md:** `wakatime-cli` → `~/.wakatime/wakatime-cli` (полный путь)
- **SETUP-GUIDE.md:** MCP-команды отделены от bash-блока (пользователи пытались запускать в терминале)
- **DS-strategy naming:** унифицировано `DS-my-strategy` → `DS-strategy` в protocol-open.md (15 замен). Убран FAQ-костыль из LEARNING-PATH

## [0.6.3] — 2026-03-16

### Fixed
- **Cross-platform compat:** `sed -i ''` → `sed_inplace` (setup.sh, update.sh) — GNU sed (Linux)
- **Cross-platform compat:** `date -v` → `portable_date_offset` (fetch-wakatime.sh, dt-collect.sh, scheduler.sh) — GNU date (Linux)
- **Cross-platform compat:** `osascript` → fallback notify-send (strategist.sh, extractor.sh) — Linux desktop
- **Cross-platform compat:** setup.sh шаг 5 пропускается на Linux (нет launchctl)

### Added
- **docs/PLATFORM-COMPAT.md** — чеклист + обёртки + grep-команды
- **.githooks/pre-commit** — блокирует коммит с raw платформозависимыми конструкциями
- **CLAUDE.md §Различения** — правило кроссплатформенности

## [0.6.2] — 2026-03-16

### Added
- **Правило Ru-first (SPF §5 п.13)** — русский как основной язык шаблонов/протоколов/документов. EN только для YAML-ключей, аббревиатур из онтологии, имён собственных
- **AUTHOR-ONLY зоны** — маркеры `<!-- AUTHOR-ONLY -->` для пользовательских расширений протоколов. При обновлении шаблона (template-sync/update.sh) пользовательский контент сохраняется
- **Параметризация strategy_day** — день стратегирования читается из `day-rhythm-config.yaml`, не хардкодится. Пользователь может выбрать любой день недели
- **Strategy_day guard в Day Open** — в день стратегирования DayPlan не создаётся (план дня уже в WeekPlan → секция «План на [день]»)
- **LEARNING-PATH** — §2.4 три паттерна кастомизации (L3→L4), §5.1 strategy_day guard, §5.5 настройка дня стратегирования, Quick Reference: 2 новых вопроса
- **Четвёртая зона** — CONFIG (day-rhythm-config.yaml) + AUTHOR-ONLY в описании структуры (§2.2)
- **Двухуровневый FAQ** — категоризация Pack FAQ (§11, 5 категорий) и LEARNING-PATH Quick Ref (§11, 4 категории). Процесс capture-to-FAQ формализован. Правило синхронизации FAQ в CLAUDE.md

### Changed
- **strategist.sh** — маршрутизация morning читает `strategy_day` из конфига вместо `DAY_OF_WEEK -eq 1`
- **protocol-open.md** — шаг 4 блокирующий (strategy_day → пропуск DayPlan), шаг 7 с guard, DayPlan Gate с исключением
- **README.md §FAQ** — расширен (3 новых вопроса) + ссылки на полный FAQ в Pack и LP

### Migration (для существующих пользователей)
- `day-rhythm-config.yaml` уже содержит `strategy_day: monday` — менять не нужно, если понедельник подходит
- Если вы скопировали `scheduler.sh` из авторского репо — замените `"$DOW" = "1"` на чтение из конфига (см. авторский `scheduler.sh`)
- AUTHOR-ONLY зоны: в протоколах появятся плейсхолдеры `<!-- YOUR CUSTOM CHECKS HERE -->` — замените на свой контент при необходимости

## [0.6.1] — 2026-03-15

### Changed
- **README переработан** — концептуальный файл для новичков: проблемы пользователей, аналогия IDE↔IWE, протокол ОРЗ, сценарии (рабочие + личные), сравнение с Obsidian/Notion. Детали установки → SETUP-GUIDE.md, глоссарий → ONTOLOGY.md
- **LEARNING-PATH полная актуализация** — §5 ОРЗ-фрактал (День+Сессия), §1.3 тиры T0-T4, §3.2 различения HD #25-36, §5.3 dual routing, §8.1 АрхГейт + coordination cost, §11 чеклист Close 7→15 шагов
- **Backport live→template** — protocol-work.md (ОРЗ День+Сессия), protocol-close.md (ветки, ad-hoc), hard-distinctions.md (HD #25-36), checklists.md (Pack + посты)

### Added
- **Activation Gate** — колонка «Активация» в WP-REGISTRY (3 типа: date/dep/on-demand) + Dormant Review в WeekPlan
- **ONTOLOGY.md расширение** — 4 реализационных понятия (Creative Pipeline, Guard, DayPlan, WeekPlan) + 14 аббревиатур (TTL, HD, SOTA, SOP, DDD, CLI, API, LMS, S2R, PII, RSS, TG, ZP)
- **Activation Check + Dormant Review** — секции в protocol-open.md (шаблон WeekPlan + повестка стратегирования)
- **LEARNING-PATH §5.5** — описание Activation Gate, 2 новых вопроса в Quick Reference

## [0.6.0] — 2026-03-14

### Added
- **Session tracking** — `open-sessions.log` в протоколах Open/Close для отслеживания активных сессий
- **TG-оповещения об обновлениях** — GitHub Action ежедневно проверяет коммиты и отправляет дайджест подписчикам через бот
- **5-й архитектурный вид (Методы)** — sync с DP.IWE.001, расширение архитектурной документации
- **roles.md** — описание ролей экзокортекса + обновление memory policy
- **ONTOLOGY.md в формате SPF.SPEC.002** — каскадная онтология с двуязычным глоссарием
- **KE dual routing** — экстрактор знаний разделяет: доменное → Pack, реализационное → DS docs/
- **dt-collect** — скрипты сбора данных активности для ЦД (WakaTime + git + sessions + WP stats) в роли синхронизатора
- **Day Rhythm config** — конфиг ритма дня: помодоро-напоминания через WakaTime + launchd
- **Опциональные компоненты** — README для модульных расширений, обновлённое дерево структуры
- **HD #29-31** — новые hard distinctions: Pack≠DS, роли владельца, Шаг 0 Open-протокола, Capture реализации

### Changed
- **README компактный** — переработан для новичков, убраны лишние детали
- **DP.AGENT → DP.ROLE** — миграция идентификаторов, удалён дубль strategist-agent/ (WP-63)
- **repo-type-rules** — DS-ecosystem-development = governance + staging for Pack
- **LEARNING-PATH** — добавлен триал 30 дней + подписка БР в таблице тиров
- **CLAUDE.md §6** — правила форматирования таблиц РП (bold active, strikethrough done)
- **notify-update workflow** — рефакторинг: webhook → бот рассылает подписчикам (вместо прямых Telegram API вызовов)
- **Memory policy** — обновлены лимиты и правила хранения

### Fixed
- **MCP серверы** — регистрация через `claude mcp add` вместо JSON config (фикс для Claude Code)
- **Memory symlink** — добавлен в setup.sh + правило workspace root в CLAUDE.md
- **Стейлые промпты** — удалены дублирующие файлы из roles/strategist/prompts/
- **CHANGELOG v0.5.0** — русскоязычный текст, убраны ссылки на Github
- **Пути шаблона** — исправлены пути для Day Rhythm конфига

## [0.5.0] — 2026-03-10

### Added
- **CHANGELOG.md** — история изменений шаблона в формате release notes
- **update.sh: release notes** — при обновлении показывает «Что нового» из CHANGELOG
- **update.sh: re-substitution** — автоматическая подстановка рабочей директории после обновления
- **DATA-POLICY.md** — политика данных IWE + подтверждение при установке

### Fixed
- **Захардкоженные пути** — 14 файлов теперь используют переменную рабочей директории (шаблон работает с любым расположением)
- **update.sh** — убран хардкод пути, теперь динамическое определение директории

### Changed
- **Рабочая директория по умолчанию** — документация теперь рекомендует ~/IWE

## [0.4.0] — 2026-03-01

### Added
- **setup.sh** встроен в шаблон (ADR-001, АрхГейт 6.4→8.3)
- **Модульные роли** с `role.yaml` autodiscovery (ADR-002, АрхГейт 8.9)
- **Core-режим** установки (`--core`) — только git, без сети
- **Vendor-agnostic AI CLI** — поддержка Codex, Aider, Continue.dev через переменные
- **Авто-переименование репо** при установке
- **Творческий конвейер** — 7 категорий заметок, draft-list, guards
- **WP-REGISTRY** — seed template для отслеживания РП
- **Экзоскелет vs протез** — принцип #21 в LEARNING-PATH

### Fixed
- **setup.sh fallback** — явное предупреждение при отсутствии `seed/strategy/`
- **Битая ссылка** FPF/README.md
- **Приватные ссылки** убраны из README

## [0.3.0] — 2026-02-16

### Added
- **LEARNING-PATH.md** — полный путь изучения экзокортекса (T0→T4 + TM/TA/TD)
- **update.sh** — обновление шаблона из upstream (fetch + merge + reinstall)
- **SETUP-GUIDE.md** — пошаговое руководство установки
- **IWE-HELP.md** — быстрый справочник
- **АрхГейт (ЭМОГССБ)** — 7 характеристик в CLAUDE.md
- **SOTA-reference.md** — справочник SOTA-практик
- **WakaTime** — интеграция в стратег-отчёты

## [0.2.0] — 2026-02-09

### Added
- **Note-Review** — сценарий обзора заметок + детерминированная очистка
- **WP Context Files** — поддержка inbox/WP-*.md
- **CI: validate-template.yml** — проверка генеративности на каждый push
- **ONTOLOGY.md** — терминология платформы

## [0.1.0] — 2026-01-27

### Added
- Начальная структура шаблона экзокортекса
- CLAUDE.md, memory/, roles/ (стратег, экстрактор, синхронизатор)
- Стратег: session-prep, day-plan, strategy-session, week-review
- seed/strategy/ — шаблон DS-strategy
