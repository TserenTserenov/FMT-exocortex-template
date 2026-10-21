---
agents: single
argument-hint: '[optional: date in format YYYY-MM-DD, default is today]'
browser_safe: true
description: The personal guide is assembled automatically on the platform server
  on a schedule. Use this when a pilot asks to "rebuild the guide", "update my plan",
  or "assemble today's guide" — the Skill explains the current state and verifies
  that the guide has been delivered.
experimental: true
gates_enforced: []
gates_rationale: operational skill; WP Gate applicable only when creating a new WP,
  not for operational calls
gates_required: []
interaction: single-step
layer: L1
name: personal-guide-render
related:
- WP-149
- personal-guide-start
- DP.SC.187
routing:
  deterministic: false
  executor: sonnet
status: awaiting-server-tool
supersedes: v2.0.0 (call mcp render_personal_guide — tool is not published on
  platform server, see. «Current Status»)
triggers:
  phrases: []
  slash:
  - /personal-guide-render
version: 2.1.0
---

# Personal Guide: How It Is Assembled

## Current State (2026-07-29)

Guide assembly is a cloud capability of the Platform: it reads the pilot's data from the Platform databases, calls an LLM using the Platform API key, and publishes the result to the guide's GitHub Repository. All of this happens **on the platform server automatically on a schedule** — a new lesson appears every morning, and the full set is rebuilt every Monday.

Manual rebuild from chat ("rebuild now") is not yet available: the server-side MCP tool for this has not been published yet. When it is released, this Skill will call it directly — watch for Template updates.

## When to use

The pilot asks to "rebuild the guide", "update my plan", or "assemble today's guide" — or asks why today's guide is missing.

## Algorithm

## Step 0. Check the precondition (setup complete)

Call `personal_search(source: "DS-personal-guide", path: "README.md")`.

> HD #503: previously this step checked the platform path `.claude/skills/...` —
> that path lives in the Template (layer L1) and is never copied to the user Repository DS-personal-guide,
> so the check always returned empty and blocked all subsequent steps. The real indicator
> of a completed bootstrap is README.md: bootstrap itself creates it when the Repository is
> initialized (notes structure Gateway: inbox/, docs/, README.md), meaning it exists
> BEFORE the first render.

If the file is **not found** → notify the pilot:
```
Skills are not installed or installation is not complete.
Run /personal-guide-start for initial setup.
```
Stop (do not proceed to Step 1).

## Step 1. Determine the date

`date` = the Skill argument if provided (format YYYY-MM-DD), otherwise today.

Determine the ISO week of the selected date in the format `YYYY-Www`, using the ISO week year (which may differ from the calendar year around New Year).

## Step 2. Check whether the guide has been delivered

Check the pilot's `DS-personal-guide` Repository for the presence of `guide/<ISO-week>.md` (weekly material), `guide/<date>.md` (daily material), and `panel/<date>.md` (dashboard). The first two paths are candidates for different modes: do not require both to be present and do not determine the mode by day of the week alone.

If `guide.json` is available, explicitly compare the paths listed in `sections.weekly` and `days` against the selected period. Confirm the mode only when there is an explicit reference to the corresponding material; otherwise, indicate that the mode is not confirmed. A table of contents is not a completeness indicator: do not require non-existent fields `mode`, `complete`, or a dashboard reference.

**Report the result separately for each checked path:**
```
Files checked for <date>:
<learning material path> — found / not found.
panel/<date>.md — found / not found.
Mode: weekly / daily (confirmed by table of contents) / not confirmed.
```

The presence of files confirms their availability, but does not confirm a new successful generator run or that the content is current. Do not declare the set complete based on a single file or a single table of contents.

**If no learning material is found for the selected period, or the dashboard is missing:**
```
The guide is assembled on the platform server automatically (every morning on a schedule).
Manual rebuild from chat is not yet available — the server-side tool is in development.
If the guide is missing by midday — contact platform support.
```

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
