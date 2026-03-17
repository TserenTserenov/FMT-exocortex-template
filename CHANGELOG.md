# Changelog

All notable changes to FMT-exocortex-template will be documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/).

## [0.8.3] — 2026-03-17

### Added
- **LEARNING-PATH.md §11** — FAQ: cross-device workflow (ноут + десктоп, кросс-ОС)

## [0.8.2] — 2026-03-17

### Added
- **protocol-open.md** — 4-й класс верификации `trivial` (Haiku): результат очевиден, проверка не нужна
- **protocol-open.md** — два сценария переключения модели:
  - Сценарий A: вся сессия — Claude рекомендует `/model`, пользователь переключает
  - Сценарий B: отдельная задача внутри сессии — делегирование sub-agent'у (только вниз)
- **SETUP-GUIDE.md §0.5b** — класс верификации в таблице моделей + описание двух сценариев
- **LEARNING-PATH.md §5.1b** — trivial в таблице классов + два сценария переключения

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
