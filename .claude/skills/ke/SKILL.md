---
argument-hint: '[what to extract]'
browser_safe: true
description: Knowledge Extraction — captures and routes knowledge at work boundaries.
  Use when you discover a pattern, make a decision, find a distinction, or complete
  a sub-task.
name: ke
routing:
  deterministic: false
  executor: sonnet
---

# Knowledge Extraction (Capture-to-Pack)

Execute knowledge extraction: $ARGUMENTS

## Scope

**This Skill does:**
- Inline capture at a Session boundary (routing "what → where", announcing *"Capture: X → Y"*).
- Immediate rule recording (1–3 lines) to CLAUDE.md.
- Deferred recording (complex knowledge) — appending to `inbox/captures/<YYYY-MM>.md` (routed by event date; rule → Step 3) for the extractor agent. The legacy file `inbox/captures.md` does not receive new entries (rotation WP-526, 29.08.2026) — treat it as an archive.

**This Skill does NOT do:**
- Does not process `extraction-reports/*.md` (pending-review candidates from agent R2). That is handled by `/apply-captures`.
- Does not write Pack entities (files DP.*, PD.*, MIM.*). That is handled by `/apply-captures` after an R15 decision. Alternatively, R15 can write to the Pack directly via Edit — `/apply-captures` is not the only path.
- Does not launch the extractor agent R2 (runs via launchd every 3h during work hours, invoked as `extractor.sh inbox-check`).

**Three knowledge tools (distinctions):**

| Tool | Role | When | Output |
|------|------|------|--------|
| `/ke` (this Skill) | R14 Client / R1 Strategist | Session boundary, inline | Rule in CLAUDE.md / entry in `inbox/captures/<YYYY-MM>.md` |
| `extractor.sh inbox-check` (agent R2) | R2 Extractor (AI, launchd 3h, work hours) | Automatically | `extraction-reports/*.md` with `status: pending-review` |
| `/apply-captures` | R15 Validator | Close when N>0 pending-review | Pack entities + commit + status update |

Detailed VDV cycle map: `<governance-repo>/inbox/WP-247-ke-pipeline-vdv.md`

## Step 1. Identify the knowledge type

| Type | Destination | When | Via KE? |
|------|-------------|------|---------|
| Rule for all repos (1–3 lines) | `CLAUDE.md` (workspace root) | Immediately | No |
| Rule for a single repo (1–3 lines) | `<repo>/CLAUDE.md` | Immediately | No |
| Domain (architecture, patterns) | Corresponding Pack | Close | Yes |
| Distinction, Method, FM, WP | Corresponding Pack | Close | Yes |
| Implementation (vendor, stack, deployment) | DS docs/ | Close | Yes (KE → DS) |
| Major lesson | `memory/<topic>.md` | Close | No |
| Post seed | `{{GOVERNANCE_REPO}}/drafts/draft-list.md` | Close | No |

## Step 2. Routing

Test HD #29: *"If we replace the vendor, does the statement become false?"*
- Yes → implementation (DS)
- No → domain (Pack)

## Step 3. Recording

- If "Immediately" → record right away
- If "Close" → append an entry to `inbox/captures/<YYYY-MM>.md`:
  - unambiguous event date in the entry → month of the event;
  - event date is absent or ambiguous → month of recording (today), mark in the entry text as `event_date: unknown` or `event_date: ambiguous` — do not guess
  - `inbox/captures.md` (legacy) — read-only, do not add new entries there

## Step 4. Announce

Output: *"Capture: [what] → [where]"*

If this is a Distinction — propose a formulation for `memory/hard-distinctions.md`.
