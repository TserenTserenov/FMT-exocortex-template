# Inter-Agent Handoff: Kimi ↔ Claude Code

> Роль: архитектурный паттерн WP-207 H6  
> Scope: передача контекста между агентами в разных окнах VS Code  
> Статус: active

## Проблема

При использовании двух агентов в разных окнах VS Code (Kimi в одном, Claude в другом) контекст не передаётся автоматически. Каждое окно — изолированная сессия.

## Три способа handoff (по надёжности)

| # | Способ | Когда | Надёжность |
|---|--------|-------|-----------|
| 1 | **Git-commits + Co-Authored-By** | Задача >30 мин, несколько фаз | ⭐⭐⭐⭐⭐ |
| 2 | **`.handoff.md` файл-мост** | Быстрая итерация 5–15 мин | ⭐⭐⭐⭐ |
| 3 | **Branch-based relay** | Сложные задачи, несколько агентов | ⭐⭐⭐⭐⭐ |

## Шаблон `.handoff.md`

Размещается в корне IWE (`~/IWE/.handoff.md`). Жизнь ≤4 часа — устаревшие handoff опасны.

```markdown
# Handoff: [WP-XXX]
## От: [Agent] ([роль]) — [дата/время]
- **Контекст:** что сделано, почему выбран этот путь
- **Решение:** итоговое решение / ADR / commit
- **Ограничения:** что НЕ работает, на что обратить внимание
- **Следующий шаг:** конкретное действие для принимающего агента

## Кому: [Agent] ([роль])
- [ ] Шаг 1
- [ ] Шаг 2
```

## Git trailer (обязательно для cross-agent коммитов)

```bash
git commit -m "feat: ..." \
  --trailer "Co-Authored-By: Claude <noreply@anthropic.com>" \
  --trailer "Co-Authored-By: Kimi <noreply@moonshot.ai>"
```

## Workflow по умолчанию

```
Claude (оценка / think)
  → git commit --trailer "Co-Authored-By: Claude ..."
  → Kimi читает git log / .handoff.md
  → Kimi (реализация / coding / tests)
  → git commit --trailer "Co-Authored-By: Kimi ..."
  → Claude читает diff → verify
```

## Ограничения

- **Lock collision:** оба агента через MCP gateway → `acquire_file_lock` обязателен
- **Context window:** `.handoff.md` ≤150 строк (Sawtooth compression — WP-207 P3)
- **Freshness:** handoff устаревает за часы → обязательный probe перед стартом
