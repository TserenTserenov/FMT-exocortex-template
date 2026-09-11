---
# see DP.SC.160, DP.ROLE.058
name: artifactor
description: "Classifies raw pilot request → structured JSON {task_type, class, artifact, budget_estimate, confidence, routing_tag, resolution_path, schema_version, result_type, expected_result_kind, result_kind_resolution, hypothesis_relation}. Keyword-fast (<200ms) or Haiku fallback (<60s). Does NOT create WP or call executor."
version: 1.1.0
layer: L1
status: active
browser_safe: false
triggers:
  slash: [/artifactor]
  phrases: []
owner_role: DP.ROLE.058
related:
  - DP.SC.160
  - DP.ROLE.058
  - DP.ROLE.059
routing:
  executor: sonnet
  deterministic: false
agents: single
interaction: multi-step
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл; WP Gate применим только при создании нового РП, не для операционных вызовов"
---

# /artifactor — Артефактор-Постановщик

> **Роль:** DP.ROLE.058 Артефактор-Постановщик  
> **Триггер:** запрос без routing-tag (Маршрутизатор → Артефактор) или `/artifactor "текст"`  
> **Service Clause:** DP.SC.160

## When to use

Classifies raw pilot request → structured JSON {task_type, class, artifact, budget_estimate, confidence, routing_tag, resolution_path, schema_version, result_type, expected_result_kind, result_kind_resolution, hypothesis_relation}. Keyword-fast (<200ms) or Haiku fallback (<60s). Does NOT create WP or call executor.

## Обещание (контракт)

**Вход:** сырой текст запроса пилота (любой длины, без routing-tag)  
**Выход:** JSON, schema_version 3 (WP-575 Ф2 — добавлено поле `result_type`) → stdout:

```json
{
  "task_type": "string",
  "class": "trivial | closed-loop | open-loop | problem-framing",
  "artifact": "string (одна строка на русском — существительное-результат)",
  "budget_estimate": "~Xh | ?",
  "confidence": "high | low",
  "routing_tag": "string",
  "resolution_path": "keyword | llm",
  "schema_version": 3,
  "result_type": "system | episteme | unresolved",
  "expected_result_kind": "kind_id из PACK-digital-platform/pack/digital-platform/result-kinds-registry.yaml | null",
  "result_kind_resolution": "static | deferred-to-session | unresolved",
  "hypothesis_relation": "unclassified"
}
```

**Инвариант:**
- НЕ создаёт РП, НЕ вызывает исполнителя, НЕ задаёт уточняющих вопросов
- `confidence=high` только при keyword-пути; `confidence=low` при LLM-пути
- При запросе <5 слов: вернуть `{"error": "INSUFFICIENT_INPUT"}`, стоп
- `budget_estimate: "?"` только при `problem-framing` или полной неопределённости
- `result_type` (WP-575 Ф2, hard-distinctions.md №36) — Исполнитель (`system`: агент/скрипт/сервис — действующее) vs Информационный объект (`episteme`: документ/знание/правило — читаемое). Решается ДО имени и класса задачи, независимая ось от `expected_result_kind` — НЕ выводится из `kind_id` (кортеж `kind_id`/`task_type`/`class` присваивается одновременно, вывод из него нарушил бы «раньше имени и класса», и `kind_id` создавался для другого различения). `unresolved` — тип неочевиден → форсирует уточнение у пилота на WP Gate, классификатор НЕ гадает (тот же принцип, что `hypothesis_relation: "unclassified"` ниже).
- **Маршрутизация по `result_type`** (делает потребитель — `/wp-new`/WP Gate Ритуал, не сам Артефактор, тот же принцип, что и передача `hypothesis_relation` в WP Gate): `system` → обязательна проверка IntegrationGate (новизна инструмента/агента/скрипта/сервиса); `episteme` → Routing Gate (карта размещения документа/знания, `DP.KR.001 §5`); `unresolved` → уточнение у пилота до продолжения.
- `expected_result_kind` — дискриминатор ожидаемого kind-а результата (WP-481 Ф7, «не бывает общего результата»), НЕ показатель готовности проверки (`gate_ready` — забота `/verify`, не Артефактора)
- `result_kind_resolution: "unresolved"` — ни один kind реестра не подходит; классификатор НЕ подменяет ближайшим (анти-утечка в супертип)
- `result_kind_resolution: "deferred-to-session"` — мета-триггер (например `peer_session`), kind решается внутри самого процесса, не в момент классификации
- **stdout = CONFIG_ERROR** (exit 3) → реестр kind-ов не читается или устарел относительно `KEYWORD_MAP` (дрейф) — fail-closed, эскалировать пилоту, не игнорировать поле
- В handoff к WP Gate передать `hypothesis_relation: "unclassified"`. До выбора
  `tests | enables | responds | researches | operational` РП остаётся pending,
  а не запускается в работу.

## Стратегическое основание РП

Артефактор не вправе приписать РП гипотезу без решения пилота. Он обязан
передать в WP Gate вопрос о типе связи:

- `tests H-NNN` — РП проверяет одну ставку;
- `enables H-NNN` — делает её проверку измеримой или возможной;
- `responds H-NNN` — следует из вердикта;
- `researches` — ищет основание для новой гипотезы;
- `operational` — поддерживает норму, устраняет инцидент или исполняет обязанность.

Для первых трёх нужен один `H-NNN`. Для двух последних номер гипотезы не
подставляется. Связь `unclassified` видна в карточке РП и блокирует её запуск,
но не создание: это сохраняет обратимость и не ломает старые автоматизации.

## Algorithm

### Шаг 1. Keyword-lookup

Запустить скрипт (возвращает JSON или сигнал):

