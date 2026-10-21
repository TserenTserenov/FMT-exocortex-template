---
description: DayPlan and WeekPlan templates — single source of truth for day-open
  and day-close
domains:
- reference
- planning
horizon: warm
name: templates-dayplan
owner: platform
schema_version: 1
status: active
type: reference
updated: 2026-04-21
valid_from: 2026-04-13
---

# DayPlan and WeekPlan Templates

> Single source of truth. Used by: `day-open/SKILL.md` (creation) and `day-close/SKILL.md` (recording results).
> Style: collapsible, no `---`, `<b>` in summary. Priority = traffic light (🔴🟡🟢).
> **`multiplier_enabled` condition:** read `params.yaml` before copying the template.
> Keep only the blocks with the matching label `multiplier:on` or
> `multiplier:off`. Do not carry the HTML comments themselves into the final plan.

## DayPlan Template

```markdown
---
type: daily-plan
date: YYYY-MM-DD
week: W{N}
status: active
agent: Strategist
---

# Day Plan: DD Month YYYY (Weekday)

## Today's Plan

| 🚦 | # | WP | h | Status | Result |
|----|---|-----|---|--------|--------|
| ⚫ | N | **Self-development** — [WP-NNN personal guidance topic] | 1-2 | pending | — |
| 🔴 | ... | **Name** | X | in_progress | Short name |

> The value of each task is in [WeekPlan W{N}](<../current/WeekPlan W{N} YYYY-MM-DD.md>).

> **Self-development = link to the active WP of the personal guidance.** Specific topic for today = next action from that WP.
> **Input:** WeekPlan W{N} + carry-over → select 5–12 WPs, set priorities → day WP table.

<!-- multiplier:on -->**Day budget:** ~Yh WP total / ~Xh physical / Planned multiplier ~N.Nx<!-- /multiplier:on -->
<!-- multiplier:off -->**Day budget:** ~Yh WP total<!-- /multiplier:off -->

## Day Close (filled in the evening)

> **Canonical structure** (from PD.METHOD.008 § Stage 5 Day Closing). Three subsections: three options for tomorrow's plan + KE routing + alignment with dissatisfactions.
> **Input:** day results + KE routing → record results, route knowledge → updated DayPlan + carry-over.

### Three Options for Tomorrow's Plan

> Each option = a coherent day scenario, not a list of WPs. Choose one at Day Open YYYY-MM-DD.

| # | Option | Basis | 🔴 focus | Risk | Result by end of day |
|---|--------|-------|----------|------|----------------------|
| A | _minimum_ | carry-over only | — | — | — |
| B | _main_ | plan + 1 new | — | — | — |
| C | _aggressive_ | expanded scope | — | — | — |

**Choice:** _to be made at tomorrow's Day Open_. Criterion: evening state (energy, blockers, external events).

### KE Routing (Knowledge Extraction)

> What from today became knowledge — and where it went. At the day milestone = Capture-to-Pack checkpoint.

| Source (what happened) | Knowledge type | Route | Status |
|------------------------|----------------|-------|--------|
| — | — | — | ⬜ |

**Rule:** rule (1–3 lines) → `{{WORKSPACE_DIR}}/CLAUDE.md` or `.claude/rules/distinctions.md`. Domain knowledge → Pack. Implementation → DS docs/. Lesson/habit → memory/. No repetition (≥2 times) — keep only in handoff WP.

### Alignment With Dissatisfactions

> Which S-dissatisfaction (from [Dissatisfactions.md](../docs/Dissatisfactions.md)) moved today? Which had no movement? If no WP in today's plan addressed any S — ask "why."

| S-code | Short formulation | Today | Comment |
|--------|-------------------|-------|---------|
| — | — | ⬜ | — |

## Calendar (DD Month)

> **Input:** external events → check for slot conflicts → list of free blocks.

| Time | Event | Duration | Link to WP |
|------|-------|----------|------------|
| HH:MM | Name | Xh | WP-N / — |

⏱ Free blocks ≥1h: [slots]

## IWE Overnight (traffic light)

| Subsystem | Status | Details |
|-----------|--------|---------|
| template-sync | 🟢/🔴 | [status] |
| Scout | 🟢/🟡/🔴 | [N findings] |

## Scout Findings (Review)

> Report for DD Month — N findings, M capture candidates
> **Review status:** ⬜ not reviewed / ✅ reviewed
> **Input:** overnight findings → classification → capture candidates / ⬜.

**Awaiting review:** N captures over the last DD days (no review).

## Notes Review

> Source: `inbox/fleeting-notes.md` (mini-triage, Day Open step 1c); `✅proposed` marks remain from manual note review.
> **If there are no notes awaiting a decision from the pilot** (no bold notes or notes marked `✅proposed` in the inbox; deferred `🔄` items do not count) → write: "No notes awaiting decision. Carry-over: none."
> **If such notes exist** → table below; without a pilot decision they carry over to the next DayPlan.

| Note | Type | Proposal | ✅ |
|------|------|----------|----|
| "text" | Dissatisfaction / Task / Draft / Knowledge / Noise | → destination | [ ] |

## Yesterday's Results (DD Month)

**Commits:** N in M repos | **WPs closed:** N

*Created: YYYY-MM-DD (Day Open)*
```

