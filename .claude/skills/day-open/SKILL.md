---
name: day-open
description: "Day Open protocol. Collects yesterday's commits, issues, notes, calendar, bot QA, Scout, world events — builds DayPlan and compact dashboard."
argument-hint: ""
version: 1.1.0
routing:
  executor: sonnet
  deterministic: false
---

# Day Open (протокол открытия дня)

> **Роль:** R1 Стратег. **Два выхода:** DayPlan (git, 80+ строк) + compact dashboard (VS Code, 20-30 строк).
> **Порядок:** сначала DayPlan → потом compact. **Дата:** ПЕРВОЕ действие = `date`.
> **Режим:** `memory/day-rhythm-config.yaml` → `interactive: false` = одним блоком, решения → «Требует внимания».
> **Фильтр свежести:** issues, видео, заметки — за 2 дня. Urgent — всегда.
> **Issues — только actionable:** пропускать read-only репо (CLAUDE.md) и upstream без push-доступа (Base, чужие fork).
> **Шаблоны:** ниже (после алгоритма).

## БЛОКИРУЮЩЕЕ: пошаговое исполнение

Day Open = протокол. Исполнять ТОЛЬКО пошагово через TodoWrite.
Каждый шаг алгоритма ниже → отдельная задача (pending → in_progress → completed).
Переход к следующему — ТОЛЬКО после отметки текущего. Шаг невозможен → blocked (не пропускать молча).
**Почему:** без TodoWrite агент пропускает шаги из-за загрязнения контекста (SOTA.002).

## Алгоритм

### 0. Extensions (before)
Загрузить: `bash .claude/scripts/load-extensions.sh day-open before`. Exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить содержимое как первые шаги. Exit 1 → пропустить. Поддерживает `extensions/day-open.before.md` И `extensions/day-open.before.<suffix>.md`.

### 1. Вчера
Прочитать вчерашний DayPlan (`archive/day-plans/` или `current/`). Взять:
- Секцию «Итоги» → 1-3 результата
- Секцию «Завтра начать с:» / carry-over РП → **приоритетный вход** для шага 2
- Незакрытые вопросы из «Требует внимания»

Fallback: файла нет → пропустить, работать из коммитов.

Коммиты за вчера по всем `$IWE_WORKSPACE/*/` репо. Сопоставить с DayPlan.

### 1b. GitHub Issues
`gh issue list` по всем репо (включая вложенным). Фильтр 2 дня. Связь с РП по ключевым словам.
**Только actionable:** пропускать read-only и upstream без push-доступа.

**Critical FMT issues (детектор):** `bash $IWE_SCRIPTS/fmt-critical-alert.sh --no-telegram` — выводит markdown-таблицу открытых issues с label `critical`/`deadline` в FMT-exocortex-template. Если `TG_BOT_TOKEN` и `TG_CHAT_ID` настроены — убрать `--no-telegram` для дублирования в Telegram (MVP detection chain для weekend P0). Источник: peer-session 2026-06-01-18.

### 1c. Inbox Triage (ежедневный — WP-196 Ф11 п4)

> Явный шаг: разобрать новые входы, поступившие в `inbox/` за ночь и в начале дня.

**Источники:**
- `<governance-repo>/inbox/fleeting-notes.md` — свежие заметки
- `<governance-repo>/inbox/captures.md` — знаниевые кандидаты (если есть)
- `<governance-repo>/inbox/extraction-reports/*.md` со `status: pending-review` — отчёты Экстрактора (если есть)

