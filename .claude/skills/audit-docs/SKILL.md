---
name: audit-docs
description: "Audit repository documentation: detect drift between code and docs, report coverage by category. Run manually or on triggered drift critical."
argument-hint: "--repo <path> | . | --init --repo <path>"
version: 0.2.0
layer: L3
status: active
browser_safe: false
triggers:
  slash: [/audit-docs]
  phrases: []
routing:
  executor: sonnet
  deterministic: false
---

# Audit Docs (R24 Аудитор)

> **Роль:** R24 Аудитор. Полное описание: `PACK-digital-platform/pack/digital-platform/02-domain-entities/DP.ROLE.024-auditor.md` (WP-224). Маппинг: R24 = VR.R.002.
> **Метод:** R24 coverage по категориям + R23 pair-diff между парами `код файл ↔ docs файл`.
> **Получатель отчёта:** владелец репо в другой временной позиции (категория 3 — внешняя проектная роль). Это аудит в строгом смысле — не автор кода, не ты сейчас.
> **Тип роли (DP.D.080):** R24 — контрольная роль. Read-only к аудитуемым артефактам. Отчёт = output-канал, не изменение аудитуемого.

Аргументы: $ARGUMENTS

## Что делает

Проходит указанный репо и формирует **отчёт** о расхождениях между кодом и документацией. **Не правит ни код, ни docs** — только отчёт.

## Параметр

- `--repo <path>` (обязателен) или `.` (текущая директория).
- `--init --repo <path>` — направляемая подготовка конфигурации; аудит не запускает.

## Владение конфигурацией

| Ответственность | Подотчётная роль |
|---|---|
| Решить, что покрытие документацией требуется, и утвердить модель репозитория | Владелец репозитория |
| Определить категории документации и пары «источник ↔ документация» | R5 Архитектор совместно с владельцем |
| Материализовать утверждённый YAML | Мейнтейнер или агент-исполнитель |
| Потреблять YAML и сообщать о расхождениях | R24 Аудитор / `audit-docs` |
| Поставить шаблон, схему, bootstrap и утверждение о владении | Мейнтейнер платформы / FMT |

**Блокирующее ограничение:** агент вправе создать `docs/.audit-context.yaml`
только после того, как владелец утвердил категории и маппинги. R24 Аудитор не
изобретает семантическую модель ни во время аудита, ни перед ним.

## Bootstrap (`--init`)

1. Прочитать `<repo>/CLAUDE.md`; определить владельца и R5 Архитектора.
2. Показать им пример `.claude/skills/audit-docs/.audit-context.yaml.example`.
3. Получить от владельца явное утверждение списка категорий и каждой пары
   `source_patterns` ↔ `docs_patterns`/`file_naming`. Без утверждения остановиться.
4. Материализовать утверждённую модель в `<repo>/docs/.audit-context.yaml`,
   поставить `owner_approved: true`, `approved_by` и реальную дату.
5. Выполнить валидацию ниже. Только успешный файл становится входом аудита.

## Схема и валидация

Корень — mapping со строгими ключами `schema_version: 1`,
`owner_approved: true`, `approved_by`, `approved_at`, `categories`. `categories` —
непустой список; каждая категория содержит уникальный `id`, непустые списки строк
`source_patterns` и `docs_patterns`, строку `file_naming`; `drift_days` —
необязательное положительное целое. Неизвестные ключи и пустые glob-паттерны — ошибка.

Перед аудитом выполнить этот валидатор (требуется PyYAML):

```bash
python3 - "$REPO/docs/.audit-context.yaml" <<'PY'
import datetime as dt
import sys
import yaml

path = sys.argv[1]
data = yaml.safe_load(open(path, encoding="utf-8"))
root_keys = {"schema_version", "owner_approved", "approved_by", "approved_at", "categories"}
category_keys = {"id", "source_patterns", "docs_patterns", "file_naming", "drift_days"}
assert isinstance(data, dict) and set(data) == root_keys, "invalid root keys"
assert data["schema_version"] == 1, "unsupported schema_version"
assert data["owner_approved"] is True and data["approved_by"], "owner approval missing"
assert isinstance(data["approved_at"], (str, dt.date)), "approved_at missing"
categories = data["categories"]
assert isinstance(categories, list) and categories, "categories must be non-empty"
ids = []
for category in categories:
    assert isinstance(category, dict) and set(category) <= category_keys, "invalid category keys"
    assert {"id", "source_patterns", "docs_patterns", "file_naming"} <= set(category), "category keys missing"
    ids.append(category["id"])
    for key in ("source_patterns", "docs_patterns"):
        assert isinstance(category[key], list) and category[key] and all(isinstance(v, str) and v.strip() for v in category[key]), key
    assert isinstance(category["file_naming"], str) and category["file_naming"].strip(), "file_naming"
    assert "drift_days" not in category or isinstance(category["drift_days"], int) and category["drift_days"] > 0, "drift_days"
assert len(ids) == len(set(ids)) and all(isinstance(v, str) and v.strip() for v in ids), "category ids"
print("audit-context: valid")
PY
```

