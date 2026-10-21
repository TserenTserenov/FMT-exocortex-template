---
description: Snapshot of P0–P5 engineering code style for setups without PACK-rhetoric
name: p05-core
owner: platform
promoted_from: WP-412 Phase11
source: PACK-digital-platform/pack/digital-platform/02-domain-entities/engineering-code-style-base.md
style_version: '2026-06-14'
type: reference
update_via: style-promote.sh p05-core.md
---

## Organizing Principle — Negative Definition

The base **does not describe "good code"**. The base is a list of specific smells (anti-patterns) with "before → after" pairs. **Taste is the absence of smells.** Any rule that cannot be reduced to a before/after pair is too vague for L0 and belongs in the authorial L1 layer.

**Why the base exists (root cause).** An agent optimizes for "done now" — it has no "future self" that will maintain the result. A professional writes for the next reader (often themselves three months later). The base is a "voice of the future reader" built into the moment of generation.

## Context Detector — "Does This Code Have a Future Reader?"

| Context | Signals | Strictness |
|---------|---------|------------|
| Production / shared code | merges into main, lives in a shared module, a test is expected | strict — all P-rules apply |
| Throwaway script / prototype | `/tmp`, one-off analysis, will not outlive the task | relaxed — over-engineering a throwaway is also a smell |

Test: "Will anyone return to this code?" No → do not create abstractions. Yes → P1–P5 are mandatory.

## Boundary With Adjacent Layers

- **Hard prohibitions** (`git add -A`, secrets in logs, `--no-verify`) → agent rules (PACK-agent-rules, AR.*). Blocking, security. **Do not duplicate here.**
- **Markdown markup / documents** → `.claude/rules/formatting.md`.
- **Style base = craft and taste layer.** Non-blocking recommendation. Boundary test: "Does it break the system or security?" → AR. "Does it make code worse in a professional's eyes?" → here.

## P0 — Trigger Bridge (Mechanics Are Handled by the Tool)

**Before committing code — run the repo formatter and linter** (`ruff`/`prettier`/`shellcheck`/`eslint` depending on which config is present). No config → ask the pilot; do not invent your own style. This ensures the mechanical layer (indentation, imports, casing) is handled by the tool, and the base deals only with the craft layer.

## P1 — A Test Without a Verifiable Observed Result Is Prohibited

"Ran and did not crash" ≠ "works". A test must assert a specific observable effect.

**Before:**
```python
await dp.feed_update(bot, update)
assert True
```
**After:**
```python
await dp.feed_update(bot, update)
assert len(bot.sent) > 0          # verify the reaction, not the absence of an exception
```
`expect(true).toBe(true)` and `expect(x).toBeDefined()` as the only assert are prohibited. Relates to "tests are green ≠ migration is correct".

## P2 — A Block Repeated Three Times → Extract a Function; Do Not Address a Variable via `locals()[str]`

**Before:**
```python
for conn_attr in ("rewards_conn", "reference_conn"):
    await locals()[conn_attr].close()   # accessing a variable by string name
```
**After:**
```python
async def ensure_conn(conn, dsn):
    return conn if conn and not conn.is_closed() else await asyncpg.connect(dsn)

conns = {name: await ensure_conn(c, dsn) for name, (c, dsn) in pool_spec.items()}
```
Use real objects in a list/dict, not names via `locals()`.

## P3 — A Dead Branch / Enum Variant the System Never Enters — Delete It; Do Not "Keep for Compatibility"

**Before:**
```ts
type CircuitState = "closed" | "open" | "half-open" | "probing"; // half-open is never set
if (c.state === "half-open") { c.state = "probing"; return true; } // dead branch
```
**After:** remove `"half-open"` from the type and its handlers. Dead "just in case" code costs more than deleting it and restoring from history if needed.

## P4 — `except Exception: pass` Without Logging Is Prohibited

A swallowed exception hides the root cause.

**Before:**
```python
try:
    await conn.close()
except Exception:
    pass
```
**After:**
```python
try:
    await conn.close()
except Exception:
    log.warning("conn.close failed", exc_info=True)   # visible in the log, not silent
```
A bare `except:` without a type and without any action is always a smell.

## P5 — A Long Function With Mixed Responsibilities → Split It; Boolean Mode Flags → Separate Functions

Signals: >~120 lines, >~6 parameters, boolean flags `skip_x`/`force_y`/`in_z` (control coupling).

**Before:**
```python
async def process_event(event_id, learning_pool, target_pools, rules,
                        cursor_cache, lookup_pools, event_seq,
                        skip_dlq_check, force_apply, in_replay):
    # read + DLQ check + grouping + apply + advance cursor + metrics
```
**After:** separate by responsibility (`read_event` → `check_dlq` → `group_by_domain` → `apply` → `advance_cursor`); replace boolean mode flags with separate calls or a strategy. A mode flag in a signature means "this function does two different things".

**Counter-criterion (Ousterhout): do not split a deep module.** Length by itself is not a smell. A deep module (rich functionality behind a narrow interface) is better than a shallow one (thin interface, complexity leaks outward). Split when the internals **mix levels of abstraction** (Martin) or different execution time points. Do NOT split when a function is long but does **one thing at one level of abstraction** — splitting for the sake of length produces small helpers and size-coupling (jumping around a file to reconstruct a single idea). Test: "Does splitting reduce or increase what you need to hold in your head to understand the module?"

## P6 — A Handler/Service Without a Structured Log on Entry and at a Critical Failure Is a Smell

Clean structure without Observability is still a craft mistake: there is nothing to diagnose during an Incident. The minimum is a structured entry record at the handler's start and at a critical failure.

**Before:**
```python
async def handle(request):
    data = await load(request)
    return process(data)          # failed in production — why, from where, with what inputs?
```
**After:**
```python
async def handle(request):
    log.info("[handle] start id=%s", request.id)   # entry is visible
    try:
        data = await load(request)
        return process(data)
    except Exception:
        log.exception("[handle] failed id=%s", request.id)  # critical failure — with context
        raise
```
The `[handler]` prefix localizes the source in a shared log; a structured field (id/phase) makes the record machine-filterable. Do not confuse with P4: P4 is about a swallowed exception; P6 is about the absence of any signal at all.
