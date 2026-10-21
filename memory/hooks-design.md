---
description: IWE hook design principles — trigger = artifact, not TOOL_INPUT text
domains:
- reference
- hooks
horizon: warm
name: hooks-design
originSessionId: WP-273-stage-2
owner: platform
schema_version: 1
status: active
type: reference
valid_from: 2026-04-27
---
# Hooks Design Principles

> **Source:** WP-273 R4.5 fix (Round 4 red-team, 26 Apr).
> **Applies to:** all hooks in `.claude/hooks/*.sh`.

## Principle 1. Trigger = artifact, NOT TOOL_INPUT text

**Anti-pattern:**
```bash
# BAD: trigger on command text
if ! echo "$TOOL_INPUT" | grep -q 'DayPlan\|day-close\|WeekPlan'; then
    exit 0
fi
```

**Problem:** TOOL_INPUT includes paths in `git add`, commit messages, and file content in `cat <<EOF`. As a result, committing a file such as `.claude/skills/day-close/SKILL.md` or a commit message like "fix day-close ordering" triggers DayPlan validation even though DayPlan has not changed. This is a false positive — the user is blocked by an irrelevant check.

**Correct:**
```bash
# GOOD: trigger on staged files (the actual artifact)
STAGED=$(cd "$GOV_PATH" && git diff --cached --name-only 2>/dev/null || echo "")
if ! echo "$STAGED" | grep -qE '^current/DayPlan.*\.md$|^current/WeekPlan.*\.md$'; then
    exit 0
fi
```

**Why:** the artifact (what changes) is not the same as the intent (what the command says). A Hook validates the artifact, not the text. A linter does not run on paths mentioned in a commit message for the same reason.

**Applies to:** PreToolUse hooks, especially those with matcher: Bash + git operations.

## Principle 2. Hook responsibility boundary

A Hook must:
- ✅ Validate ONE class of artifacts (DayPlan, WeekPlan, …) — single responsibility
- ✅ Return a chunked decision (block/warn/ok) with a specific reason
- ❌ NOT modify files (read-only under the PreToolUse contract)
- ❌ NOT make network calls (slow + race condition)

## Principle 3. Idempotency

A Hook must return the same result on repeated calls against the same state. If a Hook depends on external state (env-var, git-status), that dependency is part of its trigger. If it depends on runtime semantics (random, timestamp), that is an anti-pattern.

## Principle 4. Fail open for non-blocking checks

If a Hook cannot determine the result — for example, `jq` is missing or `$IWE_GOVERNANCE_REPO` is not set — output `echo '{}'` and `exit 0`. Do not block. Skipping validation is preferable to blocking a user's commit because of an Infrastructure failure.

## Application

- All new hooks → follow Principles 1–4
- All existing hooks → verify with `integration-contract-validator.sh` (detector Phase12.5 — grep `TOOL_INPUT.*grep` in `.claude/hooks/*.sh`)
- On violation: Refactoring as in `protocol-artifact-validate.sh` (R4.5 fix, WP-273 commit 0.29.0)
