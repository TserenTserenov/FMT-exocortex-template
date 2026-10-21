> Used in: `.claude/skills/day-open/SKILL.md` (steps 7a, 7d).

## DayPlan Template

> **Style:** collapsible, no `---`, `<b>` in summary. Priority = traffic light (🔴🟡🟢). Result = short name from Strategy.md.

```markdown
---
type: daily-plan
date: YYYY-MM-DD
week: W{N}
status: active
agent: Strategist
---

# Day Plan: DD Month YYYY (Weekday)

<details open>
<summary><b>Today's plan</b></summary>

| 🚦 | # | WP | h | Status | Result |
|----|---|-----|---|--------|--------|
| ⚫ | N | **Self-development** — [topic] | 1-2 | pending | — |
| 🔴 | ... | **Name** | X | in_progress | Short name |

**Day budget:** ~Yh WP total / ~Xh physical / Planned multiplier ~N.Nx

</details>
<details>
<summary><b>Calendar (DD Month)</b></summary>

| Time | Event | Duration | WP link |
|------|-------|----------|---------|
| HH:MM | Name | Xh | WP-N / — |

⏱ Free blocks ≥1h: [slots]

</details>
<details>
<summary><b>IWE overnight (traffic light)</b></summary>

| Subsystem | Status | Details |
|-----------|--------|---------|
| template-sync | 🟢/🔴 | [status] |
| Scout | 🟢/🟡/🔴 | [N findings] |

</details>
<details>
<summary><b>Scout findings (review)</b></summary>

> Report for DD Month — N findings, M capture candidates
> **Review status:** ⬜ not reviewed / ✅ reviewed

**Awaiting review:** N captures over the last DD days (no review).

</details>
<details>
<summary><b>Notes review</b></summary>

> Source: `inbox/fleeting-notes.md` (mini-triage, Day Open step 1c); `✅proposed` marks remain from manual note review.
> **If there are no notes awaiting a pilot decision** (no bold notes and no notes marked `✅proposed` in the inbox; deferred `🔄` items do not count) → write: "No notes awaiting decision. Carry-over: none."
> **If such notes exist** → use the table below. Notes without a decision carry over to the next DayPlan.

| Note | Type | Proposal | ✅ |
|------|------|----------|---|
| "text" | Unsatisfied need / Task / Draft / Knowledge / Noise | → destination | [ ] |

</details>
<details>
<summary><b>Content editor</b></summary>

> Top 3 drafts from `drafts/` to work on today.

**Top 3 to work on:**

| D-ID | Name | R/S | Reason |
|------|------|-----|--------|
| D-??? | Name | R? / S? | Reason for readiness |

**Stuck (TTL expired):**
- D-??? "Name" (ttl: YYYY-MM-DD) — advance / archive / update TTL?

</details>
<details>
<summary><b>Yesterday's results (DD Month)</b></summary>

**Commits:** N in M repos | **WP closed:** N

</details>

*Created: YYYY-MM-DD (Day Open)*
```

## Compact dashboard Template (VS Code)

> Short summary for a quick start. Details are in DayPlan (git).

```markdown
## DD Month YYYY (Weekday) — Day Open

**Yesterday:** N WP done, N commits. Key: #X [name], #Y [name]
**Issues:** N open in M repos [most recent: #X repo, #Y repo]
**Calendar:** [events comma-separated or "free"]
**Budget:** W{N}: ~Zh WP / ~Yh physical | Today: ~Zh WP / ~Yh physical
**TOC:** [bottleneck] | Progress: R1 ✅/🔄/⏳, R2 ...

### Day plan

| 🚦 | # | WP | h |
|----|---|-----|---|
| ⚫ | N | **Self-development** — [topic] | 1 |
| 🔴 | ... | **Name** | X |

### Requires attention

1. [item — if any]

*No items → section is not rendered.*

> Details: [DayPlan YYYY-MM-DD](link to git)
```

## WeekPlan Template

