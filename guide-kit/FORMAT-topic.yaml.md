# Topic Format (Ф6-Ф8)

## Назначение

`topic.yaml` — специфик прикладной темы для режимов Б/В (пользователь принесённые источники).  
Контрактует вход между пользователем и генератором прикладных руководств.

## Структура

```yaml
# Основные поля
scenario: learn|research|formalize
mode: B|V
source_url: https://example.com/course  # режим Б только
source_title: "Advanced Python Patterns"
source_type: course|book|tutorial|paper|podcast|video|other

# Элементы темы
topic_name: "Advanced OOP Design"  # свободный текст или Pack-riferimento
domain_mapping: "programming.oop"  # optional, наша 5-область или свобдный путь
target_stage: intermediate|advanced  # ожидаемый уровень выхода (не присваиваем, только сигнал)

# Методология
methodology:
  estimated_hours: 20  # оценка общего часа обучения
  learning_style: conceptual|applied|mixed
  prerequisites:  # карточки/темы, которые должны быть пройдены
    - "oop.inheritance"
    - "oop.polymorphism"
  assessment_points:  # where to check understanding
    - chapter: 3
      checkpoint: true
    - chapter: 6
      checkpoint: true

# Граф темы (режим Б)
sections:
  - id: "sec-01-design-patterns-intro"
    title: "Introduction to Design Patterns"
    source_location: "Chapter 1"
    learning_objectives:
      - "Understand pattern taxonomy"
      - "Recognize common patterns in code"
    prerequisites: []
    estimated_hours: 2

  - id: "sec-02-creational"
    title: "Creational Patterns"
    source_location: "Chapters 2-4"
    learning_objectives:
      - "Distinguish creation strategies"
      - "Apply Factory, Singleton, Builder"
    prerequisites:
      - "sec-01-design-patterns-intro"
    estimated_hours: 5

# Выходные опции
outputs:
  include_worked_examples: true
  include_exercise_suggestions: true
  prefer_mixed_guide: true  # Интеллектуал + Ученик в одном руководстве

# Опции для режима В (подборщик источника)
search_criteria:  # режим В только
  domain: "programming.python"
  difficulty: intermediate
  recency_years: 5
  coverage: ["patterns", "best-practices", "refactoring"]
  format_preference: ["video", "interactive"]
  max_candidates: 5

# Фреш и управление
freshness:
  valid_from: "2026-07-26"
  ttl_days: 90
  supersede: []  # можно указать ID предыдущей версии темы

# Метаданные и атрибуция
metadata:
  created_by: "guide-kit@human"
  external_source_id: "topic-adv-oop-2026"
  notes: "Custom learning path based on work_section: programming"
```

## Поля по сценариям

### learn×Б (источник назван, пользователь выбрал)

**Обязательные:**
- `scenario: learn`
- `mode: B`
- `source_url` или `source_title` (одно из них)
- `source_type`
- `topic_name`
- `sections` — граф тем (минимум 1)

**Опциональные:**
- `domain_mapping`
- `target_stage`
- `methodology.prerequisites`
- `outputs`

### learn×В (источник неизвестен, подборщик ищет)

**Обязательные:**
- `scenario: learn`
- `mode: V`
- `topic_name`
- `search_criteria` (что именно ищем)
- `methodology.estimated_hours` (нужно ориентир бюджета)

**Опциональные:**
- `target_stage`
- `outputs`

### research (Исследователь)

**Обязательные:**
- `scenario: research`
- `topic_name`
- `domain_mapping`

**Опциональные:**
- `search_criteria` (на что сконцентрировать foresight)
- `methodology.estimated_hours`

### formalize (Просветитель)

**Обязательные:**
- `scenario: formalize`
- `topic_name`

**Опциональные:**
- `domain_mapping`
- `methodology.learning_style`

## Валидация

- `scenario` ∈ {learn, research, formalize}
- `mode` ∈ {B, V} — обязателен только для learn
- `source_type` ∈ {course, book, tutorial, paper, podcast, video, other}
- `target_stage` ∈ {beginner, intermediate, advanced, expert}
- Режим В: все поля `search_criteria.*` опциональны, но минимум одно должно быть

## Примеры

### Пример 1: Режим Б (учебник Python)

```yaml
scenario: learn
mode: B
source_url: https://github.com/user/python-advanced-repo
source_title: "Advanced Python Patterns"
source_type: book
topic_name: "Advanced Python Design Patterns"
domain_mapping: "programming.python.oop"
methodology:
  estimated_hours: 24
  prerequisites:
    - "python.basics"
    - "oop.inheritance"
sections:
  - id: "sec-creational"
    title: "Creational Patterns"
    source_location: "Chapter 2"
    learning_objectives:
      - "Master Factory, Singleton, Builder"
    prerequisites: []
    estimated_hours: 6
```

### Пример 2: Режим В (открытый поиск)

```yaml
scenario: learn
mode: V
topic_name: "Web accessibility for React developers"
search_criteria:
  domain: "web.accessibility"
  difficulty: intermediate
  recency_years: 3
  coverage: ["wcag", "testing", "best-practices"]
  format_preference: ["video", "course"]
  max_candidates: 3
methodology:
  estimated_hours: 12
  learning_style: applied
target_stage: intermediate
```

### Пример 3: Research (фронтир)

```yaml
scenario: research
topic_name: "Large Language Models in 2026"
domain_mapping: "ai.llm"
search_criteria:
  recency_years: 1
  coverage: ["capabilities", "limitations", "applications"]
methodology:
  estimated_hours: 0  # не порционное, на исследование нет оценки часов
```

## Интеграция с adapter.py

```python
# adapter.py получает topic.yaml, маршрутизирует сценарий
def load_topic(topic_path: str) -> dict:
    topic = _read_yaml(topic_path)
    scenario = topic.get('scenario', 'learn')
    mode = topic.get('mode', 'A')  # режим А если не указан (наша тема)
    
    if scenario == 'learn' and mode in ('B', 'V'):
        # Делегировать декомпозитору Ф6
        return apply_decomposer(topic)
    elif scenario == 'research':
        # Делегировать генератору фронтира Ф8
        return research_generator(topic)
    elif scenario == 'formalize':
        # Делегировать помощнику формализации Ф8
        return formalize_generator(topic)
    else:
        # Дефолт: режим А (наша тема)
        return apply_planner_mode_a(topic)
```

## Обновления от IntegrationGate Ф6

*(Заполняется после гейта, шаг 3)*
- Новые поля добавить сюда
- Удаления полей (если есть) обновить в примерах
- Валидация ужесточена/ослаблена: документировать
