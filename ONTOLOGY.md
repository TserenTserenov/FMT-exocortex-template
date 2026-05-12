# Онтология: Экзокортекс-шаблон IWE

> Downstream-онтология по SPF.SPEC.002 §4.3.
> Ссылается на понятия Pack DP (Digital Platform) и SPF. Собственные понятия не вводит — только реализационные.
> **§1-4: Platform-space** (обновляется через `update.sh`). **§5-6: User-space** (только локально).

---

## 1. Upstream-зависимости

| Upstream | Уровень | Что используется |
|----------|---------|-----------------|
| SPF (SPF.SPEC.002) | Base | Виды сущностей, правила онтологии, аббревиатуры |
| PACK-digital-platform (DP) | Pack | Доменные понятия, различения, архитектура платформы |

---

## 2. Используемые понятия из Pack

> Ссылочные понятия из PACK-digital-platform. Определения — в Pack ontology.md. Здесь — как они используются в шаблоне.

| Термин (RU) | Term (EN) | Pack-понятие | Как используется в шаблоне |
|-------------|-----------|-------------|---------------------------|
| Среда (IWE) | Environment (IWE) | DP.CONCEPT.002 | Корневое понятие — шаблон развёртывает IWE |
| Экзокортекс-интерфейс | Exocortex Interface | DP.EXOCORTEX.001 | CLAUDE.md + memory/ — ядро шаблона |
| Platform-space | Platform-space | DP.D.011 | Файлы, обновляемые через update.sh (CLAUDE.md, memory/*.md) |
| User-space | User-space | DP.D.011 | Файлы пользователя (MEMORY.md, DS-strategy/, личные планы) |
| Экстракция знаний | Knowledge Extraction | DP.M.001 | Метод Capture-to-Pack в протоколе работы |
| Адаптивная персонализация | Adaptive Personalization | DP.M.004 | MCP ddt — цифровой двойник ученика |
| Цифровой двойник | Digital Twin | DP.CONCEPT.001 | MCP ddt — метамодель, цели, самооценка |
| Навигация знаний | Knowledge Navigation | DP.NAV.001 | Gateway iwe-knowledge (mcp.aisystant.com/mcp) — hybrid search по Pack и guides |
| IPO-паттерн | IPO Pattern | DP.ARCH.001 | Контракт описания компонентов в CLAUDE.md |
| Архитектурная характеристика | Architectural Characteristic | DP.D.010 | АрхГейт (ЭМОГССБ) в CLAUDE.md §5 |
| Файл контекста РП | WP Context File | DP.EXOCORTEX.001 | inbox/WP-*.md в DS-strategy |
| Harness (упряжь) | Harness | DP.D.025 | IWE как harness для интеллектуальной работы |
| ИИ-система | AI System | DP.ROLE.001 | Claude Code, бот — исполнители ролей |
| ИТ-система | IT System | DP.SYS.001 | MCP-серверы, WakaTime — детерминированные компоненты |

---

## 3. Терминология реализации

> Собственные понятия шаблона, специфичные для реализации. Привязаны к понятиям Pack.

| Термин (RU) | Term (EN) | Определение | Pack-понятие |
|-------------|-----------|-------------|-------------|
| Слой памяти | Memory Layer | Уровень хранения инструкций экзокортекса (Layer 1: MEMORY.md, Layer 2: CLAUDE.md, Layer 3: memory/*.md) | DP.EXOCORTEX.001 |
| Контур системы | Platform Contour | Уровень вложенности IWE (L1 Ecosystem → L2 Platform → L3 Template → L4 Personal) | DP.ARCH.001 |
| Ритуал ОРЗ | ORZ Ritual | Реализация протокола сессии: Открытие → Работа → Закрытие | DP.M.003 |
| WP Gate | WP Gate | Блокирующая проверка наличия РП в плане перед началом работы | DP.EXOCORTEX.001 |
| Capture-to-Pack | Capture-to-Pack | Рубежная проверка: есть ли знание для записи в Pack | DP.M.001 |
| АрхГейт (ЭМОГССБ) | ArchGate | Обязательная оценка архитектурного решения по 7 характеристикам, порог ≥8 | DP.M.005 |
| Стратегический хаб | Strategy Hub | DS-strategy — governance-репо для планов, ревью, сессий | DP.ROLE.012 |
| Placeholder-переменная | Placeholder Variable | `{{VAR}}` — подставляется setup.sh при развёртывании шаблона | — (реализационное) |
| Контракт роли | Role Contract | role.yaml + промпты + скрипты в roles/<name>/ | DP.ROLE.001 |
| Реестр РП | WP Registry | Single-source агрегатор активных РП: `WP-REGISTRY.md` + `inbox/WP-*.md` в governance-репо, sweep через `scripts/active-wp-sweep.sh` (отменён hub-and-spoke с WORKPLAN.md, WP-283 Ф-H, май 2026) | DP.ROLE.012 |
| Творческий конвейер | Creative Pipeline | 4 стадии превращения мысли в публикацию: заметка → черновик → заготовка → пост. Каждый артефакт обязан продвинуться или быть закрыт в пределах TTL | DP.M.003 |
| Guard (страж) | Guard | Автоматическая проверка TTL-нарушений на стратегировании и Day Close | DP.EXOCORTEX.001 |
| DayPlan | DayPlan | Дневной план — артефакт Day Open. Handoff Стратег→Человек | DP.M.003 |
| WeekPlan | WeekPlan | Недельный план — артефакт стратегирования. Содержит РП, бюджеты, фокус | DP.M.003 |

---

## 4. Аббревиатуры (Platform-space)

> Аббревиатуры, используемые в шаблоне. Наследованные из upstream отмечены уровнем.

| Аббревиатура | Расшифровка (RU) | Full form (EN) | Уровень |
|-------------|-----------------|----------------|---------|
| FPF | Фреймворк первых принципов | First Principles Framework | FPF |
| SPF | Фреймворк вторых принципов | Second Principles Framework | SPF |
| UL | Единый язык | Ubiquitous Language | FPF (DDD) |
| BC | Ограниченный контекст | Bounded Context | FPF (DDD) |
| KE | Экстракция знаний | Knowledge Extraction | SPF |
| FM | Режим ошибки | Failure Mode | SPF |
| WP | Рабочий продукт | Work Product | SPF |
| IPO | Вход-Обработка-Выход | Input-Processing-Output | SPF |
| DP | Цифровая платформа | Digital Platform | Pack |
| IWE | Среда интеллектуальной работы | Intellect Work Environment | Pack |
| MCP | Протокол контекста модели | Model Context Protocol | Pack |
| ОРЗ | Открытие-Работа-Закрытие | Open-Work-Close | Pack |
| РП | Рабочий продукт (экземпляр) | Work Product (instance) | Pack |
| ЦД | Цифровой двойник | Digital Twin | Pack |
| ЭМОГССБ | 7 арх. характеристик | Evolvability, Scalability, Learnability, Generativity, Speed, Modernity, Security | Pack |
| DS | Downstream-репозиторий | Downstream Repository | Template |
| FMT | Формат (шаблон) | Format (Template) | Template |
| TTL | Срок жизни артефакта | Time To Live | Template |
| HD | Жёсткое различение | Hard Distinction | Template |
| SOTA | Современное состояние практик | State Of The Art | Template |
| SOP | Стандартная операционная процедура | Standard Operating Procedure | FPF |
| DDD | Предметно-ориентированное проектирование | Domain-Driven Design | FPF |
| CLI | Интерфейс командной строки | Command-Line Interface | общее |
| API | Программный интерфейс | Application Programming Interface | общее |
| LMS | Система управления обучением | Learning Management System | Pack |
| S2R | Формат «Системы-к-ролям» | Systems-to-Roles | SPF |
| PII | Персональные данные | Personally Identifiable Information | общее |
| RSS | Лента новостей | Really Simple Syndication | общее |
| TG | Telegram | Telegram | общее |
| ZP | Нулевые принципы | Zero Principles | Base |

---

<!-- ═══════════════════════════════════════════════════════ -->
<!-- USER-SPACE: Секции ниже НЕ обновляются через update.sh -->
<!-- ═══════════════════════════════════════════════════════ -->

## 5. Мой глоссарий

> Твои собственные понятия. Добавляй сюда термины, которые важны для твоей работы.
> Если термин окажется доменным (полезен другим пользователям) — Knowledge Extractor предложит добавить его в Pack.

| Термин (RU) | Term (EN) | Определение | Связь с Pack |
|-------------|-----------|-------------|-------------|
| _Пример: Утренний ритуал_ | _Morning Ritual_ | _Моя последовательность session-prep + day-plan_ | _DP.M.003 (протокол ОРЗ)_ |

---

## 6. Мои аббревиатуры

> Аббревиатуры, специфичные для твоей работы. Платформенные — в §4 выше.

| Аббревиатура | Расшифровка (RU) | Full form (EN) |
|-------------|-----------------|----------------|
| _ПР_ | _Пример расшифровки_ | _Example abbreviation_ |

---

_Downstream-онтология по SPF.SPEC.002 §4.3. Upstream: Pack DP (Digital Platform)_
