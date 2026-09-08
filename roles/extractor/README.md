# Экстрактор (Knowledge Extractor, R2)

> Извлекает, формализует и маршрутизирует знания в Pack-репозитории и DS docs/.

## Что делает

При закрытии сессии или по запросу — находит знания (паттерны, различения, методы, ошибки), формализует и предлагает записать в правильное место. **Два выхода routing:** доменное знание → Pack (по шаблону SPF), реализационное знание → DS docs/ (сценарии, процессы, данные). Пользователь всегда одобряет перед записью.

## Сценарии

| Сценарий | Триггер | Режим |
|----------|---------|-------|
| **Session-Close** | Закрытие сессии (протокол Close) | Интерактивный |
| **On-Demand** | «Запиши это в Pack» | Интерактивный |
| **Knowledge Audit** | «Аудит Pack» / ежемесячно | Интерактивный |
| **Inbox-Check** | launchd каждые 3ч (опционально) | Headless (отчёт) |

## Когда подключать

- Создал первый Pack (PACK-{твоя-область})
- Работаешь с Claude Code регулярно (≥3 сессии/неделю)
- Хочешь автоматически фиксировать знания

## Установка

### 1. Настрой маршрутизацию

Отредактируй `config/routing.md` — добавь свои Pack'и:

```markdown
| Домен | Pack | Префикс | Путь |
|-------|------|---------|------|
| Мой домен | PACK-my-domain | MD | {{WORKSPACE_DIR}}/PACK-my-domain/pack/my-domain/ |
```

### 2. Подключи Экстрактор к своей подписке (нужно для Headless-сценариев)

Headless-сценарии (Inbox-Check, launchd/systemd) запускают Claude Code без интерактивного логина — нужен долгоживущий токен вашей подписки Claude Code (Pro/Max/Team/Enterprise):

```bash
bash "$IWE_TEMPLATE/roles/extractor/scripts/connect.sh"
```

Одна команда, один вход в браузере — скрипт объяснит, что делать, попросит вставить напечатанный токен и сам проверит подключение тестовым вызовом. Токен сохраняется локально в `~/.secrets/claude_code_oauth_token` (права 600) — та же конвенция, что и для остальных секретов шаблона (`scripts/add-secret.sh`).

Токен со временем может протухнуть (срок жизни официально не документирован) — если Inbox-Check начал падать, `extractor.sh` покажет в логе подсказку перезапустить `connect.sh`. Проверить сохранённый токен без нового входа: `connect.sh --check`.

Интерактивные сценарии (Session-Close, On-Demand) подключения не требуют — они выполняются внутри вашей уже открытой сессии Claude Code.

### 3. (Опционально) Установи автоматический inbox-check

```bash
cd {{WORKSPACE_DIR}}/FMT-exocortex-template/roles/extractor
bash install.sh
```

Это установит launchd-агент для проверки inbox каждые 3 часа.

### 4. Ручной запуск

```bash
# Inbox-check (без launchd) — через собранную runtime-копию, НЕ сырой файл в FMT
bash "$IWE_RUNTIME/roles/extractor/scripts/extractor.sh" inbox-check

# Knowledge Audit
bash "$IWE_RUNTIME/roles/extractor/scripts/extractor.sh" audit
```

## Как работает

```
Knowledge Extraction Pipeline:

  Обнаружение → Классификация → Маршрутизация → Формализация → Валидация → Одобрение → Запись

  1. Найти знания (captures + пропущенные инсайты)
  2. Определить тип (entity, distinction, method, fm, wp, rule)
  3. Определить: domain или implementation? (тест доменности)
     ├─ domain → Pack по домену (routing.md §1-4)
     └─ implementation → DS docs/ по системе (routing.md §5)
  4. Создать файл: Pack → шаблон SPF; DS → шаблон docs/
  5. Проверить: нет ли дубликатов и противоречий
  6. Показать Extraction Report пользователю
  7. Записать только одобренное
```

## Файлы

| Файл | Назначение |
|------|-----------|
| `config/routing.md` | Таблицы маршрутизации (Pack'и, типы, директории) |
| `config/feedback-log.md` | Лог отклонённых кандидатов (не предлагать повторно) |
| `prompts/session-close.md` | Промпт: экстракция при закрытии сессии |
| `prompts/on-demand.md` | Промпт: экстракция по запросу |
| `prompts/inbox-check.md` | Промпт: headless проверка inbox |
| `prompts/knowledge-audit.md` | Промпт: аудит Pack'ов |
| `scripts/extractor.sh` | Скрипт запуска (аналог strategist.sh) |
| `scripts/launchd/` | launchd plist для inbox-check |

## Принципы

1. **Human-in-the-loop:** Экстрактор предлагает, не записывает без одобрения
2. **Один пайплайн:** Все сценарии используют classify → route → formalize → validate
3. **Тест универсальности:** Можно использовать в другом контексте? Нет → governance, не экстрагируй
4. **Lazy reading:** Inbox-check читает только целевой Pack, не все сразу

---

*Source-of-truth: DP.AISYS.013 (PACK-digital-platform)*
