# Инструкции для всех репозиториев

> Slim-ядро: триггеры + правила. Детали → `memory/protocol-*.md`, `.claude/rules/`, `.claude/skills/`.
> Синхронизация: `scripts/template-sync.sh` · Агент-специфичные инструкции: Hermes → Aisystant MCP `get_instructions`.

## 1. Архитектура репозиториев

| Тип | Что содержит | Первоисточник |
|-----|-------------|---------------|
| **Base** (Принципы + Форматы) | ZP, FPF, SPF, FMT-* | Да (платформа) |
| **Pack** | Паспорт предметной области | Да (пользователь) |
| **DS** (instrument/governance/surface) | Код, планы, курсы | Нет (производное от Pack) |

**Fallback Chain:** DS → Pack → Base (SPF → FPF → ZP). **Pack = source-of-truth доменного знания.**
**Лестница принципов (уровень специфичности):** ZPF → FPF → SPF → TPF → LPF
где: ZPF/FPF/SPF-методология → Base · SPF-инстанс → Pack · TPF → DS + операционный слой агента · LPF → партикулярные практики роли (тест: без носителя данной роли — бессмысленны); детали → `memory/repo-type-rules.md`
> Словарь ailev ↔ IWE (DPF ≈ Pack, переименование не планируется) → `memory/fpf-reference.md`.
**Pack Creation Gate:** хочешь Pack → `/pack-new`. Имя = существительное-домен.
Детали типов: → `memory/repo-type-rules.md`

## 2. ОРЗ-фрактал (Открытие → Работа → Закрытие)

| Масштаб | Открытие | Работа | Закрытие |
|---------|----------|--------|----------|
| **Сессия** | `protocol-open.md § Сессия` | `protocol-work.md` | `/run-protocol close` |
| **День** | `/day-open` | Между Open и Close | `/run-protocol day-close` |
| **Неделя** | — | — | `/run-protocol week-close` |
| **Месяц** | — | — | `/month-close` |

### Блокирующие правила

> Source-of-truth: `PACK-agent-rules/rules/AR.NNN.md`. Структурные (1-5) > поведенческих (6-10).

1. **WP Gate:** ЛЮБОЕ задание → протокол Открытия → ДО начала работы. Новый РП: объявить (Роль пользователя · Роль Claude · Работа · РП · ТВС · Класс верификации · Метод · ~Xh · Модель) → ждать «да». Шаги 3-4 → `memory/protocol-open.md`.
2. **Push:** «заливай/запуши/закрывай» → commit+push без вопросов. При Close: `git status` по ВСЕМ репо → незафиксированное → commit+push ДО следующего шага.
3. **Close:** Триггер Закрытия → протокол Закрытия → выполнить.
4. **Pull-on-Touch:** `git pull --rebase` при ПЕРВОМ обращении к репо за сессию (lazy, один раз). Конфликт → вариант А: stash + «potentially stale». Сетевой fail → potentially stale.
5. **Чеклист-верификация:** Quick/Day Close → sub-agent Haiku R23. Исключение: сессия ≤15 мин или без изменений файлов.
6. **Hooks/Scripts Bypass Gate (БЛОКИРУЮЩЕЕ):** НЕ менять `.claude/hooks/`, `.claude/scripts/`, `.iwe-runtime/`, `FMT-exocortex-template/` без явного разрешения. Хук заблокировал → (1) НЕ обходить (2) записать в `inbox/bugs/bug-YYYY-MM-DD-<тема>.md` (3) сообщить пилоту (4) ждать инструкций.
7. **Автономность:** НЕ спрашивать «добавить/продолжить/записать?». Задание → выполни → отчитайся. Исключения: необратимое действие · WP Gate Ритуал · Choice-question («X или Y?»).
8. **Напоминания:** «напомни через X» → `send_telegram_message` (schedule_at) + ScheduleWakeup.
9. **Финиш > отлог:** новая задача → делаю сейчас. Исключения: бюджет ×2-×3 · требует ArchGate · контекст переключился. Если >15 мин + новый артефакт → WP Gate.

### Протокол Работы → `memory/protocol-work.md`

**Capture-to-Pack:** на рубеже — «Capture: [что] → [куда]». Routing Gate (DP.KR.001 §5) при создании артефакта.

| Pre-action Gate | Когда |
|-----------------|-------|
| Repo-Touch Gate | Первое действие в репо → читать `<repo>/CLAUDE.md` |
| Routing Gate | Создание/размещение артефакта → DP.KR.001 §5 |
| ArchGate | Архитектурное решение → `/archgate` |
| Security Gate | РП затрагивает PII → §Б чеклист ArchGate ДО реализации |
| IntegrationGate | Новый инструмент/агент/система → скилл `integration-gate` |
| LegacyPortGate | Замена legacy → 15-мин субагент «как сейчас?» ДО решения |

