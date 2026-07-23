# IWE Engineering Code Style

> For developers writing or editing code in IWE repositories. Referenced from [developer-guide.md](developer-guide.md) at station 4 (Work).

## Principle

The style base does not describe "good code" — it is a list of specific smells with "before → after" pairs. **Good taste means the absence of smells.**

**Context detector:** "Will anyone return to this code?" A one-off Script or prototype — do not create abstractions. Production code (main, shared modules) — all rules are mandatory.

**Boundary with hard prohibitions:** `git add -A`, secrets in logs, `--no-verify` — these are agent security rules (PACK-agent-rules), not covered here. Test: "Does it break the system or security?" → goes there. "Does it make the code worse in the eyes of a professional?" → goes here.

## Rules (P0–P12)

| Rule | Before → after (brief) |
|------|------------------------|
| **P0** — formatter and linter before commit | No config → ask, do not invent a style |
| **P1** — test verifies an observable result | `assert True` is a smell; assert a specific effect |
| **P2** — third repetition → function | Not `locals()[str]` — use real objects in a dict/list |
| **P3** — delete dead branches | Do not keep them "for compatibility" — retrieve from history when needed |
| **P4** — `except: pass` without a log is forbidden | Bare exception with no type and no action is always a smell |
| **P5** — split a long function with mixed responsibilities | Counter-criterion (Ousterhout): do not split a deep module for length — split on abstraction-level changes |
| **P6** — structured log on entry and on failure | A handler with no signal on entry or failure is a smell |
| **P7** — ASCII banner inside a function = hidden decomposition | Section under a banner → separate function |
| **P8** — idiom instead of fighting the language | `range(len(x))` instead of `for item in x`; language-specific idioms below |
| **P9** — library instead of manual parsing of a standard format | CSV/JSON/date by hand → `csv`/`json`/`date.fromisoformat` |
| **P12** — a paragraph justifying a workaround signals an unresolved root cause | Long explanation of "why not to touch" → fix the root cause or add a one-line WHY anchor pointing to a ticket |

## Before/After Examples

**P1 — observable result:**
```python
# before:
await dp.feed_update(bot, update); assert True
# after:
await dp.feed_update(bot, update); assert len(bot.sent) > 0
```

**P4 — log instead of a swallowed exception:**
```python
# before:
try: await conn.close()
except Exception: pass
# after:
try: await conn.close()
except Exception: log.warning("conn.close failed", exc_info=True)
```

**P8 — idiom:**
```python
# before:
result = []
for x in items:
    if x.active: result.append(x.name)
# after:
result = [x.name for x in items if x.active]
```

**P12 — WHY anchor instead of a justification paragraph:**
```python
# before: a paragraph justifying the workaround (incident history, "do not touch without review")
conn.close()
# after:
conn.close()  # WHY: driver X does not release fd on timeout (INC-4821, driver v2.3)
```

Full examples and language-specific idioms (Python/TypeScript/Go/Rust/Bash) are in `PACK-digital-platform/pack/digital-platform/02-domain-entities/engineering-code-style-base.md` (source of truth, injected into the agent context automatically by a Hook before any code edit).

## Working With Claude

- Rules P0–P12 are injected into the agent context automatically before any code edit (Hook `inject-code-style.sh`) — no manual reminder is needed.
- If a change looks like a workaround (requires a justification paragraph) — ask Claude about the root cause before accepting the code.
- PR Review: look for familiar smells from the table above — any discrepancy warrants a comment referencing the rule number (for example, "P5 — split into 3 functions").

## Source

`PACK-digital-platform`, promise `DP.SC.172` (Engineering Code Style Base). Three levels: platform (L0, all agents), author (L1, additive-only), personal (L2, additive-only).