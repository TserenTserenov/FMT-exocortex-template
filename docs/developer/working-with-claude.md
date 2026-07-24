# Working With Claude in Development

> For developers using the Claude Code adapter when writing or editing IWE code. Referenced from [developer-guide.md](developer-guide.md) at station 4 (Work) — alongside [testing as specification](testing-as-spec.md) and [engineering code style](code-style.md), which Claude must follow in your Session no less than you do yourself.

## When Claude Is Useful, When Claude Is Dangerous

**Useful:**
- Mechanical work against a known contract — migrating N files by one pattern, Refactoring to an already agreed-upon Interface, writing boundary tests (see [testing-as-spec.md](testing-as-spec.md)).
- Exploring the codebase before making changes — "where is this already implemented", "what calls this function".
- Drafting where you already know how to verify the result (closed-loop task — a test or checklist exists).

**Dangerous:**
- Tasks where the problem framing itself is unclear (open-loop) — Claude will readily propose a solution to a misunderstood problem without asking.
- Code at system boundaries without an explicit contract — without a specification, Claude guesses the boundary instead of reading it from your intent.
- Anything you cannot verify quickly yourself — if reviewing the solution takes longer than writing it yourself, the delegation did not pay off.

## Prompt Patterns: "Explain First" vs "Write Directly"

**"Explain how you will do it, then write"** — for non-trivial work: a new function with side effects, an edit at a Module boundary, anything where discovering the wrong direction after the fact is costly. Ask for a 3–5 point plan before any code. If the plan is wrong, catching it before 200 lines are written is cheaper than catching it after.

**"Write directly"** — for trivial and reversible work: a one-line fix, a test against an already described specification, a rename from an explicit list. An intermediate explanation here wastes time for both sides.

**How to recognize you chose the wrong mode:** if after "write directly" you spend more time understanding the diff than an upfront explanation would have taken — use the plan-first approach next time.

## Stop Signals: When Claude Writes Dead Code

- **A third repetition instead of a function (P2, [code-style.md](code-style.md)).** Claude tends to copy a similar block a third time instead of proposing a shared function — ask explicitly: "extract the shared logic", if you see a third near-duplication.
- **A dead branch "for compatibility" (P3).** Asking "do not delete the old path, it might be needed" with no real consumer — that is exactly the P3 smell. If nothing calls the branch, it must be removed, not left marked TODO.
- **Abstraction for a hypothetical future.** A mode flag, a "future-use" parameter, an Interface for a second consumer that does not yet exist — Claude eagerly designs extensibility no one requested. Ask: "who uses this today?"
- **Error handling for a scenario that cannot occur.** A `try/except` around an internal call that cannot fail by contract — extra code that hides real bugs under a silent `pass`.

## Pre-Merge Checklist: What to Verify Manually, What to Leave to Claude

**Leave to Claude (reliable and cheap to re-check):**
- Formatting, linter (P0) — mechanical verification.
- Conformance to an already written test specification (boundary contract from testing-as-spec.md).
- List of changed files and a brief diff summary.

**Verify manually — do not trust Claude's report of "done and working":**
- **The system boundary** — Claude may write a test that passes but checks the wrong thing (see the stop signal in testing-as-spec.md: a test that breaks when the implementation is replaced with an equivalent → it tests an implementation detail, not the contract).
- **Side effects outside the announced list of files** — run `git diff --stat` in full, not only the files discussed.
- **Secrets and credentials in the diff** — Claude sometimes logs environment variable values during debugging; grep for token patterns before committing.
- **The real failure scenario** — "what happens if the network is unavailable / input is empty / file does not exist" — Claude writes the happy path by default unless you explicitly request failure mode handling.
- **Double exit** (see [developer-guide.md](developer-guide.md) station 4) — code without captured Knowledge (Distinction/Memory/Pack) is considered unclosed. Claude will not stop you at this step on its own unless you explicitly ask "what is worth capturing here".

## Source

This section was written as an extension of the testing methodology (a session with an external expert; the Protocol lives in your governance repository, `{{GOVERNANCE_REPO}}/inbox/`) and hands-on experience working with the Claude Code adapter in IWE development.