## Шаг 0. Загрузка контекста

При старте обязательно прочитать:

1. `<repo>/CLAUDE.md` целиком — как любой агент в этом репо. В частности § 10 «Известные ловушки/инварианты» (если есть).
2. `<repo>/docs/.audit-context.yaml` — категории docs, source patterns, file_naming. Без файла сообщить о `--init` и остановиться; самостоятельно создавать модель запрещено. Файл есть → выполнить схему-валидатор выше, ошибка блокирует аудит.
3. `${IWE_ROOT:-$HOME/IWE}/.claude/sync-manifest.yaml` — найти пары, где `source` или `derived` пересекают этот репо. Использовать как дополнительный источник связей «код ↔ docs».

## Шаг 1. R24 coverage по категориям

Для каждой категории из `.audit-context.yaml`:

1. Перечислить все source-файлы (по `source_patterns`).
2. Для каждого source-файла найти связанный docs-файл по `file_naming` или эвристике.
3. Посчитать: `coverage % = docs_files / source_files`.
4. Зафиксировать **gaps** (source без docs) и **orphans** (docs без source).

## Шаг 2. R23 pair-diff (drift детекция)

Для каждой существующей пары `source ↔ docs`:

1. Сравнить mtime — если docs старше source более чем на N дней (порог из манифеста или дефолт 7), отметить как кандидат на обновление.
2. Если есть git history — посмотреть последние коммиты в source и проверить, упоминаются ли затронутые сущности (функции, таблицы, эндпоинты) в docs.
3. Зафиксировать `drift_candidates` с приоритетом (critical / warn / ok).

## Шаг 3. Связь с CLAUDE.md § 10

Для каждой ловушки/инварианта из § 10 CLAUDE.md репо проверить: упомянута ли в docs? Если нет — добавить в раздел «Неочевидности».

## Шаг 4. Формирование отчёта

Записать отчёт в `<repo>/docs/audit-reports/audit-YYYY-MM-DD.md` со структурой:

```markdown
# Audit report — <repo> — <YYYY-MM-DD>

## Coverage по категориям
| Категория | Source файлов | Docs файлов | Coverage % | Статус |
|-----------|---------------|-------------|------------|--------|

## Gaps (source без docs)
- ...

## Orphans (docs без source)
- ...

## Drift candidates (pair-diff)
| Source | Docs | mtime lag | Приоритет |
|--------|------|-----------|-----------|

## Неочевидности (§ 10 CLAUDE.md, не покрыто docs)
- ...

## Итого
- Coverage суммарный: X%
- Drift critical: N
- Drift warn: N
- Gaps: N
- Orphans: N
```

## Чего НЕ делает

- НЕ правит код.
- НЕ правит docs.
- НЕ создаёт draft-PR с предложениями (это будет следующий шаг — `/auto-docs`).
- НЕ принимает решений о категориях docs (новая категория = архитектурное решение, не аудит).

## Связь с другими скиллами

- `/verify` — проверка артефакта по эталону Pack (VR.R.001). `/audit-docs` — кросс-репо coverage аудит (R24/VR.R.002). Разные роли, разные методы.
- `iwe-drift.sh` — детектирует drift между парами в `sync-manifest.yaml` (S-класс). `/audit-docs` — углублённый аудит docs/ внутри одного репо. drift→решение «нужно пройтись /audit-docs» — типовой workflow.

## Связь с SC.024.∞

Этот скилл реализует Variant C (manual baseline) из дизайна `SC.024.∞ — Auto-update docs/`. После 2 недель обкатки и калибровки точности — переход на Variant A (post-merge GitHub webhook). См. README.md рядом.
