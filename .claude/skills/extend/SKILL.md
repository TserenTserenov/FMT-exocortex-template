---
name: extend
description: "Каталог расширяемости IWE: что можно настроить, какие extension points существуют, какие параметры доступны, как установить чужое расширение."
argument-hint: "[название протокола или пустое для полного каталога]"
user_invocable: true
version: 1.0.0
---

# /extend — Каталог расширяемости IWE

> **Триггер:** `/extend`, «что я могу расширить?», «как настроить протокол», «как добавить свой шаг».
> **Роль:** R6 Кодировщик. **Один выход:** карта того, что доступно + конкретные инструкции.

## Алгоритм

### 1. Определить область запроса

Если аргумент указан (например `/extend day-open`) → показать только этот протокол.
Если аргумент пустой → показать полный каталог.

### 2. Показать текущее состояние кастомизаций

```bash
ls {{WORKSPACE_DIR}}/extensions/*.md 2>/dev/null || echo "(нет расширений)"
cat {{WORKSPACE_DIR}}/params.yaml 2>/dev/null
```

Сообщить:
- Какие расширения уже установлены (✅)
- Какие параметры уже изменены от defaults

### 3. Вывести каталог

#### Extension points (файлы в extensions/)

| Протокол | Hook | Файл для создания | Когда выполняется |
|----------|------|-------------------|-------------------|
| `protocol-close` | `checks` | `extensions/protocol-close.checks.md` | **ДО** commit+push — pre-commit gate (R4.3, WP-273) |
| `protocol-close` | `after` | `extensions/protocol-close.after.md` | После чеклиста, перед верификацией |
| `day-open` | `before` | `extensions/day-open.before.md` | Перед шагом 1 — утренние ритуалы |
| `day-open` | `after` | `extensions/day-open.after.md` | После «Требует внимания», перед DayPlan |
| `day-close` | `checks` | `extensions/day-close.checks.md` | После governance batch, перед архивацией |
| `day-close` | `after` | `extensions/day-close.after.md` | После итогов дня, перед верификацией |
| `week-close` | `before` | `extensions/week-close.before.md` | Перед ротацией уроков |
| `week-close` | `after` | `extensions/week-close.after.md` | После аудита memory |
| `protocol-open` | `after` | `extensions/protocol-open.after.md` | После ритуала согласования |

**Несколько файлов одного hook** — загружаются в алфавитном порядке.
Пример: `day-close.after.md` + `day-close.after.health.md` — оба выполнятся.

#### Параметры (params.yaml)

| Параметр | Протокол | Default | Описание |
|----------|----------|---------|----------|
| `video_check` | Day Open | `true` | Проверка видео за предыдущий день |
| `multiplier_enabled` | Day Close | `true` | Расчёт мультипликатора IWE (требует WakaTime) |
| `reflection_enabled` | Day Close | `false` | Рефлексия дня через `day-close.after.md` |
| `lesson_rotation` | Week Close | `true` | Ротация уроков в MEMORY.md |
| `auto_verify_code` | Quick Close | `true` | Автоверификация кода sub-agent Haiku |
| `verify_quick_close` | Quick Close | `true` | Верификация чеклиста sub-agent Haiku |
| `telegram_notifications` | Все роли | `true` | Telegram уведомления |
| `extensions_dir` | Все протоколы | `extensions` | Директория расширений |

#### Day Open (memory/day-rhythm-config.yaml)

| Параметр | Описание |
|----------|----------|
| `budget_spread.enabled` | Распределять бюджет РП по дням |
| `budget_spread.threshold_h` | Минимальный бюджет для расчёта (default: 4h) |
| `budget_spread.rounding` | Шаг округления daily_slot (default: 0.5h) |
| `strategy_day` | День стратегирования (session-prep вместо day-plan) |

#### Свои навыки (.claude/skills/)

Создать `.claude/skills/<name>/SKILL.md` — skill будет доступен как `/<name>`.
Frontmatter: `name`, `description`, `user_invocable: true`.
`update.sh` не трогает пользовательские skills (не в манифесте).

### 4. Предложить следующий шаг

На основе того что уже настроено — предложить что добавить дальше.

**Нет ни одного расширения:**
> «Хороший старт — рефлексия дня. Создать `extensions/day-close.after.md` с 3 вопросами?»

**Есть расширения, нет утреннего ритуала:**
> «Следующий шаг — `extensions/day-open.before.md` для утренней подготовки.»

### 5. Создать расширение (если попросили)

Если пользователь говорит «создай», «добавь» после просмотра каталога:
1. Уточнить содержимое (или предложить шаблон)
2. Создать файл в `extensions/`
3. Напомнить: активируется с **следующего** вызова протокола

---

## Sharing — установка чужого расширения

Расширения IWE — обычные Markdown-файлы. Установка:

```bash
cp ~/Downloads/day-close.after.health.md ~/IWE/extensions/
```

**Конфликт имён** (два файла одного hook):
Переименовать с суффиксом: `day-close.after.md` + `day-close.after.health.md`.
Оба загрузятся в алфавитном порядке — конфликта нет.

**Формат пакета расширений (bundle):**
```
my-extension-pack/
  README.md                  # описание, автор, версия
  extensions/
    day-close.after.md        # файлы расширений
  params-defaults.yaml        # рекомендуемые параметры (не применяются автоматически)
```

Установка bundle:
```bash
cp my-extension-pack/extensions/* ~/IWE/extensions/
# Просмотреть params-defaults.yaml и добавить нужные параметры в ~/IWE/params.yaml вручную
```
