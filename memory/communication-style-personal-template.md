---
description: Template for the S2 personal communication style layer — the hook does
  not read this file
domains:
- communication
- ux
- personal
horizon: warm
inherits: communication-style-base
layer: S2
name: communication-style-personal-template
owner: user
schema_version: 1
status: active
type: reference
valid_from: 2026-06-03
---

# S2 - Personal Communication Style Template

> **Layer:** S2 (personal). Inherits from S0 (`communication-style-base.md`).
> S0 rules are mandatory — they cannot be overridden. Add your own rules here.
>
> **This file is a template only. The hook does not read it (WP-412 Phase13).** To activate your rules:
> copy this file as `memory/communication-style-personal.md` (without `-template`) and
> fill in your own rules in that copy. This separation ensures that an unfilled template
> does not enter the prompt as "your style" on every new installation.

## My Rules (add or modify)

<!-- Examples — delete or replace with your own: -->

1. **Address:** use my name (specify name).
2. **Tone:** (choose: formal / friendly / neutral).
3. **Response length:** (choose: short — up to 3 sentences / medium / detailed).
4. **Terms I know:** (list them — the agent will use them directly, without explanation).
5. **Terms I do NOT know:** (list them — the agent will explain them in plain language).

## My Banned Words

<!-- If there are words or phrases that bother you, add them here: -->

| Do not use | Write instead |
|------------|---------------|
| (example: "aforementioned") | (example: "this") |

## My Channel Preferences

<!-- If you communicate across multiple channels, specify preferences for each: -->

**Telegram:**
- (example: send morning reminders before 8:00)

**Browser:**
- (example: always use spoilers for lists longer than 5 items)

---

## How This Works

- **S0 (platform)** — baseline rules for everyone. You do not see them; the agent loads them automatically.
- **S2 (`communication-style-personal.md`, your copy of this template)** — your personal rules. The agent loads them at every Session if the file exists and is not empty.
- S0 cannot be overridden. S2 adds to or tightens S0.
- To update your rules, edit your copy (`communication-style-personal.md`) and save it. You do not need to modify this file (`-template.md`) — it is a template only.
