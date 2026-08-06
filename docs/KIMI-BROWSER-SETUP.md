---
scope: FMT-exocortex-template
status: active
title: Browser Access to IWE via the MIM Stand
updated: 2026-08-06
---

# Browser Access to IWE via the MIM Stand

> Who this is for: a newcomer without VS Code and without Claude who wants to try IWE directly in the browser.
> Time: ~2 minutes.
> Difference from `KIMI-SETUP.md`: that document covers Kimi Code inside VS Code (for those who already write code and have cloned the repository). This document covers a standalone browser-based stand — no installation required.

## What You Will Get

- You will open a web page with a chat interface.
- You will ask a question — the assistant will find the answer in the knowledge base and the IWE Platform Memory, just as Claude does through its browser connector.
- You will sign in once with your platform account — after that, the assistant sees only your personal data, not the data of other users.
- You will use the stand under your platform subscription. No separate model provider key is required.

## Why Sign-In and Subscription Are Required

Unlike Claude, which can connect directly to the platform through a connector, some models require a dedicated web page. IWE provides the MIM stand for this purpose. It uses the same sign-in as all other platform channels: after signing in, the assistant gains access to knowledge base search and your personal Memory, but sees only your data.

Model responses are billed through the platform subscription. The stand verifies the subscription automatically. You do not need to enter a Moonshot, OpenRouter, or other provider key.

## How to Connect

1. Open the [MIM stand](https://mim-iwe-production.up.railway.app).
2. Click the sign-in button.
3. If you already have an account, sign in as usual. If not, you can register on the same page.
4. With an active subscription, the chat will open and you can start writing your question immediately. If there is no subscription, the stand will display a clear message instead of a technical error.

## What You Can Ask

- Questions about the structure and principles of IWE (for example, "what is the ORZ fractal" or "how is platform Memory structured").
- Questions that require a search of the platform knowledge base.

The assistant does not respond instantly — a question that requires a search may take up to a minute. If the answer does not arrive within the allotted time, the page will suggest rephrasing the question more briefly or specifically. This is normal behavior, not an error.

## If Something Does Not Work

1. The page shows the sign-in button again after you have already signed in — try signing in again; your browser Session may have expired.
2. The response takes too long or a network error appears — refresh the page and try asking your question again.
3. If sign-in fails, contact the instructor or the platform administrator.
4. If the stand reports that there is no active subscription, check your platform subscription or contact the administrator.

## Related Documents

- `docs/KIMI-SETUP.md` — Kimi Code inside VS Code, for those who work with code.
- `docs/onboarding/web-connect-guide.md` — connecting IWE to Claude through the browser connector.
- `docs/inter-agent-handoff.md` — how different agents pass context to each other (for those already working in VS Code who want to go further).

