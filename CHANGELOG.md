# Changelog

All notable changes to FMT-exocortex-template will be documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/).

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
