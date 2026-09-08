---
name: protocol-close
description: Slim-ядро протокола Close — триггеры, маршрутизация, Quick Close inline
type: reference
valid_from: 2026-04-13
originSessionId: b5655b53-7d87-478a-aad9-437479e81691

horizon: warm
domains: [protocol]
status: active
owner: platform
schema_version: 1
---
# Протокол Close (ОРЗ-фрактал)

> **Три масштаба:** Сессия (Quick Close), День (Day Close), Неделя (Week Close).
> **Точка входа:** Вызвать Skill `run-protocol` с нужным аргументом (см. таблицу ниже).
> **Порядок чтения (WP-484.md:1953, ошибка 28.07):** если разговор перед Close шёл про конкретный РП — прочитать сегодняшние записи его WP-context ПЕРВЫМ действием, только потом открывать сам протокол. Протокол раньше контекста = причина ошибки «принял фразу пилота за отсылку к прошлому решению, не перечитав contextfile».
> **Принцип:** Quick Close = «не потерять» (inline, без TodoWrite, ~3 мин). Day/Week Close = через SKILL.md + TodoWrite (принудительное исполнение).
> **CGUS (WP-481 Ф5):** порядок шагов = порядок удержания внимания, НЕ порядок исполнения. `[[gate]]`/`[[gate:AR.NNN]]` = предусловие (блокирует); `[[narrative]]` = демонстрационный порядок (skippable). Close проверяет удовлетворённость набора gate, не линейность прохождения.

## Маршрутизация

| Триггер | Аргумент | Skill |
|---------|---------|-------|
| «закрываю сессию» / «всё» / «закрывай» | `close` или `close session` | Quick Close (ниже, inline) |
| «закрываю день» / «итоги дня» | `close day` | `.claude/skills/day-close/SKILL.md` — **шаг 6: WakaTime + Мультипликатор IWE** |
| «закрываю неделю» / «итоги недели» | `week-close` | `.claude/skills/week-close/SKILL.md` |

> **`close` без уточнения** → Quick Close (сессия) по умолчанию.


## Quick Close (сессия, inline)

> **Роль:** R6 Кодировщик. **Бюджет с пилотом: ~1-2 мин** (свод + рефлексия) + **полное закрытие агент доводит один** (без пилота).
> **Принцип (DP.D.288, WP-484 31.07 — быстрое закрытие ≠ полное закрытие):** быстрое закрытие происходит быстро ДЛЯ ПИЛОТА — короткий свод того, что закоммичено, + рефлексия, не механика. Полное закрытие (WP-context, KE, MEMORY.md, R23) агент доводит сам сразу после, без пилота — результат в архиве, не в чате по умолчанию.
> «Закрывай» = push сразу без вопросов (пользователь дал согласие словом).
> **Day Close ≠ Quick Close.** Day Close самодостаточен — Quick Close внутри него не повторять.

### Раннер — условный драйвер (WP-482 Ф3+Ф5, issue #356)

```bash
# #512: для установки с author_mode: false исход известен заранее — раннер
# это личный инструмент мейнтейнера (issue #306/#356), в шаблон не поставляется.
# Ветвление по params.yaml убирает файловую пере-проверку из горячего пути
# каждого закрытия; file-probe остаётся только когда флаг не читается.
AUTHOR_MODE=$(grep -E '^author_mode:' "${IWE_WORKSPACE:-$HOME/IWE}/params.yaml" 2>/dev/null | awk '{print $2}')
if [ "$AUTHOR_MODE" = "false" ]; then
  echo "Quick Close: author_mode=false — раннер не поставляется, шаги протокола вручную (штатный режим шаблона)"
else
RUNNER="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/process-runner.py"
GRAPH="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/processes/quick-close.yaml"
if [ -f "$RUNNER" ] && [ -f "$GRAPH" ]; then
  cd "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}" && \
    python3 scripts/process-runner.py start quick-close --slug <slug сессии> \
      --input '{"agent":"<agent>","wp":"<WP-N сессии или null, если сессия без своего РП>","slug":"<slug>","session_file":"<путь или null>","repos":["<repo1>", ...]}'
else
  echo "Quick Close: раннер не поставляется этой инсталляцией; выполнить шаги протокола вручную"
fi
fi
```

