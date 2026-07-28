---
scope: FMT-exocortex-template
status: active
title: Connecting a New AI Agent to IWE (Vendor-Agnostic)
updated: 2026-07-28
---

# Connecting a New AI Agent to IWE

> Audience: a pilot who wants to connect **any** AI agent vendor to their `FMT-exocortex-template` fork — Claude Code, Kimi Code, Codex, Hermes, a ChatGPT extension, or any other file-based CLI/IDE agent not yet covered by a dedicated guide.
> Time: ~15–30 minutes, depending on whether the agent supports MCP out of the box.
> Verified in practice (28.07.2026) with 4 different agents running simultaneously (Claude, Kimi, Codex, Hermes) — coordinated on shared files without conflicts.

This document is written so that **the agent itself** (not only the human) can read it and complete the connection independently — without assuming anything is "already known" about a specific vendor.

## What You Get

- When a new agent opens the repository, it reads `AGENTS.md` and applies the common IWE rules.
- If the agent edits repository files simultaneously with other agents, it coordinates with them through the shared local lock gateway without overwriting others' changes.
- The agent's commits carry correct attribution (it is visible which agent changed what).

## Step 1. Read AGENTS.md

The `AGENTS.md` file in the repository root is the common minimum ruleset for any file-based agent — it is not vendor-specific. Most modern CLI agents (Claude Code, Codex, Kimi, Cline) read it automatically when opening the directory; no additional configuration is needed.

