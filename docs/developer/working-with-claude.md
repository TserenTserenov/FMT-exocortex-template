# Working with Claude in Development

> For T4+ developers (senior developers). Claude Code is an exoskeleton for thinking, not an autopilot. This document covers practices from `memory/reference/agent-core.md` and real IWE development sessions.

## When Claude Is Useful / When Claude Is Dangerous

### ✅ Useful

1. **Exploring the unknown** — a new library, API, or tool. Claude quickly assembles patterns from documentation. **Rule:** always verify examples against the real versions you are using.

2. **Refactoring against a specification** — when tests are already written (station 4, [testing-as-spec.md](testing-as-spec.md)) and the code is messy. Claude proposes several options; you choose and run the tests.

3. **Boilerplate and templates** — configs, standard error handlers, data structures. Saves mechanical work when there is little domain-specific logic.

4. **Copying and adapting from adjacent files** — Claude remembers the local style from `.claude/rules/distinctions.md` and your code, and adapts the pattern.

5. **Documenting known code** — Claude generates examples for docstrings when the code logic is clearly defined.

6. **Peer dialogue on complex design** — discuss an idea before writing code: fewer likely mistakes. You think out loud; Claude catches contradictions. **You execute the work yourself.** The dialogue accelerates thinking, but responsibility is yours.

### ❌ Dangerous

1. **Architectural decisions without ArchGate** — Claude may propose an elegant solution that breaks Platform Integration. **Always go through ArchGate first** (CLAUDE.md §5).

2. **Copy-paste without localization** — patterns from the internet or neighboring projects may be incompatible in the IWE context (versions, permissions, API, hooks). **Always adapt; never just copy.**

3. **Trusting "consensus"** — two Claude sessions agreeing on a solution does not mean it is verified. Independent validation (live run, code review, test) is required before merge. Even consensus between two agents requires an arbitrator.

4. **API hallucinations** — Claude may confidently write a function call that does not exist in the current version. **After generation → run `pytest` immediately; if an error occurs → diagnose together.**

5. **Logging PII** — Claude may capture user data in logs or traces. **The Security Gate (CLAUDE.md pre-action gates) is mandatory before implementation** when a Work Product touches personal data.

## Workflow: From WP Gate to Merge

### Step 0: WP Gate (before engaging Claude)

**BLOCKING.** Read `memory/protocol-open.md` BEFORE starting. Declare:
- **Role:** what role are you playing (developer, architect, diagnostician)?
- **Work:** specifically what (specification, design, implementation)?
- **Verification class:** how will it be verified (closed-loop = tests; open-loop = peer session)?
- **Assessment and model:** time, LLM model if needed.

**Example:**
```
Pilot: Write an error handler for API requests.

Claude: ❌ Insufficient. Questions:
- New function or refactoring an existing one?
- Which errors to focus on (5xx, timeout, malformed)?
- Is logging in place? What kind?
- Verification class? (are tests ready?)

Pilot: New. 5xx errors. Logging is ready. Tests are ready.
Class: closed-loop (tests exist).

Claude: ✅ WP-XYZ opened. Read the tests, see the spec.
```

### Step 1: Design Talk (if non-trivial)

If routine (test → code) → skip. If ambiguous (two solution options):
- Ask Claude: what approaches are available? What are the trade-offs?
- **You choose** what is best for your project.
- Articulate the risks: where could it break?

**Example:**
```
Claude: Two approaches:
  A) Retry with exponential backoff (simple, but may hang).
  B) Circuit Breaker (more complex, but scales better).

Are you scaling to thousands of requests per minute?

Pilot: No. A is sufficient.

Claude: OK. One risk: conflict between the LB timeout and our retry.
What is the timeout on your load balancer?
```

### Step 2: Implementation (code-pair)

**Prompt patterns:**

**"Explain first"** — for non-trivial work (new function, side effects, module boundary). A 3–5 point plan before code. Catching an error in the plan is cheaper than catching it in 200 lines.

**"Write directly"** — for trivial work (test-driven implementation, one-line fix). An intermediate explanation here is wasted time.

**Example prompts:**
```
Write a function validate_user(data: dict) -> Tuple[bool, str].
Requirements:
- Check type_id is in the range [1..999]
- Check email against SMTP format
- On error, return False + error message
Examples:
  {"type_id": 42, "email": "test@ex.com"} → (True, "")
  {"type_id": 0, "email": "bad"} → (False, "invalid type_id")
Style: as in src/validators.py (repeat imports, naming conventions)
```

**RULE: Run tests immediately after generation.** Do not wait.

```bash
pytest tests/test_validators.py::test_validate_user -v
```

Error? Diagnose it together with Claude. Regression in neighboring tests? You will see it immediately.

### Step 3: Pre-Commit Check

**Checklist:**

- [ ] **All tests passed.** Run `pytest` (full suite), not selectively.
- [ ] **No code duplication (P2).** If you see a block repeated in a third place — refactor a shared function; do not copy.
- [ ] **No dead branches (P3).** Remove code that nothing calls. Do not leave it "for the future" without a consumer.
- [ ] **No `except: pass` without logging (P4).** At minimum, log it or raise the exception explicitly.
- [ ] **No PII logging.** Grep for field names (email, phone, personal_id, secret). If you log context — verify that no personal data can appear there.
- [ ] **Long functions are split (P5).** If a function does multiple things (parsing + validation + writing) → split it into parts.