Если оба файла доступны, раннер обязателен: он ведёт по шагам ниже и останавливается на каждом `pilot`/`ai`/`requires_input`; отвечать `process-runner.py next <run_id> --input '{...}'`, используя текст под каждым шагом как содержание ответа. Если хотя бы одного файла нет, пройти те же шаги вручную, а проверки карточки раннера явно пометить `неприменимо: раннер не установлен` — это штатный режим шаблона, а не ошибка закрытия.

**Три пункта чеклиста раннер пока не покрывает**, даже когда он установлен, — выполнять вручную: Decision log, Docs Gate (условный), conversational-report.

---

## ЧАСТЬ А. Быстрое закрытие (с пилотом, ~1-2 мин)

> **DP.D.288.** Единственная цель этой части — убедиться, что работа не потеряна (закоммичена и запушена), и собрать рефлексию пилота. Никакой механики здесь не считается и не пишется — она вся в Части Б, без пилота.

### 1. Pre-commit checks → Commit + Push (шаги `precommit-checks` → `commit-push` → `commit-push-check`) [[gate:AR.005]]

**1a. Pre-commit checks (БЛОКИРУЮЩЕЕ).** `bash .claude/scripts/load-extensions.sh protocol-close checks` — exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить. Exit 1 → пропустить. **При ❌ commit запрещён** — исправить, повторить checks.

**1b. Commit + Push (БЛОКИРУЮЩЕЕ, шаг `commit-push`, вход `{"commits":[{"repo","paths","message"}, ...]}`).** `git status --short` по ВСЕМ репо, которых касалась сессия. Незафиксированные изменения → `git add <specific paths>` → commit → push. При доступном раннере использовать его хендлер и не обходить `blocked-push-failed`; в ручном режиме провал push так же блокирует переход к следующему шагу.

### 2. Короткий свод + рефлексия (шаг `reflection-gate` → `session-reflection` при `duration_min > 15`, WP-484 31.07 — перенесено сюда с конца цепочки) [[gate]]

Показать пилоту 2-3 строки: **цифры** (сколько коммитов, файлов, репозиториев затронуто), не список сделанного текстом — та же логика, что у Дня, DP.D.288. Найдено живьём 31.07 (WP-484): агент дважды подряд подменял цифры прозой, хотя данные (репозитории, коммиты этой сессии) уже были под рукой — сам факт, что инструкция здесь называлась «свод», не гарантировал числа без явного слова «цифры». Если сессия длиннее 15 минут — задать вопрос: «Что сегодня в этой сессии сработало / не сработало, что стоит запомнить?». В режиме раннера он останавливается на `session-reflection`, а ответ записывает `session-reflection-append`; в ручном режиме агент записывает ответ в ledger сам. Сессия ≤15 мин → вопрос пропустить.

### 3. «Ты свободен» [[gate]]

Сказать пилоту: **«Ты свободен, дальше довожу закрытие сам»** — и продолжить Часть Б (WP-context, KE, MEMORY.md, R23) без дальнейшего участия пилота. При доступном раннере вызывать `process-runner.py next` по каждому оставшемуся шагу; без него выполнить тот же порядок вручную.

---

## ЧАСТЬ Б. Полное закрытие (агент один, без пилота)

> **DP.D.288.** Пилот уже свободен. Показывать пилоту процесс не нужно — только итоговый короткий отчёт в конце (см. «Отчёт Quick Close» ниже). Детали (SHA, полный чеклист) — по запросу, не по умолчанию.

**4. Session Index (шаг `session-index`/`session-index-write`, раннер маршрутизирует по наличию `session_file` сам — WP-7, 07.07).** Если сессия зафиксирована файлом `sessions/YYYY-MM-DD-<тема>.md` (не folder-структура peer-conversation, у той регистрацию уже делает `peer-session-finalize.sh`) — добавить строку в `sessions/00-index.md`: `Агенты` = только исполнявший агент, `Ходы`/`Эскал` = `—`, `Отчёт` = ссылка на файл сессии. [[narrative]]