## Compact Dashboard Template (VS Code)

```markdown
## DD Month YYYY (Weekday) — Day Open

**Yesterday:** N WPs done, N commits. Key items: #X [name], #Y [name]
**Issues:** N open in M repos [most recent: #X repo, #Y repo]
**Bot:** N new complaints (↑↓X vs yesterday), M urgent open (oldest ≤date)
**Calendar:** [events comma-separated or "free"]
<!-- multiplier:on -->**Budget:** W{N}: ~Zh WP / ~Yh physical | Today: ~Zh WP / ~Yh physical<!-- /multiplier:on -->
<!-- multiplier:off -->**Budget:** W{N}: ~Zh WP | Today: ~Zh WP<!-- /multiplier:off -->
**TOC:** [bottleneck] | Progress: R1 ✅/🔄/⏳, R2 ...

### Day Plan

| 🚦 | # | WP | h |
|----|---|-----|---|
| ⚫ | N | **Self-development** — [WP-NNN personal guidance topic] | 1 |
| 🔴 | ... | **Name** | X |

### Requires Attention

1. [item — if any]

*No items → section is not rendered.*

> Details: [DayPlan YYYY-MM-DD](link to git)
```

## WeekPlan Template

> Budget when `multiplier_enabled: true`: `~Zh WP total / ~Yh physical / Planned multiplier ~N.Nx`; when `false`: `~Zh WP total`. Active items — **bold**. Done — strikethrough.

