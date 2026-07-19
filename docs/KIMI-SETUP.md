---
scope: FMT-exocortex-template
status: active
title: Connecting Kimi to IWE
updated: 2026-06-17
---

# Connecting Kimi to IWE

> Audience: a pilot who has forked the `FMT-exocortex-template` and wants to work with IWE through Kimi Code.
> Time: ~15 minutes.
> Source-of-truth: `AGENTS.md`, `.claude/skills/kimi-peer-writer/SKILL.md`, `.claude/skills/peer-conversation/SKILL.md`.

## What You Get

- Kimi Code reads `AGENTS.md` when the repository is opened and applies IWE rules.
- Kimi sees the IWE skills (`/kimi-peer-writer`, `/peer-conversation`, and others).
- You can run peer sessions where Kimi acts as writer or Peer partner.

## Prerequisites

- VS Code.
- The **Kimi Code** extension installed (Moonshot AI).
- The `FMT-exocortex-template` forked and cloned.
- The **Claude Code CLI** (`claude`) installed — required for peer sessions where Kimi calls Claude.

Verify that `claude` is available:

```bash
which claude
```

If the command returns nothing, install the Claude Code CLI before starting peer sessions.

## How Kimi Learns the IWE Rules

The file `AGENTS.md` in the repository root is read automatically by Kimi Code when the repository is opened in VS Code. It contains:

- WP Gate — the opening ritual for each work item.
- Git staging rules.
- Response style for the pilot.
- Commit rules when Kimi is involved.
- Coordination through the MCP Gateway.

Kimi-specific customizations go into `extensions/` or `AGENTS-agent-blocks.md`.

## Configuring IWE Skills

By default, Kimi Code looks for skills in standard paths (`~/.kimi/skills/`, `<git-root>/.kimi/skills/`). IWE skills live in `.claude/skills/` inside your repository, so you need to register them manually.

Open `~/.kimi/config.toml` and add the path to `.claude/skills` of your repository to the `extra_skill_dirs` array:

```toml
merge_all_available_skills = true
extra_skill_dirs = [
  "/path/to/FMT-exocortex-template/.claude/skills",
  # other paths, if any already exist
]
```

Important notes:

- `~/.kimi/config.toml` is a personal file on your machine. **Do not commit it** to the repository.
- If `extra_skill_dirs` already contains paths (for example, to `.kimi/skills` of your governance repository), **add** the new path to the array — do not replace existing entries.
- The array must point to `.claude/skills` of **your repository**, not to `.kimi/skills`. These are different directories.
- If the path contains spaces or special characters, wrap it in quotes.
- After saving, restart the Kimi Code window or refresh the skills list.

## Verifying the Connection (Smoke Test)

Run three checks:

1. **Claude CLI is available**:

   ```bash
   which claude
   ```

2. **IWE skill files are in place**:

   ```bash
   ls /path/to/FMT-exocortex-template/.claude/skills/kimi-peer-writer/SKILL.md
   ls /path/to/FMT-exocortex-template/.claude/skills/peer-conversation/SKILL.md
   ```

3. **The skill responds in Kimi Code**:

   In the Kimi chat, enter:

   ```
   /kimi-peer-writer --list
   ```

   If the skill is connected, you will see the peer session log from `sessions/00-index.md`.

If `/kimi-peer-writer --list` does not work, verify that `extra_skill_dirs` points to `.claude/skills` and that `merge_all_available_skills = true`.

## Operating Modes

### Kimi = Writer, Claude = Peer Partner

Skill: `/kimi-peer-writer` (`.claude/skills/kimi-peer-writer/SKILL.md`).

Triggers:

- "start peer session"
- "together with Claude"
- "with Claude"
- "bring in Claude"
- slash `/peer-writer`

Kimi initiates the Session, writes the opening position, calls Claude via `scripts/claude-peer-adapter.sh`, runs the turn-loop until consensus, and — on the pilot's decision — implements the result.

### Kimi = Peer Partner, Claude = Writer

Skill: `/peer-conversation` (`.claude/skills/peer-conversation/SKILL.md`).

Triggers:

- "start peer session"
- "peer session"
- slash `/peer-conversation`

Claude initiates the Session and calls Kimi via `scripts/kimi-peer-adapter.sh`.

### Kimi Standalone (Without Claude)

Kimi works alone, without a Peer partner — for scheduled headless tasks (`kimi-wp-queue.sh`) or manual standalone sessions.

- `scripts/session-guard.sh open --wp WP-N --task "..." --agent kimi` — required Session opening before any edits.
- `scripts/kimi-standalone-preflight.sh` — hard gate: checks that a Session is open and not stale (threshold `IWE_SESSION_STALE_THRESHOLD`, default 30 min), stops execution if not.
- `scripts/kimi-auto-heartbeat.sh --interval 120` — background heartbeat immediately after opening a Session, so that `kimi-session-watchdog.sh` does not treat the Session as hung.
- `scripts/kimi-whisper-safe.sh` — safe audio transcription wrapper (see `docs/PLATFORM-COMPAT.md`, optional dependencies `ffmpeg`/`openai-whisper`).

## Handoff With Claude

When a task is transferred between Kimi and Claude, use one of the mechanisms from `docs/inter-agent-handoff.md`:

- **Git commits + `Co-Authored-By`** — for tasks longer than 30 minutes:

  ```bash
  git commit -m "feat: ..." \
    --trailer "Co-Authored-By: Kimi <noreply@moonshot.ai>" \
    --trailer "Co-Authored-By: Claude <noreply@anthropic.com>"
  ```

- **`.handoff.md` bridge file** — for fast Iteration cycles of 5–15 minutes.
- **Branch-based relay** — for complex tasks involving multiple agents.

## Troubleshooting

1. Check the path in `extra_skill_dirs` — it must point to `.claude/skills` of your repository.
2. Verify that `merge_all_available_skills = true`.
3. Restart the Kimi Code window.
4. Confirm that the `claude` CLI is installed (`which claude`).
5. Check the peer session log: `sessions/00-index.md`.

## Related Documents

- `AGENTS.md` — rules for all agents.
- `docs/inter-agent-handoff.md` — context transfer between agents.
- `.claude/skills/kimi-peer-writer/SKILL.md` — Kimi as writer.
- `.claude/skills/peer-conversation/SKILL.md` — Kimi as Peer partner.
- `docs/skills-catalog.md` and `docs/scripts-catalog.md` — skill and Script catalogs.

