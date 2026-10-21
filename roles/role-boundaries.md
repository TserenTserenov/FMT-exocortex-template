# Role Boundaries and Handoff Points (Role Boundaries)

> Artifact: handoff point map between Diagnostician (R28), Navigator (R27), Strategist (R1), and Planner (DP.ROLE.066).
> Scope: who is responsible for what, when and how handoffs occur.
> Status: active

> **R1 unbundling (WP-378, 2026-06-04, peer consensus).** Role R1 previously combined two thinking Operations: strategizing (WHAT/WHY) and operational planning (HOW MUCH/WHEN). The boundary is drawn **between roles**: Strategist (R1) narrows to strategizing; the new role Planner (DP.ROLE.066) takes on operational planning. The name R1 is retained (Strategist). The strategizing discovery channel (pilot request from claude.ai) is a new function, implemented in WP-378 Phase 1+.

## Roles

| Role | Horizon | Key Function | Trigger |
|------|---------|--------------|---------|
| **Diagnostician (R28)** | Mastery stage, bottleneck | Assessment of current stage, bottleneck identification | Pilot request or regular (quarterly) |
| **Navigator (R27)** | Quarter, program | Program planning, selection of quarterly focus | Diagnostician output + Strategy.md |
| **Strategist (R1)** | Month + reflection | Strategizing (WHAT/WHY): NEP discovery, state diagnosis, monthly priorities | Reflection, notes, signals, month start |
| **Planner (DP.ROLE.066)** | Week, day | Operational planning (HOW MUCH/WHEN): packing priorities into WP-week, budgets, WIP, days | Priority context from R1, week/day start |

## Handoff Points (Handoff Map)

### 1. Diagnostician → Navigator

| Field | Value |
|-------|-------|
| **Trigger** | Stage diagnosis complete (cp-profile updated) or bottleneck identified |
| **Artifact** | `cp-profile.md` (stage, strengths, bottleneck, recommendations) |
| **Format** | YAML frontmatter + "Planning Recommendations" section |
| **Receives** | Navigator — uses bottleneck as input for selecting quarterly focus |
| **SLA** | Before the next quarterly strategizing session |

### 2. Navigator → Strategist

| Field | Value |
|-------|-------|
| **Trigger** | Quarterly focus and program goals approved |
| **Artifact** | `docs/Strategy.md` — "Quarter YYYY-QN" section (focus, goals, hypothesis) |
| **Format** | Markdown with explicit R1–R6 for the quarter, TOC, growth hypothesis |
| **Receives** | Strategist — decomposes quarter into months, months into weeks |
| **SLA** | Before the first monthly strategizing session |

### 3. Strategist → Navigator

| Field | Value |
|-------|-------|
| **Trigger** | Month complete, R1–R6 results collected |
| **Artifact** | `archive/month-reports/Month-Report-YYYY-MM.md` or a section in Strategy.md |
| **Format** | Actual vs. plan for R1–R6, deviations, lessons |
| **Receives** | Navigator — adjusts quarterly plan when deviations exceed 20% |
| **SLA** | Within 3 days after Month Close |

### 4. Strategist → Diagnostician

| Field | Value |
|-------|-------|
| **Trigger** | ≥3 lessons accumulated relating to "stage" or "bottleneck" |
| **Artifact** | `memory/lessons.md` — lessons tagged `#bottleneck` or `#stage-transition` |
| **Format** | Markdown, tags for filtering |
| **Receives** | Diagnostician — uses for the next diagnosis |
| **SLA** | Asynchronous, at the next diagnosis |

### 5. Strategist → Planner

| Field | Value |
|-------|-------|
| **Trigger** | Monthly strategizing session complete (priorities + state recorded) |
| **Artifact** | "Priority context" — monthly priorities + pilot state + NEP system levels (not a bare `monthly-priorities.md`) |
| **Format** | Markdown: priorities, state (Chaos/Ceiling/Pivot/Growth), system levels |
| **Receives** | Planner (DP.ROLE.066) — packs into WP-week with budgets + WIP + day distribution; has the right to interpret during packing |
| **SLA** | Before the first weekly planning session |
| **Joint ritual** | Strategist participates in the weekly session only if priorities are outdated or state has changed; otherwise Planner runs the week alone |

## What Is NOT Included in This Map

- **Extractor (R25)** — works with domain knowledge (Pack), does not participate in strategizing rhythms; handoff toward Extractor is not possible — no plan-intake Interface exists
- **Auditor (VR.R.002)** — invoked on demand (per-ArchGate), is not a permanent participant in the handoff cycle; initiates a check but not a handoff between strategizing roles
- **Peer agents** — Kimi Code / Claude Code — are tools, not roles in the strategizing process

## Sources

- **Diagnostician:** `roles/strategist/prompts/diagnose.md` (if present) or `/diagnose` skill
- **Navigator:** `docs/Strategy.md` §"Quarter"
- **Strategist:** `roles/strategist/prompts/strategy-session-weekly.md`, `week-review.md`, `day-plan.md`
- **Handoff pattern:** `docs/inter-agent-handoff.md` (cross-agent, not cross-role)