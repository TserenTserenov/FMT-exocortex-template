---
valid_from: 2026-03-14
originSessionId: 9a0e726a-951e-4408-9e02-94d7eeffbf74
---
# SOTA-практики (операционный справочник)

> **Источник:** Pack DP (`06-sota/DP.SOTA.*`) + SPF.SPEC.003
> **Edition:** 2026-02 | **Обновлять:** при появлении новой SOTA или устаревании существующей

## Приоритетная тройка (ВСЕГДА применяй)

| # | Практика | Правило для Claude |
|---|----------|--------------------|
| 1 | **Context Engineering** (DP.SOTA.002) | Write/Select/Compress/Isolate. Каждая строка CLAUDE.md = токен. Удаляй лишнее. |
| 2 | **DDD Strategic** (DP.SOTA.001) | BC = Pack scope. UL = ontology.md. Context Map = typed `related:`. |
| 3 | **Coupling Model** (DP.SOTA.011) | Оценивай связи по 3 измерениям: knowledge (сколько А знает о B), distance (насколько далеко), volatility (как часто меняется контракт). |

## Полная таблица: Platform SOTA (Pack DP)

| ID | Практика | Статус | Когда применять |
|----|----------|--------|----------------|
| SOTA.001 | DDD Strategic (Khononov) | SOTA | Создание Pack, определение BC, словаря, интеграций |
| SOTA.002 | Context Engineering | SOTA (фронтир) | Проектирование CLAUDE.md, memory/, agent context |
| SOTA.003 | Open API Specs | SOTA (зрелые) | Проектирование MCP, API-контракты между системами |
| SOTA.004 | GraphRAG + KG | SOTA | Проектирование retrieval, typed `related:`, MCP tools |
| SOTA.005 | AI-Native Org Design | SOTA (emerging) | Организация агентов, distribution of responsibility |
| SOTA.006 | Agentic Development | SOTA (defining) | Архитектура multi-agent, оркестрация, IPO-паттерн. **Amdahl Law:** multi-agent оправдан ТОЛЬКО при (1) context isolation, (2) parallelism gain, (3) tool specialization. Иначе coordination cost > benefit. Start single-agent. (Anthropic 2026, Левенчук). **Coordination Cost Check** (АрхГейт Шаг 2b): применять на обоих масштабах ОРЗ — День (агенты дневного цикла) и Сессия (sub-agents задачи). |
| SOTA.007 | AI-Accelerated Ontology | SOTA (breakthrough) | KE pipeline, ontology generation, validation |
| SOTA.008 | Real-Time Knowledge Capture | SOTA (консенсус) | Протокол Work, capture-to-pack, рубежи |
| SOTA.009 | Knowledge-Based Digital Twins | Emerging | DDT архитектура, Pack + данные + агенты |
| SOTA.010 | DSL → DSLM Evolution | Evolving | Формализация доменных правил, validation |
| SOTA.011 | Coupling Model (Khononov) | SOTA | Оценка связей: knowledge/distance/volatility coupling |
| SOTA.012 | Multi-Representation Arch | SOTA | Pack → multiple views (vector, graph, hierarchical) |
| SOTA.013 | SAI (Superhuman Adaptable Intelligence) | Emerging (LeCun 2026) | Evolvability как главная характеристика AI. Не AGI (повторить человека) и не ASI (превзойти на тех же задачах), а SAI — быстро осваивать новые классы задач, включая недоступные людям. World models + adaptability. Пересекается с Эволюционируемостью в АрхГейте. |

## Полная таблица: Pack Architecture SOTA (SPF.SPEC.003)

| Метод | Источник | Реализация в Pack |
|-------|----------|-------------------|
| RAPTOR (Hierarchical Indexing) | Stanford 2024 | manifest → MAP → entity cards (3 layers) |
| Contextual Chunking | Anthropic 2024 | `summary` в frontmatter каждой entity |
| Hybrid Retrieval (dense+BM25) | Production 2025 | Vector search по summary + поиск по ID-кодам |
| LightRAG | HKUDS, EMNLP 2025 | Typed `related:` = рёбра графа для traversal |
| MemGPT/Letta | UCB 2023 | 3-layer memory: core (manifest) + recall (MAP) + archival (cards) |
| llms.txt | llmstxt.org 2024 | Manifest как machine-readable index |

## Операционные правила (derived from SOTA)

1. **Архитектурное решение** → проверь 6 характеристик ЭМОГСС (эвол., масштаб., обуч., генерат., скорость, современность)
2. **Новый Pack** → BC (SOTA.001), Layer 0/1/2 (RAPTOR), summary обязателен (Chunking)
3. **Новый агент** → определи BC, IPO, контракты (SOTA.006), контекст (SOTA.002). **Coordination Cost Check:** (1) context isolation — агенту нужен отдельный контекст? (2) parallelism gain — задачи параллелизуемы? (3) tool specialization — агенту нужны свои инструменты? Все три «нет» → не создавать отдельного агента
4. **Интеграция систем** → coupling model: knowledge/distance/volatility (SOTA.011)
5. **Рубеж работы** → capture during-work (SOTA.008), не откладывай
6. **MCP/API дизайн** → Open Specs (SOTA.003), graph traversal (SOTA.004)
7. **Онтология/KE** → LLM-assisted first pass, human validates (SOTA.007)
8. **View, не копия** → projectionView, не дублирование (SOTA.012)
