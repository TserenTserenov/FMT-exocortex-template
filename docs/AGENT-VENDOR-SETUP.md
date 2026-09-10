---
scope: FMT-exocortex-template
status: active
title: Connecting a New AI Agent to IWE (Vendor-Agnostic)
updated: 2026-07-29
---

# Connecting a New AI Agent to IWE

> Audience: a pilot who wants to connect **any** AI agent vendor to their fork of `FMT-exocortex-template` — Claude Code, Kimi Code, Codex, Hermes, a ChatGPT extension, or any other file-based CLI/IDE agent not yet covered by a dedicated guide.
> Time: ~15–30 minutes, depending on whether the agent supports MCP out of the box.
> Verified live (2026-07-28) on 4 different agents simultaneously (Claude, Kimi, Codex, Hermes) — coordination on shared files with no conflicts.

This document is written so that **the agent itself** (not just the human) can read it and complete the connection independently — without assuming anything is "already known" about a specific vendor.

## What You Get

- When opening the Repository, the new agent reads `AGENTS.md` and applies the common IWE rules.
- If the agent edits Repository files at the same time as other agents, it coordinates with them through a shared local lock gateway and does not overwrite others' changes.
- The agent's commits carry correct attribution (showing which agent made which change).

## Step 1. Read AGENTS.md

The `AGENTS.md` file in the Repository root is the common minimum rule set for any file-based agent (not vendor-specific). Most modern CLI agents (Claude Code, Codex, Kimi, Cline) read it automatically when opening a directory — no separate Configuration is needed.

