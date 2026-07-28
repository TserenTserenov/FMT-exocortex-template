---
scope: FMT-exocortex-template
status: active
title: Browser Access to IWE via Kimi
updated: 2026-07-28
---

# Browser Access to IWE via Kimi

> Audience: beginners without VS Code or Claude who want to try IWE via Kimi directly in the browser.
> Time: ~5 minutes (including getting your Moonshot API key).
> Difference from `KIMI-SETUP.md`: that document covers Kimi Code inside VS Code (for users who already code and have cloned the Repository). This document covers a standalone web page — no installation required.

## What You Get

- You open a web page with a chat interface.
- You ask a question — Kimi finds the answer in the IWE Platform knowledge base and Memory, the same way Claude does through its browser connector.
- You sign in once with your aisystant account — after that, the Platform sees only your personal data, not other users' data.
- You paste your API key from Moonshot (the company that created Kimi) once — after that, you pay for your queries directly to Moonshot, not through us.

## Why You Need an Account Login and Your Own Moonshot Key

Unlike Claude (which can connect directly to the Platform without a separate page), Kimi in the browser does not have that built-in capability. To work around this, IWE provides a dedicated intermediary web page. It uses the same aisystant login as all other Platform channels — after signing in, Kimi gets access to exactly the same tools (knowledge base search, your personal Memory) as in other channels, but sees only your data.

Payment for model responses works the same way as with Claude: there, you pay Anthropic for your subscription directly, and the Platform only forwards the request. Here it is the same — you pay Moonshot for your Kimi queries directly, by entering your own API key.

## How to Connect

1. Open the demo stand page (the link will be provided by your instructor or Platform administrator).
2. Click "Sign in via aisystant".
3. If you already have an account, sign in the usual way. If not, you can register on the same page.
4. After signing in, the page will ask for your Moonshot key. Follow the link to `platform.moonshot.ai`, create an account there (if you do not have one yet), and generate a key in the API keys section.
5. Paste the key on our page and click "Save and continue" — you can start asking questions immediately.

## What You Can Ask

- Questions about the structure and principles of IWE (for example, "what is the ORZ fractal", "how does the Platform Memory work").
- Questions that require a search of the Platform knowledge base.

Kimi does not respond instantly — a question that requires a search may take up to one minute. If no answer arrives within the allotted time, the page will suggest rephrasing the question more briefly or specifically — this is normal, not an error.

## If Something Does Not Work

1. The page shows the sign-in button again after you have already signed in — try signing in again; your browser Session may have expired.
2. The answer takes a long time or a network error appears — refresh the page and try asking the question again.
3. If signing in via aisystant fails — contact your instructor or Platform administrator.
4. If you cannot create a key on `platform.moonshot.ai` (for example, payment with your card does not go through) — that is a question for Moonshot directly; IWE Platform has no involvement in that payment.

## Related Documents

- `docs/KIMI-SETUP.md` — Kimi Code inside VS Code, for users who work with code.
- `docs/inter-agent-handoff.md` — how different agents pass context to each other (for users who already work in VS Code and want to go further).

