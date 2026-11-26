---
scope: IWE
status: active
title: Connecting a New AI Agent to IWE (Vendor-Agnostic)
updated: 2026-11-24
---

# Connecting a New AI Agent to IWE

> Audience: a Pilot who wants to connect **any** vendor AI agent to their fork of `IWE` — Claude Code, Kimi Code, Codex, Hermes, a ChatGPT extension, or any other file-based CLI/IDE agent not covered by a dedicated guide.
> Two cases: **the primary agent is being replaced** (for example, a Claude account is blocked) — start with [Migrating from Claude to Another Agent](#migrating-from-claude-to-another-agent); **an agent is being added alongside an already-working one** — go straight to Step 1.
> Time: approximately 15–30 minutes, depending on whether the agent supports MCP out of the box.
> Verified live (28.07.2026) on 4 different agents simultaneously (Claude, Kimi, Codex, Hermes) — coordination on shared files with no conflicts.

This document is written so that **the agent itself** (not only the person) can read it and complete the connection independently — with no assumptions about what is "already known" about a specific vendor.

## Migrating from Claude to Another Agent

Your notes, plans, Work Products, rules, and Skills are stored in the IWE folder on disk and in your repositories. When you switch agents, they stay in place: only the program that works with them changes. The only thing lost is the conversation history stored with the vendor (for example, on claude.ai).

**Step A. Choose a new agent.** You need an agent that can see files in the folder and edit them.

| Agent | How it learns IWE rules | Details |
|---|---|---|
| Codex (OpenAI): application or VS Code extension | reads `AGENTS.md` | Step 1 below; knowledge base connection — `docs/CHATGPT-CODEX-SETUP.md`, section "Connecting to Codex" |
| Kimi Code | reads `AGENTS.md`, Skills — via `extra_skill_dirs` | `docs/KIMI-SETUP.md` |
| Hermes | receives instructions via MCP (`get_instructions`), does not read repository files directly | `docs/PORTABILITY.md`, Hermes section |
| Other file-based agents (Qwen Code, Cursor, Cherry Studio, etc.) | varies — verify with Step 1 | Steps 1, 5, 6 below |
| Anthropic models via an API proxy (e.g. OpenRouter) inside one of the agents above | same as the chosen agent | Works, but token-based billing is significantly more expensive than a subscription |

If you need AI immediately — including for guidance while the new agent is not yet configured — use the browser version at [iwe.system-school.ru](https://iwe.system-school.ru/) with your MIM account (MIM subscription required). This is a chat connected to the IWE knowledge base. To let it see your materials, write "connect my GitHub" in the chat: it will provide a GitHub sign-in link, and if needed a second link for installing the `aisystant-knowledge` app, where you choose which repositories to include (see `docs/SETUP-GUIDE.md`, section 1.3c for details). It cannot see the folder on your computer, cannot run commands or Skills, and can only see what has already been pushed to GitHub and indexed; the model and request budget are limited by your subscription tier. This is sufficient for guidance and step-by-step help during migration.

**Step B. Open the IWE folder with the new agent, without making changes.** File-based agents (Codex, Kimi Code, etc.) work with files on your computer, so they need the environment folder. If you used IWE through a desktop application, the folder already exists — open it. If you worked only in claude.ai chat and your notes are in GitHub, ask the agent to clone your repository (or environment repositories) and open the cloned folder. If you are using the browser version for now, cloning is not necessary. First request: "Read `AGENTS.md` and `CLAUDE.md` in the root, do not change anything, and explain how you will work here." Verify with Step 1 below.

**Step C. Make it the primary agent.** When the agent has responded to the Step B request and its explanation is satisfactory, ask it to complete Steps 1, 5, and 6 of this document, and explicitly tell it that it is now the primary agent. Steps 2–4 (file coordination and attribution) are only needed if multiple agents are running in parallel.

**First day with the new agent.** Full IWE functionality (Skills, safety checks, scheduled roles) currently works only in Claude Code; other agents work with the shared rules from `AGENTS.md` and the connection to our MCP. Therefore, on the first day:
- **Run Day Open and Day Close by text, without slash commands.** Tell the agent: "Read `.claude/skills/day-open/SKILL.md` and execute its steps in order, skipping nothing; at the end, list the steps you completed." Do the same for Day Close with `.claude/skills/day-close/SKILL.md`. With Kimi, Skills are connected via `extra_skill_dirs` (see `docs/KIMI-SETUP.md`).
- **The new agent does not have safety checks.** The hooks in `.claude/settings.json` are run only by Claude Code. Before each commit, ask the agent to show the list of changed files, and do not allow it to delete files or edit `.claude/hooks/` or `.claude/settings.json` without your explicit approval.
- **If the agent skips a step, write it into its rules** (`extensions/`) — do not just correct it in the moment.

**Step D. For the first week, verify Day Open and Day Close independently.** A different model follows instructions differently and may skip items it considered optional. The check must be done by someone who did not run the day. If you have only one agent, connect the browser version at [iwe.system-school.ru](https://iwe.system-school.ru/) to your GitHub (write "connect my GitHub" in the chat); close the day with the new primary agent; once it has pushed the notes to GitHub, write to the browser version: "Read the Day Close protocol and my notes for today, check whether all protocol steps were completed, do not change anything, and list any skipped items and discrepancies." It can only see the pushed result, not the work on your computer. If you have a second agent from a different vendor (for example, Codex closed the day and Kimi is checking), open it in the same folder with the same task. Record any found gaps in the new agent's rules (`extensions/`).

## What You Get

- When the new agent opens the repository, it will read `AGENTS.md` and apply the shared IWE rules.
- If the agent edits repository files simultaneously with other agents, it will coordinate with them through the shared local lock gateway without overwriting others' changes.
- The agent's commits will have correct attribution (showing which agent changed what).

## Step 1. Read AGENTS.md

The `AGENTS.md` file in the repository root is the shared minimum set of rules for any file-based agent (not specific to one vendor). Most modern CLI agents (Claude Code, Codex, Kimi, Cline) read it automatically when the directory is opened — no separate configuration is needed.

**Verification:** open the repository with the new agent and ask it directly — "did you read AGENTS.md in the repository root? List 3 rules from it." If the agent cannot answer — check whether it supports automatic reading of instruction files in the repo root (for some vendors this is a separate setting — see the agent's documentation for the keywords "project instructions", "system prompt from file", "AGENTS.md support").

### 1.1. If Auto-Loading Is Not Available (Verified on Hermes)

Some agents (for example Hermes) do not read `AGENTS.md` automatically at all — and there is no separate setting to enable this. The check above will consistently return "no" for them; this is not a reason to look for a hidden flag. Instead, ask the agent explicitly as the first message:

> "Read the file `AGENTS.md` in the repository root and follow the rules stated there. Confirm that the file has been read and list 3 rules from it."

After this, the agent typically behaves normally for the rest of the Session without further reminders — the instruction itself is not forgotten, only the fact that it needed to be explicitly requested. If the repository tree contains multiple `AGENTS.md` files, the more specific one (deeper in the directory tree) takes priority, as with any agent that supports auto-loading.

## Step 2. Determine Whether File Coordination Is Needed

Coordination is needed if another agent (a person + Claude, or multiple CLI agents in parallel) may work on the same repository files simultaneously.

It is not needed if the agent works solo and never overlaps with others on the same files — in that case, skip Steps 3–4 and go directly to Step 5.

## Step 3. Connect the Agent to the Local Lock Gateway

IWE uses a local MCP server (`DS-MCP/local-gateway`) that maintains a shared file lock manager. Any agent that supports MCP (Model Context Protocol) as a client can connect to it.

### 3.1. Check Whether the Agent Supports an MCP Client

Ask the agent's documentation or the agent itself: "do you support connecting to external MCP servers as a client, and can you pass environment variables when starting a server?"

If yes — the agent typically has a subcommand such as `<agent> mcp add` or a configuration file (`config.toml`, `config.yaml`, `settings.json`) where a new MCP server entry is added.

### 3.2. Find the Local Gateway Start Command

If your repository's `.mcp.json` already has an `iwe-local-gateway` entry (someone connected the gateway previously) — copy the `command` and `args` from there; that is the fastest path.

If the entry does not yet exist — the gateway itself is most likely not installed either (it is not part of the template directly; it is a separate dependency with its own version lifecycle). Install it:

```bash
bash setup/optional/setup-local-gateway.sh
```

The script clones the gateway at a pinned version, builds it, starts the daemon, and prints a ready `command`/`args`/`env` block to paste into `.mcp.json` — use it in Step 3.3 below. The path to `proxy.js` in that block is `node <absolute-path-to-your-IWE>/DS-MCP/local-gateway/dist/proxy.js`.

**Important:** `env.IWE_AGENT_ID` in the printed block is set to the agent that ran the script (or `claude-code` by default). When registering the **second and subsequent** agents, replace this value with a unique name for each one (see Step 3.3 below); identical `IWE_AGENT_ID` values across different agents silently breaks lock coordination.

### 3.3. Register the Agent with a Unique IWE_AGENT_ID

Each agent gets its own unique identifier through the environment variable `IWE_AGENT_ID` — the local gateway uses it to distinguish which agent holds a lock on a file. The identifier is a short name with no spaces (for example `codex`, `hermes`, `kimicode`, `chatgpt`).

**General registration syntax (replace placeholders for the specific agent):**

```
<agent-command> mcp add iwe-local-gateway --env IWE_AGENT_ID=<unique-agent-name> -- node <path-to-proxy.js>
```

**Three verified examples** (different agents, different registration syntax — same general principle):

```bash
# Codex (standard --env flag for stdio MCP servers)
codex mcp add iwe-local-gateway --env IWE_AGENT_ID=codex -- node /path/to/IWE/DS-MCP/local-gateway/dist/proxy.js

# Hermes (separate --command/--args/--env flags)
hermes mcp add iwe-local-gateway --command node --args /path/to/IWE/DS-MCP/local-gateway/dist/proxy.js --env IWE_AGENT_ID=hermes

# Kimi (via MCP client config, not a CLI subcommand — see docs/KIMI-SETUP.md)
```

If your agent has neither an `mcp add` CLI subcommand nor a config file for MCP clients — it **does not support MCP as a client**, and coordination through the local gateway cannot be configured for it by technical means. In this case the agent can participate only at the level of Step 1 (reading AGENTS.md), without file coordination — tell the user this directly and do not invent a workaround.

### 3.4. Verify Registration

```bash
<agent> mcp list
```

The output should include an `iwe-local-gateway` entry. If the agent supports direct MCP tool calls from the chat — try calling `gateway_status`; the response should return `locks: []` (an empty list of active locks) if no one currently holds a file lock.

## Step 4. Configure Commit Attribution

Add a trailer of the following form to the agent's configuration (or use a flag at commit time):

```
Co-Authored-By: <Agent name> <noreply@vendor-domain>
```

For example:
- `Co-Authored-By: Codex <noreply@openai.com>`
- `Co-Authored-By: Hermes <noreply@aisystant.com>`
- `Co-Authored-By: Kimi <noreply@moonshot.cn>`

If you are unsure of the correct vendor domain — use the official product domain of the agent. After the first real commit, verify that the email does not look like a spam address and does not trigger errors in the repository's git hooks.

## Step 5. Point the Agent to IWE Skills (Optional)

If the agent has its own mechanism for loading additional instructions/Skills (analogous to `.claude/skills/` in Claude Code) — point it to the `.claude/skills/` path of your repository, in the same way as is done for Kimi (`extra_skill_dirs` in `~/.kimi/config.toml`, see `docs/KIMI-SETUP.md`).

If no such mechanism exists — skip this step; it does not block the agent's other work.

**Codex.** Codex reads Skills only from the `.agents/skills` folder of the IWE working directory. Installing and updating the template automatically places a symlink there for each Skill whose `runs_on` list in the header includes `codex`. There are no copies: a Skill is edited in one place, inside `.claude/skills`. Skills that require Claude Code-only capabilities are not delivered to Codex until they have a fallback path. The Day Close verification-by-a-clean-context-assistant has such a fallback (`scripts/close_verify_fallback.py`): Codex receives the `run-protocol` Skill; `day-close` and other close Skills become available after their own live verification.

To rebuild symlinks manually (for example, after editing `runs_on` in your own Skill):

```bash
python3 scripts/skill_links.py --workspace ~/IWE
```

Run the command from the template folder. The output lines mean: `link` — symlink created; `unlink` — symlink removed; `CONFLICT` — your own file or folder is at that location (the script does not touch it); `REFUSED` — the OS denied symlink creation. The last case occurs on Windows without Developer Mode enabled: enable it (Settings → Privacy & Security → For Developers) and re-run the command. There is no copy mode. The script manages symlinks in `.agents/skills` pointing to Skill folders in `.claude/skills`: do not place your own symlinks there — they will be removed on the next update (shown as `unlink` in the output). The script does not distribute a Skill whose folder itself is a symlink pointing outside `.claude/skills`.

### Migrating IWE Skills to Codex: Step-by-Step Instructions (Version 1)

For a person who already has IWE installed and has Codex on the same computer (the ChatGPT application with Codex, or the VS Code extension). Claude is not required. Version 1 applies to the template that includes `scripts/skill_links.py` and `scripts/close_verify_fallback.py`; when steps change, the version number increments and a line is added to `CHANGELOG.md`.

**Step 1. Open Terminal.** Press Cmd+Space, type `Terminal`, press Enter. A window with a blinking input prompt will open. In VS Code the same applies: menu Terminal → New Terminal. Paste the command into that window and press Enter:

```bash
cd ~/IWE/IWE
```

No errors means the input prompt simply returned. The message "No such file or directory" means the template is in a different folder: navigate to wherever it is installed.

**Step 2. Create Skill symlinks.** In the same window, paste the command and press Enter:

```bash
python3 scripts/skill_links.py --workspace ~/IWE
```

Lines of the form `link: <skill name>` will scroll past, and the last line will read something like `skill links: 34 new, 0 kept, 0 removed, 0 conflicts, 0 refused`. The step passed if it shows `0 conflicts` and `0 refused`. Otherwise, see the `CONFLICT` and `REFUSED` explanations above.

**Step 3. Verify that the symlinks are in place.** In the same window, paste the command and press Enter:

```bash
ls ~/IWE/.agents/skills
```

A list of Skill names will appear. It must include `think`, `archgate`, `decompose`, `run-protocol`, and `wp-new`. The template author's Skills and not-yet-verified close Skills (`day-close`, `week-close`) are absent — this is expected.

**Step 4. Navigate to the IWE working folder and start Codex.** In the same window, paste the first command and press Enter:

```bash
cd ~/IWE
```

Then the second, press Enter again:

```bash
codex
```

The Codex window with an input field at the bottom will appear. "command not found" means the `codex` command is not available in Terminal: open Codex from the ChatGPT application and select the IWE working folder there. If you are working in VS Code, open the IWE folder (menu File → Open Folder) and open the Codex panel on the left. Paste the following task into the input field and press Enter:

```text
Read the skill .agents/skills/think/SKILL.md and use it to solve the task: decide whether to store program settings in a file or in a database. Show the method stages.
```

The step passed if the response contains five headings in order: Abduction, Deduction, Induction, Audit, Decide. If the headings are absent, find the Codex version by pasting this command into Terminal (not into Codex):

```bash
codex --version
```

and include the version and Codex's response in a report to the template.

**Step 5. Closing a session without Claude.** Codex does not have a clean-context assistant invoked by the `run-protocol` Skill. Therefore, on the final step of closing, the verification is performed by a separate process via `scripts/close_verify_fallback.py`, which requires a second agent already connected to IWE (for example, Kimi). Ask Codex in its window: "close the session using the run-protocol Skill." Codex will read the "Fallback Path" paragraph in Step 4 of the Skill and start the check. The step passed if Codex shows a verdict containing the word `pass`, or a list of findings (`fail`), and does not silently skip anything. If the script returns code `23`, Codex blocked network access or launch of another agent: grant the permission in its window, or close the session from a regular Terminal. All other codes are explained in the same Skill paragraph.

**Kimi Code in Terminal (optional).** Kimi Code reads the `.claude/skills` folder directly. To point it to only the shared Skills, start it in Terminal from the `~/IWE` folder with this command:

```bash
kimi --skills-dir .agents/skills
```

The Kimi window with an input field will open. The Kimi Code VS Code extension has not been verified with this method.

**What is not verified in Version 1:** Windows (Developer Mode required, see above), Codex versions other than 0.169, Kimi Code in the VS Code extension, Day Close and Week Close (`day-close`, `week-close`) in Codex.

## Step 6. Connecting to Aisystant MCP (Non-Claude Agents)

> Claude Code connects to the Aisystant knowledge base via `claude.ai` connectors (`docs/SETUP-GUIDE.md`, Step 1.3b) — it has a separate browser settings page. Other agents (Hermes, etc.) connect differently: directly through their own MCP client, without `claude.ai`. This step covers those agents. Ready-to-use step-by-step prompts for ChatGPT (including a working Business/Enterprise account) and for local Codex are in `docs/CHATGPT-CODEX-SETUP.md`.

### 6.1. Check the MCP Config

If your repository's `.mcp.json` already contains an `iwe-knowledge` entry — it was created automatically by the installer (`setup.sh`) during installation. Open the file and check the `url` and `headers`:

- If there is an `Authorization: Bearer ...` header — authorization is already configured (this is typically the path for T3/T4 tier via `IWE_ICT_TOKEN`); a browser is not needed; go to Step 6.3.
- If there is no header — the server uses OAuth2; authorization will occur on the agent's first real request to the server (not during `setup.sh`).

### 6.2. OAuth2 Authorization: What to Watch For

When the agent's MCP client first contacts the `iwe-knowledge` server, the server responds with an OAuth2 authorization request — this will open the **default system browser** (the one set as default in the OS, not necessarily the one you typically use).

**Before connecting the agent — make sure you are already logged in to your Aisystant account in the default browser.** If not — either log in in advance, or temporarily change the default browser to one where you are already signed in, for the duration of this step. Otherwise authorization will open on an empty or wrong session, and you will need to repeat the attempt after signing in.

### 6.3. Verify That MCP Tools Are Available

Ask the agent directly (exact wording depends on how your agent refers to available tools): "which MCP tools are available to you? Is there anything about knowledge/a knowledge base among them?" If the agent supports direct tool calls — ask it to run a knowledge base search and check whether real documents are returned, rather than a connection error.

### 6.4. Troubleshooting

| Problem | Solution |
|----------|---------|
| Browser did not open automatically (headless/remote session) | Copy the authorization URL from the agent output and open it manually on any device with a browser and internet access |
| Authorization succeeded but under the wrong account | Log out of the wrong Aisystant account in the default browser and repeat Step 6.2 |
| Agent does not support an MCP client at all | Knowledge base coordination through this path is technically impossible — see Step 3.1; the same limitation applies here |

## Connection Verification (Smoke Test)

### Codex Calling Kimi or Claude as a Peer Partner

This step is only needed when Codex runs `kimi-peer-adapter.sh` or
`claude-peer-adapter.sh` as a child process. Normal standalone use of Kimi and
Claude does not require any changes to the Codex sandbox.

By default, the local Codex sandbox blocks outgoing network and writes outside
the working directory. Both restrictions matter: Kimi writes state to `~/.kimi`,
Claude writes to `~/.claude` and `~/.claude.json`, and both clients contact
their respective APIs. These permissions are sufficient for Kimi, but on macOS
they may be only necessary for Claude: its active authorization may be stored in
the Keychain, which is inaccessible to a child process inside the sandbox.
In your user `~/.codex/config.toml`, keep the root keys before the first
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
`$HOME`, so a literal `"$HOME/.kimi"` does not work here. Existing root keys
`model` and `model_reasoning_effort` must remain above `[sandbox_workspace_write]`
— otherwise TOML will assign them to the wrong section.

**The security decision must be made explicitly:** in Codex 0.146.0,
`sandbox_workspace_write.network_access = true` opens outgoing network access for
all commands inside that sandbox. This version does not accept `[features.network_proxy]`;
do not copy settings from a newer schema without verifying against the installed binary.
Specific risk: any command inside the sandbox (not only the Kimi/Claude call itself)
gets full outgoing network access — a tool invoked by the agent inside this sandbox
can technically send data to an arbitrary external host. If broad network access is
unacceptable, run the peer session from a separate trusted terminal instead of
relaxing the sandbox.

If Claude inside the sandbox responds with `Not logged in · Please run /login`,
do not re-run the login flow automatically. First call the same adapter from a
regular terminal: on macOS this is a typical sign that the Keychain is inaccessible
from an isolated process, not that authorization has been lost. Until the installed
Codex provides a narrowly scoped Keychain permission, the canonical path for
Codex→Claude is an external trusted executor or a separate terminal with the same
minimal text Projection. Do not enable `danger-full-access` solely for this
workaround.

After saving, fully restart Codex/VS Code and verify the configuration:

```bash
codex debug models
codex doctor
```

Then run a short live call to Kimi through the adapter. Test Claude inside the
sandbox first; if a Keychain error occurs, repeat from a trusted terminal.
Successful configuration commands do not substitute for actual responses from
Kimi and Claude.

Run on a real small task:

1. **The agent sees AGENTS.md** — ask the agent directly; see the check in Step 1.
2. **If gateway coordination is configured** — `<agent> mcp list` shows `iwe-local-gateway`.
3. **A real file edit with a lock** (only if coordination was configured):
   - Ask the agent to call `acquire_file_lock` on any test file, make a small edit, commit with the correct trailer, and call `release_file_lock`.
   - Check the commit: `git log -1 --format="%H %s%n%b"` — it must contain `Co-Authored-By` with the correct name and domain.
   - Verify the lock was released: calling `gateway_status` should again show `locks: []`.

If any of this does not work — do not connect the agent to file coordination until you have identified the cause. An agent that commits without attribution or does not release locks creates confusion for other agents in the repository.

## Difference from "Orchestrating an Agent as a Peer Partner"

Do not confuse this connection with the wrapper adapter (`*-peer-adapter.sh`), where one agent calls another headlessly as a subordinate peer partner inside a peer session (one writes, the other critiques, and the entire dialogue is managed by the first agent). That is a different scenario — the calling agent orchestrates the called one, rather than two independent MCP clients coordinating as equals through locks. The connection described in this document makes the new agent an independent participant in the repository, not a subprocess subordinate to another agent.

## If Something Does Not Work

1. Verify that the path to `proxy.js` in the registration command is absolute and matches the actual location of your `DS-MCP/local-gateway` clone.
2. Verify that `IWE_AGENT_ID` in the registration command is unique and does not match any already-connected agent (`<agent> mcp list` for each already-connected agent).
3. If the agent does not support an MCP client at all — file coordination is technically impossible for it; limit it to Step 1 (AGENTS.md).
4. Check the `gateway_status` output — a stuck lock (`locks` is non-empty after a long time) typically means the previous agent did not call `release_file_lock` after committing.
5. An error such as "connect ECONNREFUSED" when calling gateway tools typically means the daemon is not running — re-run `bash setup/optional/setup-local-gateway.sh`; it checks for the daemon and starts it if needed.

## Related Documents

- `AGENTS.md` — shared rules for all agents.
- `setup/optional/setup-local-gateway.sh` — gateway installation (clone, build, daemon start).
- `docs/KIMI-SETUP.md` — specifics of connecting Kimi Code (detailed example for Step 5).
- `docs/CHATGPT-CODEX-SETUP.md` — ready-to-use prompts for connecting ChatGPT and Codex to Aisystant MCP (Step 6).
- `docs/inter-agent-handoff.md` — passing context between agents without a shared gateway.
- `memory/agent-vendor-connect-pattern.md` — a brief technical reference card for the same pattern (reference format for agent Memory, not a step-by-step guide for a person).

