# Template: analyze-section

> Анализ раздела руководства v4 по WRITING-PIPELINE (паттерн WP-321, WP-300).

## Параметры (params в task)

| Параметр | Тип | Пример |
|----------|-----|--------|
| `section_number` | int | 11 |
| `guide_repo` | str | `aisystant/docs` |
| `guide_path` | str | `ru/personal-new/1-1-systemic-self-development` |
| `pipeline_repo` | str | `MimEcoSys/DS-principles-curriculum` |
| `pipeline_path` | str | `specs/v4-reference/WRITING-PIPELINE.md` |
| `result_branch` | str | `main` |

## Промпт

```
Ты агент-аналитик. Проанализируй раздел {{section_number}} руководства по системному саморазвитию и сохрани замечания.

## Шаг 1: Прочитай конвейер анализа

Прочитай `{{pipeline_path}}` в репо `{{pipeline_repo}}`. Это WRITING-PIPELINE v4 — все 10 стадий проверки.

## Шаг 2: Прочитай раздел {{section_number}}

В репо `{{guide_repo}}` найди файл по пути `{{guide_path}}/{{section_number:02d}}-*.md` (двузначный номер с ведущим нулём).

Прочитай файл полностью.

## Шаг 3: Анализ по 10 стадиям WRITING-PIPELINE

Для каждой стадии:
- Маркер: ✅ соответствует / ⚠️ частично / ❌ нарушено
- Конкретное замечание с цитатой из текста

## Шаг 4: Создай файл результата

Путь: `{{pipeline_repo}}/specs/v4-reference/Проверка/раздел-{{section_number:02d}}-замечания.md`

Структура:
```
# Замечания по разделу {{section_number:02d}}

**Дата анализа:** YYYY-MM-DD
**Анализировал:** CCR Agent (claude-opus-4-7)
**Раздел:** <название из заголовка файла>

## Анализ по стадиям

### Стадия 1: <название>
[маркер] [замечание]

... (все 10 стадий) ...

## Итог

N/10 стадий: ✅ N, ⚠️ M, ❌ K

## Приоритетные замечания

1. [P0/P1/P2] <конкретное предложение исправления>
2. ...
```

## Шаг 5: Commit + push в main

```bash
cd /path/to/{{pipeline_repo}}
git checkout {{result_branch}}
git pull origin {{result_branch}}
mkdir -p specs/v4-reference/Проверка
git add specs/v4-reference/Проверка/раздел-{{section_number:02d}}-замечания.md
git commit -m "review(WP-321): анализ раздела {{section_number:02d}} по WRITING-PIPELINE"
git push origin {{result_branch}}
```

## Failure modes (КРИТИЧЕСКОЕ)

- Если `git push origin {{result_branch}}` вернул ошибку (branch protection, permission, etc.):
  - **НЕ создавай feature-branch + PR через `gh pr create`** (это создаёт навигационный шум — root cause Ф1 WP-324).
  - Вместо этого: запиши в чат-вывод полную ошибку push'а + содержимое анализа + статус `status: failed: branch protection`.
  - Dispatcher увидит failure → пометит task failed → пилот руками решит как обойти protection.

- Если раздел `{{section_number:02d}}` не найден в `{{guide_repo}}` — `status: failed: section not found`.

## Acceptance

- Файл `Проверка/раздел-{{section_number:02d}}-замечания.md` существует на `{{result_branch}}` в `{{pipeline_repo}}`.
- Содержит ровно 10 разделов «Стадия N: ...».
- Итоговый балл N/10 указан.
- ≥1 приоритетное замечание.
```
