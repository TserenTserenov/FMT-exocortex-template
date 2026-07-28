---
scope: FMT-exocortex-template
status: active
title: Browser Access to IWE via Kimi
updated: 2026-07-28
---

# Browser Access to IWE via Kimi

> Who this is for: a newcomer without VS Code and without Claude who wants to try IWE via Kimi directly in the browser.
> Time: ~2 minutes.
> Difference from `KIMI-SETUP.md`: that document covers Kimi Code inside VS Code (for those who already write code and have cloned the repository). This one covers a standalone web page — no installation required.

## What you will get

- You open a web page with a chat interface.
- You ask a question — Kimi finds the answer in the knowledge base and the memory of the IWE platform, the same way Claude does through its browser connector.
- You sign in once using your Aisystant account — after that, the platform sees only your personal data, not the data of other users.

## Why you need to sign in

Unlike Claude (which can connect directly to the platform without a separate page), Kimi in the browser does not have that built-in capability. To work around this, IWE provides a dedicated intermediary web page. It uses the same Aisystant sign-in as all other platform channels — after signing in, Kimi gets access to exactly the same tools (knowledge base search, your personal memory) as in other channels, but sees only your data.

## How to connect

1. Open the demo stand page (the link will be provided by your session instructor or platform administrator).
2. Click "Sign in via Aisystant".
3. If you already have an account — sign in the usual way. If not — you can register on the same page.
4. After signing in, you will be redirected back to the chat page — you can start asking questions immediately.

## What you can ask

- Questions about the structure and principles of IWE ("what is the ORZ fractal", "how does platform memory work").
- Questions that require a search of the platform knowledge base.

Kimi does not respond instantly — a question that requires a search may take up to a minute. If the answer does not arrive within the allotted time, the page will suggest rephrasing the question more concisely or specifically — this is normal behavior, not an error.

## If something is not working

1. The page shows the sign-in button again after you have already signed in — try signing in again; your browser session may have expired.
2. The answer takes a long time or a network error appears — refresh the page and try asking the question again.
3. If sign-in via Aisystant fails — contact your session instructor or platform administrator.

## Related documents

- `docs/KIMI-SETUP.md` — Kimi Code inside VS Code, for those who work with code.
- `docs/inter-agent-handoff.md` — how different agents pass context to each other (for those who already work in VS Code and want to go further).

