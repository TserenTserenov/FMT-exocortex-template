---
name: week-close
description: "Протокол закрытия недели (Week Close). Ретро 7 дней + carry-over в новую неделю + платформенные шаги (бэкап, dirty repos)."
argument-hint: ""
version: 1.2.0
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

```bash
for repo in $(ls {{WORKSPACE_DIR}}/); do
  if [ -d {{WORKSPACE_DIR}}/$repo/.git ]; then
    commits=$(git -C {{WORKSPACE_DIR}}/$repo log --since="last monday 00:00" --until="today 00:00" --oneline --no-merges 2>/dev/null)
    [ -n "$commits" ] && echo "=== $repo ===" && echo "$commits"
  fi
done
```

Сопоставить коммиты с РП в WeekPlan → определить статусы (done/partial/not started).

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

### 6. Captures и уроки

- Просмотреть `inbox/fleeting-notes.md` за неделю → маршрутизировать невыключенные.
- Уроки сессий → MEMORY.md + thematic `lessons_*.md` (если есть).
- Drift-scan недели: что в MEMORY.md устарело за 7 дней.

### 7. Платформенные шаги

#### 7a. Бэкап IWE в iCloud

> Условный шаг: только macOS с iCloud Drive.

```bash
${IWE_SCRIPTS}/backup-icloud.sh
```

Архив всех файлов IWE (без `.git`, `node_modules`, `.venv`) → iCloud Drive. Хранит 4 последних архива.

#### 7b. Скан незакоммиченных файлов

```bash
${IWE_SCRIPTS}/check-dirty-repos.sh
```

Если есть грязные репо → закоммитить и запушить ДО завершения Week Close.

#### 7c. Memory Validate (T22b, WP-217 Ф10.2)

```bash
bash ${IWE_SCRIPTS}/memory-bleed.sh
```

**Нарушения** (HOT-лимит, orphans, superseded_by без ссылки) → исправить до коммита Week Close.
**Кандидаты на понижение горизонта** → информативно, пользователь решает при следующем Month Close.

#### 7d. ТО памяти (T, SC.024.3 §5)

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

### 8. Запись итогов в WeekPlan

Дописать секцию «Итоги W{N}» в текущий WeekPlan (структура — см. `roles/strategist/prompts/week-review.md`).

### 9. Extensions (after)

Загрузить: `bash .claude/scripts/load-extensions.sh week-close after`. Exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить. Exit 1 → пропустить. Поддерживает `extensions/week-close.after.md` И `extensions/week-close.after.<suffix>.md`.

### 10. Закоммитить governance-репо

```bash
cd {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}} && git add -A && git commit -m "week-close: W{N} итоги" && git push
```

### 11. Верификация (Haiku R23)

Запустить sub-agent Haiku в роли R23 Верификатор (context isolation).
Передать: чеклист, итоги недели, список обновлённых файлов.

---

## Чеклист Week Close

- [ ] Все изменения закоммичены и запушены (по всем репо)
- [ ] Ретро 7 дней: closed/partial/not_started/blocked разобраны
- [ ] Метрики посчитаны (completion rate, мультипликатор)
- [ ] Carry-over → W+1 (или явно «нет»)
- [ ] Captures маршрутизированы, уроки записаны
- [ ] Drift-scan недели: устаревшие факты обновлены
- [ ] iCloud backup выполнен (если macOS)
- [ ] Dirty repos: 0 (или явно проигнорированы)
- [ ] ТО памяти: distinctions.md/MEMORY.md/memory/*.md проверены, флаги зафиксированы (или «норма»)
- [ ] Итоги W{N} записаны в WeekPlan
- [ ] Extensions `.after.md` выполнены (если есть)
- [ ] Governance-репо закоммичено

Все ✅ → «Неделя закрыта.» Иначе — указать что осталось.
