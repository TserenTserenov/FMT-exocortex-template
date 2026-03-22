# Протокол Close (ОРЗ-фрактал)

> **Три масштаба:** Сессия (Quick Close), День (Day Close), Неделя (Week Close).
> **Источник:** CLAUDE.md § 2 (slim) → этот файл.
> **Принцип:** «не потерять» (сессия) отделено от «навести порядок» (день).

---

## § Масштаб: Сессия (Quick Close)

> **Триггер:** «закрываю сессию», «всё», «закрывай», или РП завершён.
> **Роль:** R6 Кодировщик
> **«Закрывай» = push сразу без вопросов** (пользователь дал согласие словом).
> **Бюджет:** ~3 мин. Цель — зафиксировать результат и не потерять знание.

### Различение: Quick Close vs Day Close vs Week Close

| | Quick Close (сессия) | Day Close (день) | Week Close (неделя) |
|---|------|--------|--------|
| **Цель** | Не потерять | Навести порядок | Ротация и стратегия |
| **Что пишем** | Итоги + «Осталось» | Итоги дня + «На завтра» | Метрики + carry-over |
| **Governance** | Только MEMORY.md | Batch: WeekPlan, DayPlan, WP-REGISTRY, Linear, backup | Ротация уроков, свежая таблица MEMORY |
| **Верификация** | Haiku R23 (context isolation) | Haiku R23 (полный чеклист) | В составе Week Review |

## Exit Protocol (ОБЯЗАТЕЛЬНО при завершении каждой роли)

> При завершении единицы работы в любой роли — ОБЯЗАН выполнить 3 шага.
> Тест: если роль не выполнит шаги — узнает ли кто-то, что работа выполнена? Нет → нарушен.

| # | Шаг | Что делать |
|---|-----|-----------|
| 1 | **Артефакт** | Зафиксировать результат (коммит, файл, запись) |
| 2 | **Статус** | Обновить трекер (MEMORY.md, WP context) |
| 3 | **Уведомление** | Сообщить следующему (пользователь, агент, Стратег) |

---

### Алгоритм Quick Close (7 шагов)

> **Исполнение:** всегда через `/run-protocol close` (пошаговый чеклист, предотвращает пропуск шагов).
> **Принцип порядка:** «горячий контекст» — механические статусы сразу после commit (пока файлы свежие), содержательные шаги (KE, верификация) — в середине.

0. **Pull** → `cd DS-my-strategy && git pull --rebase`
1. **Commit + Push** — все изменения зафиксированы
<!-- AUTHOR-ONLY: CHANGELOG FMT — только для разработчика платформы -->
1b. **CHANGELOG FMT** (если были коммиты в FMT-exocortex-template): обновить `FMT-exocortex-template/CHANGELOG.md` **сейчас**, пока контекст изменений свежий. На Day Close контекст потерян.
<!-- /AUTHOR-ONLY -->
2. **Статусы** (механические, пока файлы «горячие»):
   - **MEMORY.md** — обновить статус РП (одна строка: `in_progress` / `done`)
   - **DayPlan** — обновить строку РП в `DS-my-strategy/current/DayPlan YYYY-MM-DD.md`. **Правило зачёркивания:** зачеркнуть всё, что отработано на сегодня — даже если РП остаётся in_progress (в WeekPlan он не зачёркивается, пока не done). DayPlan отражает «что сделано сегодня», WeekPlan — «что закрыто на неделе». Day Close = safety net, но DayPlan должен быть актуален между сессиями.
   - **WP-REGISTRY** (при done) — `DS-my-strategy/docs/WP-REGISTRY.md`: зачеркнуть строку, статус → `~~✅~~ | ~~done~~`. Пропуск = рассинхрон MEMORY vs REGISTRY.
3. **KE (Knowledge Extraction)** → прочитай и выполни `DS-IT-systems/DS-ai-systems/extractor/prompts/session-close.md`:
   - Собрать отложенные captures + проверить пропущенные
   - Классифицировать → маршрутизировать → формализовать → валидировать
   - Показать Extraction Report → получить одобрение
   - Применить одобренные (accept → Pack/CLAUDE.md/memory)
   - Немедленные captures (CLAUDE.md, repo CLAUDE.md) — применить сразу
