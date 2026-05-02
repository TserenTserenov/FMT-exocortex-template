Выполни **полный** Day Open для роли Стратег (R1) **автономно**.

## Алгоритм (skill /day-open, шаги 0-7)

### Шаг 0 — Scaffold (детерминированный каркас, БЛОКИРУЮЩЕЕ)

```bash
DATE=$(date +%Y-%m-%d)
DAYPLAN_FILE="$HOME/IWE/{{GOVERNANCE_REPO}}/current/DayPlan $DATE.md"

# Если файла нет — создать через scaffold
if [ ! -f "$DAYPLAN_FILE" ]; then
  bash "$HOME/IWE/scripts/day-open-scaffold.sh" "$DATE" > "$DAYPLAN_FILE"
  SCAFFOLD_EXIT=$?
  if [ "$SCAFFOLD_EXIT" -eq 2 ]; then
    rm -f "$DAYPLAN_FILE"
    echo "Сегодня strategy_day, DayPlan не создаётся (план в WeekPlan)."
    exit 0
  fi
fi
```

### Шаги 1-6 — заполнение PENDING-маркеров (LLM-синтез)

**Прочитай созданный DayPlan**, найди ВСЕ `<!-- PENDING: ... -->` маркеры. Для каждого:

1. **План на сегодня (today_plan)** — синтез из:
   - `{{GOVERNANCE_REPO}}/current/WeekPlan W{N}.md` (текущий план недели)
   - `{{GOVERNANCE_REPO}}/inbox/WP-*.md` (контекстные файлы РП с `status: active`)
   - Carry-over из вчерашнего DayPlan (секция «Завтра начать с»)
   - `day-rhythm-config.yaml → mandatory_daily_wps` (обязательные)
   - Budget spread по дням до конца недели
   Результат: таблица с 5-12 РП, бюджетом, приоритетами (🔴/🟡/🟢/⚪).

2. **Итоги вчера** — `git log --since="yesterday 00:00" --until="today 00:00"` по ВСЕМ репо в `{{WORKSPACE_DIR}}/`:
   - Группировка по репо
   - Сопоставление коммитов с РП
   - 1-3 ключевых результата (синтез)

3. **Carry-over** — цитата секции «Завтра начать с» из `archive/day-plans/DayPlan {вчера}.md`. Если первый день — «нет».

4. **Бюджет дня** — СТРОГИЙ формат для прохождения protocol-artifact-validate.sh hook:
   ```
   **Бюджет дня:** ~Xh РП / ~Yh физ / Плановый мультипликатор ~N.Nx
   ```
   - X = aggregate бюджет всех РП дня (одно число, не диапазон)
   - Y = физическое время (одно число или диапазон 6-8 — ОК)
   - N.N = мультипликатор как одно число `~2.75x` (НЕ диапазон `~2.5-3x` — hook fail)
   - НЕ писать "aggregate" перед "РП" (hook regex ищет `~Xh РП`)

5. **Mandatory check** — проверить наличие в плане: WP-7 (техдолг бота, ≥30 мин) + ≥1 контентный РП.

5a. **Здоровье платформы (валидация формата)** — секция `<details><summary>Здоровье ...</summary>` ОБЯЗАНА содержать markdown-таблицу с **числовыми ячейками** ИЛИ явный текст «нет данных». Hook regex: `\| *[0-9]|нет данных`. Например:
   ```markdown
   | Метрика | Значение |
   |---------|----------|
   | Triage 7d | 0 |
   | Open Issues | 0 |
   ```
   Светофор-таблица (`| Scheduler | 🟢 | ...`) **не проходит** валидацию (после pipe идёт буква, не цифра).

6. **Inbox Triage** (если нужно):
   - Прочитать `{{GOVERNANCE_REPO}}/inbox/fleeting-notes.md` — есть ли **жирные** заметки?
   - Если есть — классифицировать по 7 категориям (НЭП / Задача / Знание / Черновик / Личные / Шум).
   - НЕ помечать заметки и НЕ архивировать (это делает Note-Review в 23:00).

### Шаг 7 — сохранение и коммит

```bash
cd "$HOME/IWE/{{GOVERNANCE_REPO}}"
git add current/DayPlan*.md
git commit -m "day-plan: $DATE автономный полный (strategist morning)"
git pull --rebase  # на случай если Mac тоже что-то закоммитил
git push
```

## АВТОНОМНЫЙ РЕЖИМ (БЛОКИРУЮЩЕЕ)

- ❌ **НЕ задавать вопросов** «что от меня нужно?» / «вариант A/B/C?»
- ❌ **НЕ останавливаться** если файл DayPlan уже существует — заполни PENDING секции (не пересоздавай)
- ❌ **НЕ просить подтверждения** — все решения по алгоритму
- ✅ Все решения принимай по skill /day-open (`{{WORKSPACE_DIR}}/.claude/skills/day-open/SKILL.md`)
- ✅ Финал: SUCCESS + git push + Telegram (через notify.sh strategist day-plan)

## Источники (на сервере tsekh-1)

- HUB: `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/current/`
- SPOKES: `{{WORKSPACE_DIR}}/*/WORKPLAN.md`
- MEMORY: `~/.claude/projects/-Users-tseren-IWE/memory/`
- Skill: `{{WORKSPACE_DIR}}/.claude/skills/day-open/SKILL.md`
- Templates: `~/.claude/projects/-Users-tseren-IWE/memory/templates-dayplan.md`
- Scaffold: `{{WORKSPACE_DIR}}/scripts/day-open-scaffold.sh`
- Extensions: `{{WORKSPACE_DIR}}/extensions/day-open.before.md`, `.after.md`, `.checks.md`

## Если что-то отсутствует

- Файлы или репо нет → log warning, продолжай с тем что есть. НЕ падай.
- Calendar: на сервере его нет (Mac-only). Секцию пометь «Календарь недоступен на сервере».
- Видео: если scaffold нашёл 0 файлов — секция «нет новых видео сегодня».

Результат: DayPlan в `current/` с заполненными PENDING-секциями, закоммичен и запушен.