Formatting (P0) is checked by the pre-commit hook.

**Git staging (CRITICAL):**

```bash
# ❌ PROHIBITED — will pick up work from parallel agents
git add -u
git add .
git add -A

# ✅ ALWAYS — only specific files
git add src/handlers/api.py tests/test_handlers.py

# Before committing — verify scope
git diff --cached --name-only
# If unexpected files appear → git restore --staged <file>
```

**Commit message:**
```
Fix: retry logic for API errors

- Add exponential backoff (1s, 2s, 4s, 8s max)
- Log retry attempts for debugging
- Preserve original error in fallback

Fixes WP-XYZ stage #3

Co-Authored-By: Claude Haiku <noreply@anthropic.com>
```

### Step 4: Peer Review (senior developer)

The senior developer (TD1+TA4) reviews:
- Does the logic match the Work Product specification?
- Do the tests cover edge cases?
- Does the style conform to code-style.md?
- Are there no regressions in neighboring components?

Any issues → return to development (Step 2), do not merge.

## Capture (Dual Output)

At a Work milestone, when code is ready → **what needs to be documented?**

**Rule:** a task without capture = **not closed**. Code alone is not enough.

| What you did | Capture → |
|-------------|-----------|
| New retry-logic pattern | `memory/lessons_retry_patterns.md` — when to use it, trade-offs |
| Found a pitfall (race condition in concurrent write) | `docs/reference_db_concurrency.md` — how we solved it |
| Integrated a new library | `docs/dependencies-changelog.md` + `CONTRIBUTING.md` (versions) |
| Non-standard security decision | `docs/security-decisions.md` + ArchGate profile in archive |

**Announcement before committing:**
```
Capture: Race condition in concurrent updates → docs/reference_db_concurrency.md
Three developers had solved the UPDATE+SELECT mix in one transaction differently.
Committing the solution so the mistake is not repeated.
```

## Common Mistakes (How to Avoid Them)

| Mistake | Cause | Fix |
|---------|-------|-----|
| Claude generated code with an outdated API | library version in context was stale | Before the request: "I am using `requests` v2.31. Show me an example." |
| Two solution options — chose the wrong one | ArchGate was skipped | **Always run ArchGate before implementation** (CLAUDE.md §5) |
| Did not run tests → merge → regression | rushed | After generation → terminal → `pytest` → then read the result |
| Copied code from the internet without adapting | rushing the pull request | Grep imports (your version?). Run the example locally. |
| PII ended up in logs | Claude did not know about sensitivity | Security Gate (CLAUDE.md) — before working with personal data |
| Third duplication instead of a function (P2) | Claude copies instead of factoring | Ask explicitly: "extract the shared logic into a function" |
| Dead code branch (P3) | Claude leaves things "for the future" | Delete without a TODO — if nothing calls it → remove it |

## Example of a Good Session (closed-loop, simple case)

```
[WP-452 Ф2] Write a validator for user_input

Claude: Read the tests. Clarifying questions:
  - Email syntax only (SMTP)?
  - Or also check domain MX records?

Pilot: Syntax only. Nothing further needed.

Claude: [Generates validate_user_input + examples]

Pilot: [Runs pytest in terminal]
  ✅ 12 passed, 0 failed

Claude: ✅ Done. Anything worth capturing?

Pilot: Nothing special. Standard validator.

[Commit] Fix: validate_user_input for WP-452 (Ф2 done)
```

**What worked:**
1. WP Gate BEFORE code (verification class — closed-loop).
2. Claude asked a clarifying question (did not guess).
3. Code was verified against tests immediately.
4. Capture was not required (standard solution).

## Example of a Dangerous Session (do not do this)

```
[WP-500] Rewrite database schema

Claude: Current schema is 3NF. I suggest denormalization for read speed.

Pilot: Sounds logical. Go ahead.

❌ MISTAKES:
- No ArchGate (architectural decision).
- No peer session before writing code.
- No verification: do you actually read Reports frequently?
```

**How to avoid it:**
- ArchGate FIRST for architectural decisions.
- open-loop class → peer session before code, not after.

## Coordination Syntax

**If Claude helped with code:**
```bash
git commit -m "Feature: exponential backoff for API retries

- Implement retry with 1s, 2s, 4s, 8s delays
- Add full unit tests for all scenarios
- Update docs/error-handling.md

Fixes WP-XYZ stage #2.

Co-Authored-By: Claude Haiku <noreply@anthropic.com>"
```

**If you consulted on design:**
In WP-context or peer-session report:
```
[2026-07-24, 14:30] Peer session with Claude — design retry-logic:
- Discussed exponential backoff vs Circuit Breaker.
- Chose exponential (option A — simpler, fits your scale).
- Risk: conflict with LB timeout → assert in tests.
Decision: WP-452 Ф2, merged.
```

## Resources

- **CLAUDE.md §2** — WP Gate, mandatory Opening protocol
- **CLAUDE.md §5** — ArchGate for architectural decisions
- **memory/reference/agent-core.md** — Pull-on-Touch, Git Staging, Status Reporting (full versions)
- **[code-style.md](code-style.md)** — engineering style P0–P5
- **[testing-as-spec.md](testing-as-spec.md)** — tests are written BEFORE code
- **Neighboring files** (`src/handlers/`, `src/db/`) — local patterns for adaptation

---

*Version: 2026-07-24, Ф3. Context: WP-452 (IWE Developer Guide), section 4 (Work).*