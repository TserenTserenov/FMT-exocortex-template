---
created: YYYY-MM-DD
id: DP.ROLE.NNN
name: Constraint Analyst
name_en: Constraint Analyst
related:
  component_of:
  - DP.ROLE.001
  downstream_consumers:
  - DP.ROLE.001 IWE Creator (pilot)  — opens the umbrella WP, receives the choice of bottleneck
    + the stage map
  - DP.ROLE.012 Strategist              — when selecting NEP items at a strategy session
  - Diagnostician                         — a special case for the learner system-learner (FORM.089
    RCS)
  - Artifactor                       — Analyst identifies stages, Artifactor decomposes
    into physical artifacts
  realizes:
  - DP.SC.NNN
  specializes:
  - U.RoleAssignment
  uses:
  - DP.WP.NNN
  - .claude/skills/bottleneck-pick
status: draft
summary: 'Carrier of the TOC methodology (Goldratt Five Focusing Steps + Tendon TameFlow
  Replenishment Cycle + Dettmer Thinking Processes). Identifies the Pipeline system,
  scans functional promises (SC-first), finds the constraint, selects the TOC tool,
  and produces a work plan as a Stage Dependency Map (no dates or hours). Universal:
  applicable to the pilot''s learning Pipeline, work Pipeline (WP/epic/project/repo),
  and cohort Pipeline.'
type: role-description
updated: YYYY-MM-DD
valid_from: YYYY-MM-DD
---

<!--
Template (IWE/pack-templates/).

This is a Role transfer from an authored Pack (WP-313 Phase11, 20 May 2026).
When adapting to your own Pack:
1. Replace `DP.ROLE.NNN` with the next available Role number in your Pack
2. Replace `DP.SC.NNN` with your Constraint Analyst service clause number
3. Replace `DP.WP.NNN` with your Stage Dependency Map work-product number
4. Set `created` / `updated` / `valid_from` to today's date
5. Remove this HTML comment before committing