**Verification:** open the repository with the new agent and ask it directly — "did you read AGENTS.md in the repository root? List 3 rules from it." If the agent cannot answer, check whether it supports automatic reading of instruction files in the repo root (some vendors require a separate setting — see the agent's documentation for keywords such as "project instructions", "system prompt from file", "AGENTS.md support").

## Step 2. Determine Whether File Coordination Is Needed

Coordination is needed if another agent can work on the same repository files at the same time as this agent (a human + Claude, or multiple CLI agents in parallel).

Coordination is not needed if the agent works solo and never overlaps with others on the same files — in that case, skip Steps 3–4 and go directly to Step 5.

## Step 3. Connect the Agent to the Local Lock Gateway

IWE uses a local MCP server (`DS-MCP/local-gateway`) that maintains a shared file lock manager. Any agent that supports MCP (Model Context Protocol) as a client can connect to it.

### 3.1. Check Whether the Agent Supports an MCP Client

Ask the agent's documentation or the agent itself: "do you support connecting to external MCP servers as a client, and can you pass environment variables when starting the server?"

If yes, the agent typically has a subcommand such as `<agent> mcp add` or a configuration file (`config.toml`, `config.yaml`, `settings.json`) where a new MCP server entry is added.

### 3.2. Find the Local Gateway Launch Command

The launch command is `node` plus the path to the compiled `proxy.js` file at `DS-MCP/local-gateway/dist/proxy.js` inside your IWE clone. Get the exact absolute path from the existing entry in your repository's `.mcp.json` (Claude Code and possibly other agents are already registered there) — copy the `command` and `args` values from that entry.

If `.mcp.json` is empty or the local gateway is not yet listed there, the path is always:

```
node <absolute-path-to-your-IWE>/DS-MCP/local-gateway/dist/proxy.js
```

### 3.3. Register the Agent with a Unique IWE_AGENT_ID

Each agent receives its own unique identifier via the `IWE_AGENT_ID` environment variable — the local gateway uses it to distinguish which agent holds a file lock. The identifier is a short name with no spaces (for example: `codex`, `hermes`, `kimikode`, `chatgpt`).

**General registration syntax (replace placeholders for the specific agent):**

```
<agent-command> mcp add iwe-local-gateway --env IWE_AGENT_ID=<unique-agent-name> -- node <path-to-proxy.js>
```

**Three verified examples** (different agents, different registration syntax — the same general principle applies):

```bash
# Codex (standard --env flag for stdio MCP servers)
codex mcp add iwe-local-gateway --env IWE_AGENT_ID=codex -- node /path/to/IWE/DS-MCP/local-gateway/dist/proxy.js

# Hermes (separate --command/--args/--env flags)
hermes mcp add iwe-local-gateway --command node --args /path/to/IWE/DS-MCP/local-gateway/dist/proxy.js --env IWE_AGENT_ID=hermes

# Kimi (via MCP client config file, not a CLI subcommand — see docs/KIMI-SETUP.md)
```

If your agent has neither an `mcp add` CLI subcommand nor a configuration file for MCP clients, it **does not support MCP as a client**, and file coordination through the local gateway cannot be configured by technical means. In that case, the agent can participate only at Step 1 (reading AGENTS.md), without file coordination — tell the user this directly; do not invent a workaround.

### 3.4. Verify Registration

```bash
<agent> mcp list
```

The output must include an `iwe-local-gateway` entry. If the agent supports calling MCP tools directly from chat, try calling `gateway_status` — the response must return `locks: []` (an empty list of active locks) when no agent currently holds a file lock.

## Step 4. Configure the Commit Attribution Line

Add a trailer to the agent's configuration (or use a flag at commit time) in the following form:

```
Co-Authored-By: <Agent Name> <noreply@vendor-domain>
```

Examples:
- `Co-Authored-By: Codex <noreply@openai.com>`
- `Co-Authored-By: Hermes <noreply@aisystant.com>`
- `Co-Authored-By: Kimi <noreply@moonshot.cn>`

If you are unsure of the correct vendor domain, use the official domain of the agent's product. After the first real commit, verify that the email does not look like a spam address and does not trigger errors in the repository's git hooks.

## Step 5. Point the Agent to IWE Skills (Optional)

If the agent has its own mechanism for loading additional instructions or skills (analogous to `.claude/skills/` in Claude Code), point it to the `.claude/skills/` directory in your repository — the same way it is done for Kimi (`extra_skill_dirs` in `~/.kimi/config.toml`, see `docs/KIMI-SETUP.md`).

If no such mechanism exists, skip this step. It does not block the rest of the agent's work.

## Connection Verification (Smoke Test)

Run on a real small task:

1. **The agent sees AGENTS.md** — ask the agent directly, as described in the Step 1 verification.
2. **If gateway coordination is configured** — `<agent> mcp list` shows `iwe-local-gateway`.
3. **A real file edit with locking** (only if you configured coordination):
   - Ask the agent to call `acquire_file_lock` on any test file, make a small edit, create a commit with the correct trailer, and call `release_file_lock`.
   - Check the commit: `git log -1 --format="%H %s%n%b"` — it must contain `Co-Authored-By` with the correct name and domain.
   - Verify the lock is released: calling `gateway_status` must again return `locks: []`.

If any of these checks fail, do not connect the agent to file coordination until you identify the cause. An agent that commits without attribution or does not release locks creates confusion for other agents in the repository.

## Difference From "Orchestrating an Agent as a Peer Partner"

Do not confuse this connection with the wrapper adapter (`*-peer-adapter.sh`), where one agent calls another as a subordinate Peer partner in headless mode within a peer session (one writes, the other critiques, and the entire dialogue is orchestrated by the first agent). That is a different scenario — the calling agent orchestrates the called agent, rather than two independent MCP clients coordinating as equals through locks. The connection described in this document makes the new agent an independent participant in the repository, not a subprocess subordinate to another agent.

## If Something Does Not Work

1. Verify that the path to `proxy.js` in the registration command is absolute and matches the actual location of your `DS-MCP/local-gateway` clone.
2. Verify that `IWE_AGENT_ID` in the registration command is unique and does not match any already-connected agents (run `<agent> mcp list` for each already-connected agent).
3. If the agent does not support an MCP client at all, file coordination is technically impossible for it — limit it to Step 1 (AGENTS.md).
4. Check the `gateway_status` output — a stuck lock (`locks` is not empty after a long time) typically means the previous agent did not call `release_file_lock` after committing.

## Related Documents

- `AGENTS.md` — common rules for all agents.
- `docs/KIMI-SETUP.md` — specifics of connecting Kimi Code (a detailed example for Step 5).
- `docs/inter-agent-handoff.md` — passing context between agents without a shared gateway.
- `memory/agent-vendor-connect-pattern.md` — a concise technical card for the same pattern (reference format for agent Memory, not a step-by-step guide for humans).

