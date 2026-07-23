# Day Close — Детали (lazy-load)

> Загружать при необходимости деталей по конкретному шагу.
> Основной протокол: `day-close/SKILL.md`

---

## Шаг 0б: Дайджест + фазовая модель исполнения (issue #234)

**Зачем.** Day Close в хвосте длинной сессии делает ~25-40 tool-вызовов, и каждый повторно отправляет весь разговор дня как input (~100K-токенная сессия × 30 вызовов ≈ 3M input-токенов). Дайджест + context isolation субагентов отвязывают стоимость закрытия от размера сессии: ~1 вызов дайджеста + 2 изолированных субагента.

**Карта замен (секция дайджеста → что заменяет в SKILL.md):**

| Дайджест § | Заменяет в SKILL.md |
|------------|---------------------|
| 1 commits today | шаг 1 — цикл `git log` по репо |
| 2 dirty repos | шаг 10b — `check-dirty-repos.sh` |
| 3 open-sessions.log | шаг 2d — чтение лога |
| 4 memory drift hits | шаг 4б — grep |
| 5 index health | шаг 4в — запуск `check-index-health.py` |
| 6 lesson/memory stats | шаг 4 — скан |
| 7 WakaTime | шаг 6 |
| 8 peer sessions today | шаг 6 prerequisite (`sessions/00-index.md`) |
| 9 DayPlans в current/ | шаг 3 — lookup |
| 10 done WP contexts в inbox/ | шаг 3 — lookup |
| 11 WeekReport presence | шаг 2f — precondition |

**Фазы субагентного исполнения.** Родительская сессия выполняет ТОЛЬКО: дайджест → диспетчеризацию → согласование с пилотом → диспетчеризацию → верификацию. Сама она governance-файлы не перечитывает и правок не делает.

- **Фаза B — исполнитель.** ОДИН general-purpose субагент (sonnet). В промпт: (а) дайджест целиком, (б) сегодняшняя дата, (в) инструкция: «Прочитай `.claude/skills/day-close/SKILL.md`, выполни шаги 1-7 через TodoWrite, применяя карту замен ниже. Шаг 0 пропусти — родитель уже выполнил. Форматирование таблиц — `.claude/rules/formatting.md`. Git: стейджить только конкретные файлы, НЕ коммитить. Верни: черновик итогов (шаг 7), список правленных файлов, блокеры». Приложить карту замен.
- **Фаза C — согласование (родитель).** Показать черновик пилоту дословно (шаг 8). Корректировки → одобрение.
- **Фаза D — финализатор.** Второй субагент (sonnet): одобренный черновик + корректировки + список файлов фазы B. Выполняет шаги 9, 10, 10b, затем posconditions одним вызовом: `bash "$IWE_SCRIPTS/day-close-prepare.sh" --verify` (заменяет два inline-grep 9a/9b + повторный dirty-скан; паттерны языко-толерантны). Любой FAIL → дописать недостающее / commit+push → повторить до exit 0. Возвращает вывод `--verify` + SHA коммитов.
- **Фаза E — верификация (родитель).** Шаг 11: R23-верификатор (haiku) диспетчеризует родитель — субагенты не могут порождать субагентов. Передать чеклист, одобренный черновик, оба списка файлов, вывод `--verify`.

**TodoWrite:** родитель ведёт фазы 0б/B/C/D/E как задачи; каждый субагент ведёт свои SKILL-шаги собственным TodoWrite — блокирующее правило пошаговости соблюдено.

**Fallback:** Agent tool недоступен или субагент упал дважды → исполнять шаги inline в родителе (legacy), всё равно на данных дайджеста.

## Шаг 0в: Strategy_day guard (issue #286)