Name in your language: "Constraint Analyst" (Russian) / Constraint Analyst (English). The operational name is used, not the literary one (Goldratt's "Jonah" is an inspirational metaphor, not a technical id). See §12 for literature crosscheck.
-->

# Constraint Analyst — DP.ROLE.NNN

> # see DP.SC.NNN, DP.ROLE.NNN, DP.WP.NNN
>
> **Kind:** Analytical Role — analyzes the system, does not manage it. Does not own the work of removing the constraint (that belongs to other Roles: Strategist, Artifactor, WP performer).
> **Owner Role:** IWE Platform — performer: skill `/bottleneck-pick` (text-based, headless or interactive), called via LLM agent in exocortex mode.

---

## 1. Mission

Guarantee that when working with a complex system (pilot's learning Pipeline, work Pipeline, cohort Pipeline) the selection of the next work focus is based on **justified constraint identification** using the TOC methodology — not on intuition, sunk cost, sexy-work bias, or recency.

Analogy: a process engineer who walks the entire production line and says "this is the tightest bottleneck — there is no point speeding up the other stations, they are fine." Does not build stations, hire workers, or order parts — only shows where Herbie is and what class of constraint is blocking.

**Boundary:** The Constraint Analyst does NOT:
- perform the work of removing the constraint (that belongs to execution Roles)
- make architectural decisions (that belongs to ArchGate / Strategist)
- set priorities for next best actions (that belongs to Strategist + pilot)
- give self-development recommendations (that belongs to Navigator, which uses the Analyst's `bottleneck_slot` as input)

---

## 2. Responsibilities

| Responsibility | How it is performed |
|----------------|---------------------|
| Identify the Pipeline system | Accepts `--target`, classifies system type (see §3) |
| Collect current state | git log for the last 7 days, DB metrics, content files (PROCESSES.md, WP-context, SC maps) |
| Scan functional promises (SC-first) | List service clauses for the system → for each, test "working / broken / partial" |
| Apply signal-scan across 6 TameFlow signals | Queue accumulation, Flow Efficiency, handover count, buffer consumption, policy markers, cognitive freeze |
| Classify the constraint | Trichotomy (Tendon): Work Flow / Work Process / Work Execution; Class: Policy / Resource / Cognitive |
| Select TOC tool | Decision tree: Five Focusing Steps / EC / Five Steps + EC + NBR |
| Build the Stage Dependency Map | Stage Dependency Map: nodes = stages, edges = hard dependency, parallelism within a node, external dependencies explicit |
| Produce Constraint Brief | Description, type, signal-based justification, selected tool with trace |
| Record the application | Calibration YAML in `inbox/bottleneck-pick-runs/<date>-<target>.yaml` for subsequent precision assessment |
| Signal bottleneck-shift | On repeated application to the same system after the previous constraint is removed — re-assessment |

---

## 3. Pipeline Systems (3 Classes)

> **Principle:** system ≠ flow. The system is the carrying Pipeline; the flow is what circulates through it.

| System class | Pipeline object | Flow through the Pipeline | Source of truth |
|--------------|-----------------|--------------------------|-----------------|
| **Pilot learning Pipeline** | Pilot's RCS machine | Learning cycles / reflections / completed lessons | cp-profile + digital twin |
| **Work Pipeline** | WP Pipeline inside an umbrella, epic phases, or repo | WP flow (inbox → in_progress → done) | WP-REGISTRY + inbox/WP-*.md |
| **Cohort Pipeline** | Product adoption machine: onboarding → activation → habituation | Flow of pilots through adoption stages | Activity Hub events |

**System type identification** is the mandatory first cascade step (see §5). Without it, it is impossible to select relevant signals or the applicable class of TOC tool.

---

## 4. Inputs / Outputs

**Inputs (from consumers):**
- `target-ref` — Pipeline system identifier: WP-NNN, project-name, repo-path, or `rcs-profile:<account_id>` for a learner system
- `--horizon` (optional) — wave-1 / week / quarter / next-stage
- `--depth` (optional) — 1 (Five Steps only) / 2 (+ EC for conflicting candidates)
- `--scope` (optional) — direct / direct+related / full (connection graph depth)

**Outputs (3 Artifacts):**

| Artifact | Content | Where it is written |
|----------|---------|---------------------|
| **System Card** | System type, promises (SC map), consumers, current state, data freshness | inline in chat + section in calibration YAML |
| **Constraint Brief** | Constraint description, trichotomy, class (Policy/Resource/Cognitive), signal-scan signals, selected TOC tool with trace, NBR result | inline in chat + calibration YAML |
| **Stage Dependency Map** | Work plan as dependency graph: nodes = stages, parallelism within node, edges = hard dependency, external edges explicit | inline in chat + optionally in `inbox/WP-NNN/stage-map.md` |

---

## 5. Work Algorithm — Five-Phase Cascade

> Cascade principle: the output of each phase is the input of the next. Every input and output is a physical Artifact.

| # | Phase | Input (Artifact) | Action | Output (Artifact) |
|---|-------|-----------------|--------|-------------------|
| **P1** | **Identify system** | target-ref from consumer | Classify system type (learning / work / cohort); collect PROCESSES, WP-context, metrics; record data freshness | **System Card** (type, promises, consumers, current state) |
| **P2** | **Scan promises (SC-first)** | System Card | List functional promises for the system → for each, test: "working? broken? partial?" → mark candidates from "not working" | **SC-status map** (each promise + status + signals) |
| **P3** | **Identify constraint** | SC-status map + work structure (directions / phases / WPs) | Signal-scan across 6 TameFlow signals for top candidates from P2; classify trichotomy + Policy/Resource/Cognitive | **Constraint Brief draft** (top-3 candidates + classification + signals) |
| **P4** | **Choose TOC tool** | Constraint Brief draft | Decision tree: Five Focusing Steps / EC / Five Steps + EC; mandatory NBR after injection | **TOC tool trace** (selected tool + assumptions + injection + NBR-trim) |
| **P5** | **Compose stage map** | Constraint Brief + TOC tool trace + dependency list (including external) | Build dependency graph: nodes = stages, parallelism = within node, edges = hard dependency, external edges explicit | **Stage Dependency Map** |

**SC-first principle (P2 before P3):** a document-centric approach of "what is pending in the WP" substitutes the product for the delivery channel. The correct approach starts with "which functional promise is not working for the consumer." The channel is a consequence, not the goal.

---

## 6. Constraints (Role Invariants)

1. **System ≠ flow.** The Analyst ALWAYS classifies the Pipeline system (3 classes, §3) before signal-scan.
2. **SC-first before WP scanning.** Functional promises first (P2), then work structure (P3).
3. **Trichotomy + class are mandatory.** Output without classification (Work Flow / Process / Execution × Policy / Resource / Cognitive) is a P3 failure.
4. **NBR after any EC injection.** 3 negative branches + trim of each.
5. **Stage Dependency Map — no dates or hours.** Structural dependency only.
6. **External dependencies — explicit.** If a stage depends on work in another WP / repo / external supplier — an explicit external edge is required.
7. **Constraint Replenishment Cycle (Tendon).** After the constraint is removed — mandatory re-assessment (P1 again).
8. **Calibration tracking.** Every application → YAML in `bottleneck-pick-runs/`.

---

## 7. Relations With Other Roles

| Role | Relation |
|------|----------|
| **IWE Creator (pilot)** | Primary consumer: opens an umbrella WP or epic, requests bottleneck selection |
| **Strategist** | Uses the Analyst in a strategic session when selecting next best actions |
| **Diagnostician** | Special case: for a learner system the Analyst is a different instantiation of the same methodology (FORM.089 as a specialization of signal-scan) |
| **Artifactor** | Sibling Role: the Analyst identifies the constraint and plan stages; the Artifactor decomposes stages into physical Artifacts with acceptance checklists |
| **Navigator** | Consumer: when answering the pilot's "where to start," uses the Analyst's `bottleneck_slot` |

**Distinction from Artifactor:** The Analyst answers **"where to look."** The Artifactor answers **"how to do it."** Sequencing: Analyst → Artifactor.

**Distinction from Diagnostician:** The Diagnostician is a specialization of the Analyst for the "pilot learning Pipeline" system. One TOC algorithm, different parameters.

---

## 8. Entry Points

### Skill invocation (for the consumer)

```bash
# Umbrella WP with directions
/bottleneck-pick --target WP-250

# Epic with phases + horizon
/bottleneck-pick --target WP-188 --horizon wave-1

# Full project
/bottleneck-pick --target {{PROJECT_REPO}} --scope direct+related

# Pilot learning Pipeline
/bottleneck-pick --target rcs-profile:<account_id> --horizon next-stage
```

---

## 9. Metrics

| Metric | Norm | Source |
|--------|------|--------|
| Bottleneck selection precision | ≥70% correct per retrospective | Calibration YAML `was_correct` |
| % of applications where pilot accepted the selection | ≥80% | Calibration YAML `action_taken` |
| Throughput change after fix | positive | Calibration YAML `observed_throughput_change_after_2w` |
| Average time P1→P5 | ≤15 min | Skill logs |

---

## 10. Open Questions

1. **Auto-classification of system type** from target format.
2. **SC maps for all system types** (unified SC-scanning methodology).
3. **Stage Dependency Map persistence** (when to save as a file, when to keep inline).
4. **Relation to ArchGate** (auto-call if bottleneck = architectural decision).
5. **Relation to Artifactor** (auto-call for decomposing stages into physical Artifacts).

---

## 11. TOC Literature Crosscheck (name selection)

| Source | Name in literature | Role |
|--------|--------------------|------|
| Goldratt "The Goal" 1984 | **Jonah** | Inspirational metaphor, Socratic mentor |
| Dettmer "Logical Thinking Process" 2007 | **Constraint Manager** | Formal carrier of Thinking Processes |
| Schragenheim "Throughput Economics" 2019 | **TOC Analyst** | TOC decision analyst |
| Tendon "Tame Your Work Flow" 2020 | Distributed (no dedicated Role) | TameFlow: distributed team responsibility |
| Goldratt S&T Tree 2009 | **S&T Tree Planner** | Builder of the Strategy & Tactics tree |

**Adopted name:** "Constraint Analyst" — general, operational, not tied to a specific TOC school.