**Категоризация заметок** по PD.FORM.083 (7 категорий): НЭП / Задача / Знание доменное / Знание реализационное / Черновик / Личные данные / Шум. Полная справка → `memory/feedback_note_review_routing.md`. НЕ удалять.
**Carry-over заметок из вчерашнего DayPlan:** проверить по git log (`note-review`), были ли обработаны. Если да → секция «Разбор заметок» = «все обработаны» (с ссылкой на коммит). Не переносить обработанные заметки как carry-over.
**Гиперссылки на заметки (БЛОКИРУЮЩЕЕ):** каждая заметка в секции «Разбор заметок» DayPlan — markdown-ссылка на её источник (`inbox/fleeting-notes.md` для свежих, `archive/notes/Notes-Archive.md#L<line>` для обработанных, `inbox/captures.md` для знания). Причина: после Note-Review сама заметка исчезает из fleeting-notes.md, и без ссылки суть заметки теряется через день. Формат строки таблицы: `[«заголовок»](путь#L<line>) (DD мес HH:MM)`.
**Знаниевые заметки = кандидаты (БЛОКИРУЮЩЕЕ):** заметки категории «Знание доменное» без явного маркера «Экстрактору» в тексте → в DayPlan секция «Разбор заметок» таблицей **Кандидаты Экстрактору** с колонками «Заметка | Тип | Предполагаемый Pack | Действие». Решение «отдать / оставить» принимает пользователь в живом разборе. Note-Review в `captures.md` пишет ТОЛЬКО при явном маркере. Причина: `captures.md` = очередь Экстрактора; любое знание туда = неявное согласие на формализацию, которое Note-Review делать не уполномочен.

### 2. План на сегодня
**Приоритет входов (строгий порядок):**
1. **Carry-over из Day Close (БЛОКИРУЮЩЕЕ):** ВСЕ РП из секции «Завтра начать с» → в план без обрезки. Это решение пользователя — Day Open не фильтрует и не сокращает этот список
2. **WeekPlan (ОБЯЗАТЕЛЬНО):** прочитать WeekPlan → ВСЕ in_progress и pending РП → проверить каждый: релевантен сегодня? Есть дата/дедлайн сегодня? Просрочен? → добавить.
   **Budget Spread** (если `budget_spread.enabled: true` в day-rhythm-config.yaml): для каждого РП с бюджетом ≥ `threshold_h` (колонка «h» в таблице WeekPlan):
   - `days_left` = оставшиеся рабочие дни пн–пт включая сегодня
   - `daily_slot` = round(budget_week / days_left, `rounding`)
   - Нет бюджета в WeekPlan → пропустить, добавить в «Требует внимания»
   - РП уже в плане (carry-over) → взять max(carry_over_budget, daily_slot)
   - Иначе → добавить с daily_slot
   Не ограничиваться «2-4 штуки» — план дня отражает реальную нагрузку
3. **MEMORY.md → «РП текущей недели»:** сверить — нет ли РП, упущенных в WeekPlan (ad-hoc, reopened)
4. `day-rhythm-config.yaml → mandatory_daily_wps` — обязательные РП (проверить наличие в плане, если нет → добавить)

**Слот 1 = саморазвитие.**
Mandatory РП отсутствуют в WeekPlan → «Требует внимания».

### 3. Саморазвитие
Руководство, где остановился, черновики (`<governance-repo>/drafts/`).

### 4. Стратегирование
Если strategy_day → DayPlan НЕ создавать, план в WeekPlan. Пропустить шаг 7.

### 4b. Помидорки
Из `day-rhythm-config.yaml → pomodoro`.

### 4c. Календарь (Day Mode)
`bash ${IWE_SCRIPTS:-$IWE_WORKSPACE/scripts}/server-calendar.sh YYYY-MM-DD` — секция «Календарь» для DayPlan.

**Что делает скрипт:**
1. Запрашивает ВСЕ календари из `calendar_ids` (см. feedback `feedback_calendar_query_day_open` — никаких сокращений).
2. Фильтрует только по `visibility == "private"` (не по названию).
3. Классифицирует:
   - **Встречи** — несколько участников, длительность >30 мин, нет маркеров задачи.
   - **Напоминания / Тех-операции** — маркеры 🔧 ✅ ⏰ 🔔 📋 ❗ или ключевые слова (backup, проверить, remind, smoke, test), либо ≤30 мин без участников.
4. Статус относительно текущего времени:
   - ⏳ предстоит / 🔄 идёт / ✅ завершено.
5. Считает свободные блоки ≥1h в рамках 09:00–22:00.

**Формат в DayPlan:** две таблицы (Встречи + Напоминания) по шаблону `memory/templates-dayplan.md`.

