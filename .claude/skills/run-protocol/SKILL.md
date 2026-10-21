---
argument-hint: '[open|close] [day|session]'
browser_safe: false
description: Step-by-step execution of the OWC protocol with mandatory checkpoint
  at each step. Prevents skipping steps (including Verification).
name: run-protocol
routing:
  deterministic: false
  executor: sonnet
---

# Protocol Execution

> **Principle:** A Protocol is a sequence of Steps. Mark each Step complete before moving to the next. Skipping Steps is not allowed.
> **Problem solved:** The agent "forgets" final Steps (Verification, Backup) due to context contamination (SOTA.002).

**Arguments:** $ARGUMENTS

## Step 1. Identify the Protocol

| Argument | Routing (short) | Full algorithm |
|----------|----------------|----------------|
| `day-open` / `open day` | `memory/protocol-open.md` (§ Scope: Day) | `.claude/skills/day-open/SKILL.md` |
| `open session` or task | `memory/protocol-open.md` (§ Scope: Session) | — (inline in protocol-open.md) |
| `day-close` / `close day` | `memory/protocol-close.md` (§ Routing) | `.claude/skills/day-close/SKILL.md` |
| `close session` | `memory/protocol-close.md` (§ Quick Close) | — (inline in protocol-close.md) |
| `week-close` | `memory/protocol-close.md` (§ Routing) | `.claude/skills/week-close/SKILL.md` |

> If a Skill file exists for the argument → read it (contains the full algorithm and checklist). The protocol file is a slim router + Quick Close inline.

## Step 1b. Load extensions (BLOCKING)

Identify the protocol name: `day-open`, `day-close`, `week-close`, `protocol-close`, `protocol-open`.

Check and read (if they exist):
1. `extensions/{protocol}.before.md` → add as the **first** Steps in TodoWrite
2. `extensions/{protocol}.after.md` → add as Steps **after** the main algorithm, **before** Verification
3. `extensions/{protocol}.checks.md` → add as a Step **before git commit** (BLOCKING: commit is forbidden until checks pass)

Does not exist → skip silently. Exists → read and include in the plan.

## Step 2. Extract Steps

From the protocol algorithm (Skill file or protocol file) and extensions, extract a numbered list of Steps. Record them as tasks (TodoWrite; the tool may be unavailable in the session — on models newer than Sonnet 4.6 it is disabled by the client by default, enabled via the `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` variable in the `env` settings (issue #1216); until then, or on installations without this variable, track the same Steps using explicit numbering in responses, marking each one complete before moving to the next, and notify the pilot in one line — issues #561, #563):

Task order:
1. Extensions `.before.md` (if present)
2. Main Steps from the algorithm
3. Extensions `.after.md` (if present)
4. Extensions `.checks.md` + git commit (if there is an Artifact to commit)
5. Closing Verification (sub-agent Haiku R23 against the closing checklist) — closing Protocols only, see Step 4

- Each main Step = a separate task
- For closing Protocols, the last task = "Closing Verification (sub-agent Haiku R23)"; opening and other Protocols do not include this task
- Status: pending

## Step 3. Execute Sequentially

For each Step:
1. Mark the Step as `in_progress`
2. Execute it
3. Mark it as `completed`
4. Move to the next Step

**BLOCKING:** Do NOT skip Steps. If a Step is impossible — mark it as blocked and ask the user.

## Step 4. Closing Verification (closing Protocols only)

This Step applies only during closing: Quick Close (`close`, `close session`), Day Close, Week Close, Month Close. Opening and other Protocols do not include R23 Verification; skip this Step.
Quick Close: if `params.yaml` has `verify_quick_close: false` — skip this Step. Day Close, Week Close, and Month Close are not subject to this key.

After all closing Steps are complete:
1. Launch sub-agent Haiku in the R23 role (context isolation): pass the closing checklist (from the protocol or closing Skill), the list of modified files, and a brief summary
2. R23 compares execution against the closing checklist
3. For each ❌ — fix the issue BEFORE showing the result to the user

## Rules

- Only one Step `in_progress` at a time
- Do not run ahead — context becomes contaminated (SOTA.002)
- Record Protocol Steps as work progresses, not at the moment of compression: the agent receives nothing on PreCompact. The `precompact-checkpoint.sh` Hook takes a snapshot of the conversation turns (outside the project, at `$CLAUDE_CONFIG_DIR/iwe-checkpoints/`); `precompact-restore.sh` restores it after compression — but only what has already appeared in the most recent turns, not the Protocol Step separately
- If the Protocol is interrupted by the user — write the remaining Steps to a checkpoint