> **Style:** collapsible, no `---`, `<b>` in summary. Priority = traffic light (🔴🟡🟢). Result = short name from Strategy.md (not ID).
> **Budget:** format `~Zh WP total (including Xh for R1-R{N}) / ~Yh physical / Planned multiplier ~N.Nx`. Active items — **bold**. Done — strikethrough: `| ~~#~~ | ~~name~~ | ... |`

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

<details open>
<summary><b>Week W{N} plan</b></summary>

**Focus:** [1 sentence]
**Budget:** ~Zh WP total (including Xh for R1-R{N}) / ~Yh physical / Planned multiplier ~N.Nx

> 🔴 critical 🟡 medium 🟢 low

| 🚦 | # | WP | h | Source | P | Status | Result |
|----|---|-----|---|--------|---|--------|--------|
| 🔴 | ... | **Name** — description | X | R{N} / S-UN-X / carry | P3 | in_progress | Short name |

> **"Source" column (WP↔UN reconciliation, WP-196 P11):** `R{N}` = monthly priority, `S-UN-X` = unsatisfied need, `carry` = carried over. A WP without a source is a signal: "why are we doing this?"
> **"P" column (S-25):** project P1-P6 from `docs/Projects.md` (if applicable).

**Summary:** N WP, Xh. 🔴 Xh (N) 🟡 Xh (N) 🟢 Xh (N)
**Off-plan:** [list]

### Time-boxing (PD.METHOD.017)

- Small (≤4h): N
- Large (4-15h): N
- Open-ended: 0 (not allowed)

### What we are NOT taking into this week and why
- WP X — deferred, reason: ...

</details>
<details>
<summary><b>TOC + week request</b></summary>

> ONE constraint whose removal unlocks the greatest throughput (PD.METHOD.017 step 4).

**TOC:** [one statement]
**Week request:** [what is needed from yourself or others]

</details>
<details>
<summary><b>Last week's results W{N-1}</b></summary>

> **Split (OPT-5, WP-297):** facts have moved to `WeekReport W{N-1}`. Only a link remains here.

See `current/WeekReport W{N-1} YYYY-MM-DD.md` (link via frontmatter `week_report:`).

</details>
<details>
<summary><b>Strategic reconciliation</b></summary>

| ID | Result | Budget | Status | P | Related WPs |
|----|--------|--------|--------|---|-------------|
| R1 | ... | ... | ... | P3 | WP-X, WP-Y |

**Monthly TOC:** [bottleneck]
**Deviations:** [plan vs actual]

</details>
<details>
<summary><b>Strategy session agenda</b></summary>

- [ ] Last week review (source: WeekReport W{N-1})
- [ ] Inbox Triage (weekly)
- [ ] Unsatisfied needs: check O1-O{N}
- [ ] Strategic reconciliation
- [ ] **Applied WP selection criteria** (PD.METHOD.017): TOC + Budget fit + Time-boxing
- [ ] **WP↔UN reconciliation:** source for each WP (R{N} / S-UN)
- [ ] Video review (S3)
- [ ] Activation check + dormant review

### Discussion questions
1. ...

</details>
<details>
<summary><b>WP↔UN reconciliation (for Week Close)</b></summary>

| WP | Source (R/S-UN) | Result | Resolves UN? |
|----|-----------------|--------|--------------|
| ... | ... | ... | yes / partially / no |

</details>
<details>
<summary><b>Recommended changes to unsatisfied needs and Strategy (for Week Close)</b></summary>

- **Unsatisfied needs:** ...
- **Strategy.md:** ...

</details>
<details>
<summary><b>Inbox Triage (weekly)</b></summary>

[from fleeting-notes, unsatisfied-questions, WP context files]

</details>
<details>
<summary><b>Content plan W{N}</b></summary>

1. **#NNN Name** — channel, budget, deadline

</details>
<details open>
<summary><b>Monday DD Month plan</b></summary>

| 🚦 | # | WP | h | Result |
|----|---|-----|---|--------|

</details>

*Created: YYYY-MM-DD (Strategy Session)*
```
