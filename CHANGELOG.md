# Changelog

All notable changes to FMT-exocortex-template will be documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/).

## [0.16.0] — 2026-03-25

### Changed
- **WeekReport deprecated** — итоги недели теперь записываются в секцию «Итоги W{N}» внутри WeekPlan. Отдельный файл WeekReport больше не создаётся. АрхГейт 8.9 (62/70)
- **week-review.md** — пишет секцию в WeekPlan, не создаёт файл
- **session-prep.md** — читает секцию из WeekPlan, не ищет файл WeekReport

### Added
- **Кроссплатформенное предотвращение сна** — `strategist.sh` и `scheduler.sh` автоматически блокируют засыпание: macOS `caffeinate -diu` / Linux `systemd-inhibit`. Флаг `-s` не используется — он игнорируется когда Optimized Battery Charging переключает профиль на батарею
- **SETUP-GUIDE: инструкции wake+sleep** для macOS, Linux, Windows. Включая `pmset -b sleep 0` для ноутбуков и Charge Limit рекомендацию
- **PLATFORM-COMPAT: sleep prevention** — документация кроссплатформенных ограничений

### Updated
- docs/LEARNING-PATH, USE-CASES, SETUP-GUIDE, onboarding-guide — убран WeekReport
- roles/strategist/README, seed/strategy/CLAUDE.md — WeekReport помечен deprecated
- synchronizer/scripts/templates/strategist.sh — ищет WeekPlan вместо WeekReport
- README.md FAQ — обновлён вопрос про сон/выключение
- install.sh — кроссплатформенные подсказки при установке

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
- **[DP.SC.019](../PACK-digital-platform/pack/digital-platform/08-use-cases/DP.SC.019-template-update.md)** — сценарий «Обновление экзокортекса» + сервис S50 Template Update в MAP.002
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
