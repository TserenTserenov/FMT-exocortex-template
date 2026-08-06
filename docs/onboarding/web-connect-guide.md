# Connecting IWE from a Browser in 2 Minutes

> **Who this is for:** You want to connect an AI assistant that knows the MIM methodology, knows you, and grows with you. Nothing to install — works directly in the browser.
>
> **What you need:** A Claude Pro subscription ($20/month) on claude.ai. This gives you access to the AI assistant. MIM Knowledge connects free for 30 days (then ~$10/month on system-school.ru).

---

## Step 1. Open Claude Settings

Go to [claude.ai](https://claude.ai) → click your profile name (bottom left corner) → **Settings**

## Step 2. Add IWE

In Settings, find the **Integrations** section → click **Add custom integration** (or **Add connector**):

- **Name:** `IWE`
- **URL:** `https://mcp.aisystant.com/mcp`

Click **Save**.

## Step 3. Authenticate

After adding, Claude will prompt you to sign in — log in with your system-school.ru account.

If you do not have an account, register at [system-school.ru](https://system-school.ru). The first 30 days are free.

## Step 4. Done — Start a Conversation

Open a new chat and type:

> **Where do I start?**

The AI assistant will load the IWE context and guide you from there: it will offer to answer a question, run a level diagnostic, or provide a development roadmap.

---

## Troubleshooting

**The Connect button spins and nothing happens.** The browser has blocked the popup window where the login form opens. In Safari: Settings → Websites → Pop-up Windows → set claude.ai to Allow. The simplest workaround is to repeat the connection in Chrome.

**After entering your login and password — "Safari Cannot Open the Page" (or a similar error).** The browser failed to return to claude.ai after login. Check that your VPN is enabled for the entire device (not just as an extension in one browser) and did not disconnect mid-process: after entering the password, the browser returns to claude.ai, and the VPN must be active at that moment.

**Before retrying,** remove the partially connected IWE connector (Settings → Connectors → next to IWE → Remove) and add it again following Step 2 — this starts the connection from a clean state.

**Still not working?** Send support a screenshot showing the browser address bar at the moment of the error — the URL immediately shows which step failed.

---

## What You Get

| Capability | What It Does |
|------------|-------------|
| **Knowledge base** | Search across 5000+ MIM documents — methodologies, guides, courses |
| **Your profile** | Goals, level, progress — the AI knows you and adapts its responses |
| **Navigator** | Tells you where to start, which program to choose, how to build a rhythm |
| **Diagnostic** | Identifies your mastery stage and what is blocking your growth |
| **Personal knowledge base** | Save notes, ideas, strategy — the AI will offer to create it in your first conversation |

## Pricing

| What | Cost | Why |
|------|------|-----|
| **Claude Pro** | $20/month | AI assistant (dialogue, analysis, generation) |
| **MIM Knowledge** | ~$10/month | Programs, guides, personalization, community |

The first 30 days of MIM Knowledge are free. The price is locked forever with auto-renewal (it will be ~$40/month later).

Knowledge subscription: [system-school.ru/open-endedness](https://system-school.ru/open-endedness)

## Why This Matters (Brief)

Plain ChatGPT or Claude is like a smart new hire on their first day. They know a lot, but they do not know *you*. IWE turns it into a personal assistant:

- **Knows the subject** — backed by a knowledge base covering Systems Thinking, management, and engineering
- **Knows you** — your goals, level, and context
- **Grows with you** — the more you work with it, the more precise the help

The competition now is not between people, but between people and their AI assistants.

---

## Other AI Clients

IWE works beyond Claude.ai:

| Client | How to Connect |
|--------|---------------|
| **Cursor** | Settings → Features → MCP → Add New MCP Server → URL: `https://mcp.aisystant.com/mcp` |
| **ChatGPT** | Business/Enterprise → Workspace Settings → Add MCP connector |
| **Claude Code (full IWE)** | [SETUP-GUIDE.md](../SETUP-GUIDE.md) — day planning, AI strategist, automated reports |

---

## Issues

| Issue | Solution |
|-------|---------|
| No Integrations section in Claude | A Claude Pro subscription ($20/month) is required |
| Authentication error | Check that you have an account on system-school.ru |
| Claude does not use IWE tools | Open a new chat. Type: "Use IWE — find documents about systems thinking" |
| "Not found in the knowledge base" | Check that the integration is active: Settings → Integrations → IWE → Connected |

---

*Created: 2026-04-08 | Related: [post in the club](https://systemsworld.club/t/iwe-dostupen-iz-brauzera/38058) | DP.SC.119, DP.SC.101*