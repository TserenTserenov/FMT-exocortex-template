# Extensions (пользовательские расширения)

> Эта директория — ваше пространство. `update.sh` **никогда** не трогает ваши пользовательские файлы здесь: `*.after.md`, `*.before.md`, `*.checks.md`, `mcp-user.json`.
>
> Исключение — этот `README.md`: он обновляется как платформенный справочник (новые hook points, примеры). Пользовательский контент в нём не хранится.

## Dry-run контракт (БЛОКИРУЮЩЕЕ для extensions)

> **Полный контракт:** [memory/dry-run-contract.md](../memory/dry-run-contract.md). Когда `/audit-installation` smoke-тестит ритуал, он создаёт sentinel `/tmp/iwe-dry-run.flag` (единый файл, не session-bound — issue #237) и ожидает, что **никто не пишет**.

PreToolUse-хук `dry-run-gate.sh` блокирует Write/Edit/git-write/MCP-write автоматически. Но **extensions, которые запускают собственный bash или вызывают exotic tools** (бинарные API, прямой psql) — могут обойти хук.

### Обязательство для extension

Если extension содержит write-логику (создание файла, INSERT в БД, отправка сообщения), **в начале** должна быть проверка sentinel:

```bash
if [ -f "/tmp/iwe-dry-run.flag" ]; then
    echo "[extension <name>] dry-run active, skipping write steps"
    exit 0
fi
# далее обычная логика
```

**Альтернатива:** сделать write через стандартные tools (Write/Edit/Bash redirect) — хук перехватит автоматически. Явная проверка нужна только если extension хочет дать «осмысленный rehearsal» (например, печать «здесь будет создан DayPlan») вместо немого block'а.

**Защита от sticky-state:** TTL sentinel — 10 минут (mtime). Если sentinel старше — хук игнорирует и удаляет (фейл сессии CLI / kill -9).

---

## Как расширить протокол

Создайте файл с именем:
- `<protocol>.<hook>.md` — единственный extension для hook (manifest-стиль), или
- `<protocol>.<hook>.<suffix>.md` — модульный extension (несколько suffix-файлов на один hook, см. раздел [Несколько расширений одного hook](#несколько-расширений-одного-hook-конфликты-имён))

Где:
- `<protocol>` — имя протокола или скилла (`protocol-close`, `protocol-open`, `day-open`, `day-close`, `week-close`, `month-close`, `iwe-update`, `verify`, `archgate`)
- `<hook>` — точка вставки (`before`, `after`, `checks`)
- `<suffix>` — произвольное имя модуля (например, `health`, `linear`, `slack`)

**Loader native (с 0.29.9):** все skills/protocols вызывают `bash .claude/scripts/load-extensions.sh <protocol> <hook>` и итерируют по выводу. И manifest-, и suffix-стиль работают одинаково. Manifest вручную делегирующий в suffix-файлы больше не нужен (вызовет двойное выполнение).

### Поддерживаемые extension points

| Протокол | Hook | Когда выполняется |
|----------|------|-------------------|
| `protocol-close` | `checks` | **ДО** Step 1 (commit+push) — pre-commit gate (R4.3 fix, WP-273) |
| `protocol-close` | `after` | После основного чеклиста, перед верификацией |
| `protocol-open` | `after` | После ритуала согласования |
| `protocol-open` | `sync` | На шаге синхронизации; уточняет поведение синхронизации |
| `day-open` | `before` | Перед шагом 1 (Вчера) — утренние ритуалы, подготовка |
| `day-open` | `after` | После шага 6b (Требует внимания), перед записью DayPlan |
| `day-open` | `checks` | После записи DayPlan, **ДО** git commit (БЛОКИРУЮЩЕЕ) |

> **Два пути исполнения `day-open.*.md` (WP-529 Ф11).** Интерактивный скилл (`day-open/SKILL.md`) читает и исполняет файл как агент — `load-extensions.sh` + `Read`. Автономный конвейер `scripts/day-open-pipeline.sh` (launchd/cron, LLM в цикле нет физически) исполняет **те же файлы** через `scripts/day-open-hooks-runner.sh`: извлекает и `eval`ит каждый ```` ```bash ```` блок механически — тот же приём, что уже был у `checks` (`day-open-checks-runner.sh`). Отсюда правило: содержимое `day-open.before.md`/`day-open.after.md`/`day-open.checks*.md` должно быть исполняемым bash-блоком, а не прозой для LLM — иначе конвейер честно упадёт «извлечено 0 bash-блоков» на автономном прогоне. Неуспешный `before`/`after`/`checks`-хук блокирует commit конвейера целиком (может мутировать состояние до commit — тихий WARN рисковал бы закоммитить половинчатый результат).
| `day-close` | `before` | Перед шагом 1 |
| `day-close` | `checks` | После governance batch, перед архивацией |
| `day-close` | `after` | После итогов дня, перед верификацией |
| `week-close` | `before` | Перед ротацией уроков (шаг 1) |
| `week-close` | `after` | После аудита memory (шаг 4), перед финализацией |
| `month-close` | `before` | Перед сбором данных |
| `month-close` | `after` | После итогов месяца, перед записью |
| `strategy-session` | `before` | Перед началом стратегической сессии |
| `strategy-session` | `after` | После итогов стратегической сессии |
| `iwe-update` | `before` | До превью и применения обновления |
| `iwe-update` | `checks` | После применения, до успешного итогового отчёта |
| `iwe-update` | `after` | После итогового отчёта об обновлении |
| `verify` | `before` | До выбора типа и запуска проверки |
| `verify` | `checks` | После основной проверки, до итогового verdict |
| `verify` | `after` | После показа итогового verdict |
| `archgate` | `before` | До принципов и начала архитектурной оценки; ошибка блокирует старт |
| `archgate` | `checks` | После DRR, до единственной публикации вердикта; ошибка блокирует публикацию |
| `archgate` | `after` | После публикации; ошибка только предупреждает и не меняет вердикт |

**Контракт исхода АрхГейта:** `archgate.before` и `archgate.checks` завершаются
маркером `ARCHGATE_EXTENSION: PASS` либо
`ARCHGATE_EXTENSION: BLOCK — <причина>`. `BLOCK` — содержательное возражение,
а поломка loader/исполнения — отдельная ошибка; оба исхода блокируют продолжение.
Для `archgate.after` используйте `ARCHGATE_EXTENSION: WARN — <причина>`:
эта фаза только предупреждает и не меняет опубликованный вердикт.
Расширению запрещено снова запускать lifecycle АрхГейта через
`load-extensions.sh archgate ...`: loader возвращает `BLOCK` для `before/checks`
и `WARN` для `after`. При смешанном наборе повреждённый или рекурсивный
`archgate.after` пропускается, а все корректные `after`-файлы выполняются.

Имя всегда включает hook. Например, `extensions/verify.md` не вызывается;
используйте `extensions/verify.before.md`, `verify.checks.md` или
`verify.after.md`.

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
| `video_check` | Day Close | Проверка видео за день (шаг 6д) |
| `multiplier_enabled` | Day Close | Расчёт мультипликатора IWE (шаг 5) |
| `reflection_enabled` | Day Close | Рефлексия через `day-close.after.md` |
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

Если нужно несколько extensions в одной точке — используйте suffix через точку:

```
extensions/day-close.after.health.md      # модуль 1: health-check
extensions/day-close.after.linear.md      # модуль 2: Linear sync
extensions/day-close.after.telegram.md    # модуль 3: Telegram notification
```

Loader (`.claude/scripts/load-extensions.sh day-close after`) возвращает все matching файлы в **алфавитном порядке** — все три выполнятся (`health` → `linear` → `telegram`). Конфликта имён нет.

> **Порядок при смешивании manifest и suffix:** lexicographic sort даёт `<protocol>.<hook>.<suffix>.md` < `<protocol>.<hook>.md` (потому что `.h` < `.m` в точке-префикс сравнении). Manifest без suffix всегда выполнится **последним**. Если важен порядок — используй suffix-имена с явной нумерацией (`day-close.after.01-health.md`, `day-close.after.02-linear.md`).

**Manifest без suffix не нужен** — пишите контент сразу в suffix-файлы. Если у вас есть `day-close.after.md` (manifest), который Read'ом подгружает suffix-файлы, **уберите его** — loader сам подхватит и manifest, и suffix → двойное выполнение.

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

## Фильтрация контекста Kimi (.agentigore)

Файл `.agentigore` в корне репо управляет тем, что Kimi **не видит** как контекст при работе через `kimi-peer-adapter.sh`. Синтаксис как у `.gitignore`.

**Важно:** имя файла — `.agentigore` (не `.agentignore`). Именно это имя читает `kimi-peer-adapter.sh`.

Чтобы создать файл, скопируй образец:
```bash
cp extensions/agentigore.sample .agentigore
```

Три уровня приоритета:
- **LEVEL-1** — секреты и приватное (`.secrets/`, `personal/`): всегда игнорировать
- **LEVEL-2** — тяжёлый контекст (`docs/`, `archive/`): игнорировать без прямой задачи
- **LEVEL-3** — по умолчанию включён: не добавлять без причины

Файл `.agentigore` не влияет на git — только на Kimi. `update.sh` его не затрагивает.

## Правила

1. Имена файлов: `<protocol>.<hook>.md` или `<protocol>.<hook>.<suffix>.md`
2. Содержимое: markdown, будет вставлен как блок в протокол
3. `update.sh` не трогает ваши файлы в `extensions/` (`*.after.md`, `*.before.md`, `*.checks.md`, `mcp-user.json`). Исключение — `extensions/README.md` (платформенный справочник)
4. Несколько расширений одного hook: загружаются в алфавитном порядке