4. **Verification Gate** (VR.M.003 — приёмка WP):
   - Прочитать WP context file → извлечь критерии готовности
   - Проверить по verification_class:
     - **trivial/closed-loop:** автоматический pass (не задерживать Close)
     - **open-loop:** содержательная проверка → результат в секцию «Что проверить» отчёта
     - **problem-framing:** полная проверка + пометка «требует приёмки человеком»
   - Если РП done → verdict обязателен. Если in_progress → skip
   - Verdict НЕ блокирует Close — записывается в отчёт для решения человека
4b. **Code Verification** (автотриггер — S56):
   - Проверить `git diff --name-only` по затронутым репо
   - Если среди изменённых файлов есть **код** (`.py`, `.ts`, `.sh`, `.sql`, `.yaml`, `.json`) → запустить `/verify code` (sub-agent Верификатор с context isolation)
   - Если только `.md` файлы → пропустить (верификация кода не нужна)
   - Если в сессии был **АрхГейт** и после него менялся код → запустить `/verify archgate` вместо `/verify code`
   - Verdict → в секцию «Что проверить» отчёта
5. **WP Context File:**
   - in_progress → обновить секцию «Осталось» в `DS-my-strategy/inbox/WP-{N}-{slug}.md`
   - done → пометить (архивация — на Day Close)
   - Незавершённое → context file. Идея → `<repo>/MAPSTRATEGIC.md`. Зерно → `DS-my-strategy/drafts/draft-list.md`
6. **Отчёт** (5-7 строк) + закоммитить DS-my-strategy

### Чеклист Quick Close

- [ ] Всё закоммичено и запушено
<!-- AUTHOR-ONLY: CHANGELOG -->
- [ ] **CHANGELOG FMT:** коммиты в FMT → CHANGELOG обновлён (пока контекст свежий)
<!-- /AUTHOR-ONLY -->
- [ ] **Статусы:** MEMORY.md + DayPlan + WP-REGISTRY обновлены (сразу после commit)
- [ ] KE выполнен, captures применены
- [ ] Verification Gate пройден (WP + code)
- [ ] WP Context: «Осталось» записано (или done помечен)
- [ ] Repo CLAUDE.md проверен (если feat-коммиты)
- [ ] Отчёт сформирован

### 7. Верификация Quick Close (Haiku R23)

> Запустить sub-agent **Haiku** в роли **R23 Верификатор** (context isolation — VR.SOTA.002).
> Передать: (1) чеклист Quick Close, (2) отчёт, (3) список изменённых файлов (`git diff --name-only` по затронутым репо).
> По ❌ — исправить до показа пользователю.

**Исключения** (верификация не запускается):
- Сессия ≤15 мин
- Сессия-вопрос без изменений файлов

### Шаблон отчёта Quick Close

```
**РП:** #N — [название]
**Статус:** done / in_progress
**Класс верификации:** closed-loop / open-loop / problem-framing

**Исполнитель:** A1 Claude Code (модель: Opus 4.6 / Sonnet 4.6 / Haiku 4.5)
**Роли в сессии:**
- R6 Кодировщик: [что сделал]
- R2 Экстрактор: [N кандидатов → куда / не активирован]

**Сделано:** [итог]
**Captures:** [N → Pack, N → DS docs/, N → IWE root]. «0» только если ничего не записано.
**Что проверить:** [что требует внимания человека]
**Git:** закоммичено + запушено ✅
<!-- AUTHOR-ONLY: Деплой и ветки конкретных систем автора -->
**Деплой бота:** залито на `pilot` ✅ / на `new-architecture` не заливалось
**Ветки бота:** pilot и new-architecture синхронизированы ✅ / расходятся
<!-- /AUTHOR-ONLY -->
**Осталось:** ничего / [что — Agent→Agent handoff для следующей сессии]
```

> Указывать только активированные роли. R2 — указывать всегда (даже «не активирован»).
> Основание: DP.D.033 — роль ≠ исполнитель.

---

## § Масштаб: День (Day Close)

