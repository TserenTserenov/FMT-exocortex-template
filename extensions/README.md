# Extensions (пользовательские расширения)

> Эта директория — ваше пространство. `update.sh` **никогда** не трогает ваши пользовательские файлы здесь: `*.after.md`, `*.before.md`, `*.checks.md`, `mcp-user.json`.
>
> Исключение — этот `README.md`: он обновляется как платформенный справочник (новые hook points, примеры). Пользовательский контент в нём не хранится.

## Dry-run контракт (БЛОКИРУЮЩЕЕ для extensions)

> **Полный контракт:** [memory/dry-run-contract.md](../memory/dry-run-contract.md). Когда `/audit-installation` smoke-тестит ритуал, он создаёт sentinel `/tmp/iwe-dry-run-${SESSION_ID}.flag` и ожидает, что **никто не пишет**.

PreToolUse-хук `dry-run-gate.sh` блокирует Write/Edit/git-write/MCP-write автоматически. Но **extensions, которые запускают собственный bash или вызывают exotic tools** (бинарные API, прямой psql) — могут обойти хук.

### Обязательство для extension

Если extension содержит write-логику (создание файла, INSERT в БД, отправка сообщения), **в начале** должна быть проверка sentinel:

```bash
SID="${CLAUDE_SESSION_ID:-noid}"
if [ -f "/tmp/iwe-dry-run-${SID}.flag" ]; then
    echo "[extension <name>] dry-run active, skipping write steps"
    exit 0
fi
# далее обычная логика
```

**Альтернатива:** сделать write через стандартные tools (Write/Edit/Bash redirect) — хук перехватит автоматически. Явная проверка нужна только если extension хочет дать «осмысленный rehearsal» (например, печать «здесь будет создан DayPlan») вместо немого block'а.

**Защита от sticky-state:** TTL sentinel — 10 минут (mtime). Если sentinel старше — хук игнорирует и удаляет (фейл сессии CLI / kill -9).

---

## Как расширить протокол

Создайте файл с именем `<protocol>.<hook>.md`, где:
- `<protocol>` — имя протокола (`protocol-close`, `protocol-open`, `day-open`)
- `<hook>` — точка вставки (`before`, `after`, `checks`)

### Поддерживаемые extension points

| Протокол | Hook | Когда выполняется |
|----------|------|-------------------|
| `protocol-close` | `checks` | **ДО** Step 1 (commit+push) — pre-commit gate (R4.3 fix, WP-273) |
| `protocol-close` | `after` | После основного чеклиста, перед верификацией |
| `day-open` | `before` | Перед шагом 1 (Вчера) — утренние ритуалы, подготовка |
| `day-open` | `after` | После шага 6b (Требует внимания), перед записью DayPlan |
| `day-close` | `checks` | После governance batch, перед архивацией |
| `day-close` | `after` | После итогов дня, перед верификацией |
| `week-close` | `before` | Перед ротацией уроков (шаг 1) |
| `week-close` | `after` | После аудита memory (шаг 4), перед финализацией |
| `protocol-open` | `after` | После ритуала согласования |

### Пример: рефлексия дня

Файл `extensions/day-close.after.md`:

```markdown
## Рефлексия дня

- Что сегодня было самым сложным?
- Что бы я сделал иначе?
- За что себя похвалить?
```

При Day Close агент автоматически подгрузит этот блок в соответствующую точку протокола.

### Пример: дополнительные проверки при закрытии сессии

Файл `extensions/protocol-close.checks.md`:

```markdown
- [ ] Проверить что тесты проходят (pytest / npm test)
- [ ] Обновить CHANGELOG.md если были feat-коммиты
```

## Параметры (params.yaml)

Файл `params.yaml` содержит персистентные параметры, влияющие на поведение протоколов.
`update.sh` **не перезаписывает** params.yaml — ваши настройки в безопасности.

