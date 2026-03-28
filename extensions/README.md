# Extensions (пользовательские расширения)

> Эта директория — ваше пространство. `update.sh` **никогда** не трогает файлы здесь.

## Как расширить протокол

Создайте файл с именем `<protocol>.<hook>.md`, где:
- `<protocol>` — имя протокола (`protocol-close`, `protocol-open`, `day-open`)
- `<hook>` — точка вставки (`before`, `after`, `checks`)

### Поддерживаемые extension points

| Протокол | Hook | Когда выполняется |
|----------|------|-------------------|
| `protocol-close` | `checks` | После Step 1 (commit+push), перед Step 2 (статусы) |
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

## Правила

1. Имена файлов: `<protocol>.<hook>.md` — строго по формату
2. Содержимое: markdown, будет вставлен как блок в протокол
3. `update.sh` не трогает `extensions/` — ваши файлы в безопасности
4. Несколько расширений одного hook: загружаются в алфавитном порядке