**Проблема, которую закрывает этот шаг.** `/day-open` в стратегический день (по умолчанию понедельник, `day_open.strategy_day` в `day-rhythm-config.yaml`) не создаёт DayPlan — план целиком в WeekPlan (`day-open/SKILL.md` шаг 4). До этого шага `/day-close` про исключение не знал: шаги 1, 2b, 3, 9a безусловно требовали DayPlan, а постусловие 9a («Итоги дня» найдено grep'ом) было структурно недостижимо — файла, куда писать, нет. Протокол не мог завершиться `completed`.

**Проверка (в начале алгоритма, до шага 1):**
```bash
STRATEGY_DAY_NAME=$(python3 -c "
import yaml
d = yaml.safe_load(open('${IWE_GOVERNANCE_REPO:-DS-strategy}/exocortex/day-rhythm-config.yaml'))
print((d.get('day_open') or {}).get('strategy_day', 'monday'))
" 2>/dev/null || echo monday)
TODAY_DOW=$(date +%A | tr '[:upper:]' '[:lower:]')
if [ "$TODAY_DOW" = "$STRATEGY_DAY_NAME" ]; then
  echo "strategy_day: true"
fi
```

**Если strategy_day:**
- Шаги 1, 2b, 3 (архивация DayPlan сегодня — старые DayPlan'ы в `current/` архивировать всё равно), 9a — помечать **неприменимо**, не FAIL (постусловие 9a не проверяется вообще, не входит в решение «Все ✅»).
- Итоги дня — только в WeekReport (шаг 9b), как обычный день: только факты (РП-результаты, коммиты, мультипликатор). Плановые строки в WeekReport НЕ копировать.
- Чеклист Day Close: соответствующие пункты (статусы строк DayPlan, архивация DayPlan, «Итоги дня записаны в DayPlan», Handoff-валидация из DayPlan) — N/A на сегодня, не блокируют «Все ✅».

## Шаг 1: Сбор данных

```bash
for repo in $(ls {{HOME_DIR}}/IWE/); do
  if [ -d {{HOME_DIR}}/IWE/$repo/.git ]; then
    commits=$(git -C {{HOME_DIR}}/IWE/$repo log --since="today 00:00" --oneline --no-merges 2>/dev/null \
      | grep -vE "^(docs|chore|ci|style|perf|test)(\\(|:| )" \
      | grep -vE "memory/|\.claude/rules/|template-sync|backup|reindex" \
      || true)
    [ -n "$commits" ] && echo "=== $repo ===" && echo "$commits"
  fi
done
```

Сопоставить коммиты с таблицей «На сегодня» из DayPlan → определить статусы.

---

## Шаг 2f: WeekReport — правила записи итогов

- Файл: `${IWE_GOVERNANCE_REPO:-DS-strategy}/current/WeekReport W{N} YYYY-MM-DD.md`
- Добавить новый раздел `<details><summary><b>Итоги {День} {Дата}</b></summary>` **перед** предыдущими `Итоги` (обратная хронология: сегодня → старше)
- Содержимое: коммиты по репо, РП-статусы за день, carry-over блокеры
- **strategy_day (Пн без DayPlan):** итоги в WeekReport как обычный день — только факты (РП-результаты, коммиты, мультипликатор). Плановые строки в WeekReport НЕ копировать.
- **Правило ОПТ-5:** WeekPlan = намерения только; WeekReport = факты только.

---

## Шаг 4б: Memory Drift Scan — алгоритм

```bash
grep -nE "→ ждёт|ждёт|dep:|блокер|blocked:|остановлен|ждёт согласования" \
  {{HOME_DIR}}/.claude/projects/*/memory/MEMORY.md 2>/dev/null
```

Для каждого найденного паттерна:
1. Определить номер РП (WP-NNN) из контекста строки
2. Найти WP-context: `ls ${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/WP-{N}-*.md` (если заархивирован → `archive/wp-contexts/`)
3. Прочитать секцию «Что узнали» / «Осталось» / финальный статус
4. Если есть признак закрытия (`DONE`, `РЕШЕНО`, `✅`, `починил`, `закрыт`, `снят`) → обновить MEMORY.md, анонс: *«Memory drift: [факт] устарел → обновлён»*
5. Если WP-context не найден → *«Memory drift: WP-N — context не найден, проверить вручную»*

Анонс при 0 изменениях: *«Drift-scan: проверено N паттернов, устаревших фактов не найдено»*

---

## Шаг 4в: Index Health Check — алгоритм

> Ловит раздутие индекс-файлов (MEMORY.md, WP-REGISTRY.md, MAPSTRATEGIC.md, *-registry.md, *-index.md, *-catalog.md).
> Правило: [feedback_memory_index_discipline.md](../../../memory/feedback_memory_index_discipline.md)

```bash
python3 ${IWE_TEMPLATE:-{{HOME_DIR}}/IWE/FMT-exocortex-template}/.claude/scripts/check-index-health.py
```

Для каждого FAIL/WARN в отчёте:
1. Открыть файл, посмотреть конкретные строки/ячейки из отчёта
2. Диагностика: это дамп контекста (болезнь) или методологическая таблица (жанр)?
   - Дамп → перенести контекст в source-of-truth (inbox/WP-NNN-*.md, WeekPlan, отдельный `*-changelog.md`); в индексе — hook + ссылка
   - Жанр (таблица-матрица, каталог доменных сущностей) → пометить в начале файла: `<!-- index-health: skip-cells -->` или `<!-- index-health: skip -->` с обоснованием
3. Если FAIL в Pack-файле — не чистить автоматически, только пометить skip с обоснованием

Анонс при 0 WARN/FAIL: *«Index-health: N файлов OK, M skip»*.

---

## Шаг 6: Мультипликатор IWE — алгоритм

1. **WakaTime** — физическое время за день:
   - CLI: `~/.wakatime/wakatime-cli --today`
   - Fallback Neon: `SELECT payload->>'human_readable', payload->>'total_seconds' FROM learning.public.domain_event WHERE event_type='coding_time' AND account_id='{DT_USER_ID}' AND external_id='wakatime:{DT_USER_ID}:{YYYY-MM-DD}'`
   - Если Neon тоже пуст → пометить «pending Neon», пересчитать при следующей сессии

2. **Бюджет закрыт — считать ПО ФАКТУ (БЛОКИРУЮЩЕЕ):**
   - **Шаг 2.0 (prerequisite):** открыть `<governance-repo>/sessions/00-index.md`, отфильтровать строки за сегодня (`grep "$(date +%Y-%m-%d)"`), составить полный список peer-сессий с числом ходов. Без этого расчёт занижен ×2.
   - done → полный бюджет (или пропорционально фазам для зонтичных)
   - partial → % выполнения × бюджет; если сверхплановая работа в плановом РП — засчитывать ФАКТ
   - not started → 0h
   - **ad-hoc peer-сессии (без РП-метки в DayPlan):**
     - 2-4 хода → 0.25-0.5h
     - 5-7 ходов → 0.75-1h
     - 8+ ходов → 1-1.5h
   - Мелкие правки без peer-сессии (бюджет «—» / merged) → 0.25h

3. **Мультипликатор дня** = Бюджет закрыт / WakaTime. Формат: `N.Nx`

4. **Sanity check (БЛОКИРУЮЩЕЕ):** мультипликатор <1.5x при ≥10 peer-сессий → пересчитать. Показать пилоту 3 метода (буква SKILL / по факту / компромисс) и спросить какой записывать.
   Урок: `lessons_multiplier_peer_sessions_uncounted.md`

---

## Шаг 7: Черновик итогов — структура

**а) Обзор:** таблица «что сделано» (РП × статус)

**б) Что нового узнал:** captures в Pack, различения, инсайты