## 3. Описания методов (PROCESSES.md)

≤15 мин — не нужен. Внутри системы — `<repo>/PROCESSES.md`.

## 4. Memory (Слой 3)

| Ситуация | Читай |
|----------|-------|
| Файлы/репо | `memory/navigation.md` |
| Pack-репо | `memory/repo-type-rules.md` |
| Терминология | `memory/hard-distinctions.md` |
| FPF/SOTA/Роли | `memory/fpf-reference.md`, `memory/sota-reference.md`, `memory/roles.md` |
| Документ/чеклист | `memory/checklists.md` |

Политика: ≤15 HOT+WARM, суммарно ≤150 строк hot. CLAUDE.md = ядро (цель ≤150). `memory/` = симлинк auto-memory.

## 5. АрхГейт — ОБЯЗАТЕЛЬНАЯ оценка

> **БЛОКИРУЮЩЕЕ.** Архитектурное решение → `/archgate` (скилл `archgate`): профиль ЭМОГССБ, conjunctive screening.

## 6. Форматирование → `.claude/rules/formatting.md`

## Различения → `.claude/rules/distinctions.md`

## 7. Обновление этого файла

> **3 слоя:** L1 (§1-§7) = платформа. L2 (§8) = staging. L3 (§9) = авторское.

- Протоколы → `memory/protocol-*.md` · Правило (1-3 строки) → CLAUDE.md · Доменное → Pack
- §8+§9 (staging/авторское) → скилл `author-mode`

<!-- PLATFORM-END -->

---

## Agent Core (единое ядро для всех агентов)

> WP-394 Ф4.2. Единое ядро для Claude, Kimi, Hermes. Правки — сюда.

<!-- SYNC-CORE-START -->

## WP Gate — CRITICAL

**ЛЮБОЕ задание → протокол Открытия → ДО начала работы.** При создании нового РП: объявить роль, работу, РП, класс верификации, метод, оценку, модель. Дождаться согласования пилота.

## Git Staging — CRITICAL

**NEVER use `git add -u`, `git add .`, or `git add -A`.** Picks up other agents' changes.

**Always stage only specific files you edited:**
```bash
git add path/to/specific-file.md   # correct
# git add -u / git add . / git add -A  — FORBIDDEN
```

**Before every commit:** `git diff --cached --name-only` → confirm all files belong to current WP/context. Unexpected files → `git restore --staged <file>`.

## Artifact Naming
**Do not invent artifact names.** Names come from the plan/task. If silent on name — report "need clarification on name."
## Drift Reporting
Discrepancy found → **Report to pilot, do not silently fix.** "Found drift: [what] in [file]. Fix?" Fix only if instructed.
## Working Directory
`{{HOME_DIR}}/IWE/`
## Status Reporting
Start: `agent_status_update(agent=claude-code, status=working, task=..., files=[...])`. Done: `status=idle`. Team repo: add `repo="org/repo-name"`. Fail-safe: Stop-хук → `scripts/agent-status-report.sh`.
## WP-REGISTRY Naming — CRITICAL
**Колонка «Название» = ТОЛЬКО имя артефакта ≤80 символов.** Запрещено: даты, SHA, метрики, статусы фаз, ссылки. Итог → `archive/wp-contexts/WP-NNN.md §Закрытие`. Статус фаз → frontmatter `inbox/WP-NNN.md`.
## WP Context Scope — Umbrella РП
`umbrella: true` + `agent_scope: open-only` → читать только `pending/in_progress/blocked`. Архивные — не читать без запроса. Применяется к: WP-5, WP-7.
## Calendar Events — CRITICAL
**Все события агента — ДО 09:00.** Создано после 09:00 → удалить + пересоздать + сообщить пилоту.
## Language
Respond in Russian unless the user writes in English.
## Response Style — Pilot-Facing
Применять A1-A11 (`memory/feedback_response_clarity_for_pilot.md`). Channel: технический (commit/PR + пилот пишет `grep`/`git`/SHA) vs «на пальцах» (остальной чат).
## Code Style — Engineering (DP.SC.172)
→ `engineering-code-style-base.md` (PACK-digital-platform). P0 форматтер+линтер; P1 тест без assert запрещён; P2 повторение×3 → функция; P3 мёртвую ветку удалять; P4 `except: pass` без лога запрещён.

<!-- SYNC-CORE-END -->

---

## 8–9. Staging + Авторское → скилл `author-mode`

> Staging-канал (обкатка → FMT), Extensions Gate, авторские правила L3.

*Последнее обновление: 2026-06-26*