### 4c-alt. Календарь недели (Week Mode, strategy_day)
Если сегодня `strategy_day` (из `day-rhythm-config.yaml`) — перед формированием WeekPlan запустить:
```bash
bash ${IWE_SCRIPTS:-$IWE_WORKSPACE/scripts}/server-calendar.sh --week YYYY-MM-DD
```
Результат → вставить в WeekPlan секцию **«Календарь недели W{N}»** (шаблон `memory/templates-dayplan.md`). Это позволяет при планировании сразу учитывать встречи и тех-операции.

### 5. IWE за ночь (светофор)
update.sh, MCP reindex, Scout. 🟢/🟡/🔴.

**Проверка обновлений:** `cd "$IWE_TEMPLATE" && bash update.sh --check 2>&1`. Если доступно обновление → добавить в «Требует внимания»: «Доступно обновление IWE → `/iwe-update`».

**Проверка Base-репо (FPF, SPF, ZP):**
```bash
for repo in FPF SPF ZP; do
  dir="$IWE_WORKSPACE/$repo"
  [ -d "$dir/.git" ] && (cd "$dir" && git fetch --quiet 2>/dev/null && behind=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0) && [ "$behind" -gt 0 ] && echo "$repo: $behind новых коммитов" || echo "$repo: актуален")
done
```
Если есть новые коммиты → добавить в «Требует внимания»: «[repo] обновлён upstream → `cd "$IWE_WORKSPACE/[repo]" && git pull --rebase`». После pull FPF/SPF — запустить локальный reindex MCP-индекса, если установлен.

### 5a2. Видео
Если `day-rhythm-config.yaml → video.enabled: true`:
1. Сканировать директории из `video.directories` на файлы с расширениями из `video.extensions`
2. Показать ТОЛЬКО новые записи за сегодня (`-mtime 0`). Старые файлы — не оповещать (архивный долг, не daily concern)
3. Есть новые → «N новых видеозаписей сегодня (X ГБ)». Нет → «0 новых записей сегодня»
4. `video.enabled: false` → пропустить

### 5c. Редактор контента (DP.ROLE.033 / DP.SC.127)
`config: content_editor.enabled` (day-rhythm-config.yaml) — `false` → пропустить.
1. Читать все `<governance-repo>/drafts/D-NNN-*.md` — frontmatter (`created`, `ttl`, `updated`) + текст.
2. Читать WeekPlan активной недели — R-таблица (инициативы) + S-таблица (неудовлетворённости).
3. Оценить каждый черновик: (a) сильная идея — тезис в 1-2 предл.; (b) актуальность — совпадает с ≥1 R или S по тексту; (c) свежесть — `updated`/`created` ≤14 дней и TTL не истёк; (d) полнота — есть вступление + основная часть.
4. Отобрать топ-3 → секция «Редактор контента» в DayPlan: таблица D-ID / название / R/S-связь / причина.
5. Список застрявших (TTL истёк) отдельно под таблицей. Не архивировать — только показать.
6. Сигнал: проверить репо из `config.content_editor.index_repo` на посты со статусом из `config.content_editor.index_ready_status`. Если ≥ `config.content_editor.publish_signal_threshold` → добавить в «Требует внимания»: «N готовых постов в Index — запустить цикл публикации (Ц3)?»
7. Топ-3 формируется каждый день заново — не кэшировать вчерашние рекомендации.

### 5d. Scout
Scout report. Не проревьюен → «Требует внимания».

### 6. Мир
`day-rhythm-config.yaml → news`. Feeds/WebSearch. `enabled: false` → пропустить.
**Ссылки на источники обязательны** (URL).

**6a. News Lens (анализ через субагент).**
После сбора заголовков — вызвать субагент (Haiku, context isolation) с промптом:

> Ты — разведчик новостей. Тебе дан список заголовков + список активных РП пользователя.
> Задача: написать 2-4 предложения «Что из этого важно для работы сегодня?»
> Отвечай только на русском. Без перечисления всех новостей — только синтез.
> Входные данные:
> НОВОСТИ: {заголовки с темами}
> АКТИВНЫЕ РП: {топ-5 РП по приоритету из DayPlan}

