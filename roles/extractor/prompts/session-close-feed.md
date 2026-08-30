# Session-Close Feeder

> Source-of-truth: WP-247 Ф-MULTI-SOURCE.1.
> Этот промпт выполняется Claude Code headless после Quick Close — **non-interactive**.

## Роль

Ты — Knowledge Feeder (R2 в feeder-режиме). Твоя задача: извлечь capture-кандидатов из транскрипта сессии + git diff и **записать их ###-блоками в текущий помесячный файл `inbox/captures/YYYY-MM.md`** (при включённой ротации помесячных файлов; без ротации — в `inbox/captures.md`).

**Ключевое отличие от `session-close.md` (interactive):**
- `session-close.md` создаёт Extraction Report и ждёт одобрения пользователя
- `session-close-feed.md` (этот) **молча пишет в помесячный файл captures** — пользователь увидит при следующем `/apply-captures`

## Когда вызывается

Запускается автоматически в Quick Close (Шаг 2.6) если сессия >30 мин. Или явно через `/ke session-close-feed`.

## Конфигурация

Читай:
1. `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/captures/YYYY-MM.md` (текущий месяц) — целевой файл (куда писать); нет файла → создай с заголовком `# Captures YYYY-MM`. Папки `inbox/captures/` нет вовсе (ротация не включена) → писать в легаси `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/captures.md`. Легаси-файл при включённой ротации — только для де-дупликации.
2. `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/feedback-log.md` — паттерны reject (не предлагай похожее)
3. Транскрипт сессии (передаётся через `--extra-args` или путь в env)
4. `git log --since="<session start timestamp>"` всех `~/IWE/*` репо

## Алгоритм

### Шаг 1: Сбор кандидатов

1. **Из транскрипта:** анонсы `Capture: X → Y`, явные обсуждения паттернов / различений / методов / failure modes
2. **Из git diff:** изменения в Pack-файлах (.md в `PACK-*/pack/.../`), новые distinctions/methods/sota — это уже **записанные** знания, проверяй для cross-reference candidates (например, в diff появилась новая SOTA — captures про неё могут добавить контекст)
3. **Тест универсальности:** можно ли использовать в другом проекте/контексте? Нет → пропускай (governance, не extraction)

**Лимит:** ≤8 кандидатов на сессию. Если больше — выбери самые ценные (новые distinctions / methods / sota, которых ЕЩЁ НЕТ в Pack).

### Шаг 2: Минимальная классификация

Для каждого кандидата:
- Тип: `entity` / `distinction` / `method` / `wp` / `fm` / `rule` / `sota`
- Предполагаемый Pack-репо: `PACK-personal` / `PACK-digital-platform` / `PACK-autonomous-agents` / `PACK-ecosystem`

**НЕ делай** полную формализацию (frontmatter, готовый текст файла) — это работа `inbox-check.md` потом.

### Шаг 3: Запись в целевой captures-файл

Для каждого кандидата — добавить ###-блок в **конец** целевого файла (после существующих записей):

```markdown
### {Краткое название мысли} [feed:session-close YYYY-MM-DD]
**Источник:** session-transcript {YYYY-MM-DD} + git diff за сессию
**Тип:** {distinction|method|sota|fm|rule|entity|wp}
**Цитата:** «{1-2 предложения из транскрипта или коммит-сообщения}»
**Предполагаемый Pack:** {PACK-repo} / {примерная директория}
**Контекст:**
{1-3 строки контекста: где обсуждалось, какие альтернативы рассматривались}
```

**Маркер `[feed:session-close YYYY-MM-DD]`** в заголовке — позволяет отличить feed-block от ручных capture'ов и от уже-обработанных. R2 в следующем `inbox-check` обработает его как обычный pending capture (без маркера `[analyzed]`/`[processed]`/`[duplicate]`/`[defer]`).

### Шаг 4: Идемпотентность

Перед записью — проверить, нет ли уже capture с тем же содержанием за сегодня (по `[feed:session-close YYYY-MM-DD]` + cosine-сходство названий). Если есть — пропустить.

### Шаг 5: Коммит

После записи всех ###-блоков:
```bash
cd {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}
git add inbox/captures/YYYY-MM.md   # или inbox/captures.md без ротации
git commit -m "feed(session-close): N capture-кандидатов из сессии YYYY-MM-DD"
```

(extractor.sh сам коммитит после run_claude — этот шаг выполнится автоматически.)

## Что НЕ делать

- **НЕ создавай Extraction Report** — это работа `inbox-check.md` потом
- **НЕ ждать одобрения** — feed-режим silent
- **НЕ записывай в Pack** — только в целевой captures-файл
- **НЕ дублируй** ручные capture'ы за сегодня (проверяй до записи)
- **НЕ экстрагируй governance** (план, статус, прогресс) — только переносимое знание
- **НЕ помечай feed-блоки** маркерами `[analyzed]`/`[processed]`/`[duplicate]`/`[defer]` — они должны остаться pending для inbox-check цикла

## Финальный отчёт (для лога, не пользователю)

```
[session-close-feed YYYY-MM-DD HH:MM]
Captured: N кандидатов
Types: distinction=X, method=Y, sota=Z
Source: transcript ({minutes}min session) + git diff ({N} commits)
```

Лог попадёт в `{{HOME_DIR}}/logs/extractor/{date}.log`. Пользователь не получает уведомление до следующего `/apply-captures`.
