---
name: "SOTA — Prompt Cache PREFIX/BODY/TAIL"
description: "Паттерн стабилизации prompt-кэша для headless-агентов (WP-375)"
type: reference
horizon: warm
domains: [agents, prompts, cache, performance]
status: active
valid_from: 2026-06-03
owner: platform
schema_version: 1
---

# SOTA — Prompt Cache: паттерн PREFIX/BODY/TAIL

> **WP-375 / WP-394 Ф4.3.** Референс для любого нового headless-агента (Kimi, cron-задачи,
> agent-runner). Discovery-якорь — в `AGENTS-agent-blocks.md` (читается агентом при старте).

## Проблема

Headless-агент собирает системный промпт на каждый ход. Если стабильная и волатильная части
перемешаны, content-addressed prompt-кэш (Anthropic TTL 5 мин) не попадает — каждый ход
оплачивается как cache-miss. Для агентов без переиспользования кэша (Kimi headless) лишний
килотокен = реальные секунды на каждом ходе.

## Паттерн: три слоя промпта

| Слой | Что содержит | Волатильность | Кэш |
|------|--------------|---------------|-----|
| **PREFIX** | Идентичность агента, блокирующие правила, список навыков (компактный индекс) | Стабильно между ходами | До `cache_control` breakpoint — кэшируется |
| **BODY** | Контекст проекта: AGENTS.md, CLAUDE.md, активный РП | Меняется редко (раз в сессию) | В зоне кэша, пока не изменился |
| **TAIL** | Волатильный контекст хода: память, профиль косяков, timestamp, текущий запрос | Каждый ход | Не кэшируется (и не должен) |

**Правило:** стабильное — выше `cache_control` breakpoint; волатильное — строго в TAIL.
Не вставлять timestamp/счётчики/per-turn данные в PREFIX или BODY — это инвалидирует кэш.

## Эффект

- Claude Opus через OpenRouter: cache hit rate 55% → 99% за 5 ходов (WP-394 Ф1.4, замер 2026-06-03).
- TTL кэша 5 мин — для интерактивных сессий префикс почти бесплатен; для headless без
  переиспользования выигрыш реализуется только при стабильном префиксе.

## Реализация-референс

- `DS-MCP/agent-runner` (WP-375) — рабочая реализация PREFIX/BODY/TAIL сборки.
- Hermes pre-turn hook (`~/.hermes/`, WP-394 Ф1.4) — стабилизация через OpenRouter.

## Когда применять

- Новый headless-агент с multi-turn диалогом → закладывать трёхслойную сборку с самого начала.
- Агент на Anthropic-раннере (прямо или через OpenRouter) → cache_control breakpoint после PREFIX+BODY.
- Агент на не-Anthropic раннере (Moonshot/Kimi) → Anthropic-кэш неприменим; выигрыш только
  от минимизации префикса (см. tiering инструкций, WP-394 Ф3.1/4.1).
