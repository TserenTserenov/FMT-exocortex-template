---
argument-hint: '[raw material: notes/reflection, optional]'
browser_safe: false
description: A discovery-strategy conversation for unpacking dissatisfactions. Socratic
  analysis of raw reflections and notes into the Problem/Dissatisfaction/Emotion triad
  → pilot state → monthly priorities (WHAT/WHY). Role R1 Strategist, method DP.METHOD.053.
  Triggers — "unpack my dissatisfactions", "help with monthly strategy", "what matters
  to me right now", "/discovery-session".
layer: L1
name: discovery-session
routing:
  deterministic: false
  executor: opus
status: active
triggers:
  phrases: []
  slash:
  - /discovery-session
version: 1.0.0
---

# Discovery Session — Unpacking Dissatisfactions

> **Owner:** R1 Strategist (DP.ROLE.012). **Structure (single source of truth):** DP.METHOD.053
> (PDE extraction method). **Promise:** DP.SC.030. This Skill is one showcase of the method
> (local, for the editor); the server-side multi-turn channel is a spin-off from the same source.

## Invariant (built into the method)

- **Exoskeleton, not autopilot.** Amplify the pilot's thinking with Socratic questions. Do NOT
  formulate dissatisfactions on their behalf. Without a human gate, the Artifact does not count.
- **Model threshold.** The method declares `min_model_tier: opus` (provisional). Run this Skill
  only on a model at or above the threshold — discovery on a weak model breaks cognitive load
  (floods the pilot with questions or gives up too early).
- **Boundary.** End at the "priority context" (priorities + state + system levels). Do NOT pack
  into a WeekPlan with budgets — that is the Planner's job (DP.ROLE.066), a separate conversation
  (`/strategy-session` weekly flow).

## Step 0. Readiness

Check the session model. If it is below Opus — report: "The discovery conversation requires a
strong model (threshold from the method). Switch to Opus (`/model`) and start again." Stop.

If the pilot passed raw input as an argument — accept it as input. If not — collect it in Step 1.

## Step 1. Collect Raw Input (method stage 1)

Accept notes and reflections. Sources: `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/`
(fleeting notes), `docs/Dissatisfactions.md` (accumulated), free text from the pilot.

If raw input is sparse — ask open questions (no more than 2–3 at a time):
- "What caused worry, irritation, or anxiety over the past week?"
- "Where did expectation diverge from reality?"

## Step 2. Extract Problems (method stage 2)

For each concern — Socratic approach:
- "What is the gap here between the desired state and the current state?"
- "From which Role do you see this?" (one situation = a problem for one Role, an opportunity for another)

Record the problem as a **prediction error** + Role. If there is no error — this is an opportunity,
not a problem (do not add to the PDE table).

## Step 3. Identify Dissatisfactions (method stage 3)

- "Which Need of yours is affected by this problem?" → map to a needs list
  (Maslow / NVC list of needs), **without imposing** a formulation.
- One problem → possibly multiple dissatisfactions (safety, respect,
  self-actualization…). A dissatisfaction is a state of the person, not the Role.

## Step 4. Distinguish the Emotion (method stage 4)

- "What do you feel — in the moment and overall for the period?"
- Separate **emotion** (minutes) from **feeling** (weeks–years). Do NOT conflate emotion with
  dissatisfaction: do not derive a problem from emotion directly — go through the dissatisfaction.

## Step 5. Assess Intensity (method stage 5)

For each dissatisfaction — intensity 1–5 (= motivation to resolve it). Rank them. Intensity is
the priority criterion: high → seek a solution; low → adapt or ignore.

> **Intensity ≠ urgency.** High intensity (5) ranks **importance** (what to develop first),
> but does NOT make a dissatisfaction "urgent". Urgent = only a threat to Pipeline stoppage
> (production is down, a blocker for others) — it does not wait for a strategy session; it
> interrupts and is fixed immediately. The CIU model [[Current ≠ Important ≠ Urgent (CIU)]] +
> [[Deadline ≠ Urgency]]: a deadline on a dissatisfaction does not elevate it to urgent either.
> Discovery ranks what is important; "on fire" ≠ "urgent".

## Step 6. Link to Goals and System Levels (method stage 6)

For top dissatisfactions:
- "Which System of Interest or Work Product will resolve it?" → goal hypothesis (does not block
  recording if the "how" is unknown yet — that is normal, it gets refined in projects).
- Distribute across system levels (personal / team / organization / supersystem).

## Step 7. Monthly Priorities + TOC (method stage 7)

- Consolidate goals into **ranked monthly priorities**.
- Identify the **monthly TOC** — the primary Constraint whose removal drives the most progress.
- Determine **pilot state** (state-card): Chaos / Ceiling / Turn / Growth.

## Step 8. Artifact and Recording

Assemble a structured Artifact:

```markdown
## State (state-card): <Chaos|Ceiling|Turn|Growth>

## PDE Table
| Problem | Dissatisfaction | Emotion/Feeling | Role | Intensity (1-5) | Action Hypothesis |
|---|---|---|---|---|---|
| ... | ... | ... | ... | ... | ... |

## Top 3 Dissatisfactions (by intensity)
1. ...

## Monthly Priorities (ranked)
1. ...

## Monthly TOC
<primary constraint>

## System Levels
<distribution>
```

Save to `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/current/monthly-priorities.md` (priorities
+ TOC) and/or record the state-card. This is the **priority context** to hand off to the Planner.

## Step 9. Handoff to the Planner

Tell the pilot:
> "The priority context is ready: monthly priorities + state + system levels. Next step —
> packing into the week: say 'let's run a strategy session' (`/strategy-session`) and the Planner
> will build a WeekPlan with budgets. I (the Strategist) will re-engage only if priorities become
> outdated or the state changes."

## Edge Cases (per method §3)

- **Too many dissatisfactions** → rank by intensity, take the top 3.
- **No known way to resolve** → that is fine; the method/Role hypothesis gets refined in projects
  and does not block recording.

## Format

Up to 7 points per Work turn. Socratic mode: question → pilot reflection → structuring.
Language: plain English, conversational (S0 style). No academic jargon.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
