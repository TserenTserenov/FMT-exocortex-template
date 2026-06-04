---
name: audit-docs
description: "Аудит документации репо: детекция drift'а между кодом и docs, отчёт coverage по категориям. Запускается вручную или по triggered drift critical."
argument-hint: "--repo <path> | ."
version: 0.1.0
layer: L3
status: active
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

## Шаг 0. Загрузка контекста

При старте обязательно прочитать:

1. `<repo>/CLAUDE.md` целиком — как любой агент в этом репо. В частности § 10 «Известные ловушки/инварианты» (если есть).
2. `<repo>/docs/.audit-context.yaml` — категории docs, source patterns, file_naming. Без этого файла аудит невозможен — сообщить и остановиться.
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
