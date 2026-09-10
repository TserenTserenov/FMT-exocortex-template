---
scope: FMT-exocortex-template
status: active
title: Connecting IWE to ChatGPT and Codex
updated: 2026-09-09
---

# Connecting IWE to ChatGPT and Codex

> Audience: a user who wants access to the IWE knowledge base and tools (Aisystant MCP) from ChatGPT (personal or work account) or from local Codex — without installing the full exocortex template.
> Time: 10–15 minutes.
> The general OAuth connection principle for any file-based agent to IWE is described in `AGENT-VENDOR-SETUP.md`, step 6. This document provides ready-made prompts for two specific tools, with verified interface steps.

## What You Will Get

- ChatGPT or Codex will have access to the IWE knowledge server (`iwe-knowledge`, `https://mcp.aisystant.com/mcp`) — search across Pack repositories, guides, and the digital twin.
- The connection goes through single sign-on (OAuth) using your own aisystant account, with no manual token entry.

## Aisystant Account (MIM account)

Required for both scenarios below. Registration is free at [aisystant.system-school.ru](https://aisystant.system-school.ru/).

Pre-registering in advance is not required — if you do not have an account yet, you can create one by email directly on the OAuth authorization screen (step 6 of the prompt below); that screen is the sign-in step. The separate **@aist_me_bot** Telegram bot ([t.me/aist_me_bot](https://t.me/aist_me_bot)) uses the same account and is simply another channel — it is not required for MCP connection.

Sign in to your aisystant account in the default browser on the computer where you will connect IWE — before running the prompt from the instructions below. Otherwise the OAuth authorization will open in a foreign or empty session, and you will need to repeat the attempt after signing in.

Basic access (knowledge base search, tools such as `agent_status_list`) is free and does not require a paid subscription. A paid subscription is only needed for deeper platform levels (personal guidance, VS Code) — this does not apply to connecting MCP from ChatGPT or Codex.

## Connecting to ChatGPT (Personal or Work Account)

### Where to Open the Chat

[chatgpt.com](https://chatgpt.com), under the account — personal or Work workspace — to which you want to connect IWE.

### Prerequisites

- A ChatGPT Pro, Plus, Business, Enterprise, or Education plan — custom MCP connections are not available on the free plan.
- For a work (Business/Enterprise) workspace — administrator permission if required (Workspace Settings → Permissions & Roles → Connected Data → "Create custom MCP connectors"); the prompt below will stop and ask if the toggle is locked.
- An aisystant account as described above, signed in via the default browser.
- An agent with browser access (Computer Use); if unavailable, all prompt steps can be completed manually by following the same interface section names.

### Prompt to Paste into a New Chat

```
Configure the IWE MCP server in ChatGPT via the ChatGPT interface.

Parameters:
- Name: IWE
- Description: access to the IWE knowledge base and digital twin (Aisystant)
- URL: https://mcp.aisystant.com/mcp
- Authentication: OAuth

Use the connected Chrome via Computer Use. If Chrome is unavailable, use the built-in browser.

Steps:
1. Open Settings → Apps → Advanced settings.
2. Enable Developer mode. If the toggle is unavailable (Business/Enterprise work account) — stop and tell me that workspace administrator permission is required (Workspace Settings → Permissions & Roles → Connected Data → "Create custom MCP connectors").
3. Go to Settings → Connectors and click Create.
4. Verify the exact URL match and fill in the IWE form (Name, Description, MCP server URL, Authentication: OAuth).
5. Before final creation, show me the filled-in parameters.
6. If an OAuth authorization screen, login, password prompt, MFA, or access confirmation appears — stop and ask me to complete this step myself. Do not request the password in the chat.
7. After authorization, open Settings → Connectors → IWE and check the tool list.
8. If the list is empty, click Refresh, wait a few seconds, and check again.
9. Do not consider setup complete until agent_status_list appears among the tools.
10. Open a new chat, click "+" next to the input field, select IWE, and confirm that the IWE badge appears next to the input field.

At the end, report separately:
- whether OAuth authorization succeeded;
- whether agent_status_list appeared;
- whether IWE is selected in the new chat.
```

### Verification

Open a new chat → click "+" → select IWE from the tool list. The IWE badge should appear next to the input field — this is a reliable indicator, unlike color-coded status indicators in the interface that change between versions. Send a test query to the knowledge base and confirm that ChatGPT actually calls the IWE tool rather than responding without it.

## Connecting to Codex

### What Codex Is and Where to Open the Chat

Codex is an OpenAI tool for working with code from the terminal (command line). It is installed on your own computer separately from ChatGPT. A "Codex chat" is not a browser page — it is a terminal window with a running interactive `codex` session. Installation and official documentation: [developers.openai.com/codex](https://developers.openai.com/codex/) (instructions for Mac, Linux, and Windows). After installation, open a terminal, type `codex`, and work in the session that opens.

### Prerequisites

- Installed and authorized Codex CLI (link above).
- An aisystant account as described above, for sign-in on first connection to the server.

### Prompt to Paste into the Codex Chat

```
Configure the local IWE MCP server in Codex on this computer.

Parameters:
- Server name: iwe
- URL: https://mcp.aisystant.com/mcp
- Authentication: OAuth

First, check the existing configuration with `codex mcp list` and `codex mcp get iwe`. Do not modify or delete other MCP servers.

If IWE is absent, run:
`codex mcp add iwe --url https://mcp.aisystant.com/mcp`

If authorization is required, run:
`codex mcp login iwe`

When an OAuth screen, login, password, MFA, or access confirmation appears — stop and ask me to complete this step myself. Do not request the password in the chat.

After authorization, verify:
- `codex mcp get iwe` shows the correct URL and `enabled: true`;
- `codex mcp list` shows IWE with status `enabled` and OAuth;
- after restarting Codex or opening a new task, the `mcp__iwe__*` tools are available, including `agent_status_list`.

If the server is configured but the tools are not available in the current task, do not reinstall it: restart Codex or open a new task first, then check again.
```

### Verification

`codex mcp get iwe` shows `enabled: true`. After restarting Codex or opening a new task, the `mcp__iwe__*` tools are available, including `agent_status_list`.

## Troubleshooting

| Problem | Solution |
|----------|---------|
| Developer mode / Connectors section does not open on a work account | Workspace administrator permission is required — see prerequisites above |
| Browser for OAuth did not open automatically (headless/remote session) | Copy the authorization link from the agent output and open it manually on any device with a browser and internet access |
| Authorization succeeded but under the wrong aisystant account | Sign out of the foreign account in the default browser and repeat the authorization step |
| Tool list is empty after authorization | ChatGPT: Settings → Connectors → IWE → Refresh. Codex: `codex mcp get iwe`, restart Codex if necessary |

## See Also

- `AGENT-VENDOR-SETUP.md` — general process for connecting any file-based agent to IWE (step 6 — the same OAuth principle for Kimi, Hermes, and others)
- `KIMI-SETUP.md` — specifics of connecting Kimi Code

