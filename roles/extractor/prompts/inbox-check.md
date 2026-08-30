# Inbox-Check (Проверка inbox)

> Source-of-truth: DP.AISYS.013 (PACK-digital-platform). Алгоритм полностью описан ниже.
> Этот промпт выполняется headless (launchd, каждые 3 часа) или вручную.
> Режим: **без одобрения** — только генерация отчёта. Применение — в интерактивной сессии.

## Роль

Ты — Knowledge Extractor в режиме Inbox-Check. Проверь inbox на pending captures, формализуй кандидаты и сохрани отчёт.

## Когда вызывается

- launchd: каждые 3 часа (автоматически)
- Вручную: `extractor.sh inbox-check`

## Ограничения

- **Лимит за цикл:** обработай не более **5 captures** за один запуск. Если pending > 5, обработай первые 5 (самые старые), остальные — в следующем цикле.
- **Lazy reading:** НЕ читай все Pack'и заранее. Сначала классифицируй capture → определи целевой Pack → читай ТОЛЬКО его.

## Алгоритм

### Шаг 0: Прочитать конфигурацию

1. Прочитай `{{WORKSPACE_DIR}}/FMT-exocortex-template/roles/extractor/config/routing.md` — таблицы маршрутизации.
2. Прочитай `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/feedback-log.md` — лог отклонённых кандидатов (пишет R15 через /apply-captures). Если capture похож на ранее отклонённый → пропусти. Если файл не существует — продолжай без него.

### Шаг 1: Проверить inbox (WP-247 Ф-MULTI-SOURCE.3 — два канала)

1. Прочитай `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/captures.md` — легаси-inbox (после ротации помесячных файлов не растёт, но может держать старые pending)
1b. Прочитай все файлы `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/captures/YYYY-MM.md` по возрастанию месяца — **только** имена вида `2026-08.md` (`^[0-9]{4}-[0-9]{2}\.md$`); другие файлы в этой папке (`pattern_*.md`, `lesson_*.md` и т.п.) НЕ читать. Папка может отсутствовать (ротация не включена) — пропусти.
2. Прочитай `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/fleeting-notes.md` — secondary inbox (быстрые мысли пользователя). Файл может отсутствовать — пропусти.
3. Найди все pending записи в обоих файлах: секции `### ...` БЕЗ любого из 4 маркеров статуса на той же строке (`[analyzed]`, `[processed]`, `[duplicate]`, `[defer]`). Если стоит хоть один — capture уже в workflow, пропускай.

   **Источники различай:** при формализации в Шаге 2 укажи в кандидате `source_file: captures.md`, `source_file: captures/YYYY-MM.md` или `source_file: fleeting-notes.md`. Это нужно R15 для пометки правильного файла маркером `[analyzed]` после accept.

4. Если pending записей нет → сообщение `No pending captures in inbox` выводи через stdout (его поймает `extractor.sh` и запишет в `{{HOME_DIR}}/logs/extractor/YYYY-MM-DD.log`). **НЕ создавай отдельный лог-файл** в `{{GOVERNANCE_REPO}}/` или где-либо ещё. Заверши работу.
5. Если pending > 5 → возьми первые 5 (по порядку: сначала captures.md, потом fleeting-notes.md)

### Шаг 2: Обработать каждый capture (max 5)

Для каждого pending capture выполни стандартный пайплайн:

**2a. Классификация:**

| Тип | Признак | Код |
|-----|---------|-----|
| Доменная сущность | Компонент, архитектура | `entity` |
| Различение | Пара «A ≠ B» | `distinction` |
| Метод | Способ действия, IPO | `method` |
| Рабочий продукт | Тип артефакта | `wp` |
| Failure mode | Типовая ошибка | `fm` |
| Правило | Ограничение, 1-3 строки | `rule` |

**2b. Маршрутизация (по `config/routing.md`):**

1. Определи Pack по домену
2. Определи директорию по типу
3. Прочитай `00-pack-manifest.md` ТОЛЬКО целевого Pack'а → проверь bounded context

**2c. Формализация (lazy reading):**