> **Триггер:** «закрываю день» / «итоги дня»
> **Роль:** R1 Стратег
> **Бюджет:** ~10 мин. Включает governance, который не делается на Quick Close.
> **Формат:** Стратег собирает данные → показывает черновик → пользователь одобряет → запись.
> **Скрипт:** `day-close.sh` автоматизирует механические шаги (backup, reindex, linear sync).

### Алгоритм Day Close (12 шагов)

> **Исполнение:** всегда через `/run-protocol day-close` (пошаговый чеклист). Day Close длиннее Quick Close — риск пропуска шагов выше.

#### 1. Сбор данных

```bash
for repo in $(ls ~/IWE/); do
  if [ -d ~/IWE/$repo/.git ]; then
    commits=$(git -C ~/IWE/$repo log --since="today 00:00" --oneline --no-merges 2>/dev/null)
    [ -n "$commits" ] && echo "=== $repo ===" && echo "$commits"
  fi
done
```

Сопоставить коммиты с таблицей «На сегодня» из DayPlan → определить статусы.

#### 2. Governance batch (одним проходом)

**2a.** Обновить `DS-my-strategy/current/Plan W{N}...` (WeekPlan): статусы РП. **Grep по номеру РП** — обновить ВСЕ упоминания.

**2b.** Обновить `DS-my-strategy/current/DayPlan YYYY-MM-DD.md`: статусы **всех строк** (РП + ad-hoc). Done → зачеркнуть.

**2c.** Обновить `DS-my-strategy/docs/WP-REGISTRY.md`: статусы + даты.

**2d.** Обновить `DS-my-strategy/inbox/open-sessions.log`: удалить строки закрытых сессий.

**2e.** Governance-синхронизация: новые репо/сервисы за день? → REPOSITORY-REGISTRY, navigation.md, MAP.002↔PROCESSES.md.

<!-- AUTHOR-ONLY: CHANGELOG FMT -->
**2f.** ~~CHANGELOG FMT~~ — перенесён в Quick Close (шаг 1b). На Day Close только проверить, что не пропущен.
<!-- /AUTHOR-ONLY -->

#### 3. Архивация

- Done WP context files → `mv inbox/WP-{N}-*.md → archive/wp-contexts/`
- **Done-РП → удалить строку из MEMORY.md** (они уже в WP-REGISTRY и WeekPlan)

> **Правило:** MEMORY.md хранит ТОЛЬКО активные РП (in_progress + pending). Done = удалить.

#### 4. Автоматические шаги (скрипт `day-close.sh`)

```bash
# Запуск одной командой:
~/IWE/DS-IT-systems/DS-ai-systems/synchronizer/scripts/day-close.sh
```

Скрипт выполняет:
- **Linear sync:** `linear-sync.sh` (синхронизация статусов)
- **Downstream sync:** `update.sh` (reindex + pack-project + template — заменяет отдельный selective-reindex)
- **Backup:** `memory/ + CLAUDE.md → DS-my-strategy/exocortex/`

#### 5. Мультипликатор IWE (расчёт)

> **Мультипликатор = Бюджет закрыт / WakaTime.** Показывает, насколько агент-экзоскелет усиливает работу.
> Пример: WakaTime 10ч 14мин, бюджет закрыт ~21.4h → мультипликатор 2.09x.

**Алгоритм (день):**

1. **WakaTime** — физическое время за день. Источник: WakaTime API или `wakatime --today`.
2. **Бюджет закрыт** — сумма бюджетных оценок по ВСЕМ РП, над которыми работали сегодня:
   - done → полный бюджет РП (или пропорционально фазам для зонтичных)
   - partial (работали, но не закрыли) → % выполнения × бюджет
   - not started → 0h
   - Мелкие РП (бюджет «—» / merged / поглощён) → 0.25h (15 мин), не 0
   - Источник: таблица «План на сегодня» из DayPlan (колонка «Бюджет»)
3. **Мультипликатор дня** = Бюджет закрыт / WakaTime. Формат: `N.Nx`

**Алгоритм (неделя, при Week Close):**

4. **WakaTime недели** — сумма физического времени за все 7 дней.
5. **Бюджет закрыт за неделю** — сумма бюджетов ВСЕХ РП, над которыми работали за неделю:
   - done → полный бюджет (диапазон → среднее: 3-4h → 3.5h)
   - partial (работали, но не закрыли) → % выполнения × бюджет
   - Зонтичные → пропорционально фазам
   - Мелкие (бюджет «—» / merged / поглощён) → 0.25h (15 мин), не 0