**5. WP Context File (БЛОКИРУЮЩЕЕ, факт а не шаблон, шаг `wp-context-update` — ai-контракт: вход `[git_diff, session_summary]`, выход `[status, what_tried, what_learned, what_next]`)** — обновить секцию «Осталось» (structured формат): [[gate]]
   - in_progress → structured handoff
   - **done → 5a. Гейт согласования закрытия (WP-5, решение пилота 2026-07-18, вариант Б).** Перед `status: done` проверить: WP-context содержит содержательный факт закрытия (конкретный результат/критерий приёмки, не шаблонная фраза)? Пусто/шаблонно → закрытие не идёт молча — записать `decision_pending: true` в frontmatter и оставить `in_progress`, вопрос пилоту задать при следующем открытии РП (пилот уже свободен, спрашивать в Части Б нечего — тот самый повод, из-за которого раньше этот гейт ошибочно ждал ответа синхронно). Содержательный факт уже есть → переходить к 5b без паузы. [[gate]]
   - **done → 5b. Пометить `status: done` → и немедленно архивировать (шаг `wp-archive-run`, вход `{"wp","repo"}`):**
     ```bash
     git mv inbox/WP-N archive/wp-contexts/WP-N   # папка
     git mv inbox/WP-N-slug.md archive/wp-contexts/WP-N-slug.md  # файл
     # patch frontmatter: status: archived, archived_at: YYYY-MM-DD
     # нет results_in → добавить results_not_captured: true
     ```
     *(Реализует DP.SC.033 инвариант: done-РП не остаётся в inbox дольше одного Day Close)*
   - Незавершённое → context file. Идея → `MAPSTRATEGIC.md`. Зерно → `drafts/draft-list.md`
   - **Обнаружено «уже сделано» во время сессии** → пометить done в WP-context ПРЯМО СЕЙЧАС. Запрещено писать «Осталось» шаблонной фразой без связи с тем, что реально проверено — R23 (ниже) это отбраковывает.
   - Source: peer-сессия [2026-07-09-17-close-actualization-gap](../DS-strategy/sessions/2026-07/2026-07-09-17-close-actualization-gap/report.md) — разрыв не в том, что Close «забывает» актуализировать, а в том, что требование факт-чека не было явным/проверяемым.

**6. KE (шаг `ke-routing` — ai-контракт: вход `[what_learned]`, выход `[routed_to]`)** — прочитать поле «Что узнали» в «Осталось». Маршрутизировать: [[gate]]
   - правило (1-3 строки) → `CLAUDE.md` или `distinctions.md`
   - доменное знание → Pack (конкретный файл)
   - урок → `memory/lessons_*.md` + строка в MEMORY.md
   - нет нового знания → пропустить молча
   Анонс при маршрутизации в финальном отчёте: *«Capture: [что] → [куда]»* — не отдельным сообщением в процессе (пилота уже нет на связи).

**7. Session-Close Feeder (шаг `session-close-feeder`/`session-close-feeder-run`, раннер маршрутизирует по `duration_min`; WP-247 Ф-MULTI-SOURCE.1, авто >30мин):** [[narrative]]
   Автозахват кандидатов знания из транскрипта + git diff в `captures.md`. Таймаут хендлера — 120с (bug-2026-07-31-ke-routing-step-hangs-quick-close), при превышении деградирует в `{ran: false}`, не валит закрытие.

**8. MEMORY.md (шаг `memory-update` — ai-контракт: вход `[wp_status]`, выход `[memory_line]`)** — обновить статус РП (одна строка: `in_progress` / `done`) [[gate]]

**9. Верификация (шаг `verify-r23`)** — см. раздел «Верификация Quick Close» ниже, теперь идёт полностью в Части Б, без пилота.

### Формат «Осталось»

```markdown
## Осталось

**Что пробовали:** [краткий итог сессии — 1-2 предложения]
**Что узнали:** [решения, инсайты, изменения контекста]
  → memory: [обновить: <что именно> / не нужно]
**Что дальше:**
- [ ] [конкретный следующий шаг]
- [ ] [следующий за ним]
**Следующий шаг:** [первый unchecked из списка выше]
**Контекст для следующей сессии:** [файлы, решения, блокеры]
```

