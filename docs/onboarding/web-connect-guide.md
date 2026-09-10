# Connecting IWE from a Browser in 2 Minutes

> **Who this is for:** You want to connect an AI assistant that knows the MIM methodology, knows you, and grows with you. No installation required — works directly in the browser.
>
> **What you need:** A Claude Pro subscription ($20/month) on claude.ai. This gives you access to the AI assistant. MIM knowledge connects for free.

---

## Step 1. Open Claude Settings

Go to [claude.ai](https://claude.ai) → click your profile name (bottom left corner) → **Settings**

## Step 2. Add IWE

In Settings, find the **Integrations** section → click **Add custom integration** (or **Add connector**):

- **Name:** `IWE`
- **URL:** `https://mcp.aisystant.com/mcp`

Click **Save**.

## Step 3. Authenticate

After adding the integration, Claude will prompt you to sign in — log in using your system-school.ru account.

If you do not have an account, register at [system-school.ru](https://system-school.ru).

## Step 4. Done — Start a Conversation

Open a new chat and write:

> **Where do I start?**

The AI assistant will load the IWE context and guide you forward: it will offer to answer a question, run a level diagnostic, or generate a development roadmap.

---

## If the Connection Fails

**The Connect button spins and nothing happens.** The browser has blocked the popup window where the sign-in form opens. In Safari: Settings → Websites → Pop-up Windows → select "Allow" for claude.ai. The simplest workaround is to retry the connection in Chrome.

**After entering your login and password — "Safari Cannot Open the Page" (or a similar error).** The browser failed to return to claude.ai after sign-in. Check that your VPN is enabled for the entire device (not just as an extension in one browser) and did not disconnect during the process: after you enter your password, the browser returns to claude.ai, and the VPN must be active at that moment.

**Before retrying,** remove the partially connected IWE connector (Settings → Connectors → next to IWE → Remove) and add it again following Step 2 — this starts the connection from a clean state.

**Still not working?** Send support a screenshot showing the browser address bar at the moment of the error — the URL immediately indicates which step failed.

---

## What You Get

| Capability | What It Does |
|------------|-------------|
| **Knowledge base** | Search across 5000+ MIM documents — methodology, guides, courses |
| **Your profile** | Goals, level, Progress — the AI knows you and adapts its responses |
| **Navigator** | Suggests where to start, which program to choose, how to build a rhythm |
| **Diagnostics** | Identifies your Mastery stage and what is blocking your growth |
| **Personal knowledge base** | Save notes, ideas, and strategy — the AI will offer to create it in your first conversation |

## Pricing

| What | Cost | Purpose |
|------|------|---------|
| **Claude Pro** | $20/month | AI assistant (dialogue, analysis, generation) |
| **MIM Knowledge** | Free forever | Knowledge base search, universal guides, Mastery stage diagnostics |

Personalization (personal guide, digital twin) requires a paid "Intelligence Engineering" subscription — details at [system-school.ru](https://system-school.ru).

## Why You Need This (in Brief)

A plain ChatGPT or Claude is like a smart new hire on their first day. They know a lot, but they do not know *you*. IWE turns it into a personal assistant:

- **Knows the subject** — backed by a knowledge base covering Systems Thinking, management, and engineering
- **Knows you** — your goals, level, and context
- **Grows with you** — the more you work with it, the more precise the assistance

Competition today is not between people. It is between people together with their AI assistants.

---

## Other AI Clients

IWE works not only in Claude.ai:

| Client | How to Connect |
|--------|---------------|
| **Cursor** | Settings → Features → MCP → Add New MCP Server → URL: `https://mcp.aisystant.com/mcp` |
| **ChatGPT** (Pro/Plus/Business/Enterprise/Education) | Settings → Connectors → Create → ready-made prompts in [CHATGPT-CODEX-SETUP.md](../CHATGPT-CODEX-SETUP.md) |
| **Claude Code (full IWE)** | [SETUP-GUIDE.md](../SETUP-GUIDE.md) — day planning, AI strategist, automated reports |

---

## Troubleshooting

| Problem | Solution |
|---------|---------|
| No Integrations section in Claude | A Claude Pro subscription ($20/month) is required |
| Authentication error | Check that you have an account on system-school.ru |
| Claude does not use IWE tools | Open a new chat. Write: "Use IWE — find documents about systems thinking" |
| "Not found in the knowledge base" | Check that the integration is active: Settings → Integrations → IWE → Connected |

---

*Created: 2026-04-08 | Related: [club post](https://systemsworld.club/t/iwe-dostupen-iz-brauzera/38058) | DP.SC.119, DP.SC.101*