```markdown
---
type: week-plan
week: W{N}
date_start: YYYY-MM-DD
date_end: YYYY-MM-DD
status: draft
agent: Strategist
---

# WeekPlan W{N}: DD Month — DD Month YYYY

## Week W{N} Plan

**Focus:** [1 sentence]
<!-- multiplier:on -->**Budget:** ~Zh WP total (including Xh for R1–R{N}) / ~Yh physical / Planned multiplier ~N.Nx<!-- /multiplier:on -->
<!-- multiplier:off -->**Budget:** ~Zh WP total (including Xh for R1–R{N})<!-- /multiplier:off -->

> 🔴 critical 🟡 medium 🟢 low

| 🚦 | # | WP | h | Status | Value | Result |
|----|---|-----|---|--------|-------|--------|
| 🔴 | ... | **Name** — description | X | in_progress | R{N}-goal / stakeholder | Short name |

**Week growth hypothesis:** [1–2 sentences — what we are testing this week, from PD.METHOD.025]
> Single storage location. Do not duplicate in frontmatter.

**Summary:** N WPs, Xh. 🔴 Xh (N) 🟡 Xh (N) 🟢 Xh (N)
**Off-plan:** [list]

### Applied WP Selection Criteria (PD.METHOD.017)

> Source: [PD.METHOD.017](../../PACK-personal/pack/personal-development/03-methods/PD.METHOD.017-wp-selection.md) — selecting WPs from (a) R1–R{N} active phases + (b) carry-over + (c) new WPs through the WP Gate.

<!-- multiplier:on -->- **Budget-fit:** ≤ {{limit}}h active WPs (~{{multiplier}}x WakaTime), carry-over + new ≤ {{remainder}}h.<!-- /multiplier:on -->
<!-- multiplier:off -->- **Budget-fit:** ≤ {{limit}}h active WPs, carry-over + new ≤ {{remainder}}h.<!-- /multiplier:off -->
- **Carry-over triage:** {{which WPs were carried over and why — blocker resolved / week was needed / partial progress}}.
- **Priority:** 🔴 {{critical criteria — deadline / blocker / external meeting}} | 🟡 {{high — deadline next week}} | 🟢 {{medium/background}}.
- **TOC-of-week:** {{key bottleneck of the week — what is blocking everything else}} → explicit 🔴 slot.
- **Time-boxing (Shape Up):** a WP that has not reached 50% of its budget by Thursday → review at Strategy Session W{N+1} (shape-it or cut-it).

### TOC of Week W{N} + Week Question

- **TOC:** {{key bottleneck of the week, distinct from the general focus — what specifically is slowing further progress}}.
- **Week question:** {{by end of week, understand X — a specific question we are seeking to answer, not a task}}.
- **Answer criterion:** {{how we will know the answer has been found — decision / artifact / fixed hypothesis}}.

## Last Week W{N-1} Results

**Completion:** X/Y WPs (Z%)
**Carry-over:** [list]
**Key takeaways:** [2–3 items]

## Strategic Alignment

| ID | Result | Budget | Status | Related WPs |
|----|--------|--------|--------|-------------|
| R1 | ... | ... | ... | WP-X, WP-Y |

**TOC-of-month:** [bottleneck]
**Deviations:** [plan vs actual]

## Strategy Session Agenda

- [ ] Last week review
- [ ] Inbox Triage (weekly)
- [ ] Dissatisfactions: check O1–O{N}
- [ ] Strategic alignment
- [ ] Video review (C3)
- [ ] Activation check + dormant WP review

### Discussion Questions
1. ...

## Inbox Triage (Weekly)

[from fleeting-notes, unsatisfied-questions, WP context files]

## Content Plan W{N}

1. **#NNN Name** — channel, budget, deadline

## Monday DD Month Plan

| 🚦 | # | WP | h | Result |
|----|---|-----|---|--------|

## Week Close W{N} (filled on Sun / Mon of next week)

<!-- multiplier:on -->> **Canonical structure** (from PD.METHOD.008 § Stage 6 Week Closing). Four subsections: WP↔dissatisfactions alignment + recommendations for dissatisfactions and Strategy + carry-over + multiplier.<!-- /multiplier:on -->
<!-- multiplier:off -->> **Canonical structure** (from PD.METHOD.008 § Stage 6 Week Closing). Three subsections: WP↔dissatisfactions alignment + recommendations for dissatisfactions and Strategy + carry-over.<!-- /multiplier:off -->

## WP ↔ Dissatisfactions Alignment

> Which S-dissatisfactions (from [Dissatisfactions.md](../docs/Dissatisfactions.md)) moved this week and through which WPs? Where are the gaps?

| S-code | S-dissatisfaction | Week WPs | Movement | Comment |
|--------|-------------------|----------|----------|---------|
| — | — | — | ⬜ — | — |

**S without WPs this week:** {{list — and decision: acceptable this week or requires action}}.
**WPs without S:** {{list of off-plan WPs not linked to any S-dissatisfaction — ask "why"}}.

## Recommended Changes to Dissatisfactions and Strategy

> What accumulated this week that changes Dissatisfactions.md / Strategy.md? Processed through Strategy Session W{N+1}.

- **Dissatisfactions (Dissatisfactions.md):**
  - New S: {{list}}
  - Changed S (formulation / priority): {{list}}
  - Closed S: {{list}}
- **Strategy (Strategy.md):**
  - Month state (phase per PD.FORM.078): {{no change / phase change → which + why}}
  - Caliber (PD.CHR.007): {{no change / shift toward direction Y}}
  - R1–R{N}: {{results unchanged / budget recalculation / new R / frozen R}}
  - Q-goals: {{no change / KPI adjustment}}

## Carry-over to W{N+1}

| WP | Reason for carry-over | Remaining h | 🚦 for W{N+1} |
|----|-----------------------|-------------|---------------|
| WP-{N} | — | — | 🔴/🟡/🟢 |

**Rule:** a WP that has not reached 50% of its budget by Thursday is automatically a candidate for review (see Time-boxing above).

<!-- multiplier:on -->
## Multiplier and Metrics W{N}

| Metric | Plan | Actual |
|--------|------|--------|
| WP budget (h) | — | — |
| WakaTime (physical h) | — | — |
| Multiplier | — | — |
| Commits / WPs closed | — | — / — |

**Deviations:** {{what diverged significantly from the plan and why}}.
**What worked well:** {{2–3 items worth repeating}}.
**What did not work:** {{2–3 items for correction via stop-list or ritual change}}.
<!-- /multiplier:on -->

<!-- multiplier:off -->
## Metrics W{N}

| Metric | Plan | Actual |
|--------|------|--------|
| WP budget (h) | — | — |
| Commits / WPs closed | — | — / — |

**Deviations:** {{what diverged significantly from the plan and why}}.
**What worked well:** {{2–3 items worth repeating}}.
**What did not work:** {{2–3 items for correction via stop-list or ritual change}}.
<!-- /multiplier:off -->

*Created: YYYY-MM-DD (Strategy Session). Week Close: YYYY-MM-DD.*
```

## Day Results Template (for Day Close)

> Appended to `DayPlan YYYY-MM-DD.md` as a section at the end.

```markdown
---

## Day Results

| WP | What was done | Status |
|----|---------------|--------|
| #N | ... | done / partial |

**Commits:** N in M repos

<!-- multiplier:on -->
### IWE Multiplier

| Metric | Value |
|--------|-------|
| **WakaTime (physical time)** | Xh Ymin |
| **Budget closed (WP estimates)** | ~Nh |
| **Day multiplier** | **N.Nx** |

> Formula: Budget closed / WakaTime.
> Canonical format for the value cell: `~Nh` (no `**` around it, no "aggregate" suffix). dt-collect parses exactly this format when summing by week.
<!-- /multiplier:on -->

<!-- multiplier:off -->
### Closed WP Budget

**Budget closed (WP estimates):** ~Nh
<!-- /multiplier:off -->

**What I learned:** ...

**Acknowledgment:** ...

**Nothing forgotten:** all clear / [what remains]

**Start tomorrow with:** [ALL pending WPs — each with a specific next action]

*Closed: YYYY-MM-DD HH:MM*
```