6. **Мультипликатор недели** = Бюджет закрыт за неделю / WakaTime недели. Формат: `N.Nx`
7. **Средний мультипликатор** = мультипликатор недели (единый расчёт, НЕ среднее дневных)

#### 6. Черновик итогов (показать пользователю)

**а) Обзор:** таблица «что сделано» (РП × статус)

**б) Что нового узнал:** captures в Pack, различения, инсайты, новое из курса.

> Это экзоскелет: агент помогает увидеть, пользователь рефлексирует сам.

**в) Похвала:** что получилось, что было непросто но сделано.

**г) Не забыто?** Стратег проверяет:
- Незакоммиченные изменения (`git status` по всем репо)
<!-- AUTHOR-ONLY: Проверки специфичных для автора систем -->
- **Синхронизация веток бота** (pilot vs new-architecture):
  ```bash
  cd ~/IWE/DS-IT-systems/aist_bot_newarchitecture
  git fetch origin
  DIFF_STAT=$(git diff origin/pilot origin/new-architecture -- ':!.DS_Store' --stat)
  if [ -z "$DIFF_STAT" ]; then
    echo "pilot и new-architecture: содержимое идентично ✅"
  else
    echo "pilot и new-architecture: РАСХОДЯТСЯ по содержимому ⚠️"
    echo "$DIFF_STAT"
  fi
  ```
  Сигнализировать ТОЛЬКО если `git diff` показывает разницу в содержимом.
<!-- /AUTHOR-ONLY -->
- Незаписанные мысли? (спросить пользователя)
- Обещания кому-то? (спросить пользователя)

**д) Видео за день:**
- Если `video.enabled: true` → проверить новые видео
- Необработанные → перенести в задел на завтра

**е) Draft-list:** Pack обогащён → предложить черновик?

**ж) Задел на завтра** (Agent→Agent handoff: вечерний Стратег → утренний Стратег):
- С чего начать утром
- Какой контекст подготовить
- Незавершённые РП: что именно осталось

#### 7. Согласование

Пользователь читает черновик → корректирует → одобряет.

#### 8. Запись итогов

Дописать секцию «Итоги дня» в `DayPlan YYYY-MM-DD.md`:

```markdown
---

## Итоги дня

| РП | Что сделано | Статус |
|----|-------------|--------|
| #N | ... | done / partial |

**Коммиты:** N в M репо

### Мультипликатор IWE

| Метрика | Значение |
|---------|----------|
| **WakaTime (физическое время)** | Xч Yмин |
| **Бюджет закрыт (оценки РП)** | ~Nh |
| **Мультипликатор дня** | **N.Nx** |

> Формула: Бюджет закрыт / WakaTime. Показывает усиление от агента-экзоскелета.
> Недельный мультипликатор считается при Week Close: Σ бюджетов done-РП за неделю / WakaTime за неделю.

**Что нового узнал:** ...

**Похвала:** ...

**Не забыто:** всё чисто / [что осталось]

**Завтра начать с:** ...

*Закрыто: YYYY-MM-DD HH:MM*
```

#### 9. Закоммитить DS-my-strategy

#### 10. Верификация по чеклисту (Day Close)

Запустить sub-agent **Haiku** в роли **R23 Верификатор**. Передать: (1) чеклист Day Close, (2) черновик итогов, (3) список обновлённых файлов. По ❌ — исправить до показа пользователю.

**Почему sub-agent:** контекст основного агента загрязнён (VR.SOTA.002 context isolation).

### Чеклист Day Close

