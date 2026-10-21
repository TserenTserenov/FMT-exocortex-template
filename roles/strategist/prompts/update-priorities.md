Execute the priority update scenario for the Strategist role (R1).

> **Trigger:** Event-driven — fires when a new P1+ signal appears (dissatisfaction, Incident, proposal, new Work Product).
> **Input:** Signal (type, priority, description) + current WeekPlan.
> **Output:** Adjusted WeekPlan (priorities, budget, Top-3) + notification to the pilot.

## Steps

| Step | Input | Action | Output |
|------|-------|--------|--------|
| 1 | Signal (dissatisfaction / Incident / proposal / Work Product) | Classification: type, priority, urgency | Impact/risk Assessment |
| 2 | Assessment + current WeekPlan | Adjust priorities and budget | Updated WeekPlan (draft) |
| 3 | WeekPlan draft | Check invariants (Top-3, red lines, budget) | Valid WeekPlan or decision request to pilot |

## Algorithm

### 1. Signal Classification

| Signal type | Examples | Default action |
|-------------|----------|----------------|
| New dissatisfaction | New unmet need, threat | Add to `docs/Dissatisfactions.md`, assess urgency |
| Incident | Bug, outage, blocker | P0/P1 → add to WeekPlan immediately; notify pilot |
| Proposal | Idea, request, feedback | Classify: task / knowledge / noise |
| New Work Product | WP Gate Ritual opened a Work Product | Embed in WeekPlan with priority and budget |

### 2. WeekPlan Adjustment

**Adjustment rules:**

- **P0 (critical):** Added to WeekPlan immediately, out of queue. Budget is recalculated. Pilot is notified in Telegram. Top-3 changes only by pilot decision.
- **P1 (high):** Added to WeekPlan within the current day. May displace P2/P3.
- **P2 (medium):** Batch — accumulates until the next Day Plan, added at that point.
- **P3 (low):** Backlog — recorded in `inbox/backlog-with-triggers.md`, does not enter WeekPlan without an explicit decision.

**Invariants (do not violate without pilot decision):**
1. **Top-3 priorities** — do not change without an explicit pilot decision. A new P0/P1 may become Top-3, but the existing Top-3 is not removed automatically.
2. **Red lines** — if a signal violates a red line (runway, D7, WakaTime), notify the pilot immediately.
3. **Weekly budget** — the aggregate budget cannot exceed `{{MAX_WEEK_HOURS}}` (physical time). If it does — request a pilot decision (what to displace).

### 3. Validation and Commit

**Checks:**
- [ ] Top-3 not changed without pilot decision
- [ ] Red lines not violated
- [ ] Budget within `{{MAX_WEEK_HOURS}}` physical hours
- [ ] All P0/P1 items have an owner and a deadline

**If checks pass:**
1. Update `current/WeekPlan W*.md`
2. `git add current/WeekPlan*.md` → commit → push
3. Notify pilot in Telegram (brief: what changed and why)

**If checks do NOT pass:**
1. Compose a choice question for the pilot:
   ```
   Signal: <description>
   Impact: <what is affected>
   Options:
     A. Accept with displacement of <Work Product> (budget +Nh)
     B. Defer until <date>
     C. Split into smaller tasks
   ```
2. Do NOT update WeekPlan until the pilot responds

## Rules

- **Event-driven ≠ immediate:** P2/P3 do not interrupt current work. Batch processing until the next Day Plan.
- **Top-3 is sacred:** do not change without pilot decision.
- **Notifications:** P0/P1 — always; P2/P3 — only if an invariant is violated.
- **Audit trail:** every WeekPlan change is committed with the message `priorities: <signal> → <change>`.

## Sources

- **WeekPlan:** `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/current/WeekPlan W*.md`
- **Dissatisfactions:** `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/docs/Dissatisfactions.md`
- **Backlog:** `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/backlog-with-triggers.md`
- **Red lines:** `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/docs/Strategy.md` §Red Lines