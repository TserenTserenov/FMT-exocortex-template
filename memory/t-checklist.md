---
type: operational-checklist
wp: 217
promoted: 2026-04-25
valid_from: 2026-04-10
---
# T-чеклист (single source для skill /close)

> Линейный, не требующий суждения. Каждый пункт: owner, trigger, symptom-if-skipped.
> **Класс T (True maintenance):** идемпотентно, календарно, автопилот.
> Различение T ≠ S ≠ R: см. `.claude/rules/distinctions.md`.

## Session Close (Quick Close ≤15 мин, или по триггеру «закрывай»)

| # | Действие | Owner | Trigger | Symptom-if-skipped |
|---|----------|-------|---------|--------------------|
| T1 | Commit всех изменений (git add -p → commit) | агент | сессия с изменениями | незакоммиченные файлы, потеря работы |
| T2 | Push (по триггеру «заливай»/«запуши»/«закрывай») | агент | явный триггер | recovery не гарантирован, коллаборация ломается |
| T3 | WP Context «Осталось» обновлён (handoff для следующей сессии) | агент | любая сессия по РП | следующая сессия стартует с потерей контекста |
| T4 | MEMORY.md статус РП — сжатая запись «что сделано / что дальше» | агент | любая сессия | РП не виден в следующем Day Open |
| T5 | Открытая РП-сессия закрыта (open-sessions.log) | агент | если была запись | double-booking, «сессия не завершена» в следующем Day Open |

**Исключения:** сессии ≤15 мин БЕЗ изменений файлов → T1-T5 пропускаются (только устное summary).

**Верификация:** Haiku R23 проверяет формальное соответствие (есть ли commit, обновлён ли MEMORY.md, заполнен ли handoff).

## Day Close

| # | Действие | Owner | Trigger | Symptom-if-skipped |
|---|----------|-------|---------|--------------------|
| T6 | Все T1-T5 выполнены для текущей сессии | агент | конец дня | см. выше |
| T7 | Архивация done WP contexts → archive/wp-contexts/ | агент | день | inbox/ забит, путаница активных/закрытых |
| T8 | Backup memory/ + CLAUDE.md → `<strategy-repo>/exocortex/` (governance-репо пользователя) | агент | день | экзокортекс отстаёт, recovery ломается |
| T9 | Архивация старых DayPlan'ов → archive/day-plans/ | агент | день (auto-chore) | current/ забит устаревшими DayPlan |
| T10 | Downstream sync (update.sh — reindex + pack-project + template) | агент | день при изменениях Pack | knowledge-mcp отдаёт устаревший Pack, template-sync ломается |
| T11 | Linear sync (статусы linear ↔ git) | агент | день | Linear отражает не то, что в git |
| T12 | Governance batch: WeekPlan/DayPlan/WP-REGISTRY/open-sessions.log обновлены | агент | день | план-факт расходится |
| T13 | Drift top-3 critical в Day Report (`iwe-drift.sh --top 3 --critical`) | агент (S-вставка) | день | drift копится невидимо |
| T14 | Day Open файл завтра готов (pre-populate календарь, заметки) | агент | конец дня | Day Open утром стартует с нуля |

**Верификация:** Haiku R23 проверяет чеклист + что все 14 пунктов отмечены.

## Week Close (воскресенье)

| # | Действие | Owner | Trigger | Symptom-if-skipped |
|---|----------|-------|---------|--------------------|
| T15 | Все T1-T14 выполнены за неделю | агент | воскресенье | накапливается долг |
| T16 | Свежая таблица РП — done вычищены, in_progress перенесены на следующую неделю | агент | Week Close | MEMORY.md раздувается |
| T17 | Week Report собран: коммиты/РП/метрики | агент | Week Close | нет обратной связи «что получилось» |
| T18 | Drift полный (`iwe-drift.sh`) → раздел в Week Report | агент (S) | Week Close | S-действия копятся |
| T19 | Staging check: STAGING.md — есть `validated` → предложить промоцию | агент (S+T) | Week Close | staging замерзает, правила не попадают в FMT |
| T20 | `/iwe-rules-review` запущен — какие правила обходились | агент | Week Close | мёртвые правила живут вечно |
| T21 | R-вопросник прогнан (см. `r-questionnaire.md`) → ответы в Week Report | человек + агент модератор | Week Close | формальное закрытие недели |
| T22 | Next-week план создан | агент + человек | Week Close | понедельник стартует с нуля |
| T22a | Проверить логи запланированных задач (launchd/cron) на `FAIL`/`ERROR` за неделю — путь зависит от настройки пользователя, см. `extensions/week-close.checks.md` | агент (T+S) | Week Close | скрипт валится неделями, симптом живёт незамеченным |

**Верификация:** Haiku R23 проверяет чеклист. Для T21 проверяется только наличие ответов, не их качество.

## Month Close (первый Пн месяца)

> **Триггер:** скилл `/month-close` (см. `.claude/skills/month-close/SKILL.md`, протокол `memory/protocol-month-close.md`). T23-T25 выполняются как шаги 6-7 алгоритма Month Close.

| # | Действие | Owner | Trigger | Symptom-if-skipped |
|---|----------|-------|---------|--------------------|
| T23 | Lesson Hygiene месячный масштаб: сжатие MEMORY.md, ротация уроков, выявление устаревших записей (#5 возрождено, поглощает бывшие #13 ротация и #17 месячный аудит) | агент + человек | Month Close | MEMORY.md раздут, уроки теряются |
| T24 | Аудит протоколов на обходимые шаги (#22 возрождено): пройти `memory/protocol-*.md` и скиллы, выявить шаги, которые регулярно обходятся или мертвеют | человек | Month Close | мёртвые протокольные шаги копятся (WP-217 = следствие этого) |
| T25 | Decommission-триаж: получить кандидатов из drift-скрипта (`activity_checks:`) + ручной вопрос из R-вопросника, принять решения active → dormant → archived | человек + агент | Month Close | dormant/archived секции не обновляются |

**Верификация:** Haiku R23 — только формально (есть ли записи).
