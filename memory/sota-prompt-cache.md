---
description: Prompt cache stabilization pattern for headless agents (WP-375)
domains:
- agents
- prompts
- cache
- performance
horizon: warm
name: SOTA — Prompt Cache PREFIX/BODY/TAIL
owner: platform
schema_version: 1
status: active
type: reference
valid_from: 2026-06-03
---

# SOTA — Prompt Cache: PREFIX/BODY/TAIL Pattern

> **WP-375 / WP-394 Phase4.3.** Reference for any new Headless adapter (Kimi, cron jobs,
> agent-runner). Discovery anchor is in `AGENTS-agent-blocks.md` (read by the agent at startup).

## Problem

A headless agent assembles the system prompt on every Work turn. When stable and volatile parts are
mixed together, the content-addressed prompt cache (Anthropic TTL 5 min) does not hit — every turn
is billed as a cache miss. For agents without cache reuse (Kimi headless), one extra kiloken equals
real seconds on every turn.

## Pattern: Three Prompt Layers

| Layer | Contents | Volatility | Cache |
|-------|----------|------------|-------|
| **PREFIX** | Agent identity, Blocking rules, skill list (compact index) | Stable across turns | Before `cache_control` breakpoint — cached |
| **BODY** | Project context: AGENTS.md, CLAUDE.md, active work plan | Changes rarely (once per Session) | In cache zone as long as unchanged |
| **TAIL** | Volatile turn context: Memory, error Profile, timestamp, current request | Every turn | Not cached (by design) |

**Rule:** stable content goes above the `cache_control` breakpoint; volatile content goes strictly in TAIL.
Do not insert timestamps, counters, or per-turn data into PREFIX or BODY — this invalidates the cache.

## Effect

- Claude Opus via OpenRouter: cache hit rate 55% → 99% over 5 turns (WP-394 Phase1.4, measured 2026-06-03).
- Cache TTL is 5 min — for interactive Sessions the prefix is nearly free; for headless agents without
  cache reuse, the gain is realized only with a stable prefix.

## Reference Implementation

- `DS-MCP/agent-runner` (WP-375) — working implementation of the PREFIX/BODY/TAIL assembly.
- Hermes pre-turn hook (`~/.hermes/`, WP-394 Phase1.4) — stabilization via OpenRouter.

## When to Apply

- New headless agent with multi-turn dialogue → build the three-layer assembly from the start.
- Agent on an Anthropic runner (directly or via OpenRouter) → place the `cache_control` breakpoint after PREFIX+BODY.
- Agent on a non-Anthropic runner (Moonshot/Kimi) → Anthropic cache does not apply; gain comes only
  from minimizing the prefix (see instruction tiering, WP-394 Phase3.1/4.1).