```bash
S="${IWE_SCRIPTS:-$HOME/IWE/scripts}"
PY3="$(bash "$S/lib/find-python3.sh")" && "$PY3" "$S/artifactor.py" "$ARGUMENTS"
```

Интерпретация результата:
- **stdout = JSON** (exit 0) → вернуть пилоту, стоп
- **stdout = INSUFFICIENT_INPUT** (exit 1) → вернуть `{"error": "INSUFFICIENT_INPUT"}`, стоп
- **stdout = NO_KEYWORD_MATCH** (exit 2) → перейти к Шагу 2
- **stderr содержит CONFIG_ERROR** (exit 3) → реестр kind-ов недоступен или устарел (дрейф) — эскалировать пилоту одной строкой, НЕ переходить к Шагу 2 (это не «нет keyword-совпадения», а поломка конфигурации)

### Шаг 2. LLM-классификация (fallback при NO_KEYWORD_MATCH)

Заполнить все поля, используя правила ниже. Вернуть JSON с `resolution_path: "llm"`, `confidence: "low"`, `schema_version: 3`. Для `expected_result_kind`/`result_kind_resolution` — та же логика, что у keyword-пути: подобрать `kind_id` из `PACK-digital-platform/pack/digital-platform/result-kinds-registry.yaml` по смыслу запроса; если ни один явно не подходит — `expected_result_kind: null`, `result_kind_resolution: "unresolved"` (не подменять ближайшим).

**Шаг 2.0 — тип результата (WP-575 Ф2, ПЕРВЫЙ вопрос, до имени и класса).** Прежде чем формулировать `artifact`/`class`, ответить: результат этой работы будет действующей системой (агент, скрипт, сервис, MCP-инструмент, бот, автоматизация — что-то, что будет ВЫПОЛНЯТЬСЯ) или информационным объектом (документ, знание, правило, отчёт, план — что-то, что будет ЧИТАТЬСЯ)?
- Оба признака явно присутствуют, или ни один → `result_type: "unresolved"`, не гадать (та же дисциплина, что у `result_kind_resolution: "unresolved"`).
- Один признак явно доминирует → `result_type: "system"` или `"episteme"` соответственно.
- Пример: «создай нового бота для X» → `system`. «напиши руководство по Y» → `episteme`. «доделай хвосты РП-N» без указания что именно осталось → `unresolved` (может оказаться и кодом, и документом).

**Правила `class`:**

| Класс | Критерий |
|-------|---------|
| `trivial` | Протокол без неопределённости (day-open, week-close, peer-сессия) |
| `closed-loop` | Чёткая спецификация + известный метод (баг-фикс, миграция, ревью, триаж) |
| `open-loop` | Нет спецификации, нужно генерировать (контент-план, диагностика, сценарии) |
| `problem-framing` | Расплывчато, метод неизвестен (идеи, концепции, «что-то придумать с X») |

При сомнении — выбирать более широкий класс (open-loop, не closed-loop).

**Правила `artifact`:** одна строка на русском, первое слово — существительное, обозначающее документ, систему или состояние системы (не процесс/действие над ним — «Разбор X», «Анализ X», «Проверка X» не годятся, даже когда сами по себе грамматически существительные).  
Примеры: «Список тем для трёх постов», «Диагностический отчёт латентности», «ТЗ сценариев».  
Не так: «Разбор 88 неразобранных коммитов» (описывает действие) → так: «Реестр неразобранных коммитов ветки X» (описывает артефакт-результат).

**Общий тест «процесс → результат» (WP-7 Ф140, peer-session 2026-09-11 с Kimi+Codex).** Частные примеры выше не ловят отглагольные существительные без объекта X («Оплата», «Миграция», «Интеграция», «Синхронизация») — формально существительные, но по смыслу называют само действие. Перед тем как принять `artifact`:
1. Подставь кандидат обратно в глагол: «Оплата»→«оплатить», «Интеграция»→«интегрировать», «Синхронизация»→«синхронизировать», «Миграция»→«мигрировать». Подстановка получилась естественной → кандидат называет процесс, не результат — отклонить.
2. Спроси: «что конкретно будет существовать или в каком проверяемом состоянии окажется система после этой работы?» — назови этот объект/документ/состояние, не саму работу.
3. Переформулируй через наблюдаемый результат тем же способом, что уже работает в примерах этого файла — причастие+объект («Реализованный план», «Актуализированная стратегия», «Ротированные секреты») или предметное существительное («Реестр», «Регламент», «Канал», «Отчёт»).

Пример: не «Оплата Мастерской IWE через Aisystant и Telegram-канал» (оплата→оплатить — процесс), а «Канал оплаты Мастерской IWE через Aisystant и Telegram» или «Настроенный канал оплаты...» (в зависимости от того, что реально должно появиться).

Тест применяется и к keyword-пути (Шаг 1) — но там НЕ рантайм-проверкой (это нарушило бы контракт «<200ms, без LLM»), а разовым аудитом `KEYWORD_MAP` в `artifactor.py`: значение `artifact` каждой записи обязано проходить тот же тест на момент добавления/правки записи.

**Правила `budget_estimate`:**
- `trivial` → `~0.5h`
- `closed-loop` → `~2h` (если нет конкретного числа в запросе)
- `open-loop` → `~3h`
- `problem-framing` → `?`

**Поле `routing_tag`** = значение `task_type` (snake_case).

### Шаг 3. Вернуть результат

Вывести JSON в stdout. Без дополнительных пояснений.

## Режим отказа

| Сценарий | Поведение |
|---------|-----------|
| Запрос < 5 слов | `{"error": "INSUFFICIENT_INPUT"}` |
| Скрипт не найден / сбой | Перейти к Шагу 2 напрямую |
| Запрос на иностранном языке | Классифицировать как есть, `confidence: low` |

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
