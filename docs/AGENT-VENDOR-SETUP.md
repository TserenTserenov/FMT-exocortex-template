---
scope: IWE
status: active
title: Connecting a New AI Agent to IWE (Vendor-Agnostic)
updated: 2026-11-24
---

# Connecting a New AI Agent to IWE

> Audience: a practitioner who wants to connect **any** vendor AI agent to their fork of `IWE` — Claude Code, Kimi Code, Codex, Hermes, a ChatGPT extension, or any other file-based CLI/IDE agent not yet covered by a dedicated guide.
> Two cases: **the primary agent is being replaced** (for example, the Claude account is blocked) — start with [«Migrating from Claude to Another Agent»](#migrating-from-claude-to-another-agent); **the agent is being added alongside an already-working one** — go straight to Step 1.
> Time: ~15–30 minutes depending on whether the agent supports MCP out of the box.
> Live-tested (28.07.2026) with 4 different agents simultaneously (Claude, Kimi, Codex, Hermes) — coordination on shared files with no conflicts.

This document is written so that **the agent itself** (not only the person) can read it and complete the connection independently — without assumptions about what is "already known" about a specific vendor.

## Migrating from Claude to Another Agent

Your notes, plans, Work Products, rules, and Skills live in the IWE folder on disk and in your repositories. When you switch agents, they stay in place: only the program that works with them changes. What is lost is only the conversation history stored at the vendor (for example, on claude.ai).

**Step A. Choose a new agent.** You need an agent that can see files in the folder and edit them.

| Agent | How it learns IWE rules | Details |
|---|---|---|
| Codex (OpenAI): app or VS Code extension | reads `AGENTS.md` | Step 1 below; knowledge base connection — `docs/CHATGPT-CODEX-SETUP.md`, section "Connecting to Codex" |
| Kimi Code | reads `AGENTS.md`, Skills — via `extra_skill_dirs` | `docs/KIMI-SETUP.md` |
| Hermes | receives instructions via MCP (`get_instructions`), does not read repository files directly | `docs/PORTABILITY.md`, Hermes section |
| Other file-based agents (Qwen Code, Cursor, Cherry Studio, etc.) | varies: check with Step 1 | Steps 1, 5, 6 below |
| Anthropic models via an API proxy (e.g., OpenRouter) in one of the agents above | same as the chosen agent | Works, but token-based billing is noticeably more expensive than a subscription |

If you need an AI right now — including for consultation while the new agent is being configured — the browser version at [iwe.system-school.ru](https://iwe.system-school.ru/) is available via your MIM account login (with a MIM subscription). This is a chat connected to the IWE knowledge base. To let it see your materials, write "connect my GitHub" in the chat: it will provide a GitHub sign-in link, and if needed a second link to install the `aisystant-knowledge` app, where you choose which repositories to expose (details: `docs/SETUP-GUIDE.md`, section 1.3c). It cannot see the folder on your computer, cannot run commands or Skills, and can only see what has already been pushed to GitHub and indexed; the model and request budget there are limited by your plan tier. For consultation and step-by-step migration assistance this is sufficient.

**Step B. Open the IWE folder with the new agent, without making changes.** File-based agents (Codex, Kimi Code, etc.) work with files on your computer and therefore need the environment folder. If you used IWE through a desktop application, the folder already exists — open it. If you worked only in the claude.ai chat and your records live in GitHub, ask the agent to clone your repository (or environment repositories) and open the cloned folder. If you are using only the browser version for now, cloning is not necessary. First request: "Read `AGENTS.md` and `CLAUDE.md` in the root, do not change anything, and explain how you will work here." Verification — Step 1 below.

**Step C. Make it the primary agent.** When the agent has responded to the Step B request and its explanation satisfies you, ask it to complete Steps 1, 5, and 6 of this document, and explicitly tell it that it is now the primary agent. Steps 2–4 (file coordination and attribution) are only needed when multiple agents are working in parallel.

**First day with the new agent.** Full IWE functionality (Skills, safety checks, scheduled roles) currently works only in Claude Code; other agents work with the shared rules from `AGENTS.md` and the connection to our MCP. Therefore, on the first day:
- **Run Day Open and Day Close by text, without slash commands.** Tell the agent: "Read `.claude/skills/day-open/SKILL.md` and execute its steps in order, skipping nothing; at the end list which steps you completed." The same applies to Day Close with `.claude/skills/day-close/SKILL.md`. For Kimi, Skills are connected via `extra_skill_dirs` (`docs/KIMI-SETUP.md`).
- **The new agent does not have safety checks.** The hooks in `.claude/settings.json` are run only by Claude Code. Before each push of changes, ask the agent to show the list of changed files, and do not allow it to delete files or edit `.claude/hooks/` and `.claude/settings.json` without your explicit permission.
- **If the agent skipped a step, write it into its rules** (`extensions/`), not just fix it this one time.

**Step D. Independently verify Day Open and Day Close during the first week.** A different model follows instructions differently and may skip steps it considered optional. The verification must be done by someone who did not perform the day. If you have only one agent, connect the browser version at [iwe.system-school.ru](https://iwe.system-school.ru/) to your GitHub (write "connect my GitHub" in the chat); close the day with the new primary agent; once it has pushed the records to GitHub, write to the browser version: "Read the day-close protocol and my records for today, check whether all protocol steps were completed, do not change anything, and list any skipped items and discrepancies." It sees only the pushed result, not the work on your computer. If you have a second agent from a different vendor (for example, the day was closed by Codex and verified by Kimi), open it in the same folder with the same task. Record any found gaps in the new agent's rules (`extensions/`).

## What You Will Get

- When the new agent opens the repository, it will read `AGENTS.md` and apply the shared IWE rules.
- If the agent edits repository files simultaneously with other agents, it will coordinate with them through the shared local lock gateway without overwriting others' changes.
- The agent's commits will have correct attribution (it will be visible which agent changed what).

## Step 1. Read AGENTS.md

The `AGENTS.md` file in the repository root is the shared minimum set of rules for any file-based agent (not specific to one vendor). Most modern CLI agents (Claude Code, Codex, Kimi, Cline) read it automatically when the directory is opened — no separate configuration is needed.

**Verification:** open the repository with the new agent and ask it directly — "did you read AGENTS.md in the repository root? List 3 rules from it." If the agent cannot answer — check whether it supports automatic reading of instruction files in the repo root (for some vendors this is a separate setting — see the agent's documentation for the keywords "project instructions", "system prompt from file", "AGENTS.md support").

### 1.1. If automatic loading is absent (verified with Hermes)

Some agents (for example Hermes) do not read `AGENTS.md` automatically at all — and there is no separate setting to enable this. The verification above will consistently return "no" for them; this is not a reason to look for a hidden flag. Instead — ask the agent explicitly in the first message:

> "Read the file `AGENTS.md` in the repository root and follow the rules stated there. Confirm that the file has been read and list 3 rules from it."

After this, the agent normally behaves correctly for the rest of the Session without further reminders — the instruction itself is not forgotten, only the fact that it needed to be explicitly requested. If the repository tree contains multiple `AGENTS.md` files — the more specific one (deeper in the directory tree) takes priority, as with any agent that supports automatic loading.

## Step 2. Determine Whether File Coordination Is Needed

Coordination is needed if another agent (a person + Claude, or multiple CLI agents in parallel) may work on the same repository files at the same time as this agent.

It is not needed if the agent works solo and never overlaps with others on the same files — in that case, skip Steps 3–4 and go directly to Step 5.

## Step 3. Connect the Agent to the Local Lock Gateway

IWE uses a local MCP server (`DS-MCP/local-gateway`) that maintains a shared file lock manager. Any agent that supports MCP (Model Context Protocol) as a client can connect to it.

### 3.1. Check Whether the Agent Supports an MCP Client

Ask the agent's documentation or the agent itself: "do you support connecting to external MCP servers as a client, and can you pass environment variables when launching the server?"

If yes — the agent typically has a subcommand such as `<agent> mcp add` or a configuration file (`config.toml`, `config.yaml`, `settings.json`) where a new MCP server entry is added.

### 3.2. Find the Local Gateway Launch Command

If your repository's `.mcp.json` already contains an `iwe-local-gateway` entry (someone has connected the gateway before) — copy the `command` and `args` from there; that is the fastest path.

If the entry does not yet exist — the gateway itself is most likely not installed either (it is not part of the template directly; it is a separate dependency with its own version lifecycle). Install it:

```bash
bash setup/optional/setup-local-gateway.sh
```

The script clones the gateway at a pinned version, builds it, starts the daemon, and prints a ready `command`/`args`/`env` block for insertion into `.mcp.json` — use it in Step 3.3 below. The path to `proxy.js` in this block is `node <absolute-path-to-your-IWE>/DS-MCP/local-gateway/dist/proxy.js`.

**Important:** `env.IWE_AGENT_ID` in the printed block is set to the agent that ran the script (or `claude-code` by default). When registering the **second and subsequent** agents — replace this value with a unique name for each one (see Step 3.3 below); identical `IWE_AGENT_ID` values across different agents silently breaks lock coordination.

### 3.3. Register the Agent with a Unique IWE_AGENT_ID

Each agent receives its own unique identifier via the `IWE_AGENT_ID` environment variable — the local gateway uses it to distinguish which agent holds a lock on a file. The identifier is a short name without spaces (for example `codex`, `hermes`, `kimikode`, `chatgpt`).

**General registration syntax (replace placeholders for the specific agent):**

```
<agent-command> mcp add iwe-local-gateway --env IWE_AGENT_ID=<unique-agent-name> -- node <path-to-proxy.js>
```

**Three live-verified examples** (different agents, different registration syntax — the general principle is the same):

```bash
# Codex (standard --env flag for stdio MCP servers)
codex mcp add iwe-local-gateway --env IWE_AGENT_ID=codex -- node /path/to/IWE/DS-MCP/local-gateway/dist/proxy.js

# Hermes (separate --command/--args/--env flags)
hermes mcp add iwe-local-gateway --command node --args /path/to/IWE/DS-MCP/local-gateway/dist/proxy.js --env IWE_AGENT_ID=hermes

# Kimi (via MCP client config, not a CLI subcommand — see docs/KIMI-SETUP.md)
```

If your agent has neither a CLI subcommand `mcp add` nor a config file for MCP clients — it **does not support MCP as a client**, and lock-based coordination through the local gateway cannot be configured for it by technical means. In that case the agent can participate in connection only at the level of Step 1 (reading AGENTS.md), without file coordination — inform the user of this directly; do not invent a workaround.

### 3.4. Verify Registration

```bash
<agent> mcp list
```

The output should include an `iwe-local-gateway` entry. If the agent supports direct MCP tool calls from the chat — try calling `gateway_status`; the response should return `locks: []` (empty list of active locks) if no one is currently holding a file lock.

## Step 4. Configure the Commit Attribution Trailer

Add to the agent's configuration (or use a flag at commit time) a trailer of the form:

```
Co-Authored-By: <Agent name> <noreply@vendor-domain>
```

For example:
- `Co-Authored-By: Codex <noreply@openai.com>`
- `Co-Authored-By: Hermes <noreply@aisystant.com>`
- `Co-Authored-By: Kimi <noreply@moonshot.cn>`

If you are unsure of the correct vendor domain — use the official domain of the agent's product; on the first real commit, verify that the email does not look like a spam address and does not trigger errors in the repository's git hooks.

## Step 5. Point the Agent to IWE Skills (Optional)

If the agent has its own mechanism for locating additional instructions/Skills (analogous to `.claude/skills/` in Claude Code) — point it to the `.claude/skills/` path in your repository, similarly to how this is done for Kimi (`extra_skill_dirs` in `~/.kimi/config.toml`, see `docs/KIMI-SETUP.md`).

If no such mechanism exists — skip this step; it does not block the agent's other work.

## Step 6. Connecting to Aisystant MCP (Non-Claude Agents)

> Claude Code connects to the Aisystant knowledge base through `claude.ai` connectors (`docs/SETUP-GUIDE.md`, Step 1.3b) — it has a separate browser settings page. Other agents (Hermes, etc.) connect differently: directly through their own MCP client, without `claude.ai`. This step covers them. Ready-to-use step-by-step prompts for ChatGPT (including a working Business/Enterprise account) and for local Codex are in `docs/CHATGPT-CODEX-SETUP.md`.

### 6.1. Check the MCP Config

If your repository's `.mcp.json` already contains an `iwe-knowledge` entry — it was created automatically by the installer (`setup.sh`) during installation. Open the file and look at `url` and `headers`:

- If there is an `Authorization: Bearer ...` header — authorization is already configured (this is typically the path for the T3/T4 tier via `IWE_ICT_TOKEN`); a browser is not needed; go to Step 6.3.
- If there is no header — the server uses OAuth2; authorization will occur on the agent's first real request to it (not during `setup.sh`).

### 6.2. OAuth2 Authorization: What to Watch For

When the agent's MCP client first contacts the `iwe-knowledge` server, the server responds with an OAuth2 authorization request — this will open the **default system browser** (the one set as the default in the OS, not necessarily the one you normally use).

**Before connecting the agent — make sure you are already logged in to your Aisystant account in the default browser.** If not — either log in in advance, or temporarily change the default browser to one where you are already signed in, for the duration of this step. Otherwise authorization will open on an empty or someone else's Session, and you will need to repeat the attempt after signing in.

### 6.3. Verify That MCP Tools Are Available

Ask the agent directly (the exact wording depends on how your agent names available tools): "what MCP tools are available to you? Is there anything related to knowledge/knowledge base?" If the agent supports direct tool calls — ask it to run a knowledge-base search and check whether real documents are returned, not a connection error.

### 6.4. Troubleshooting

| Problem | Solution |
|----------|---------|
| Browser did not open automatically (headless/remote session) | Copy the authorization URL from the agent's output and open it manually on any device with a browser and internet access |
| Authorization completed but under the wrong account | Sign out of the wrong Aisystant account in the default browser and repeat Step 6.2 |
| Agent does not support MCP client at all | Coordination with the knowledge base via this path is technically impossible — see Step 3.1; the same limitation applies here |

## Connection Smoke Test

### Codex Calling Kimi or Claude as a Peer Partner

This step is only needed when Codex runs `kimi-peer-adapter.sh` or
`claude-peer-adapter.sh` as a child process. Normal standalone operation of
Kimi and Claude does not require any changes to the Codex sandbox.

By default, the local Codex sandbox blocks outbound network and writes outside
the working directory. Both restrictions matter: Kimi writes state to
`~/.kimi`, Claude to `~/.claude` and `~/.claude.json`, and both clients call
their respective APIs. These permissions are sufficient for Kimi, but on macOS
they may only be necessary for Claude: its active authorization may be stored
in Keychain, which is inaccessible to a child process inside the sandbox. In
the user-level `~/.codex/config.toml`, keep the root keys before the first
TOML section and add the permissions:

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
`model` and `model_reasoning_effort` must stay above
`[sandbox_workspace_write]`; otherwise TOML assigns them to the wrong section.

**The security decision must be made explicitly:** in Codex 0.146.0,
`sandbox_workspace_write.network_access = true` opens outbound network access
for all commands inside this sandbox entirely. This version does not accept
`[features.network_proxy]`; do not copy settings from a newer schema without
verifying against the installed binary. The specific risk: any command inside
the sandbox (not only the Kimi/Claude call itself) gets full outbound network
access — a tool invoked by the agent inside this sandbox can technically send
data to an arbitrary external host. If broad network access is unacceptable,
run the peer session from a separate trusted terminal instead of relaxing the
sandbox.

If Claude inside the sandbox responds with `Not logged in · Please run /login`,
do not restart the login flow automatically. First, call the same adapter from
a regular terminal: on macOS this is a typical sign that Keychain is
inaccessible from an isolated process, not that authorization has been lost.
Until the installed version of Codex provides a narrow Keychain permission, the
canonical Codex→Claude path is an external trusted executor or a separate
terminal with the same minimal text Projection. Do not enable
`danger-full-access` solely for this workaround.

After saving, fully restart Codex/VS Code and verify the configuration:

```bash
codex debug models
codex doctor
```

Then run a short live call to Kimi via the adapter. Test Claude inside the
sandbox first; if a Keychain failure occurs, repeat from a trusted terminal.
Successful configuration commands do not replace actual responses from Kimi and
Claude.

Run this on a real, small task:

1. **The agent sees AGENTS.md** — ask the agent directly; see the verification in Step 1.
2. **If coordination through the gateway is configured** — `<agent> mcp list` shows `iwe-local-gateway`.
3. **Real file edit with locking** (only if coordination was configured):
   - Ask the agent to call `acquire_file_lock` on any test file, make a small edit, commit with the correct trailer, and call `release_file_lock`.
   - Check the commit: `git log -1 --format="%H %s%n%b"` — it must contain `Co-Authored-By` with the correct name and domain.
   - Verify the lock is released: a `gateway_status` call should again show `locks: []`.

If any of this does not work — do not connect the agent to file coordination until you have identified the cause; an agent that commits without attribution or does not release locks creates confusion for other agents in the repository.

## Difference from "Orchestrating an Agent as a Peer Partner"

Do not confuse this connection with the wrapper adapter (`*-peer-adapter.sh`), where one agent calls another headlessly as a subordinate peer partner inside a peer session (one writes, the other critiques, the entire dialogue is orchestrated by the first agent). That is a different scenario — the calling agent orchestrates the called one, rather than two independent MCP clients coordinating as equals through locks. The connection described in this document makes the new agent an independent participant in the repository, not a subordinate process of another agent.

## If Something Does Not Work

1. Verify that the path to `proxy.js` in the registration command is absolute and matches the actual location of your `DS-MCP/local-gateway` clone.
2. Verify that `IWE_AGENT_ID` in the registration command is unique and does not match any already-connected agents (`<agent> mcp list` for each already-connected agent).
3. If the agent does not support MCP client at all — file coordination for it is technically impossible; limit yourself to Step 1 (AGENTS.md).
4. Check the `gateway_status` output — a stuck lock (`locks` is non-empty after a long time) usually means the previous agent did not call `release_file_lock` after committing.
5. An error such as "connect ECONNREFUSED" or similar when calling gateway tools usually means the daemon is not running — re-run `bash setup/optional/setup-local-gateway.sh`; it will check and restart the daemon if necessary.

## Related Documents

- `AGENTS.md` — shared rules for all agents.
- `setup/optional/setup-local-gateway.sh` — gateway installation (clone, build, daemon start).
- `docs/KIMI-SETUP.md` — specifics of connecting Kimi Code (detailed example for Step 5).
- `docs/CHATGPT-CODEX-SETUP.md` — ready-to-use prompts for connecting ChatGPT and Codex to Aisystant MCP (Step 6).
- `docs/inter-agent-handoff.md` — context handoff between agents without a shared gateway.
- `memory/agent-vendor-connect-pattern.md` — a brief technical reference card for the same pattern (reference format for agent Memory, not a step-by-step guide for a person).