Вывод субагента → поле **«Вывод:»** в начале секции «Мир». Формат секции:

```
**Вывод:** <2-4 предложения синтеза>

**AI/LLM:** [Заголовок 1](url) · [Заголовок 2](url) · ...
**Инженерия:** [Заголовок 1](url) · ...
**Мировые события:** [Заголовок 1](url) · ...
```

Субагент недоступен / таймаут → пропустить «Вывод», показать только ссылки.

### 6b. Требует внимания
Собрать из шагов 1–6. Нет → не выводить.

### 6b2. Разметка ТВС (режим работ дня)
> Модель ТВС — Текущее · Важное · Срочное (см. различения [[Текущее ≠ Важное ≠ Срочное (ТВС)]]).

При сборке плана дня пометить каждый РП/блок режимом ТВС:
- **Важное (развитие)** — ставить на максимально защищённый слот (утро, после завтрака): вероятность выполнить выше. Хотя бы один блок важного в день обязателен — иначе копится срочное.
- **Текущее (текучка)** — операционка, во вторую половину дня.
- **Срочное** — только угроза остановки конвейера; в план дня не закладывается заранее, попадает в течение дня. **Проверка нового дела:** «может подождать до ближайшей сессии стратегирования?» Да → мимолётная заметка, НЕ срочное. Нет → в план работ на сегодня. Дедлайн или «горит» сам по себе срочным не делает ([[Дедлайн ≠ Срочность]]).

### 6c. Extensions (after)
Загрузить: `bash .claude/scripts/load-extensions.sh day-open after`. Exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить содержимое (smoke-тесты, Scout gate, доп. проверки). Exit 1 → пропустить. Поддерживает `extensions/day-open.after.md` И `extensions/day-open.after.<suffix>.md`.

### 7. Запись

> ⚠️ **Перед шагами 7a и 7d:** прочитать `.claude/skills/day-open/templates.md` через Read.
> Если файл не найден — сообщить пилоту: «templates.md отсутствует в `.claude/skills/day-open/`. Установка IWE неполна — выполни `git pull` в FMT-exocortex-template или переустанови через setup.sh.» Не продолжать без шаблонов.

**7a.** Записать DayPlan: `<governance-repo>/current/DayPlan YYYY-MM-DD.md` по шаблону «Шаблон DayPlan» из `.claude/skills/day-open/templates.md`. Предыдущий → `archive/day-plans/`.
**7a2.** Записать журнал сессии (WP-196 Ф11 п1): `<governance-repo>/sessions/YYYY-MM-DD.md` со shapкой:

```markdown
---
type: session-log
date: YYYY-MM-DD
week: W{N}
agent: Стратег / Кодировщик
---

# Session Log: YYYY-MM-DD

## Day Open
- DayPlan: `current/DayPlan YYYY-MM-DD.md`
- Carry-over: [список из вчерашнего «Завтра начать с»]

## Сессии дня
> Заполняется в Day Close: список Quick Close сессий + ключевые рубежи

## Day Close
> Дописывается в Day Close: ссылка на `archive/day-plans/DayPlan YYYY-MM-DD.md` + 3 варианта плана на завтра
```

Файл создаётся пустой при Day Open и наполняется в течение дня. Назначение: гарантировать, что итог сессии не растворяется в WeekPlan — каждая сессия имеет след. Если файл уже существует (двойной Day Open) — не перезаписывать, просто пропустить.
**7b.** Загрузить: `bash .claude/scripts/load-extensions.sh day-open checks`. Exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить верификацию. Exit 1 → пропустить. БЛОКИРУЮЩЕЕ: commit запрещён до прохождения всех checks. Поддерживает `extensions/day-open.checks.md` И `extensions/day-open.checks.<suffix>.md`.
**7c.** `git commit` + `git push`.
**7d.** Compact dashboard → вывести в VS Code по шаблону «Шаблон compact dashboard» из `.claude/skills/day-open/templates.md`.