**Verification:** open the Repository with the new agent and ask it directly — "Did you read `AGENTS.md` in the Repository root? List 3 rules from it." If the agent cannot answer, check whether it supports automatic reading of instruction files in the repo root (some vendors make this a separate setting — see the agent's documentation under keywords such as "project instructions", "system prompt from file", "AGENTS.md support").

### 1.1. If Auto-Loading Is Not Available (verified on Hermes)

Some agents (for example Hermes) do not read `AGENTS.md` automatically at all, and there is no separate setting for this. The verification above will consistently return "no" — do not look for a hidden flag. Instead, ask the agent explicitly as the first message:

> "Read the file `AGENTS.md` in the Repository root and follow the rules stated there. Confirm that the file has been read and list 3 rules from it."

After that, the agent typically behaves normally for the rest of the Session without further reminders — the instruction itself is retained; only the fact that it needed to be explicitly requested is not remembered. If the Repository tree contains multiple `AGENTS.md` files, the more specific one (deeper in the directory tree) takes Priority — the same as for any agent with auto-loading.

## Step 2. Determine Whether File Coordination Is Needed

Coordination is needed when another agent (human + Claude, or multiple CLI agents in parallel) may work on the same Repository files at the same time as this agent.

Coordination is not needed when the agent works solo and never overlaps with others on the same files — in that case, skip Steps 3–4 and go directly to Step 5.

## Step 3. Connect the Agent to the Local Lock Gateway

IWE uses a local MCP server (`DS-MCP/local-gateway`) that maintains a shared file-lock manager. Any agent that supports MCP (Model Context Protocol) as a client can connect to it.

### 3.1. Check Whether the Agent Supports an MCP Client

Ask the agent's documentation or the agent itself: "Do you support connecting to external MCP servers as a client, and can you pass environment variables when starting the server?"

If yes, the agent usually has a subcommand such as `<agent> mcp add` or a Configuration file (`config.toml`, `config.yaml`, `settings.json`) where a new MCP server entry is added.

### 3.2. Find the Local Gateway Start Command

If your Repository's `.mcp.json` already contains an `iwe-local-gateway` entry (someone connected the gateway previously), copy the `command` and `args` from there — that is the fastest path.

If no entry exists yet, the gateway itself is most likely not installed either (it is not included in the Template directly; it is a separate dependency with its own version lifecycle). Install it:

```bash
bash setup/optional/setup-local-gateway.sh
```

The Script clones the gateway at a pinned version, builds it, starts the daemon, and prints a ready-to-use `command`/`args`/`env` block for insertion into `.mcp.json` — use that block in Step 3.3 below. The path to `proxy.js` in that block is `node <absolute-path-to-your-IWE>/DS-MCP/local-gateway/dist/proxy.js`.

**Important:** `env.IWE_AGENT_ID` in the printed block is set to the agent that ran the Script (or `claude-code` by default). When registering the **second or subsequent** agent, replace this value with a unique name for each agent (see Step 3.3 below). The same `IWE_AGENT_ID` on different agents silently breaks lock coordination.

### 3.3. Register the Agent with a Unique IWE_AGENT_ID

Each agent receives its own unique identifier through the `IWE_AGENT_ID` environment variable. The local gateway uses this to distinguish which agent holds the lock on a file. The identifier is a short name with no spaces (for example `codex`, `hermes`, `kimikode`, `chatgpt`).

**General registration syntax (replace placeholders for your specific agent):**

```
<agent-command> mcp add iwe-local-gateway --env IWE_AGENT_ID=<unique-agent-name> -- node <path-to-proxy.js>
```

**Three verified examples** (different agents, different registration syntax — the same underlying principle):

```bash
# Codex (standard --env flag for stdio MCP servers)
codex mcp add iwe-local-gateway --env IWE_AGENT_ID=codex -- node /path/to/IWE/DS-MCP/local-gateway/dist/proxy.js

# Hermes (separate --command/--args/--env flags)
hermes mcp add iwe-local-gateway --command node --args /path/to/IWE/DS-MCP/local-gateway/dist/proxy.js --env IWE_AGENT_ID=hermes

# Kimi (via MCP client config, not a CLI subcommand — see docs/KIMI-SETUP.md)
```

If your agent has neither an `mcp add` CLI subcommand nor a config file for MCP clients, it **does not support MCP as a client**, and the local gateway coordination cannot be configured for it by technical means. In that case, the agent can participate only at Step 1 (reading `AGENTS.md`), without file coordination. State this to the user directly; do not invent a workaround.

### 3.4. Verify the Registration

```bash
<agent> mcp list
```

The output must show an `iwe-local-gateway` entry. If the agent supports direct MCP tool calls from chat, call `gateway_status` — the response should return `locks: []` (empty list of active locks) when no file is currently locked.

## Step 4. Configure Commit Attribution

Add a trailer to the agent's Configuration (or use a commit flag) in the following form:

```
Co-Authored-By: <Agent Name> <noreply@vendor-domain>
```

For example:
- `Co-Authored-By: Codex <noreply@openai.com>`
- `Co-Authored-By: Hermes <noreply@aisystant.com>`
- `Co-Authored-By: Kimi <noreply@moonshot.cn>`

If you are unsure of the correct vendor domain, use the agent product's official domain. On the first real commit, verify that the email does not look like a spam address and does not trigger errors in the Repository's git hooks.

## Step 5. Point the Agent to IWE Skills (Optional)

If the agent has its own mechanism for loading additional instructions or skills (analogous to `.claude/skills/` in Claude Code), point it to the `.claude/skills/` directory of your Repository — the same way it is done for Kimi (`extra_skill_dirs` in `~/.kimi/config.toml`, see `docs/KIMI-SETUP.md`).

If no such mechanism exists, skip this step — it does not block the rest of the agent's work.

## Step 6. Connect to the Aisystant MCP (Non-Claude Agents)

> Claude Code connects to the aisystant knowledge base through `claude.ai` connectors (`docs/SETUP-GUIDE.md`, step 1.3b) — it has a separate browser settings page. Other agents (Hermes, etc.) connect differently: directly through their own MCP client, without `claude.ai`. This step covers those agents. Ready-to-use step-by-step prompts for ChatGPT (including a working Business/Enterprise account) and for local Codex are in `docs/CHATGPT-CODEX-SETUP.md`.

### 6.1. Check the MCP Config

If your Repository's `.mcp.json` already contains an `iwe-knowledge` entry, it was created automatically by the installer (`setup.sh`). Open the file and inspect `url` and `headers`:

- If `Authorization: Bearer ...` is present, authentication is already configured (this is typically the T3/T4 tier path via `IWE_ICT_TOKEN`) — a browser is not needed; proceed to Step 6.3.
- If the header is absent, the server uses OAuth2. Authentication will occur on the agent's first real request to the server (not during `setup.sh`).

### 6.2. OAuth2 Authorization: What to Watch For

When the agent's MCP client first contacts the `iwe-knowledge` server, the server responds with an OAuth2 authorization request. This opens the **system default browser** (whichever browser is set as default in the OS — not necessarily the one you normally use).

**Before connecting the agent, make sure you are already logged in to your aisystant account in the default browser.** If not, either log in first, or temporarily switch the default browser to one where you are already logged in for the duration of this step. Otherwise the authorization page will open in an empty or wrong session, and you will need to repeat the attempt after logging in.

### 6.3. Verify That MCP Tools Are Available

Ask the agent directly (exact wording depends on how your agent refers to available tools): "What MCP tools are available to you? Is there anything related to knowledge/knowledge base?" If the agent supports direct tool calls, ask it to run a search against the knowledge base and check whether real documents are returned instead of a connection error.

### 6.4. Troubleshooting

| Problem | Solution |
|----------|---------|
| Browser did not open automatically (headless/remote session) | Copy the authorization URL from the agent's output and open it manually on any device with a browser and internet access |
| Authorization succeeded but under the wrong account | Log out of the wrong aisystant account in the default browser and repeat Step 6.2 |
| Agent does not support an MCP client at all | Knowledge base coordination through this path is not possible by technical means — see Step 3.1; the same Constraint applies here |

## Connection Verification (Smoke Test)

### Codex Calls Kimi or Claude as a Peer Partner

This step is only needed when Codex runs `kimi-peer-adapter.sh` or
`claude-peer-adapter.sh` as a child process. Normal standalone operation of Kimi and
Claude does not require changes to the Codex sandbox.

By default, the Codex local sandbox blocks outbound network access and writes outside
the working directory. Both Constraints matter: Kimi writes state to
`~/.kimi`, Claude writes to `~/.claude` and `~/.claude.json`, and both clients call
their respective APIs. These permissions are sufficient for Kimi, but on macOS they may
be only necessary for Claude: its active authorization may be stored in the Keychain,
which is inaccessible to a child process inside the sandbox. In the user-level
`~/.codex/config.toml`, keep the root keys before the first TOML section and add the
permissions:

```toml
approval_policy = "on-request"
sandbox_mode = "workspace-write"

[sandbox_workspace_write]
network_access = true
writable_roots = [
  "<HOME_DIR>/.kimi",
  "<HOME_DIR>/.claude",
  "<HOME_DIR>/.claude.json"
]
```

Replace `<HOME_DIR>` with the actual home directory path. TOML does not expand
`$HOME`, so a literal `"$HOME/.kimi"` does not work here. Existing root keys
`model` and `model_reasoning_effort` must remain above
`[sandbox_workspace_write]`; otherwise TOML will assign them to the wrong section.

**The security decision must be made explicitly:** in Codex 0.146.0,
`sandbox_workspace_write.network_access = true` opens outbound network access for all
commands inside that sandbox entirely. This version does not accept
`[features.network_proxy]`; do not copy settings from a newer schema without
verifying against the installed binary. Specific risk: any command inside the sandbox
(not just the Kimi/Claude call itself) gains full outbound network access — a tool
invoked by the agent inside this sandbox can technically send data to an arbitrary
external host. If broad network access is unacceptable, run the peer session from a
separate trusted terminal instead of relaxing the sandbox.

If Claude inside the sandbox responds `Not logged in · Please run /login`, do not
re-run login automatically. First call the same adapter from a normal terminal: on
macOS this is a typical sign that Keychain is inaccessible from an isolated process,
not that authorization has been lost. Until the installed Codex provides a narrow
Keychain permission, the canonical Codex→Claude path is an external trusted executor
or a separate terminal with the same minimal text Projection. Do not enable
`danger-full-access` solely for this workaround.

After saving, fully restart Codex/VS Code and verify the Configuration:

```bash
codex debug models
codex doctor
```

Then run a short live call to Kimi through the adapter. Test Claude inside the sandbox
first; if a Keychain failure occurs, repeat from a trusted terminal. Success of the
Configuration commands does not substitute for actual Kimi and Claude responses.

Run the following on a real small task:

1. **Agent sees AGENTS.md** — ask the agent directly; see the verification in Step 1.
2. **If gateway coordination is configured** — `<agent> mcp list` shows `iwe-local-gateway`.
3. **Real file edit with a lock** (only if you configured coordination):
   - Ask the agent to call `acquire_file_lock` on any test file, make a small edit, commit with the correct trailer, and call `release_file_lock`.
   - Check the commit: `git log -1 --format="%H %s%n%b"` — it must contain `Co-Authored-By` with the correct name and domain.
   - Verify the lock is released: calling `gateway_status` must again show `locks: []`.

If any of this does not work, do not connect the agent to file coordination until you identify the cause. An agent that commits without attribution or does not release locks creates confusion for other agents in the Repository.

## Difference from "Orchestrating an Agent as a Peer Partner"

Do not confuse this connection with a wrapper adapter (`*-peer-adapter.sh`), where one agent headlessly calls another as a subordinate Peer partner inside a peer session (one writes, the other critiques, and the entire dialogue is managed by the first agent). That is a different scenario — the calling agent orchestrates the called agent, rather than two independent MCP clients coordinating as equals through locks. The connection described in this document makes the new agent an independent Repository participant, not a subprocess of another agent.

## If Something Does Not Work

1. Verify that the path to `proxy.js` in the registration command is absolute and matches the actual location of your `DS-MCP/local-gateway` clone.
2. Verify that `IWE_AGENT_ID` in the registration command is unique and does not duplicate an already connected agent (run `<agent> mcp list` for each already connected agent).
3. If the agent does not support an MCP client at all, file coordination is technically impossible for it — limit the setup to Step 1 (`AGENTS.md`).
4. Check the `gateway_status` output — a stuck lock (`locks` is not empty after a long time) usually means the previous agent did not call `release_file_lock` after committing.
5. An error such as "connect ECONNREFUSED" or similar when calling gateway tools usually means the daemon is not running — re-run `bash setup/optional/setup-local-gateway.sh`; it will check and start the daemon if needed.

## Related Documents

- `AGENTS.md` — common rules for all agents.
- `setup/optional/setup-local-gateway.sh` — gateway installation (clone, build, daemon start).
- `docs/KIMI-SETUP.md` — specifics of connecting Kimi Code (detailed example for Step 5).
- `docs/CHATGPT-CODEX-SETUP.md` — ready-to-use prompts for connecting ChatGPT and Codex to the aisystant MCP (Step 6).
- `docs/inter-agent-handoff.md` — passing context between agents without a shared gateway.
- `memory/agent-vendor-connect-pattern.md` — concise technical reference card for the same pattern (reference format for agent Memory, not a step-by-step guide for humans).

