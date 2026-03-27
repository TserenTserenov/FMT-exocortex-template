# Инструкции для всех репозиториев

> Slim-ядро: триггеры + правила. Детали → memory/protocol-*.md, .claude/rules/, .claude/skills/.

## 1. Архитектура репозиториев

| Тип | Что содержит | Первоисточник |
|-----|-------------|---------------|
| **Base** (Принципы + Форматы) | ZP, FPF, SPF, FMT-* | Да (платформа) |
| **Pack** | Паспорт предметной области | Да (пользователь) |
| **DS** (instrument/governance/surface) | Код, планы, курсы | Нет (производное от Pack) |

**Fallback Chain:** DS → Pack → Base (SPF → FPF → ZP)
**Pack = source-of-truth для доменного знания. DS меняется вслед за Pack.**
Детали типов, именование, измерения: → `memory/repo-type-rules.md`

## 2. ОРЗ-фрактал (Открытие → Работа → Закрытие)

> Три стадии, три масштаба. Пропуск Открытия = незапланированная работа. Пропуск Закрытия = незафиксированный результат.

| Масштаб | Открытие | Работа | Закрытие |
|---------|----------|--------|----------|
| **Сессия** | `protocol-open.md § Сессия` (любое задание) | `protocol-work.md` | `/run-protocol close` |
| **День** | `/day-open` («открывай») | Между Day Open и Day Close | `/run-protocol day-close` |
| **Неделя** | — | — | `/run-protocol week-close` |

> **Первая неделя:** Если WeekPlan ещё не создан — работайте на уровне сессий. Day Open и Week Close подключатся после первой стратегической сессии ([SETUP-GUIDE §2](docs/SETUP-GUIDE.md)).

### Блокирующие правила

1. **WP Gate:** ЛЮБОЕ задание → протокол Открытия → ДО начала работы.
2. **Push:** «заливай» / «запуши» → commit + push без доп. вопросов. Push ДО отчёта Закрытия.
3. **Close:** Триггер Закрытия → протокол Закрытия → выполнить.
4. **Чеклист-верификация (Haiku R23):** Quick Close и Day Close — sub-agent Haiku R23 (context isolation). Исключения: сессия ≤15 мин или без изменений файлов.
5. **Pull-before-Commit / Без Obsidian:** см. §9.

### Протокол Работы (полный → `memory/protocol-work.md`)

**Capture-to-Pack** — на каждом рубеже: есть ли знание для записи? Анонсировать: *«Capture: [что] → [куда]»*. Маршрутизация: правило (1-3 строки) → CLAUDE.md, доменное → Pack, реализационное → DS docs/, урок → memory/.
**Self-correction:** расхождение → немедленно предложить фикс (файл, строка, что изменить).

### Pre-action Gates

| Момент | Проверка |
|--------|---------|
| Начало работы | Какие сервисы (MAP.002) затронуты? |
| Пользовательский сценарий | **UC Gate:** какое обещание (08-use-cases/) затронуто? |
| `git commit` в репо с CLAUDE.md | Прочитать CLAUDE.md репо |
| Архитектурное решение | **АрхГейт** → `/archgate` |
| РП ≥3h | **Priority Gate:** к какому R{N} ведёт? |
| Новый инструмент/агент/система | **IntegrationGate:** тип, контур (L2/L3/L4), роли, продукты, процессы |

## 3. Описания методов (PROCESSES.md)

≤15 мин — не нужен. Внутри системы — `<repo>/PROCESSES.md`. Новая система — сценарий + процессы + данные.

## 4. Memory (Слой 3)

| Ситуация | Читай |
|----------|-------|
| Файлы/репо | `memory/navigation.md` |
| Pack-репо | `memory/repo-type-rules.md` |
| Терминология | `memory/hard-distinctions.md` |
| FPF/SOTA/Роли | `memory/fpf-reference.md`, `memory/sota-reference.md`, `memory/roles.md` |
| Документ/чеклист | `memory/checklists.md` |

Политика: ≤11 файлов. Справочники ≤100 строк. Протоколы ≤150. MEMORY.md ≤100 строк.
Рабочая директория: `{{WORKSPACE_DIR}}/` (не из sub-директорий). `{{WORKSPACE_DIR}}/memory/` = симлинк на auto-memory.

## 5. АрхГейт — ОБЯЗАТЕЛЬНАЯ оценка

> **БЛОКИРУЮЩЕЕ.** Архитектурное решение → `/archgate` → принципы (DP.ARCH.001 §7) → таблица ЭМОГССБ → порог ≥8.
> Чеклист современности: (1) Context Engineering SOTA.002, (2) DDD Strategic SOTA.001, (3) Coupling Model SOTA.011.

## 6. Форматирование → `.claude/rules/formatting.md`

## Различения → `.claude/rules/distinctions.md`

## 7. Расширения и параметры

### Extension Points (drop-in)

> При встрече `<!-- EXTENSION POINT: загрузить extensions/<file>.md если существует -->` в протоколах — **проверить файл и вставить содержимое**.

**Механика:**
1. Увидел комментарий `<!-- EXTENSION POINT: загрузить extensions/X.md -->` в протоколе
2. Проверь: файл `extensions/X.md` существует? (Glob)
3. Да → прочитай и выполни как часть протокола
4. Нет → пропусти молча

**Формат имён:** `<protocol>.<hook>.md` (например `protocol-close.checks.md`, `day-close.after.md`)
**Документация:** `extensions/README.md`

### params.yaml (персистентные параметры)

> Протоколы **проверяют** `params.yaml` перед условными шагами.

**Механика:**
1. Перед условным шагом (video check, multiplier, reflection) → прочитать `params.yaml`
2. Параметр `false` → пропустить шаг
3. Файл не существует → использовать defaults (всё включено, кроме `reflection_enabled`)

## 8. Обновление этого файла

> **3 слоя:** L1 (§1-§8) = платформа (`update.sh`). L2 (§9) = staging. L3 (§10) = авторское.

- Протоколы → `memory/protocol-*.md`
- Различение (1-3 строки) → `.claude/rules/distinctions.md`
- Форматирование → `.claude/rules/formatting.md`
- Стабильные знания → `memory/*.md`
- Расширения → `extensions/<protocol>.<hook>.md`
- Параметры → `params.yaml`
- Свои правила → §9 (staging) или §10 (авторское)

<!-- PLATFORM-END -->

---

## 9. Staging (обкатка → шаблон)

> Правила на обкатке. Работают → переносятся в шаблон (L1).
> **Перенесено в L1 (20 мар):** UC Gate, межсистемные процессы, чеклист-верификация.

---

## 10. Авторское (только мой IWE)

### Блокирующие (авторские)

- **Pull-before-Commit (DS-strategy):** `git pull --rebase` → модификация → `commit` → `push`.
- **Без Obsidian (DS-strategy):** Просмотр через VS Code.

### Именование

- `DS-strategy` (не `DS-strategy`) — личный governance-хаб
- `{{WORKSPACE_DIR}}/` — рабочая директория

### Read-only репо

<!-- Добавьте свои read-only репо. Пример: -->
<!-- > **your-org/your-repo** — ⛔ READ-ONLY. -->

### README.md (FMT-exocortex-template)

> Изменение структуры — по согласованию с владельцем.

---

*Последнее обновление: 2026-03-24*
