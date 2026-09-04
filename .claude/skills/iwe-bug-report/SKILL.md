---
name: iwe-bug-report
description: Сообщить об ошибке или проблеме платформы IWE. Создаёт GitHub issue в FMT-exocortex-template.
argument-hint: "[описание проблемы]"
version: 1.0.0
layer: L1
status: active
browser_safe: false
triggers:
  slash: [/iwe-bug-report]
  phrases: []
routing:
  executor: agent
  model: sonnet
  deterministic: false
agents: none
interaction: one-shot
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл; WP Gate применим только при создании нового РП, не для операционных вызовов"
---

# Отчёт об ошибке платформы IWE

Проблема: $ARGUMENTS

## When to use

Сообщить об ошибке или проблеме платформы IWE. Создаёт GitHub issue в FMT-exocortex-template.

## Algorithm

## Шаг 0. Проверка на запрос справки (issue #274)

Если `$ARGUMENTS` пуст, отсутствует, или равен `--help`/`-h`/`help` — НЕ создавать issue. Вместо этого вывести:

> «`/iwe-bug-report [описание проблемы]` — сообщает об ошибке платформы IWE, создаёт GitHub issue в FMT-exocortex-template. Опиши, что произошло и что ожидалось, например: `/iwe-bug-report day-close не архивирует DayPlan`.»

Прекратить выполнение.

## Шаг 1. Категоризация

Определи категорию по содержанию $ARGUMENTS:

| Метка | Когда |
|-------|-------|
| `bug` | Скилл / протокол / скрипт работает не так, как задумано |
| `documentation` | Неточность или пробел в документации / memory / SKILL.md |
| `enhancement` | Улучшение существующего поведения (не новый функционал) |
| `question` | Поведение непонятно, нужно уточнение |

## Шаг 2. Сбор деталей

Извлеки из $ARGUMENTS и контекста сессии:
- **Что произошло:** конкретное наблюдаемое поведение
- **Что ожидалось:** правильное поведение по протоколу
- **Шаги воспроизведения:** команда / скилл / триггер (если применимо)
- **Где:** путь к скиллу / протоколу / скрипту или имя файла

Если какой-либо элемент не указан — пропусти соответствующий блок в issue (не оставляй пустые заголовки).

## Шаг 3. Получить версию IWE

Запусти:
```bash
git -C "$HOME/IWE/FMT-exocortex-template" log -1 --format="%h %ad" --date=short 2>/dev/null || echo "неизвестно"
```

## Шаг 4. Проверить gh CLI

Запусти:
```bash
gh auth status 2>&1 | head -3
```

Если `gh` не авторизован или не установлен — выведи сообщение:
> «`gh` CLI не найден или не авторизован. Установи (macOS: `brew install gh`; Linux: `apt install gh` или https://cli.github.com/), затем `gh auth login`. Issue не создан.»
> Прекрати выполнение.

## Шаг 5. Создать issue

Собери переменные:
- `TITLE`: до 80 символов, формат `[ТИП] Краткое описание`
- `CATEGORY`: метка из шага 1
- `DATE`: сегодняшняя дата (YYYY-MM-DD)
- `IWE_VERSION`: из шага 3

Метки в `TserenTserenov/FMT-exocortex-template` — копия чужого репозитория и может
разойтись с таблицей шага 1 (issue #457: `docs` переименовали в `documentation`,
`gh issue create --label` в этом случае падает и issue не создаётся вовсе).
Проверь метку перед использованием:
```bash
gh label list --repo TserenTserenov/FMT-exocortex-template --json name -q '.[].name' | grep -qx "CATEGORY"
```
Метка найдена → используй `--label "CATEGORY"` ниже как обычно. Не найдена → создай issue
БЕЗ флага `--label` (не блокируй создание из-за расхождения меток) и допиши в конец
`## Контекст` строку `- Метка не создана: "CATEGORY" не найдена в репозитории (проверь актуальный список через gh label list)`.

Запусти (подставив реальные значения):
```bash
gh issue create \
  --repo TserenTserenov/FMT-exocortex-template \
  --title "TITLE" \
  --label "CATEGORY" \
  --body "$(cat <<'BODY'
## Что произошло

[описание]

## Что ожидалось

[ожидаемое поведение]

## Шаги воспроизведения

[шаги или «не применимо»]

## Контекст

- Файл / скилл: [путь или название]
- Дата: DATE
- IWE commit: IWE_VERSION
BODY
)"
```

## Шаг 6. Отчёт

Выведи одну строку:
> *«Issue создан: [URL]»*

Если `gh` вернул ошибку — вывести текст ошибки полностью.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