**в) Похвала:** что получилось, что было непросто но сделано

**г) Не забыто?**
- Незакоммиченные изменения: `${IWE_SCRIPTS}/check-dirty-repos.sh`
- Часы саморазвития (WP-310 Ф13c): записан ли `/slot` за сегодня? Спросить «Сколько часов?», предложить кнопки 0/0.5/1/2/3/4. Подсказать команду `/slot N` в бот.
- Незаписанные мысли? (спросить пользователя)
- Обещания кому-то? (спросить пользователя)

**д) Видео за день:** если `video.enabled: true` → проверить новые видео

**е) Draft-list:** Pack обогащён → предложить черновик?

**ж) Задел на завтра:**
- С чего начать утром
- Незавершённые РП: конкретный next action по каждому

**з) Утренние приоритеты (`current/priorities.yaml`, восстановлено issue #270):**
- Спросить пилота: «Какие 1-3 утренних приоритета на завтра? Укажи WP-ID в порядке важности (первый = самый важный). Если не хочешь задавать — скажи «пропустить».
- Если пилот задаёт приоритеты → перезаписать `${IWE_GOVERNANCE_REPO:-DS-strategy}/current/priorities.yaml`:
  ```yaml
  # Утренние приоритеты на сегодня — обновлять вечером или утром
  # Порядок = убывающий приоритет (первый = самый важный)
  # Пустой список = fallback на вчерашний перенос в Day Open
  last_updated: "YYYY-MM-DD"
  today:
    - WP-NNN
    - WP-MMM
  ```
  где `last_updated` = завтрашняя дата (`date -v+1d +%Y-%m-%d 2>/dev/null || date -d "tomorrow" +%Y-%m-%d`).
- Если пилот пропускает → оставить файл без изменений (Day Open покажет stale-предупреждение, если он устарел ≥3 дня).
- Добавить файл в список изменений для коммита на финальном шаге (если перезаписывался).

---

## Шаг 9: Запись итогов — postconditions

**Шаблон итогов дня:** `memory/templates-dayplan.md § Шаблон итогов дня`

**Валидация «Завтра начать с» (ADR-207):** поле не пустое + каждый pending РП упомянут + конкретный next action (не «продолжить работу»).

**Postcondition 9a:**
```bash
TODAY=$(date +%Y-%m-%d)
# NOTE (bug-2026-07-10, найден Day Close 10.07): исходная версия гнала путь через
# `xargs`, который делит аргументы по пробелам — а DayPlan-имена ВСЕГДА содержат
# пробел ("DayPlan YYYY-MM-DD.md"), поэтому xargs получал два несуществующих
# токена и постусловие молча падало в FAIL независимо от реального содержимого
# файла. Прямая проверка через переменную в кавычках не расщепляет путь.
F="$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/archive/day-plans/DayPlan ${TODAY}.md"
if grep -q "Итоги дня" "$F" 2>/dev/null && grep -q "${TODAY}" "$F" 2>/dev/null; then
  echo "9a OK"
else
  echo "9a FAIL: итоги не найдены в DayPlan ${TODAY}"
fi
```

**Postcondition 9b:**
```bash
TODAY=$(date +%Y-%m-%d)
DAY_NUM=$(date +%-d)
( grep -rl "Итоги.*${DAY_NUM}" ~/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/current/WeekReport\ W*.md 2>/dev/null \
  || grep -rl "Итоги.*${DAY_NUM}" ~/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/current/WeekPlan\ W*.md 2>/dev/null ) \
  | grep -q . && echo "9b OK" || echo "9b FAIL: итоги не найдены ни в WeekReport, ни в WeekPlan"
```

Результат `*a/*b FAIL` → шаг НЕ помечать completed, вернуться к записи.
