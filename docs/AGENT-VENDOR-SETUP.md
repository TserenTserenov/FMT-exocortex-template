---
scope: IWE
status: active
title: Connecting a New AI Agent to IWE (Vendor-Agnostic)
updated: 2026-11-24
---

# Connecting a New AI Agent to IWE

> Audience: a practitioner who wants to connect **any** vendor AI agent to their fork of `IWE` — Claude Code, Kimi Code, Codex, Hermes, a ChatGPT extension, or any other file-based CLI/IDE agent not yet covered by a dedicated guide.
> Two cases: **the primary agent is being replaced** (for example, the Claude account is blocked) — start with the section [«Migrating from Claude to Another Agent»](#migrating-from-claude-to-another-agent); **an agent is being added alongside an already-working one** — go straight to Step 1.
> Time: ~15–30 minutes depending on whether the agent supports MCP out of the box.
> Verified live (28.07.2026) with 4 different agents running simultaneously (Claude, Kimi, Codex, Hermes) — coordination on shared files with no conflicts.

This document is written so that **the agent itself** (not only the person) can read it and complete the connection independently — without assumptions about what is "already known" about a specific vendor.

## Migrating from Claude to Another Agent

Your notes, plans, Work Products, rules, and Skills live in the IWE folder on disk and in your repositories. When you switch agents, they stay in place: only the program that works with them changes. What is lost is only the conversation history stored at the vendor (for example, on claude.ai).

**Step A. Choose a new agent.** You need an agent that can see files in the folder and edit them.

| Agent | How it learns IWE rules | Details |
|---|---|---|
| Codex (OpenAI): app or VS Code extension | reads `AGENTS.md` | Step 1 below; knowledge base connection — `docs/CHATGPT-CODEX-SETUP.md`, section "Connecting to Codex" |
| Kimi Code | reads `AGENTS.md`, Skills — via `extra_skill_dirs` | `docs/KIMI-SETUP.md` |
| Hermes | receives instructions via MCP (`get_instructions`), does not read repository files directly | `docs/PORTABILITY.md`, Hermes section |
| Other file-based agents (Qwen Code, Cursor, Cherry Studio, etc.) | varies — check with Step 1 | Steps 1, 5, 6 below |
| Anthropic models via an API proxy (e.g., OpenRouter) in one of the agents above | same as the chosen agent | Works, but token-based billing is significantly more expensive than a subscription |

If you need AI immediately — including for consultation while the new agent is not yet configured — use the browser version at [iwe.system-school.ru](https://iwe.system-school.ru/) with your MIM account (MIM subscription required). This is a chat connected to the IWE knowledge base. To let it see your materials, write "connect my GitHub" in the chat: it will provide a GitHub sign-in link, and if needed a second link to install the `aisystant-knowledge` app, where you choose which repositories to include (details: `docs/SETUP-GUIDE.md`, section 1.3c). It cannot see the folder on your computer, cannot run commands or Skills, and can only see what has already been pushed to GitHub and indexed. The model and request budget there are limited by your plan. For consultations and step-by-step migration assistance, this is sufficient.

**Step B. Open the IWE folder with the new agent, without making changes.** First request: "Read `AGENTS.md` and `CLAUDE.md` in the root, do not change anything, and explain how you will work here." Verification — Step 1 below.

**Step C. Make it the primary agent.** Ask the agent to complete Steps 1, 5, and 6 of this document, and explicitly state that it will now be the primary agent. Steps 2–4 (file coordination and attribution) are only needed when several agents are running in parallel.

**What works only in Claude Code.** Hooks from `.claude/settings.json` (protective checks before agent actions) are run only by Claude Code; they do not trigger in other agents, so caution around file deletion and commits falls on you. Skill slash-commands (`/day-open` etc.) work in Kimi via `extra_skill_dirs`; for another agent, say "read `.claude/skills/day-open/SKILL.md` and execute it."

**Step D. For the first week, manually verify that the Day Open and Day Close were completed by the new vendor's agent.** A different model follows instructions differently and may skip items it considered optional. Example: Codex closed the day; you then open the same folder with Kimi and ask it to compare what was done against the Day Close protocol and list what was skipped. Record any gaps found as rules for the new agent in `extensions/`.

## What You Will Get

- When the new agent opens the repository, it will read `AGENTS.md` and apply the common IWE rules.
- If the agent edits repository files simultaneously with other agents, it will coordinate with them through the shared local lock gateway without overwriting each other's changes.
- The agent's commits will have correct attribution (it is visible which agent changed what).

## Step 1. Read AGENTS.md

The `AGENTS.md` file in the repository root is a common minimum set of rules for any file-based agent (not vendor-specific). Most modern CLI agents (Claude Code, Codex, Kimi, Cline) read it automatically when the directory is opened — no separate configuration is needed.

**Verification:** open the repository with the new agent and ask it directly — "did you read AGENTS.md in the repository root? List 3 rules from it." If the agent cannot answer, check whether it supports automatic reading of instruction files in the repository root (some vendors make this a separate setting — see the agent documentation using keywords such as "project instructions", "system prompt from file", "AGENTS.md support").

### 1.1. If Auto-Loading Is Not Available (verified on Hermes)

Some agents (Hermes, for example) do not read `AGENTS.md` automatically at all — and there is no separate setting for this. The verification above will consistently return "no" for them; this is not a reason to look for a hidden flag. Instead, ask the agent explicitly as the first message:

> "Read the file `AGENTS.md` in the repository root and follow the rules stated there. Confirm that the file has been read and list 3 rules from it."

After this, the agent normally behaves correctly for the rest of the session without repeated reminders — the instruction itself is not forgotten, only the fact that it needed to be explicitly requested. If the repository tree contains multiple `AGENTS.md` files, the more specific one (deeper in the directory tree) takes priority, as it does for any agent with auto-loading.

## Step 2. Determine Whether File Coordination Is Needed

Coordination is needed if another agent (a person + Claude, or multiple CLI agents in parallel) may be working on the same repository files at the same time as this agent.

Coordination is not needed if the agent works solo and never overlaps with others on the same files — in that case, skip Steps 3–4 and go directly to Step 5.

## Step 3. Connect the Agent to the Local Lock Gateway

IWE uses a local MCP server (`DS-MCP/local-gateway`) that maintains a shared file lock manager. Any agent that supports MCP (Model Context Protocol) as a client can connect to it.

### 3.1. Check Whether the Agent Supports an MCP Client

Ask the agent's documentation or the agent itself: "do you support connecting to external MCP servers as a client, and can you pass environment variables when starting the server?"

If yes, the agent usually has a subcommand such as `<agent> mcp add` or a configuration file (`config.toml`, `config.yaml`, `settings.json`) where a new MCP server entry is added.

### 3.2. Find the Local Gateway Start Command

If `.mcp.json` in your repository already has an `iwe-local-gateway` entry (someone connected the gateway earlier) — copy the `command` and `args` from there; that is the fastest path.

If the entry does not exist yet, the gateway itself is also most likely not installed (it is not included in the template directly; it is a separate dependency with its own version lifecycle). Install it:

```bash
bash setup/optional/setup-local-gateway.sh
```

The script clones the gateway at a pinned version, builds it, starts the daemon, and prints a ready-to-use `command`/`args`/`env` block to paste into `.mcp.json` — use it in Step 3.3 below. The path to `proxy.js` in that block is `node <absolute-path-to-your-IWE>/DS-MCP/local-gateway/dist/proxy.js`.

**Important:** `env.IWE_AGENT_ID` in the printed block is set to the agent that ran the script (or `claude-code` by default). When registering **the second and subsequent agents**, replace this value with a unique name for each one (see Step 3.3 below); identical `IWE_AGENT_ID` values across different agents will silently break lock coordination.

### 3.3. Register the Agent with a Unique IWE_AGENT_ID

Each agent receives its own unique identifier via the `IWE_AGENT_ID` environment variable — the local gateway uses it to distinguish which agent holds the lock on a file. The identifier is a short name without spaces (for example `codex`, `hermes`, `kimikode`, `chatgpt`).

**General registration syntax (replace placeholders for the specific agent):**

```
<agent-command> mcp add iwe-local-gateway --env IWE_AGENT_ID=<unique-agent-name> -- node <path-to-proxy.js>
```

**Three verified examples** (different agents, different registration syntax — the general principle is the same):

```bash
# Codex (standard --env flag for stdio MCP servers)
codex mcp add iwe-local-gateway --env IWE_AGENT_ID=codex -- node /path/to/IWE/DS-MCP/local-gateway/dist/proxy.js

# Hermes (separate --command/--args/--env flags)
hermes mcp add iwe-local-gateway --command node --args /path/to/IWE/DS-MCP/local-gateway/dist/proxy.js --env IWE_AGENT_ID=hermes

# Kimi (via MCP client config file, not a CLI subcommand — see docs/KIMI-SETUP.md)
```

If your agent has neither an `mcp add` CLI subcommand nor a configuration file for MCP clients, it **does not support MCP as a client**, and coordination through the local gateway cannot be configured for it by technical means. In that case, the agent can participate in the connection only at the level of Step 1 (reading AGENTS.md), without file coordination — communicate this directly to the user; do not invent a workaround.

### 3.4. Verify the Registration

```bash
<agent> mcp list
```

The output should include an `iwe-local-gateway` entry. If the agent supports direct MCP tool calls from the chat, try calling `gateway_status` — the response should return `locks: []` (an empty list of active locks) if no one currently holds a file lock.

## Step 4. Configure the Commit Attribution Line

Add to the agent's configuration (or use a flag at commit time) a trailer of the form:

```
Co-Authored-By: <Agent name> <noreply@vendor-domain>
```

For example:
- `Co-Authored-By: Codex <noreply@openai.com>`
- `Co-Authored-By: Hermes <noreply@aisystant.com>`
- `Co-Authored-By: Kimi <noreply@moonshot.cn>`

If you are unsure of the correct vendor domain, use the official domain of the agent's product. After the first real commit, verify that the email does not look like a spam address and does not trigger errors from the repository's git hooks.

## Step 5. Point the Agent to IWE Skills (Optional)

If the agent has its own mechanism for locating additional instructions or Skills (analogous to `.claude/skills/` in Claude Code), point it to the `.claude/skills/` directory in your repository, similar to how this is done for Kimi (`extra_skill_dirs` in `~/.kimi/config.toml`, see `docs/KIMI-SETUP.md`).

If no such mechanism exists, skip this step — it does not block the rest of the agent's work.

## Step 6. Connect to the Aisystant MCP (Non-Claude Agents)

> Claude Code connects to the Aisystant knowledge base via `claude.ai` connectors (`docs/SETUP-GUIDE.md`, Step 1.3b) — it has a separate browser settings page. Other agents (Hermes, etc.) connect differently: directly through their own MCP client, without `claude.ai`. This step is for them. Ready-to-use step-by-step prompts for ChatGPT (including an active Business/Enterprise account) and for local Codex are in `docs/CHATGPT-CODEX-SETUP.md`.

### 6.1. Check the MCP Config

If `.mcp.json` in your repository already has an `iwe-knowledge` entry, it was created automatically by the installer (`setup.sh`) during installation. Open the file and examine the `url` and `headers`:

- If there is an `Authorization: Bearer ...` header — authorization is already configured (this is typically the path for the T3/T4 tier via `IWE_ICT_TOKEN`); no browser is needed; go to Step 6.3.
- If the header is absent — the server uses OAuth2; authorization will occur on the agent's first real request to the server (not during `setup.sh`).

### 6.2. OAuth2 Authorization: What to Watch Out For

When the agent's MCP client first contacts the `iwe-knowledge` server, the server responds with an OAuth2 authorization request — this will open the **default system browser** (the one set as default in the OS, not necessarily the one you usually use).

**Before connecting the agent, make sure you are already signed in to your Aisystant account in the default browser.** If you are not, either sign in in advance or temporarily change the default browser to one where you are already signed in, for the duration of this step. Otherwise, authorization will open in an empty or foreign session, and you will have to repeat the attempt after signing in.

### 6.3. Verify That the MCP Tools Are Available

Ask the agent directly (the phrasing depends on how your agent refers to available tools): "which MCP tools are available to you? Is there anything related to knowledge/the knowledge base?" If the agent supports direct tool calls, ask it to run a knowledge base search and check whether real documents are returned rather than a connection error.

### 6.4. Troubleshooting

| Problem | Solution |
|----------|---------|
| Browser did not open automatically (headless/remote session) | Copy the authorization URL from the agent output and open it manually on any device with a browser and internet access |
| Authorization succeeded but in the wrong account | Sign out of the foreign Aisystant account in the default browser, then repeat Step 6.2 |
| Agent does not support MCP client at all | Coordination with the knowledge base via this path is not technically possible — see Step 3.1; the same limitation applies here |

## Connection Verification (Smoke Test)

### Codex Calling Kimi or Claude as a Peer Partner

This step is only needed when Codex runs `kimi-peer-adapter.sh` or
`claude-peer-adapter.sh` as a child process. Normal standalone operation of Kimi and
Claude does not require any changes to the Codex sandbox.

By default, the Codex local sandbox blocks outbound network access and writes outside
the working directory. Both restrictions matter: Kimi writes state to
`~/.kimi`, Claude writes to `~/.claude` and `~/.claude.json`, and both clients contact
their respective APIs. These permissions are sufficient for Kimi, but on macOS they may
only be necessary for Claude: its active authorization may be stored in the Keychain,
which is inaccessible to a sandboxed child process. In the user-level
`~/.codex/config.toml`, keep the root keys before the first TOML section and add the
following permissions:

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
`$HOME`, so the literal `"$HOME/.kimi"` does not work here. Existing root keys
`model` and `model_reasoning_effort` must remain above `[sandbox_workspace_write]`;
otherwise TOML will assign them to the wrong section.

**The security trade-off must be made explicitly:** in Codex 0.146.0,
`sandbox_workspace_write.network_access = true` opens outbound network access for
all commands inside this sandbox. This version does not accept
`[features.network_proxy]`; do not copy settings from a newer schema without
verifying with the installed binary. The specific risk: any command inside the
sandbox (not only the Kimi/Claude call itself) gets full outbound network access —
a tool called by the agent inside this sandbox can technically send data to an
arbitrary external host. If broad network access is unacceptable, run the peer
session from a separate trusted terminal instead of relaxing the sandbox.

If Claude inside the sandbox responds with `Not logged in · Please run /login`, do not
restart the sign-in automatically. First call the same adapter from a regular terminal:
on macOS this is a typical sign that the Keychain is inaccessible from an isolated
process, not that authorization has been lost. Until the installed Codex provides a
narrow Keychain permission, the canonical path for Codex→Claude is an external trusted
executor or a separate terminal with the same minimal text Projection. Do not enable
`danger-full-access` solely for this workaround.

After saving, fully restart Codex/VS Code and verify the configuration:

```bash
codex debug models
codex doctor
```

Then run a short live call to Kimi through the adapter. Test Claude inside the sandbox
first; if a Keychain failure occurs, repeat from a trusted terminal. Successful
configuration commands do not substitute for actual responses from Kimi and Claude.

Run the following on a real small task:

1. **The agent sees AGENTS.md** — ask the agent directly; see the verification in Step 1.
2. **If gateway coordination is configured** — `<agent> mcp list` shows `iwe-local-gateway`.
3. **A real file edit with a lock** (only if coordination was configured):
   - Ask the agent to call `acquire_file_lock` on any test file, make a small edit, commit with the correct trailer, and call `release_file_lock`.
   - Check the commit: `git log -1 --format="%H %s%n%b"` — it must contain `Co-Authored-By` with the correct name and domain.
   - Verify that the lock has been released: calling `gateway_status` should again show `locks: []`.

If any of this does not work, do not connect the agent to file coordination until you have identified the cause. An agent that commits without attribution or does not release locks creates confusion for other agents in the repository.

## Difference from "Orchestrating an Agent as a Peer Partner"

Do not confuse this connection with the wrapper adapter (`*-peer-adapter.sh`), where one agent calls another headless as a subordinate peer partner inside a peer session (one writes, the other critiques, the entire dialogue is managed by the first agent). That is a different scenario — the calling agent orchestrates the called agent, rather than two independent MCP clients coordinating as equals through locks. The connection described in this document makes the new agent an independent participant in the repository, not a subprocess of another agent.

## If Something Does Not Work

1. Verify that the path to `proxy.js` in the registration command is absolute and matches the actual location of your `DS-MCP/local-gateway` clone.
2. Verify that the `IWE_AGENT_ID` in the registration command is unique and does not match any already-connected agent (`<agent> mcp list` for each already-connected agent).
3. If the agent does not support an MCP client at all, file coordination for it is technically impossible — limit the connection to Step 1 (AGENTS.md).
4. Check the `gateway_status` output — a stuck lock (`locks` is non-empty after a long time) usually means the previous agent did not call `release_file_lock` after the commit.
5. An error such as "connect ECONNREFUSED" or similar when calling gateway tools usually means the daemon is not running — re-run `bash setup/optional/setup-local-gateway.sh`; it will check and start the daemon if needed.

## Related Documents

- `AGENTS.md` — common rules for all agents.
- `setup/optional/setup-local-gateway.sh` — gateway installation (clone, build, daemon start).
- `docs/KIMI-SETUP.md` — specifics of connecting Kimi Code (detailed example for Step 5).
- `docs/CHATGPT-CODEX-SETUP.md` — ready-to-use prompts for connecting ChatGPT and Codex to the Aisystant MCP (Step 6).
- `docs/inter-agent-handoff.md` — passing context between agents without a shared gateway.
- `memory/agent-vendor-connect-pattern.md` — a concise technical card for the same pattern (reference format for agent Memory, not a step-by-step guide for a person).