> **Правило `→ memory:`** (обязательное поле): агент явно отвечает на вопрос «нужно ли обновить MEMORY.md или memory/*.md?». Триггеры обновления: блокер снят, внешний факт изменился (чужой деплой, встреча прошла, Паша что-то починил), статус РП сменился. Если обновление нужно — сделать СЕЙЧАС, не откладывать на Day Close.

### Отчёт Quick Close

> Значения — не шаблонный текст, а данные уже пройденных шагов. При доступном раннере их отдаёт `process-runner.py status <run_id>`; в ручном режиме агент берёт те же факты из журнала сессии и Git.

```
**РП:** #N — [название] (из wp-context-update.wp)
**Статус:** done / in_progress / in_progress_background (из wp-context-update.status)
**Длительность:** N мин, M ходов (из gather-session-facts.duration_min, turns)
**Git:** K коммитов в J репо, запушено ✅ (из commit-push.commits, посчитать repo/count)
**Рефлексия:** [ответ на вопрос §18, если задавался] / — (порог не пройден)
**EXTENSION POINT (protocol-close after):** `bash .claude/scripts/load-extensions.sh protocol-close after` — exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить. Exit 1 → пропустить. Поддерживает `extensions/protocol-close.after.md` И `extensions/protocol-close.after.<suffix>.md`.
**Handoff:** → WP context «Осталось» обновлён / done
**Фон:** [если status=in_progress_background] «можно закрывать сессию, доработаю и пришлю итог в Telegram» (канал есть) / «доработаю при следующем открытии, сейчас можно продолжать или закрыть — но фоново ничего не идёт» (канала нет)
```

### Верификация Quick Close (Haiku R23) · [[gate:AR.007]]

> Условный шаг: если `params.yaml → verify_quick_close: false` → пропустить.
> Исключения: сессия ≤15 мин, сессия-вопрос без изменений файлов.
> **Trace-satisfaction (WP-481 Ф5.1):** перед запуском R23 — `bash .claude/hooks/rule-engine.sh check-trace-satisfaction --section "Quick Close"` (без `--section` гейты Week Close и Exit Protocol из этого же файла попадают в проверку тоже — блок гарантирован, они не выполняются за 3-минутную сессию). Набор gate — строки с `[[gate…]]` внутри секции, ключи через `list-gates --section "Quick Close"`; исполненные отмечать `mark-gate <key>` по ходу Close. Verdict block → вернуться на незакрытый gate, потом R23. JSON вердикта приложить к вводу R23.

Запустить sub-agent Haiku в роли R23 (context isolation). Передать: чеклист, WP context «Осталось», `git diff --name-only`, краткое резюме сессии (что делали/что нашли).

**Проверка факт-соответствия (не только присутствия секции):**
1. «Осталось» не шаблонная — содержит конкретику этой сессии (конкретные файлы/решения из `git diff`), не общую фразу, годную для любой сессии.
2. Если в ходе сессии агент упоминал «уже сделано» / «оказалось done» — соответствующий пункт в WP-context помечен done, не оставлен pending.
3. Расхождение (пункт помечен pending, хотя в сессии есть явное свидетельство done) → ❌, вернуть на исправление до отчёта пользователю.
4. **Дисциплина раннера (WP-482 Ф3+Ф5).** Сначала проверить наличие `scripts/process-runner.py` и `scripts/processes/quick-close.yaml` в репозитории управления. Оба доступны → карточка `inbox/agent/tasks/RUN-quick-close-<slug>*.md` обязательна; проверить `process_id == "quick-close"`, терминальный `status` ∈ {`completed`, `failed`} и зафиксировать `runner_terminated_cleanly`. Хотя бы одного файла нет → записать `runner_check: not_applicable (runner not installed)`; отсутствие карточки не является ❌. Исключения для короткой сессии и сессии-вопроса сохраняются.

### Чеклист Quick Close

- [ ] Всё закоммичено и запушено
- [ ] WP Context: «Осталось» записано (или done помечен) **и отражает факт, сверенный R23 с `git diff`** — не шаблон
- [ ] **Гейт закрытия РП (2a):** если `status: done` — WP-context содержит содержательный факт закрытия (не шаблонная фраза в «Осталось») ИЛИ пилот явно спрошен и ответил до архивации
- [ ] KE: «Что узнали» маршрутизировано (или «нет нового знания»)
- [ ] MEMORY.md: статус РП обновлён
- [ ] Decision log: прочитать записи сессии в `${IWE_GOVERNANCE_REPO:-DS-strategy}/decisions/decision-log-YYYY-MM.md`, скорректировать если неточно
- [ ] **Docs Gate (условный):** РП затрагивал UX или поведение онбординга (skills, MCP-сервисы, бот `/start`, тиры доступа T0-T4, имена ролей)? → проверить и обновить вводные документы в `FMT-exocortex-template/docs/` (QUICK-START, SETUP-GUIDE, onboarding/, LEARNING-PATH, IWE-HELP) + `/verify` обновлённый файл. Владелец: пользователь. Если не затрагивал → пропустить молча.
- [ ] **Маршрутизационная сверка (условный, WP-476 Ф6):** сессия создавала/размещала новый артефакт с личными/доменными данными? → взять декларацию «Типы информации → целевые дома» из Ритуала Открытия этой сессии (если была) и сверить с `git diff --name-only`: (а) артефакт лежит именно в заявленном доме своего типа 2.x, не в транзитной мета-папке (`inbox/` для не-РП-контента, корень репо); (б) файл не смешивает разные типы информации (пример дыры: `memory/*.md` без единого `type:` frontmatter — см. `docs/data-pipelines-registry.yaml` PIPE-12 sub_type_routing). Декларации не было, а артефакт с данными появился — расхождение само по себе (Открытие пропустило поле). Расхождение любого рода → не чинить молча, Drift Reporting. Не создавала новый артефакт с данными → пропустить молча.
- [ ] **Conversational-сессии:** report.md создан ИЛИ status: interrupted (DP.SC.154 Q8)
- [ ] **Раннер (условный, WP-482 Ф3+Ф5):** если скрипт и граф доступны — карточка `RUN-quick-close-<slug>*` существует в терминальном статусе и `runner_terminated_cleanly` зафиксирован; иначе записано `runner_check: not_applicable (runner not installed)`.


## Week Close (Неделя)

> **Роль:** R1 Стратег. **Бюджет:** ~20-30 мин. **Триггер:** «закрываю неделю» / `/week-close`.
> Выполняется через `.claude/skills/week-close/SKILL.md` + платформенные шаги.

### Шаги Week Close

> **Trace-satisfaction (WP-481 Ф5.1):** `bash .claude/hooks/rule-engine.sh check-trace-satisfaction --protocol memory/protocol-close.md --section "Week Close"` (без `--section` в проверку попадают ещё и гейты Quick Close). Вызывается из `.claude/skills/week-close/SKILL.md` шаг 12, перед R23.

1. **Бэкап + грязные репо** — `backup-icloud.sh` + `check-dirty-repos.sh` (платформа) [[gate]]
2. **Memory Validate** — `memory-bleed.sh` (HOT-лимит, orphans, superseded_by) [[gate]]
3. **ТО памяти (T, SC.024.3)** — проверка здоровья статической нагрузки: [[narrative]]
   - `wc -l {{WORKSPACE_DIR}}/.claude/rules/distinctions.md` → **> 80 строк = drift-флаг** (по правилу DP.KR.001 §6: 1-3 строки на различение). Предложить аудит в WP-7.
   - `wc -l` по MEMORY.md текущего проекта в `~/.claude/projects/<слаг-проекта>/memory/` (слаг = путь рабочей директории, `/` → `-`) → **> 200 строк = флаг** (превышен лимит).
   - Feedback/lessons файлы в `memory/` с `mtime > 14 дней` без обращения → предложить понизить `horizon: warm`.
   - Флаги — информативно. Пользователь решает действие.
4. **iwe-drift.sh** — полный drift-отчёт в Week Report (S) [[narrative]]
5. **STAGING.md** — есть `validated`? → предложить промоцию (S+T) [[narrative]]
6. **iwe-rules-review** — какие правила обходились? (S) [[narrative]]
7. **R-вопросник** (3 вопроса, `memory/r-questionnaire.md`, шаг 3 Части А `week-close/SKILL.md`, WP-484 30.07 — переставлен к началу) → ответы в Week Report [[gate]]
8. **Архивация done-WP** → `archive/wp-contexts/` (T) [[gate]]
9. **Обновить WeekPlan** — пометить итоги, создать carry-over секцию [[gate]]
10. **Ретро недели свободным текстом** (WP-484, 30.07) — вопрос-рефлексия задан пилоту, ответ записан в ledger через `pilot_answer/preclose_retro` (шаг 1 Части А `week-close/SKILL.md`, переставлен к началу 30.07 вечер) [[gate]]

### Симптом пропуска Week Close

- STAGING.md заморожен ≥2 недель с `validated`
- distinctions.md > 80 строк без флага в Week Report
- Week Report без R-ответов
- MEMORY.md > 200 строк уже 2+ недели подряд

## Month Close (Месяц)

> **Роль:** R1 Стратег (выполнение), R23 Верификатор (Haiku, чеклист). **Бюджет:** 30-45 мин. **Триггер:** последние дни закрываемого месяца, либо первый Пн следующего месяца (если не сделано раньше), перед Strategy Session первой недели.
> Выполняется через `.claude/skills/month-close/SKILL.md`.

### Шаги Month Close

> **Trace-satisfaction (WP-484 Ф5a):** `bash .claude/hooks/rule-engine.sh check-trace-satisfaction --protocol memory/protocol-close.md --section "Month Close"` (без `--section` в проверку попадают гейты остальных масштабов тоже). Вызывается из `.claude/skills/month-close/SKILL.md` шаг 12, перед R23. До этой фазы (19.07) Month Close вообще не имел gate-трассировки — чек-лист внизу SKILL.md был единственной проверкой, ничем не подкреплённой автоматически.

1. **Ревизия проектов P1-P6** — для каждого активного проекта: что двигало, застыл ли, баланс часов (шаг 4 `month-close/SKILL.md`) [[gate]]
2. **R-вопросник M1-M6** — ответы записаны в `MonthClose YYYY-MM.md` (шаг 5 `month-close/SKILL.md`) [[gate]]
3. **Decommission-триаж применён** — таблица переходов active/dormant/archived (шаг 7 `month-close/SKILL.md`) [[gate]]
4. **Decision log review** — минимум 1 инсайт по решениям месяца (шаг 8 `month-close/SKILL.md`) [[gate]]
5. **Strategy.md § Результаты месяца обновлён** — R{N} закрыты/перенесены/заведены новые (шаг 9 `month-close/SKILL.md`) [[gate]]
6. **Ретро месяца свободным текстом** (WP-484, 30.07) — вопрос-рефлексия задан пилоту, ответ записан в ledger через `pilot_answer/preclose_retro` (шаг 0.5 `month-close/SKILL.md`, переставлен к началу 30.07 вечер) [[gate]]

### Симптом пропуска Month Close

- `MonthClose YYYY-MM.md` создан, но R-вопросник M1-M6 пуст
- Decision log review без инсайта 2+ месяца подряд
- Strategy.md § Результаты месяца не тронут, хотя Month Close отмечен закрытым

## Мультипликатор IWE (WP-299 Ф5, шаг 6 Day Close)

> **Полная спецификация → `.claude/skills/day-close/SKILL.md` § 6.**

- **WakaTime-источник:** CLI `~/.wakatime/wakatime-cli --today` → если недоступен: Neon `domain_event WHERE event_type='coding_time'` за дату (fallback).
- **Мультипликатор** = сумма бюджетов закрытых РП за день / WakaTime (сек). Формат: `N.Nx`.
- **Эмиссия:** после вычисления — `day_close` событие в domain_event, `external_id = "day-close-YYYY-MM-DD"` (ON CONFLICT DO NOTHING — идемпотентно). Payload: `{wakatime_h, multiplier, date, session_id, source}`.
- **Pending-мультипликатор (если Day Close не успел):** Day Open шаг 1 «Вчера» — при отсутствии записи `day_close` за вчера пересчитать из Neon WakaTime (WakaTime API `summaries?start={вчера}&end={вчера}`).

## Deferred (отложены до Day Close)

> Quick Close намеренно не включает: DayPlan, WP-REGISTRY (масштаб дня, не сессии).
> **Уточнение (WP-484, 31.07):** Verification Gate и отчёт — до DP.D.288 действительно считались отложенными, сейчас это часть Часть Б (п.9 и «Отчёт Quick Close» ниже) — Quick Close их включает, просто без пилота.
> KE включён (Часть Б, п.6) — знание теряется при откладывании на Day Close.
> Причина (ADR-207): атомарные шаги выполняются всегда > длинный список, из которого половина пропускается.


## Exit Protocol (при завершении любой роли)

| # | Шаг | Что делать |
|---|-----|-----------|
| 1 | **Артефакт** [[gate]] | Зафиксировать результат (коммит, файл, запись) |
| 2 | **Статус** [[gate]] | Обновить трекер (MEMORY.md, WP context) |
| 3 | **Уведомление** [[gate]] | Сообщить следующему (пользователь, агент, Стратег) |