- [ ] Все изменения закоммичены и запушены (по всем репо)
- [ ] MEMORY.md: done-РП удалены, активные актуальны
- [ ] WP-REGISTRY.md обновлён
- [ ] WeekPlan обновлён (grep по номерам РП — ВСЕ упоминания)
- [ ] DayPlan обновлён (статусы ВСЕХ строк: РП + ad-hoc)
- [ ] open-sessions.log: строки закрытых сессий удалены
- [ ] Captures за день применены (все Quick Close → KE пройден)
- [ ] **Синхронизация downstream:** коммиты в Pack/DS → `update.sh` выполнен (reindex + pack-project + template)
- [ ] **Linear sync:** статусы соответствуют git
- [ ] **Repo CLAUDE.md:** feat-коммиты → новые правила?
- [ ] **WP context:** done → `mv inbox/ → archive/wp-contexts/`
- [ ] **Draft-list:** Pack обогащён → черновик предложен?
- [ ] **Видео:** обработанные помечены (если video.enabled)
<!-- AUTHOR-ONLY: CHANGELOG -->
- [ ] **CHANGELOG FMT:** проверить, что обновлён в Quick Close (не пропущен)
<!-- /AUTHOR-ONLY -->
- [ ] **Governance:** REPOSITORY-REGISTRY, navigation.md, MAP.002
- [ ] **Backup:** `day-close.sh` выполнен (backup + reindex + linear)
- [ ] **Верификация compliance:** /verify запускался сегодня?
- [ ] **WakaTime + Мультипликатор:** часы, бюджет, остаток недели
- [ ] Итоги дня записаны в DayPlan
- [ ] Новое репо → MAPSTRATEGIC.md + Strategy.md

Все ✅ → «День закрыт.» Иначе — указать, что осталось.

---

## § Масштаб: Неделя (Week Close)

> **Триггер:** автоматический (Пн 00:00) или «закрываю неделю» / «итоги недели».
> **Роль:** R1 Стратег
> **Протокол:** `week-review.md` + дополнительные шаги ниже.

### Дополнительные шаги Week Close (поверх Week Review)

> **Исполнение:** через `/run-protocol week-close`. Week Review (`week-review.md`) + шаги ниже.

#### 1. Ротация уроков в MEMORY.md

Для каждого урока в секции «Уроки»:
- Применялся за последние 2 недели? → оставить
- Нет → вынести в `memory/lessons-archive.md`
- Цель: ≤15 актуальных уроков в MEMORY.md

#### 2. Свежая таблица РП

- Удалить ВСЕ РП прошлой недели из MEMORY.md
- Перенести in_progress и pending в таблицу новой недели W{N+1}
- Источник: новый WeekPlan (создаётся в session-prep)

#### 3. Аудит memory-файлов

- ≤11 файлов? Лишние → объединить или удалить
- Лимиты: справочники ≤100, протоколы ≤150, реестры ≤200 строк
- Устаревшие записи → обновить или удалить

---

## Владельцы протоколов

> Владелец = роль (DP.D.033). Исполнитель всех ролей: A1 Claude Code (указывать модель).

| Протокол | Роль-владелец | Где описан |
|----------|---------------|-----------|
| Open, Work, Close (§ День) | R1 Стратег | protocol-*.md § День |
| Open, Work, Close (§ Сессия) | R6 Кодировщик | protocol-*.md § Сессия |
| Quick Close | R6 Кодировщик | protocol-close.md § Сессия |
| Day Close | R1 Стратег | protocol-close.md § День |
| Week Close | R1 Стратег | protocol-close.md § Неделя + week-review.md |
| Session-Close Extraction | R2 Экстрактор | extractor/prompts/session-close.md |
| On-Demand Extraction | R2 Экстрактор | extractor/prompts/on-demand.md |
| Bulk Extraction | R2 Экстрактор | extractor/prompts/bulk-extraction.md |
| Cross-Repo Sync | R2 Экстрактор | extractor/prompts/cross-repo-sync.md |
| Knowledge Audit | R2 Экстрактор | extractor/prompts/knowledge-audit.md |
| Inbox-Check | R2 Экстрактор | extractor/prompts/inbox-check.md |
| Ontology Sync | R2 Экстрактор | extractor/prompts/ontology-sync.md |
| Session-Prep | R1 Стратег | strategist/prompts/session-prep.md |
| Strategy-Session | R1 Стратег | strategist/prompts/strategy-session.md |
| Day-Plan | R1 Стратег | protocol-open.md § День |
| Note-Review | R1 Стратег | strategist/prompts/note-review.md |
| Week-Review | R1 Стратег | strategist/prompts/week-review.md |
