---
name: iwe-restore
description: "Восстановление памяти агента из exocortex-бэкапа при переезде на новое устройство. Находит DS-strategy/exocortex/, показывает что будет восстановлено, спрашивает подтверждение, копирует memory/ + CLAUDE.md + AGENTS.md, финализирует /audit-installation."
argument-hint: "[path/to/DS-strategy]"
user_invocable: true
version: 1.0.0
layer: L1
status: active
triggers:
  slash: [/iwe-restore]
  phrases: ["восстанови память", "восстановить IWE", "перенести на новое устройство"]
routing:
  executor: agent
  deterministic: false
agents: single
interaction: multi-step
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл; WP Gate применим только при создании нового РП, не для операционных вызовов"
---

# IWE Restore — восстановление памяти агента

> **Когда использовать:** переехал на новый ноутбук, пересоздал workspace, потерял `memory/`.
> Если `memory/` уже заполнен и ты просто хочешь проверить — используй `/audit-installation`.

Аргументы: $ARGUMENTS

## When to use

Восстановление памяти агента из exocortex-бэкапа при переезде на новое устройство. Находит DS-strategy/exocortex/, показывает что будет восстановлено, спрашивает подтверждение, копирует memory/ + CLAUDE.md + AGENTS.md, финализирует /audit-installation.

## Обещание

За 5 минут и одно подтверждение — восстановить память агента из GitHub-бэкапа. Агент не перезапишет ничего молча: сначала показывает что найдено, потом ждёт «да».

---

## Algorithm

## Шаг 1. Найти бэкап

Определить путь к governance-репо. Приоритет:

1. Аргумент скилла `$ARGUMENTS` (если передан)
2. Переменная окружения `$DS_STRATEGY` или `$GOVERNANCE_REPO`
3. Стандартный путь `~/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/`
4. Поиск: `find ~/IWE -maxdepth 2 -name "exocortex" -type d 2>/dev/null`

```bash
GOVERNANCE="${1:-${DS_STRATEGY:-$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}}}"
EXOCORTEX="$GOVERNANCE/exocortex"
```

Если `exocortex/` не найден → сказать:

> «Не нашёл бэкап. Папка `exocortex/` отсутствует в `$GOVERNANCE`. Убедись, что governance-репо склонирован: `git clone <url> ~/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}`. Если репо на другом пути — вызови `/iwe-restore путь/к/DS-strategy`.»

Завершить.

---

## Шаг 2. Показать что найдено

Собрать информацию о бэкапе:

```bash
# Список файлов в бэкапе
find "$EXOCORTEX" -maxdepth 1 -type f \( -name "*.md" -o -name "*.yaml" -o -name "*.yml" \) | sort

# Дата последнего изменения самого свежего файла
find "$EXOCORTEX" -maxdepth 1 -type f | xargs ls -lt 2>/dev/null | head -1
```

Определить путь к `memory/` на текущем устройстве:

```bash
HOME_SLUG=$(echo "$HOME" | sed 's|/|-|g')
MEMORY_DST="$HOME/.claude/projects/${HOME_SLUG}-IWE/memory"
```

Показать пользователю:

```
Найден бэкап:
  Источник:   ~/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/exocortex/   (N файлов, последний бэкап: ДАТА)
  Назначение: ~/.claude/projects/.../memory/

Что будет восстановлено:
  memory/: [список файлов .md и .yaml]
  CLAUDE.md → ~/IWE/CLAUDE.md
  AGENTS.md → ~/IWE/AGENTS.md  (если есть)

Текущее состояние memory/:
  [пусто / N файлов уже есть]
```

---

## Шаг 3. Спросить подтверждение

Спросить одним вопросом:

> «Восстановить? (да / нет / показать diff)»

- **нет** → завершить, ничего не менять.
- **показать diff** → перейти к Шагу 3a.
- **да** → перейти к Шагу 4.

### Шаг 3a. Diff (если запросил)

Для каждого файла из бэкапа, который уже существует в `memory/`:

```bash
diff "$EXOCORTEX/<file>" "$MEMORY_DST/<file>"
```

Показать расхождения кратко. После — снова спросить: «Восстановить с перезаписью? (да / пропустить существующие / нет)»

---

## Шаг 4. Восстановить

### 4a. Создать папку memory/ если не существует

```bash
mkdir -p "$MEMORY_DST"
```

### 4b. Копировать файлы памяти

```bash
rsync -av --exclude='CLAUDE.md' --exclude='AGENTS.md' \
  --include='*.md' --include='*.yaml' --include='*.yml' \
  --exclude='*' \
  "$EXOCORTEX/" "$MEMORY_DST/"
```

Если пользователь выбрал «пропустить существующие» — добавить флаг `--ignore-existing`.

### 4c. Копировать CLAUDE.md

> issue #217: подстановка `{{HOME_DIR}}` → `$HOME` делает восстановление ОС-агностичным
> (бэкап пишется на плейсхолдере в `day-close.sh`, симметрично `setup.sh`).
> `$HOME` стоит в replacement-части `sed s///` — экранируем `&`/`\`, иначе `$HOME`
> с `&` трактуется как «весь совпавший текст» и портит путь (cold-review находка).

```bash
WORKSPACE_DIR="${IWE_WORKSPACE:-$HOME/IWE}"
HOME_SED_SAFE=$(printf '%s' "$HOME" | sed 's/[&\]/\\&/g')
if [ -f "$EXOCORTEX/CLAUDE.md" ]; then
  # Если CLAUDE.md уже есть — показать: «CLAUDE.md уже существует. Перезаписать?»
  # При согласии:
  sed "s|{{HOME_DIR}}|$HOME_SED_SAFE|g" "$EXOCORTEX/CLAUDE.md" > "$WORKSPACE_DIR/CLAUDE.md"
fi
```

### 4d. Копировать AGENTS.md

```bash
if [ -f "$EXOCORTEX/AGENTS.md" ]; then
  sed "s|{{HOME_DIR}}|$HOME_SED_SAFE|g" "$EXOCORTEX/AGENTS.md" > "$WORKSPACE_DIR/AGENTS.md"
fi
```

### 4e. Отчёт

```
Восстановлено:
  memory/: N файлов скопировано, M пропущено
  CLAUDE.md: ✅ / ⏭ пропущен
  AGENTS.md: ✅ / — не было в бэкапе
```

---

## Шаг 5. Проверка

Запустить `/audit-installation` для финальной проверки целостности инсталляции.

Сказать пользователю:

> «Память восстановлена. Перезапусти Claude Code — агент подхватит файлы из `memory/` при следующей сессии.»

---

## Граничные случаи

| Ситуация | Поведение |
|----------|-----------|
| `memory/` пуст | Копировать всё без вопросов (только итоговый подтверждающий вопрос) |
| `memory/` уже заполнен | Показать diff-опцию, не перезаписывать молча |
| `exocortex/` содержит очень старый бэкап (>30 дней) | Предупредить: «Бэкап от ДАТА — N дней назад. Продолжить?» |
| `CLAUDE.md` в workspace новее бэкапа | Предупредить: «Файл в workspace новее бэкапа на N дней. Перезаписать потеряешь правки.» |
| Нет прав на запись в `memory/` | Показать ошибку + команду для ручного исправления прав |

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
