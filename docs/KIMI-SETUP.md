---
scope: FMT-exocortex-template
status: active
title: Connecting Kimi to IWE
updated: 2026-06-17
---

# Connecting Kimi to IWE

> Audience: a pilot who has forked the `FMT-exocortex-template` and wants to work with IWE via Kimi Code.
> Time: ~15 minutes.
> Source-of-truth: `AGENTS.md`, `.claude/skills/kimi-peer-writer/SKILL.md`, `.claude/skills/peer-conversation/SKILL.md`.

## What You Get

- When you open the repo, Kimi Code reads `AGENTS.md` and applies IWE rules.
- Kimi sees IWE skills (`/kimi-peer-writer`, `/peer-conversation`, and others).
- You can run peer sessions where Kimi acts as writer or Peer partner.

## Prerequisites

- VS Code.
- The **Kimi Code** extension installed (Moonshot AI).
- The `FMT-exocortex-template` forked and cloned.
- **Claude Code CLI** (`claude`) installed — required for peer sessions where Kimi calls Claude.

Verify that `claude` is available:

```bash
which claude
```

If the command returns nothing — install Claude Code CLI before starting peer sessions.

## How Kimi Learns IWE Rules

The `AGENTS.md` file in the repo root is read automatically by Kimi Code when you open the repository in VS Code. It contains:

- WP Gate — the opening ritual for each task.
- Git staging rules.
- Response style for the pilot.
- Commit rules involving Kimi.
- Coordination via MCP Gateway.

Customizations specific to Kimi go in `extensions/` or `AGENTS-agent-blocks.md`.

## Setting Up IWE Skills

By default, Kimi Code looks for skills in standard paths (`~/.kimi/skills/`, `<git-root>/.kimi/skills/`). IWE skills live in `.claude/skills/` in your repo, so you need to connect them manually.

Open `~/.kimi/config.toml` and add the path to `.claude/skills` in your repo to the `extra_skill_dirs` array:

```toml
merge_all_available_skills = true
extra_skill_dirs = [
  "/path/to/FMT-exocortex-template/.claude/skills",
  # other paths, if any already exist
]
```

Important:

- `~/.kimi/config.toml` is a personal file on your machine — do **not** commit it to the repo.
- If `extra_skill_dirs` already contains paths (for example, to `.kimi/skills` in your governance repo) — **add** the new path to the array. Do not replace existing entries.
- The array must contain the path to `.claude/skills` in **your repo**, not to `.kimi/skills`. These are different directories.
- If the path contains spaces or special characters, wrap it in quotes.
- After saving, restart the Kimi Code window or refresh the skills list.

## Connection Check (Smoke Test)

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

3. **Skill responds in Kimi Code**:

   In the Kimi chat, enter:

   ```
   /kimi-peer-writer --list
   ```

   If the skill is connected, you will see the peer session log from `sessions/00-index.md`.

If `/kimi-peer-writer --list` did not work, verify that `extra_skill_dirs` points to `.claude/skills` and that `merge_all_available_skills = true`.

## Operating Modes

### Kimi = writer, Claude = Peer partner

Skill: `/kimi-peer-writer` (`.claude/skills/kimi-peer-writer/SKILL.md`).

Triggers:

- "start peer session"
- "together with Claude"
- "with Claude"
- "bring in Claude"
- slash `/peer-writer`

Kimi initiates the session, writes the initial position, calls Claude via `scripts/claude-peer-adapter.sh`, runs the turn-loop until consensus, and implements the result on the pilot's decision.

### Kimi = Peer partner, Claude = writer

Skill: `/peer-conversation` (`.claude/skills/peer-conversation/SKILL.md`).

Triggers:

- "start peer session"
- "peer session"
- slash `/peer-conversation`

Claude initiates the session and calls Kimi via `scripts/kimi-peer-adapter.sh`.

## Handoff with Claude

When a task is passed between Kimi and Claude, use one of the mechanisms from `docs/inter-agent-handoff.md`:

- **Git commits + `Co-Authored-By`** — for tasks longer than 30 minutes:

  ```bash
  git commit -m "feat: ..." \
    --trailer "Co-Authored-By: Kimi <noreply@moonshot.ai>" \
    --trailer "Co-Authored-By: Claude <noreply@anthropic.com>"
  ```

- **`.handoff.md` bridge file** — for quick iterations of 5–15 minutes.
- **Branch-based relay** — for complex tasks involving multiple agents.

## Troubleshooting

1. Check the path in `extra_skill_dirs` — it must point to `.claude/skills` in your repo.
2. Confirm that `merge_all_available_skills = true`.
3. Restart the Kimi Code window.
4. Verify that the `claude` CLI is installed (`which claude`).
5. Check the peer session log: `sessions/00-index.md`.

## Related Documents

- `AGENTS.md` — rules for all agents.
- `docs/inter-agent-handoff.md` — context handoff between agents.
- `.claude/skills/kimi-peer-writer/SKILL.md` — Kimi as writer.
- `.claude/skills/peer-conversation/SKILL.md` — Kimi as Peer partner.
- `docs/skills-catalog.md` and `docs/scripts-catalog.md` — skill and script catalogs.

