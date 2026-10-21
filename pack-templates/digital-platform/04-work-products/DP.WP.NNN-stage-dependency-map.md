---
created: YYYY-MM-DD
id: DP.WP.NNN
name: Stage Dependency Map
name_en: Stage Dependency Map
related:
  consumed_by:
  - DP.ROLE.001
  inspired_by:
  - CCPM (Goldratt 1997) — Project Network Diagram without buffer-management
  - PERT (US Navy 1958) — dependency network without estimates
  - TameFlow (Tendon 2020) — Pursuit of Flow Efficiency via explicit-dependencies
  produced_by:
  - DP.ROLE.NNN
  services:
  - DP.SC.NNN
status: draft
summary: 'Work Product format for the Constraint Analyst: a plan for resolving a constraint,
  represented as a dependency graph with no dates or hours. Nodes = stages (each node
  contains parallel work items and Work Products), edges = hard dependencies, external
  edges = dependencies on work in other Work Products / repositories.'
type: work-product
---

<!--
TEMPLATE (IWE/pack-templates/).

This is a Work Product format ported from the author's Pack (WP-313 Phase 11, May 20 2026).
When adapting to your own Pack:
1. Replace `DP.WP.NNN` with the next available work-products number in your Pack
2. Replace `DP.ROLE.NNN` and `DP.SC.NNN` with your own Role/SC numbers
3. Set `created` to today's date
4. Remove this HTML comment before committing
-->

# Stage Dependency Map

## 1. Definition

**Stage Dependency Map** — a Work Product format for the Constraint Analyst, describing a plan for resolving an identified system constraint. It is a **dependency graph with no time dimension**:

- **Nodes** = stages. Each stage contains one or more parallel work items / Work Products.
- **Edges (internal)** = hard dependency. "The next stage starts only after the previous stage is complete."
- **External edges** = dependencies on work outside the target system. They point to a specific Work Product / repository / external supplier.

## 2. Purpose

Without this format, the Analyst's answer "do X first, then Y" leaves open questions: "Can X and Y run in parallel? Does X block only the start of Y, or all of Y? How do we handle a dependency on another Work Product?" The Stage Dependency Map provides explicit answers.

The Artifact serves:
- The Pilot — a work map for the next N stages with explicit boundaries
- The Artifact Producer — input for decomposing each stage into physical artifacts with acceptance criteria
- The Strategist — input for NEP discussions

## 3. Differences from similar formats

| Format | What it contains | What Stage Dependency Map omits |
|--------|------------------|----------------------------------|
| **PERT** | Nodes = events, edges = tasks with time estimates | Time estimates, critical path |
| **Gantt** | Tasks on a calendar timeline | Calendar, absolute dates |
| **Kanban** | Status columns (todo/doing/done) with WIP limits | Status columns, WIP limits |
| **CCPM Network** | Dependency + buffer management | Feeding buffers, project buffer |

Stage Dependency Map — **pure dependency structure**.

## 4. Structure

### YAML schema

```yaml
stage_dependency_map:
  target: WP-NNN | project-name | rcs-profile:<account_id>
  constraint_ref: "<reference to Constraint Brief>"
  generated_at: YYYY-MM-DD
  generated_by: <your DP.ROLE.NNN> / .claude/skills/bottleneck-pick

  stages:
    - id: stage_1
      label: "<short stage name, noun-artifact form>"
      goal: "<what state is achieved by this stage>"
      parallel_works:
        - "<work item A>"
        - "<work item B>"
        - "<work item C — may be a Work Product reference WP-NNN>"
      external_deps:
        - target: "WP-MMM in another repository"
          required_state: "<what must be achieved there>"

  edges:
    - from: stage_1
      to: stage_2
      type: hard_dependency
      reason: "<why stage_2 cannot start without stage_1>"
```

### Markdown notation (for inline output)

```markdown
## Stage Dependency Map: <target>

### Stage 1: <label>
**Goal:** <goal>

**Parallel work items:**
- work item A
- work item B (WP-NNN)

**External dependencies:** none

### → Stage 2: <label>
> Can start only after Stage 1 is complete (reason: <reason>)

**Parallel work items:** ...

**External dependencies:**
- WP-MMM in another repository (required: <required_state>)
```

## 5. Construction rules

### Mandatory

1. **Each stage has a goal.** Not "do X", but "state Y is achieved".
2. **Parallel work items inside a node are truly parallel.** If work item B depends on work item A, they belong in separate stages.
3. **Edge = hard dependency.** Not "preferably first", but strictly "otherwise we cannot proceed".
4. **External dependencies specify a concrete target.** Not "depends on another Work Product", but "depends on WP-MMM, required status=...".
5. **No dates, hours, or days.** The format is structural, not temporal.
6. **No status columns (todo/doing/done).** That is the job of Kanban.
7. **Stage name = noun-artifact form.** "Activation of N pilots", not "Activate pilots".

### Prohibited

- Cycles (Stage A → Stage B → Stage A) — topological sort is required
- Edges with a type other than `hard_dependency`
- Date fields, resource fields, status fields

## 6. Example

**Target:** WP-NNN (umbrella Work Product for the first cohort), bottleneck = operational gap (activation).

```markdown
## Stage Dependency Map: WP-NNN

### Stage 1: Activation of N early pilots
**Goal:** ≥50% of pilots have completed the first target action (opened the repository + received the guide + answered 1 question).

**Parallel work items:**
- Delivery of the personal guide (via managed channel)
- Sending the evening message with activation instructions
- Check-in from the Navigator (optional, non-blocking)

**External dependencies:**
- WP-MMM (daily-run Attestator) — must be running stably

### → Stage 2: Wave rollout
> Can start only after Stage 1 is complete (reason: without confirmed conversion ≥50% on early pilots, the next wave will produce the same operational gap picture).

**Parallel work items:**
- Bulk-onboarding SQL for wave-2
- Preparation of wave-2 broadcast messages
- Solo smoke pre-flight before each wave

**External dependencies:**
- WP-KKK Phase 17.9 TG-broadcast — must be tested

### → Stage 3: Mass cohort, daily rhythm stabilization
> Can start only after Stage 2 is complete (reason: rhythm works only when there is sufficient mass for a daily rhythm).

**Parallel work items:**
- Daily ping-bot
- Weekly check-in from the Navigator
- Monthly retro

**External dependencies:** none
```

## 7. Handoff to the Artifact Producer

After receiving the Stage Dependency Map from the Analyst, the Artifact Producer takes each stage and applies their decomposition method to it:

| What the Analyst does | What the Artifact Producer does |
|-----------------------|----------------------------------|
| Stage 1: "..." — parallel work items | Stage 1 → stages with physical artifacts as inputs/outputs |
| Parallel work items as a list | Each work item → acceptance checklist |
| External dependency as a target | Artifact Producer specifies exactly what state is required |

Sequencing: Analyst (where to look) → Artifact Producer (how to do it).

## 8. Related documents

- `DP.ROLE.NNN` Constraint Analyst — creator of this format (in your Pack)
- `DP.ROLE.NNN` Artifact Producer — consumer of this format
- `DP.SC.NNN` Constraint Analysis — constraint analysis promise
- `.claude/skills/bottleneck-pick/SKILL.md` — tool carrying the algorithm
