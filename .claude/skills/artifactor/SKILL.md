---
# see DP.SC.160, DP.ROLE.058
name: artifactor
description: "Classifies raw pilot request → structured request with routing and an explicit unresolved strategic-basis gate. Keyword-fast (<200ms) or Haiku fallback (<60s). Does NOT create WP or call executor."
version: 1.0.0
layer: L1
status: active
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

Classifies raw pilot request → structured JSON with routing. The later WP Gate must
also resolve how the work relates to a hypothesis; Artifactor does not invent that
relation from keywords. Does NOT create WP or call executor.

## Обещание (контракт)

**Вход:** сырой текст запроса пилота (любой длины, без routing-tag)  
**Выход:** JSON 7 полей → stdout:

```json
{
  "task_type": "string",
  "class": "trivial | closed-loop | open-loop | problem-framing",
  "artifact": "string (одна строка на русском — существительное-результат)",
  "budget_estimate": "~Xh | ?",
  "confidence": "high | low",
  "routing_tag": "string",
  "resolution_path": "keyword | llm"
}
```

**Инвариант:**
- НЕ создаёт РП, НЕ вызывает исполнителя, НЕ задаёт уточняющих вопросов
- `confidence=high` только при keyword-пути; `confidence=low` при LLM-пути
- При запросе <5 слов: вернуть `{"error": "INSUFFICIENT_INPUT"}`, стоп
- `budget_estimate: "?"` только при `problem-framing` или полной неопределённости
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
python3 "${IWE_SCRIPTS:-$HOME/IWE/scripts}/artifactor.py" "$ARGUMENTS"
```

Интерпретация результата:
- **stdout = JSON** (exit 0) → вернуть пилоту, стоп
- **stdout = INSUFFICIENT_INPUT** (exit 1) → вернуть `{"error": "INSUFFICIENT_INPUT"}`, стоп
- **stdout = NO_KEYWORD_MATCH** (exit 2) → перейти к Шагу 2

### Шаг 2. LLM-классификация (fallback при NO_KEYWORD_MATCH)

Заполнить все 7 полей, используя правила ниже. Вернуть JSON с `resolution_path: "llm"` и `confidence: "low"`.

**Правила `class`:**

| Класс | Критерий |
|-------|---------|
| `trivial` | Протокол без неопределённости (day-open, week-close, peer-сессия) |
| `closed-loop` | Чёткая спецификация + известный метод (баг-фикс, миграция, ревью, триаж) |
| `open-loop` | Нет спецификации, нужно генерировать (контент-план, диагностика, сценарии) |
| `problem-framing` | Расплывчато, метод неизвестен (идеи, концепции, «что-то придумать с X») |

При сомнении — выбирать более широкий класс (open-loop, не closed-loop).

**Правила `artifact`:** одна строка на русском, существительное-результат.  
Примеры: «Список тем для трёх постов», «Диагностический отчёт латентности», «ТЗ сценариев».

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
