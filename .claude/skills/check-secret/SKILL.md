---
argument-hint: <text-or-file-path>
browser_safe: false
description: Check a text fragment for potential secrets (API keys, tokens, passwords)
  BEFORE sending to chat / committing / publishing. Second protection layer on top
  of the pre-commit hook — manual gate, user explicitly calls on potentially sensitive
  text.
layer: L1
name: check-secret
routing:
  deterministic: true
  executor: script
  optimization_priority: 2
  script_path: .claude/skills/check-secret/check.sh
status: active
triggers:
  phrases: []
  slash:
  - /check-secret
version: 1.0.0
---

# Check Secret — manual gate (WP-212)

> **Principle (issue #410, updated 2026-08-12):** the delivery includes exactly one automatic layer — the pre-commit hook (`scripts/pre-commit-secret-scan.sh`), which checks only what enters a git commit. This Skill closes the adjacent gap — **checking arbitrary text before publication** (commit message, Slack post, docs paragraph, chat response) that will never go into a commit and therefore bypasses the hook. B7.7a (Bash command block with secrets) and B7.7b (PostToolUse redact tool output) do not exist in the delivery — if they appear, restore the "third layer" wording.
>
> **Covered patterns:** Better Stack `ust_`, Telegram bot token, hex secret in env, Neon `napi_`, DATABASE_URL with user:pass, Anthropic `sk-ant-api`, GitHub `ghp_/gho_/ghs_/ghr_/ghu_`, AWS `AKIA`, generic 40+ char API token.
>
> **Architectural Constraint** (see B7.7 in WP-212): does not cover Claude-generated text without tool-use — that requires an external wrapper over Claude Code.

## Step 1. Receive input

The `$ARGUMENTS` value is **either**:
- (a) **a file path** (if `$ARGUMENTS` exists as a file) — read the file contents;
- (b) **the text itself** (inline) — use as-is.

If no argument is provided — ask the user to paste the text.

## Step 2. Run the check

```bash
bash "$IWE_SCRIPTS/route-task.sh" --skill check-secret --args "$ARGUMENTS"
```

The Script accepts either a path or text. It returns:
- exit 0 + `OK: no secrets detected` — if nothing is found;
- exit 1 + list of matched patterns with line numbers — if potential secrets are found.

## Step 3. Interpret the result

**If OK:** report "✅ Text is safe to publish" — the user may commit / post.

**If secrets are found:**
1. List the matched patterns (with labels: Neon API key, GitHub token, etc.).
2. For each one — provide a recommendation:
   - If it is a placeholder / test value / documentation — add a `# secret-ok` marker on the line or use a `[REDACTED]` placeholder.
   - If it is a real secret — do NOT publish; run cascade rotation (see `DP.RUNBOOK.003-cascade-secret-rotation.md`); see rule 25 in `feedback_behaviour.md`.
3. After redaction — repeat the check.

## Step 4. Log

Each Skill invocation is logged to `${IWE_WORKSPACE:-$HOME/IWE}/.claude/logs/check-secret.jsonl` (metadata only: timestamp, argument hash, decision; **not the secrets themselves**).

## Relations

- **Protection layers (issue #410, updated 2026-08-12):** exactly two, not three — the pre-commit hook (`scripts/pre-commit-secret-scan.sh`, automatic) and this Skill (manual, before pasting into chat or publishing). B7.7a (Bash block) and B7.7b (PostToolUse redact) do not exist in the delivery — if they appear, add them here as the third layer.
- **Behavioral rule:** secrets are never published to chat as plaintext (if a personal behavioral rules log is maintained — record this there as well).
- **Runbook:** `DP.RUNBOOK.003-cascade-secret-rotation.md` for the reactive rotation procedure.
- **Pattern canon:** `$IWE_SCRIPTS/pre-commit-secret-scan.sh` — single source of truth for regex patterns; check.sh uses the same set.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
