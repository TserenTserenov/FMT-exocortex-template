---
name: week-close
description: "Протокол закрытия недели (Week Close). Ретро 7 дней + carry-over в новую неделю + платформенные шаги (бэкап, dirty repos)."
argument-hint: ""
version: 1.2.0
layer: L1
status: active
triggers:
  slash: [/week-close]
  phrases: []
routing:
  executor: sonnet
  deterministic: false
agents: single
interaction: multi-step
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл; WP Gate применим только при создании нового РП, не для операционных вызовов"
---

# Week Close (протокол закрытия недели)

> **Роль:** R1 Стратег. **Бюджет:** ~30 мин.
> **Принцип:** SKILL.md = L1 платформенный файл. Пользователь не редактирует напрямую — только через `extensions/`.
> **Стиль текста:** ретро недели и новый WeekPlan читает пилот → весь текст синтезировать в базе разговорного стиля (S0 база + S1 автор, источник DP.SC.050): русский, без машинных меток, главная мысль первой, код РП и путь не подлежащее.

## When to use

Протокол закрытия недели (Week Close). Ретро 7 дней + carry-over в новую неделю + платформенные шаги (бэкап, dirty repos).

## БЛОКИРУЮЩЕЕ: пошаговое исполнение

Week Close = протокол. Блокирующее требование — наблюдаемое свойство: **ни один шаг не пропущен молча**; каждый шаг отмечается ДО перехода к следующему.
**Шаг 0 — ПЕРВОЕ действие:** зафиксировать список шагов прямо сейчас (до любых других действий) — в TodoWrite, а при его недоступности явной нумерацией в ответе.
Инструмент по умолчанию — TodoWrite: каждый шаг алгоритма → отдельная задача (pending → in_progress → completed). **TodoWrite недоступен** (штатная ситуация, зависит от сборки клиента) → сообщить пилоту одной строкой, вести шаги явной нумерацией («Шаг X из Y: <название> — выполнен»), факт замены зафиксировать в отчёте закрытия (issues #561, #563).

## Algorithm

### 0. Extensions (before)
Загрузить: `bash .claude/scripts/load-extensions.sh week-close before`. Exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить как первые шаги. Exit 1 → пропустить. Поддерживает `extensions/week-close.before.md` И `extensions/week-close.before.<suffix>.md`.

### 1. Сбор данных за 7 дней

**Коммиты:**
```bash
for repo in $(ls {{WORKSPACE_DIR}}/); do
  if [ -d {{WORKSPACE_DIR}}/$repo/.git ]; then
    commits=$(git -C {{WORKSPACE_DIR}}/$repo log --since="last monday 00:00" --until="today 00:00" --oneline --no-merges 2>/dev/null)
    [ -n "$commits" ] && echo "=== $repo ===" && echo "$commits"
  fi
done
```

**Календарь недели:**
```bash
bash {{WORKSPACE_DIR}}/scripts/server-calendar.sh --week $(date -v-mon +%Y-%m-%d 2>/dev/null || date -d "last monday" +%Y-%m-%d)
```
Сверить запланированные встречи/задачи с фактом: что состоялось, что перенеслось, что отменилось. Для задач с отчётами (🔧 backup stress-test и т.п.) — проверить наличие артефакта.

Сопоставить коммиты и календарь с РП в WeekPlan → определить статусы (done/partial/not started).

### 2. Headless week-review (если включён launchd Пн 00:00)

> **Условный шаг:** если запущен через `strategist.sh week-review` (Пн 00:00 launchd) — алгоритм идёт через `{{IWE_TEMPLATE}}/roles/strategist/prompts/week-review.md`. В интерактивном режиме `/week-close` (вечер Вс) — выполнять следующие шаги вручную.

### 3. Ретро (closed/partial/not_started/blocked)

**3a.** Закрытые РП: что сделано, ключевые артефакты, мультипликатор за неделю.
**3b.** Частичные: % выполнения, что осталось, перенос в W+1.
**3c.** Не стартовавшие: причина, перенос или закрытие.
**3d.** Заблокированные: блокер, ETA снятия.

### 4. Метрики недели

- Completion rate: X/Y РП (N%)
- Коммитов всего, активных дней
- WakaTime итог недели (физическое время)
- Бюджет закрыт (сумма done × бюджет + partial % × бюджет)
- Мультипликатор недели = Бюджет закрыт / WakaTime
- **Калибровка гипотез (WP-496, из шага 6a):** сверено N записей за неделю; из них с уверенностью ≥80% — доля подтвердившихся (порог: ≥0.9 от заявленной уверенности, иначе «уверенность завышена» — явно отметить в WeekReport). Если сверок не было на этой неделе — не считать, пропустить строку.

### 5. Carry-over → W+1

Незавершённые РП с pending/in_progress статусами → перенести в новый WeekPlan W{N+1} (создаст session-prep автоматически в Пн 04:00 либо вручную).

### 5b. Pending фазы внутри активных РП (B-005)

> **Зачем:** carry-over §5 работает на уровне РП (status: in_progress → перенос). Pending **фазы** внутри Ф-таблиц context-файлов могут потеряться: если родительский РП в `in_progress` — pending-фаза не выделяется автоматически; если родительский ушёл в `done` — фаза теряется вместе с context-файлом.

```bash
bash ${IWE_SCRIPTS}/pending-phases-sweep.sh
```

Скрипт обходит все `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/WP-*.md` со `status: in_progress` (или без явного status), извлекает строки Ф-таблицы со статусом `⏳ pending` / `pending`, выводит сводку формата:

```
WP-NNN: pending-фазы (M):
  Фx — <описание фазы>
  Фy — <описание фазы>
```

Для каждой pending-фазы решить: **(a)** делать на этой неделе → добавить в W{N+1} как явный пункт; **(b)** переоценить (блокер? устарела?); **(c)** оставить как есть (если ожидание внешнего события — записать ожидаемый триггер).

Если скрипта нет — fallback: `grep -l "status: in_progress" {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/WP-*.md` → для каждого `grep -E "⏳.*pending|Ф[0-9]+.*pending"`.

### 6. Captures и уроки

- Просмотреть `inbox/fleeting-notes.md` за неделю → маршрутизировать невыключенные.
- Уроки сессий → MEMORY.md + thematic `lessons_*.md` (если есть).
- Drift-scan недели: что в MEMORY.md устарело за 7 дней.
- **Проверка полноты переноса перед архивацией (WP-5, 2026-07-10):** `bash {{IWE_SCRIPTS}}/check-wp-transfer-completeness.sh --all {{IWE_ROOT}}` по `inbox/WP-N/` — выводит `results_not_captured`-флаги (проставленные при закрытии без заполненного `results_in`) и файлы в подпапках без учёта в основном контекст-файле. Для каждого warning — пилот решает: (a) действительно нужен перенос знания, найти куда; (b) файл технический/устарел, можно оставить; (c) `results_in` заполнить постфактум. Не блокирует Close.

### 6a. Сверка журнала гипотез (LPF, WP-496)

> Регламент: `memory/lpf-hypothesis-log.md`. Журнал: `{{GOVERNANCE_REPO}}/current/hypotheses-log.md`.

1. Прочитать `hypotheses-log.md` — отфильтровать записи со статусом «на сверке» И датой сверки ≤ сегодня. Записи со статусом «черновик» (не подтверждённые пилотом Note-Review) — пропустить, они не в цикле сверки.
2. Для каждой найденной записи: сверить критерий фальсификации с доступной фактурой (коммиты недели, `domain_event`, инфраструктурные логи, факты из ретро §3-4 этого протокола).
3. Предложить вердикт: подтверждена / опровергнута / частично подтверждена / неприменимо (если условие критерия физически не выполнено — например, зависимый артефакт не был доставлен — гипотеза не проверяема, не «опровергнута»).
4. Пилот утверждает или правит вердикт → записать **новой** записью в конец журнала со ссылкой на исходную (`Сверка H-NNN`). Исходную запись не редактировать.
5. Для каждого вердикта — явное действие (обновить уверенность на будущее / добавить шаг в чек-лист / завести РП / зафиксировать кандидат в паттерн — §6 Capture-to-Pack). Вердикт без действия = «повисший», не закрывать неделю с повисшими вердиктами.
6. Если сверенных записей нет — пометить явно «сверка гипотез: 0 записей с наступившей датой» в WeekReport (не пропускать шаг молча).

### 6b. Проактивная сверка каденции архивации карточек (WP-545 Ф3)

> **Зачем:** протокол Close (§ 5c) — реактивный: предлагает архивацию только когда агент случайно касается конкретной карточки. Прецедент WP-7 — механизм архива существовал, но использование прекратилось на 2 месяца, пока карточка не была замечена вручную. Этот шаг закрывает разрыв: сканирует весь `inbox/` безусловно каждую неделю.

```bash
S="${IWE_SCRIPTS:-$HOME/IWE/scripts}"
PY3="$(bash "$S/lib/find-python3.sh")" && "$PY3" "$S/archive-cadence-sweep.py" --format md
```

Критерий (тот же, что и в § 5c, не переизобретается): `created` >14 дней И карточка >400 строк, при отсутствии `inbox/WP-N/WP-N-archive.md`. Отказ пилота (`archive_declined: YYYY-MM-DD`) уважается 14 дней от отметки.

Вывод — список кандидатов, отложенных по cooldown и (диагностически) расхождений `archive:`-поля с фактом файла. **Не архивировать автоматически** — только вставить список в WeekReport (§8) как явную рекомендацию; решение по каждой карточке пилот принимает при следующем открытии (через § 5c реактивного механизма).

### 7. Платформенные шаги

#### 7a. Проверка здоровья бэкапов

> Обязательный шаг перед бэкапом. Запускает `iwe-backup-check.sh` (WP-317 supplement).

```bash
bash ${IWE_SCRIPTS}/iwe-backup-check.sh
```

Если вернул ❌ (exit 2) — устранить критичные gaps ДО бэкапа (устаревший бэкап >14 дней, нет iCloud).  
Если вернул ⚠️ (exit 1) — зафиксировать warnings в WeekReport, продолжить.  
Если ✅ (exit 0) — бэкап в норме.

#### 7b. Бэкап IWE в iCloud

> Условный шаг: только macOS с iCloud Drive. Запускать ТОЛЬКО если 7a не вернул ❌.

```bash
${IWE_SCRIPTS}/backup-icloud.sh
```

Архив всех файлов IWE (без `.git`, `node_modules`, `.venv`) → iCloud Drive. Хранит 4 последних архива.

#### 7c. Скан незакоммиченных файлов

```bash
${IWE_SCRIPTS}/check-dirty-repos.sh
```

Если есть грязные репо → закоммитить и запушить ДО завершения Week Close.

#### 7d. Memory Validate (T22b, WP-217 Ф10.2)

```bash
bash ${IWE_SCRIPTS}/memory-bleed.sh
```

**Нарушения** (HOT-лимит, orphans, superseded_by без ссылки) → исправить до коммита Week Close.
**Кандидаты на понижение горизонта** → информативно, пользователь решает при следующем Month Close.

#### 7e. ТО памяти (T, SC.024.3 §5)

> Проверка здоровья статической нагрузки контекста. Флаги — информативно, пользователь решает.

```bash
echo "=== distinctions.md ===" && wc -l {{WORKSPACE_DIR}}/.claude/rules/distinctions.md
echo "=== MEMORY.md ===" && wc -l {{MEMORY_DIR}}/MEMORY.md
echo "=== memory/ файлы (mtime >14д) ===" && find {{MEMORY_DIR}} -name "*.md" -mtime +14 -not -name "MEMORY.md" -not -path "*/archive/*" | sort
```

| Метрика | Порог | Действие |
|---------|-------|---------|
| distinctions.md строк | **> 80** | Drift-флаг: нарушено правило DP.KR.001 §6 (1-3 строки на различение). Зафиксировать в Week Report, добавить задачу в техдолг. |
| MEMORY.md строк | **> 200** | Флаг превышения лимита. Предложить архивацию старых feedback в `archive/`. |
| memory/*.md без обращения > 14д | **> 5 файлов** | Предложить понизить `horizon: warm` (пользователь решает при Month Close). |

#### 7f. Hindsight health check (только при явном подключении)

> Hindsight — опциональное L2-расширение. Week Close проверяет уже подключённый
> сервис, но не запускает его автоматически и не превращает отсутствие сервиса
> в ошибку закрытия недели.

```bash
HINDSIGHT_CONFIGURED=0
[ -f "$HOME/.iwe/hindsight.env" ] && HINDSIGHT_CONFIGURED=1
[ "${IWE_HINDSIGHT_RETAIN:-}" = "1" ] && HINDSIGHT_CONFIGURED=1

if [ "$HINDSIGHT_CONFIGURED" -eq 0 ]; then
  echo "N/A: Hindsight не настроен (опциональное расширение)"
elif ! command -v docker >/dev/null 2>&1; then
  echo "⚠️ Hindsight подключён, но Docker недоступен — запускать только после решения пользователя"
else
  echo "=== Hindsight container ==="
  docker ps --format "table {{.Names}}\t{{.Status}}" | grep iwe-hindsight || \
    echo "⚠️ Container not running — запускать только после решения пользователя"
  echo "=== Hindsight log (last 20) ==="
  tail -20 "$HOME/.iwe/hindsight.log" 2>/dev/null || echo "⚠️ No log file"
  if docker ps --format "{{.Names}}" | grep -qx iwe-hindsight; then
    docker exec iwe-hindsight ls -lh /data/hindsight.db
  fi
fi
```

**Проверки при подключённом Hindsight:**
- Container `iwe-hindsight` → статус `Up`; если не запущен — сообщить пользователю, не запускать автоматически
- Лог без `FAIL` за неделю. Если есть FAIL → `docker logs iwe-hindsight` → диагностика (OpenAI key? network? disk?)
- Размер БД: если >100MB → флаг ротации
- **Whitelist review:** нужно ли добавить новые скиллы в `RECALL_SKILLS` (созданные за неделю)?

### 8. Запись итогов в WeekReport (split, ОПТ-5)

> **Split (WP-297 ОПТ-5):** факты недели живут в `WeekReport W{N}`, не в WeekPlan. WeekPlan — только намерения.

1. Открой текущий `WeekReport W{N} YYYY-MM-DD.md` (если нет — создай при следующем session-prep, см. CLAUDE.md §9 правило split).
2. Дополни секцию «Итоги W{N}» (структура — см. `roles/strategist/prompts/week-review.md`).
3. Также дополни секцию **«Сверка РП↔НЭП»** в WeekPlan W{N}: для каждого закрытого РП — какая НЭП снята / какой R-результат продвинут? Это вход в Strategy Session W{N+1}. **Не оставляй строку-заглушку** (`| ... | ... |`) без хотя бы одной реальной строки — пройди список закрытых РП недели (шаг 5) и для каждого сверься с `docs/Dissatisfactions.md` на явную связь (поле «Связанный РП» в реестре НЭП или обратная ссылка в контексте РП); нет связи → «нет» в столбце, не пропуск строки.
4. Заполни секцию **«Рекомендации изменений в НЭП и Стратегию»** в WeekPlan W{N} — что узнали на этой неделе → что менять в `Dissatisfactions.md` / `Strategy.md`.

### 9. Extensions (after)

Загрузить: `bash .claude/scripts/load-extensions.sh week-close after`. Exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить. Exit 1 → пропустить. Поддерживает `extensions/week-close.after.md` И `extensions/week-close.after.<suffix>.md`.

### 10. Оценка качества недели (WP-310 Gap-А)

Спросить пользователя: **«Оцени качество недели 1-5:  
1 = механически (шёл по инерции, голова не работала)  
2 = поверхностно (что было, что сделано — без анализа паттернов)  
3 = норма (осознанно, видишь паттерны, без прорывов)  
4 = хорошо (конкретные решения, что-то понято по-новому)  
5 = прорывная (изменилось понимание системы, ключевые решения)»**

Ответ N → включить `q:N` в commit message следующего шага.  
Если пользователь пропускает → commit без `q:`.

### 11. Закоммитить governance-репо

```bash
cd {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}
git status --short
# НЕ git add -A/git add ./git add -u — AGENTS.md CRITICAL (может захватить работу других агентов)
# Стейджить ТОЛЬКО файлы, изменённые в шагах 1-10 (в массив для pathspec):
WC_FILES=(<каждый файл явным путём: WeekPlan, WeekReport, WP-REGISTRY, inbox/WP-*.md и т.д.>)
git add "${WC_FILES[@]}"
git diff --cached --name-only  # проверить scope — только week-close файлы
# pathspec после `--`: commit ТОЛЬКО свои файлы, не подметаем чужой индекс
git commit -m "week-close: W{N} итоги q:{score}" -- "${WC_FILES[@]}"
git push
```

### 12. Верификация (Haiku R23)

Запустить sub-agent Haiku в роли R23 Верификатор (context isolation).
Передать: чеклист, итоги недели, список обновлённых файлов.

---

## Чеклист Week Close

- [ ] Все изменения закоммичены и запушены (по всем репо)
- [ ] Ретро 7 дней: closed/partial/not_started/blocked разобраны
- [ ] Метрики посчитаны (completion rate, мультипликатор)
- [ ] Carry-over → W+1 (или явно «нет»)
- [ ] Pending фазы активных РП обойдены (`pending-phases-sweep.sh` или fallback grep) — решения зафиксированы
- [ ] Каденция архивации карточек сверена (`archive-cadence-sweep.py`) — список в WeekReport
- [ ] Backlog `docs/Backlog.md` обойдён в следующую Strategy Session (либо триггеры активированы, либо явно «B-NNN живёт без триггеров»)
- [ ] Captures маршрутизированы, уроки записаны
- [ ] Drift-scan недели: устаревшие факты обновлены
- [ ] Проверка бэкапов (iwe-backup-check.sh) выполнена
- [ ] iCloud backup выполнен (если macOS)
- [ ] Dirty repos: 0 (или явно проигнорированы)
- [ ] ТО памяти: distinctions.md/MEMORY.md/memory/*.md проверены, флаги зафиксированы (или «норма»)
- [ ] Итоги W{N} записаны в WeekPlan
- [ ] Extensions `.after.md` выполнены (если есть)
- [ ] Hindsight: `N/A` (не настроен) или при явном подключении проверены container/log/размер БД; автозапуска не было
- [ ] Оценка качества недели q:N задана (1-5) и включена в commit message
- [ ] Governance-репо закоммичено
- [ ] Peer-сессии недели: WP Gate проверен (только сессии с 2026-06-09):
  ```bash
  find ~/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/sessions -type f -name "peer-prompt.md" \
    | awk -F/ '{d=$(NF-1); match(d,/^[0-9]{4}-[0-9]{2}-[0-9]{2}/); print substr(d,RSTART,RLENGTH) " " $0}' \
    | awk '$1 >= "2026-06-09" {print $2}' \
    | xargs -I{} sh -c 'grep -q "Открытие (WP Gate)" "{}" || echo "WP-GATE-MISS: {}"'
  # Пропуски фиксировать в inbox/bugs/bug-YYYY-MM-DD-wp-gate-miss.md или «нет пропусков»
  ```

Все ✅ → «Неделя закрыта.» Иначе — указать что осталось.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