| Параметр | Протокол | Что управляет |
|----------|----------|---------------|
| `video_check` | Day Close | Проверка видео за день (ша�� 6д) |
| `multiplier_enabled` | Day Close | Расчёт мультипликатора IWE (шаг 5) |
| `reflection_enabled` | Day Close | Ре��лексия через `day-close.after.md` |
| `lesson_rotation` | Week Close | Ротация уроков в MEMORY.md (шаг 1) |
| `auto_verify_code` | Quick Close | Автоверификация кода Haiku (шаг 4b) |
| `verify_quick_close` | Quick Close | Верификация чеклиста Haiku (шаг 7) |
| `telegram_notifications` | Все роли | Telegram уведомления от ролей |
| `extensions_dir` | Все протоколы | Директория расширений (default: `extensions`) |

Подробности: [params.yaml](../params.yaml).

## Конфиг Day Open (day-rhythm-config.yaml)

Поведение Day Open управляется через `memory/day-rhythm-config.yaml` (не params.yaml).

| Параметр | Что управляет |
|----------|---------------|
| `budget_spread.enabled` | Распределять недельный бюджет РП по дням (true/false) |
| `budget_spread.threshold_h` | Минимальный недельный бюджет для участия в расчёте (по умолчанию: 4h) |
| `budget_spread.rounding` | Шаг округления daily_slot (по умолчанию: 0.5h) |

**Пример:** РП с бюджетом 6h/нед, среда (days_left=3) → daily_slot = round(6/3, 0.5) = 2h.

## Несколько расширений одного hook (конфликты имён)

Если нужно два расширения в одной точке — добавьте суффикс через точку:

```
extensions/day-close.after.md          # основное
extensions/day-close.after.health.md   # дополнительное (например, от другого пакета)
```

Загружаются в **алфавитном порядке** — конфликта нет, оба выполнятся.

## Установка чужого расширения (sharing)

Расширения IWE — обычные Markdown-файлы. Установка:

```bash
cp ~/Downloads/day-close.after.health.md ~/IWE/extensions/
```

### Формат пакета расширений (bundle)

```
my-extension-pack/
  README.md                    # описание, автор, версия
  extensions/
    day-close.after.md          # файлы расширений
  params-defaults.yaml          # рекомендуемые параметры (не применяются автоматически)
```

Установка bundle:

```bash
cp my-extension-pack/extensions/* ~/IWE/extensions/
# Просмотреть params-defaults.yaml и добавить нужные параметры в ~/IWE/params.yaml вручную
```

Посмотреть все доступные extension points: `/extend`

## Подключение своего MCP (mcp-user.json)

Добавьте свои MCP-серверы в `extensions/mcp-user.json`. При каждом `update.sh` они автоматически мёржатся в `.mcp.json`.

### Namespace соглашение

| Префикс | Кто | Примеры |
|---------|-----|---------|
| без префикса | Платформенные (зарезервированы) | `iwe-knowledge` (Gateway, агрегирует knowledge + digital-twin) |
| `ext-*` | Вендорские | `ext-google-calendar`, `ext-linear`, `ext-slack` |
| `<ваш префикс>-*` | Ваши MCP | `tseren-notes`, `tseren-obsidian` |

Используйте свой уникальный префикс (например username) — это предотвращает конфликты при обновлениях.

### Пример: добавить свой MCP

Файл `extensions/mcp-user.json`:

```json
{
  "mcpServers": {
    "user-my-notes": {
      "command": "npx",
      "args": ["-y", "my-notes-mcp"],
      "env": {
        "NOTES_DIR": "/path/to/my/notes"
      }
    },
    "ext-linear": {
      "command": "npx",
      "args": ["-y", "@mseep/linear-mcp"],
      "env": {
        "LINEAR_API_KEY": "lin_api_..."
      }
    }
  }
}
```

После `update.sh` эти серверы появятся в `.mcp.json`. Требуется `jq` (`brew install jq`).

**Важно:** `update.sh` не трогает `extensions/mcp-user.json` — ваши MCP в безопасности при обновлениях.

## Правила

1. Имена файлов: `<protocol>.<hook>.md` или `<protocol>.<hook>.<suffix>.md`
2. Содержимое: markdown, будет вставлен как блок в протокол
3. `update.sh` не трогает ваши файлы в `extensions/` (`*.after.md`, `*.before.md`, `*.checks.md`, `mcp-user.json`). Исключение — `extensions/README.md` (платформенный справочник)
4. Несколько расширений одного hook: загружаются в алфавитном порядке