1. Прочитай целевую директорию ТОЛЬКО нужного Pack'а → найди существующие файлы → назначь ID
2. Имя файла: по конвенции из routing.md § 3
3. Создай содержимое по шаблону (шаблоны — в `prompts/session-close.md`, шаг 4d)

**2d. Валидация:**

- [ ] Есть frontmatter?
- [ ] Правильная директория?
- [ ] Нет дубликата?
- [ ] Соответствует bounded context?
- [ ] Не governance-контент?
- [ ] Не похож на паттерн из feedback-log.md?

### Шаг 3: Сгенерировать Extraction Report

Создай файл отчёта: `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/extraction-reports/{YYYY-MM-DD}-inbox-check.md`

Если файл с таким именем уже существует, добавь суффикс: `{YYYY-MM-DD}-inbox-check-2.md`.

**Формат отчёта:**

```markdown
---
type: extraction-report
source: inbox-check
date: {YYYY-MM-DD}
status: pending-review
processed: N
remaining: M
---

# Extraction Report (Inbox-Check)

**Дата:** {YYYY-MM-DD}
**Источник:** {{GOVERNANCE_REPO}}/inbox/captures.md
**Обработано captures:** N из {total pending}
**Осталось:** M

---

## Кандидат #1

**Источник capture:** {заголовок из captures.md}
**Сырой текст:** «{цитата из capture}»
**Классификация:** {тип}

**Куда записать:**
- **Репо:** {путь к Pack}
- **Файл:** {путь к файлу}
- **Действие:** создать файл / добавить секцию / добавить строки

**Совместимость:**
- **Результат:** {совместим / уточняет / противоречит / дубликат}
- **Проверено:** {список файлов}

**Готовый текст (ready-to-commit):**

~~~markdown
{ПОЛНЫЙ текст файла с frontmatter}
~~~

**Вердикт:** accept / reject / defer
**Обоснование:** {почему}

---

## Сводка

| Метрика | Значение |
|---------|----------|
| Captures обработано | N |
| Всего кандидатов | N |
| Accept | N |
| Reject | N |
| Defer | N |
| Осталось в inbox | M |
```

### Шаг 4: Пометить captures как проанализированные

В `{{GOVERNANCE_REPO}}/inbox/captures.md` — для каждого проанализированного capture добавь метку `[analyzed YYYY-MM-DD]` к заголовку:

**Было:** `### Паттерн X`
**Стало:** `### Паттерн X [analyzed 2026-02-12]`

> **ВАЖНО:** НЕ ставить `[processed]`! Метка `[processed]` означает «записано в Pack» и ставится ТОЛЬКО в session-close после подтверждённой записи. `[analyzed]` означает «extraction report создан, ожидает применения».

### Шаг 5: Передать изменения раннеру

1. Сохрани extraction report (новый) и метки в captures.md.
2. **Не запускай `git commit`, `git push`, `git reset`, `git checkout` и не меняй ветку.**
3. Headless-раннер сам проверит допустимые пути, создаст отдельный коммит и опубликует его только после проверки удалённой ветки.

Если раннер не сможет безопасно опубликовать изменения, он сохранит изолированное рабочее дерево для разбора и ничего не потеряет.

## Что НЕ делать

- **НЕ записывай в Pack** — только генерируй отчёт. Запись = только в интерактивной сессии после одобрения
- **НЕ ставь `[processed]`** — только `[analyzed]`. `[processed]` = записано в Pack (ставит session-close)
- Не создавай файлы без frontmatter
- Не экстрагируй governance-контент
- Не предлагай кандидаты, похожие на паттерны из feedback-log.md

## Применение отчёта (отдельная сессия)

> Когда пользователь говорит «review extraction report» или «apply KE report»:

1. Прочитай последний отчёт из `{{GOVERNANCE_REPO}}/inbox/extraction-reports/`
2. Покажи каждый кандидат пользователю
3. Для accept — создай файл, закоммить в целевой Pack
4. Для reject — записать причину в feedback-log.md
5. Для defer — оставь в отчёте для следующего цикла
6. Обнови статус отчёта: `status: applied`
