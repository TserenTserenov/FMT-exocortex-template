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
---

# Week Close (протокол закрытия недели)

> **Роль:** R1 Стратег. **Бюджет:** ~30 мин.
> **Принцип:** SKILL.md = L1 платформенный файл. Пользователь не редактирует напрямую — только через `extensions/`.

## БЛОКИРУЮЩЕЕ: пошаговое исполнение

Week Close = протокол. Исполнять ТОЛЬКО пошагово через TodoWrite.
**Шаг 0 — ПЕРВОЕ действие:** создать список задач прямо сейчас (до любых других действий).
Каждый шаг алгоритма → отдельная задача (pending → in_progress → completed).

## Алгоритм

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
- Бюджет закрыт (сумма done × бюджет + partial × % × бюджет)
- Мультипликатор недели = Бюджет закрыт / WakaTime

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

### 7f. FMT critical issues review (peer-session 2026-06-01-18)

> **Принцип:** Week Close = последний рубеж перед новой неделей. Критические/deadline issues в шаблоне IWE должны быть видны заказчику до планирования.

```bash
bash $IWE_SCRIPTS/fmt-critical-alert.sh --no-telegram
```

- Если 0 critical/deadline → ✅ переход к шагу 8.
- Если ≥1 → принять explicit decision: добавить в WeekPlan W{N+1} (fix), отложить с триггером (defer), или закрыть (wontfix). Без явного решения не оставлять.

### 8. Запись итогов в WeekReport (split, ОПТ-5)

> **Split (WP-297 ОПТ-5):** факты недели живут в `WeekReport W{N}`, не в WeekPlan. WeekPlan — только намерения.

1. Открой текущий `WeekReport W{N} YYYY-MM-DD.md` (если нет — создай при следующем session-prep, см. CLAUDE.md §9 правило split).
2. Дополни секцию «Итоги W{N}» (структура — см. `roles/strategist/prompts/week-review.md`).
3. Также дополни секцию **«Сверка РП↔НЭП»** в WeekPlan W{N}: для каждого закрытого РП — какая НЭП снята / какой R-результат продвинут? Это вход в Strategy Session W{N+1}.
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
cd {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}} && git add -A && git commit -m "week-close: W{N} итоги q:{score}" && git push
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
- [ ] Backlog `docs/Backlog.md` обойдён в следующую Strategy Session (либо триггеры активированы, либо явно «B-NNN живёт без триггеров»)
- [ ] Captures маршрутизированы, уроки записаны
- [ ] Drift-scan недели: устаревшие факты обновлены
- [ ] Проверка бэкапов (iwe-backup-check.sh) выполнена
- [ ] iCloud backup выполнен (если macOS)
- [ ] Dirty repos: 0 (или явно проигнорированы)
- [ ] ТО памяти: distinctions.md/MEMORY.md/memory/*.md проверены, флаги зафиксированы (или «норма»)
- [ ] Итоги W{N} записаны в WeekPlan
- [ ] Extensions `.after.md` выполнены (если есть)
- [ ] Оценка качества недели q:N задана (1-5) и включена в commit message
- [ ] Governance-репо закоммичено

Все ✅ → «Неделя закрыта.» Иначе — указать что осталось.
