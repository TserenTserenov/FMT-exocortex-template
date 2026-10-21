---
description: Template for downstream files that inherit the IWE base conversational
  style
domains:
- communication
- ux
- template
horizon: warm
name: communication-style-downstream-template
owner: platform
schema_version: 1
status: active
type: reference
valid_from: 2026-06-01
---

# Downstream File Template for Conversational Style

> Use this template in any prompt, instruction, or system prompt where an agent communicates with people.
> Copy the block below and add channel-specific rules.

---

## Communication Style

Communication style follows `communication-style-base.md`.
Base rules are inline below (synchronized by `scripts/sync-communication-style.py`).
Additional rules for this channel or role follow below.

<!-- COMMUNICATION-STYLE-BASE-START -->
[The script inserts base rules from communication-style-base.md here automatically.
Do not edit manually — changes will be overwritten on the next synchronization.]
<!-- COMMUNICATION-STYLE-BASE-END -->

---

## Additional Rules (channel-specific or role-specific)

[Write rules here that apply only to this specific channel or role.
Examples: Telegram formatting, new user onboarding, Navigator role constraints.]

**Examples for different downstreams:**

**Telegram bot:**
- Commands (`/start`, `/help`) — plain text only, not in `<code>`.
- Markdown headers (`#`, `##`) — do not render. Use `*bold text*` instead.
- Tables — do not render. Use lists with `*bold*` for headings instead.
- Standard response — up to 80 words.

**Browser (claude.ai):**
- Up to 7 items, fits on a single screen.
- Do not mention technical connection details (URL, OAuth flow) unless the user asks.

**Chat with pilot (Claude Code, Kimi):**
- Plain-language mode by default.
- Technical mode — only if the pilot themselves writes `grep`, `git`, paths, SHA.

---

## How to Add a New Downstream

1. Copy the "Communication Style" block above into your file.
2. Do not modify the content between `<!-- COMMUNICATION-STYLE-BASE-START -->` and `<!-- COMMUNICATION-STYLE-BASE-END -->`.
3. Add your channel-specific rules below.
4. Register the path in `scripts/sync-communication-style.yaml` (create it from `scripts/sync-communication-style.yaml.example` if the file does not exist yet — it is author-local and is not committed to git).
