---
browser_safe: false
description: 'Constraint Analyst (DP.ROLE.054): identifies the primary constraint
  (bottleneck) of a specific pipeline using TOC Five Steps + EC + NBR and builds a
  Stage Dependency Map. Use ONLY when working with a specific WP, epic, project, or
  weekplan (--target WP-NNN|weekplan|pilot:id). Do NOT use for general prioritization
  questions without an explicit system context.'
layer: L1
name: bottleneck-pick
routing:
  deterministic: false
  executor: sonnet
status: active
triggers:
  phrases:
  - pick bottleneck
  - what is the current constraint
  - system bottleneck
  - bottleneck-pick
  slash:
  - /bottleneck-pick
version: 1.0.0
---

# Skill: /bottleneck-pick

> # see DP.SC.045, DP.ROLE.054, DP.WP.016
>
> TOC methodology carrier for the pilot: Goldratt Five Focusing Steps + Tendon TameFlow Replenishment Cycle + Dettmer Thinking Processes.
> Implements the role of **Constraint Analyst (DP.ROLE.054)** through a five-phase VDV cascade.
> Source: WP-313 (Phase 1 research: Tendon "Tame Your Work Flow", Dettmer, Schragenheim, Goldratt S&T; Phase 11 IntegrationGate).

## Triggers

- User opens an umbrella WP, epic, or project and asks "what to do first"
- Request: "pick bottleneck", "what is more important", "where to start"
- Strategic session selecting the critical constraint ("which direction is the bottleneck right now")
- Diagnostician (R28) requests analysis for a pilot learning pipeline
- Explicit call `/bottleneck-pick --target WP-NNN`

## SC-first principle (primary rule)

> **Document-centric approach is an anti-pattern.** Starting from a list of pending WPs risks mistaking the delivery channel for the product.

**Correct:** Phase 2 scans functional promises (DP.SC) BEFORE Phase 3 (signal-scan over the work structure).
**Test:** if the Constraint Brief contains no references to specific DP.SC items that "are not working" — Phase 2 has failed.

## API

```
/bottleneck-pick --target <ref> [--layer intra|platform] [--horizon <horizon>] [--depth <1|2|3>] [--scope <direct|direct+related|full>]
```

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--target` | required | `WP-NNN` (umbrella WP), `weekplan` (current week), `pilot:<account_id>` (pilot learning pipeline), `b2:aisystant` (full ecosystem — requires `--layer=platform`), `c2:platform` (technical layer only — requires `--layer=platform`), project-name, repo-path |
| `--layer` | intra | `intra` = within a single system (constraint = phase / WP / block). `platform` = across C2 subsystems (constraint = subsystem / handover / B3 role). Requires a user-provided systems map. |
| `--systems-map` | `memory/project_iwe_systems_map.md` in the installed workspace | Path to the user-provided map for `--layer=platform`; an absolute path to a private directory is accepted. The map is not shipped with the public template. |
| `--horizon` | all | day, week, month, wave-1, wave-2, quarter, next-stage |
| `--depth` | 2 | 1 = Five Steps only; 2 = + EC for conflicting candidates; 3 = + Coupling-analysis SOTA.011 for top-3 handovers (`--layer=platform` only) |
| `--scope` | direct+related | direct = target only; direct+related = + related WPs from frontmatter; full = + reachable via dependency graph ≤2 hops |

### Sources by `--target` type

| Target | What the skill reads | Where the source lives |
|--------|----------------------|------------------------|
| `WP-NNN` | `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/WP-NNN-*.md` + related WPs + git last 7d | governance |
| `weekplan` | `${IWE_GOVERNANCE_REPO:-DS-strategy}/current/WeekPlan W{N}.md` + active-wp.md + DP.SC over active WPs | governance |
| `pilot:<id>` | `learning.activity_log` + `learning.cp_assessments` + `learning.bh_metrics` (Neon) | platform (learning pipeline) |
| `b2:aisystant` | `03-our-systems-map.md` (S2R) + `DP.MAP.002` + user map from `--systems-map` + cross-system SC | governance + Pack + user file |
| `c2:platform` | `DP.MAP.002` (12 subsystems) + new Q2 entries from user map | Pack + user file |

### Error cases

| Situation | Behavior |
|-----------|----------|
| Target not found | "Could not find `<target>`. Check the number or path." → STOP |
| Target is a closed WP | "`<target>` is already closed. Provide an active WP." → STOP |
| Target is empty (no structure) | "No structure to analyze in `<target>`." → STOP |
| `--layer=platform`, map is missing, empty, or unreadable | Run `"$IWE_TEMPLATE/scripts/check-platform-systems-map.sh"` from the installed template, display its exact diagnostic output, and STOP before the System Card and conclusions. The user must create their own map or provide `--systems-map <path>`. |
| Data is stale (>7 days without git activity) | Add ⚠️ to signal-scan; do not stop |
| EC does not converge (empty assumptions) | Fall back to Five Steps; note in output |
| All candidates are not agent-actionable | "All candidates are not agent-actionable. A different entry point is needed." |

---

## Algorithm — five-phase VDV cascade

> VDV principle (DP.M.060): the output of each phase is the input to the next. Every input and output is a physical Artifact.

### Phase 1 — Identify system

**Input:** target-ref + `--layer` from the user.

**Action:**
0. For `--layer=platform`, **before analysis**, determine the installed workspace root (`WS="${IWE_WORKSPACE:-$PWD}"`), load `. "$WS/.iwe-paths"`, and verify that `IWE_TEMPLATE`/`IWE_WORKSPACE` are non-empty; if the file or variables are missing — report a path setup error and STOP. Then run `bash "$IWE_TEMPLATE/scripts/check-platform-systems-map.sh"` or, if the parameter is set, `bash "$IWE_TEMPLATE/scripts/check-platform-systems-map.sh" --map "<path from --systems-map>"`. The script lives in the nested template; the map lives in the workspace. Exit code 2: print the diagnostic and STOP — a missing map cannot be replaced by a guess or by `DP.MAP.002` alone. The script prints the verified path — use that user file from this point on. For `--layer=intra` this check is not needed.
1. Classify the pipeline system type by `--target` × `--layer`:
   - **Pilot learning pipeline** — `--target pilot:<id>` (FORM.089 RCS, source: Neon `learning.*`)
   - **Work pipeline (intra)** — `--target WP-NNN | weekplan | project | repo-path`, `--layer=intra`. Structure = directions A–I / phases Phase 1–PhaseN / blocks within a single WP
   - **Platform (cross-system)** — `--target b2:aisystant | c2:platform | WP-NNN-umbrella`, `--layer=platform`. Structure = C2 subsystems + handovers + B3 roles. ⚠️ Validation: the verified user map and `DP.MAP.002` must be loaded; take the subsystem count from the map, not from the template.
   - **Cohort pipeline** — `--target cohort:<id> | wave-N`
2. Collect context by type:
   ```bash
   # intra
   git log --oneline --since="7 days ago" <repo>
   cat <target-context-file>
   ls <related-PROCESSES.md>

   # platform
   ls PACK-digital-platform/.../08-service-clauses/   # cross-system SC
   cat "<verified_map_path>"                           # path printed by check-platform-systems-map.sh
   git log --oneline --since="7 days ago" --all       # activity across subsystems
   ```
3. Record data freshness. If ≥7 days without activity — ⚠️. For `--layer=platform`: check `DP.MAP.002` freshness (stale >30 days → ⚠️).

**Output:** **System Card** (in chat + calibration YAML):
```
System type: learning_pipeline | work_pipeline_intra | work_pipeline_platform | cohort_pipeline
Target: <target-ref>
Layer: intra | platform
Structure: <directions A–I | phases Phase1–PhaseN | C2 subsystems + handovers | RCS slots>
Subsystems in scope: <N — only when layer=platform>
Data freshness: <date + flags>
Unregistered subsystems: <list — only when layer=platform, if any>
```

### Phase 2 — Scan promises (SC-first)

**Input:** System Card.

**Action:**
1. Locate DP.SC by system type:
   - **`--layer=intra`** (WP / epic / repo): SC from WP frontmatter + SC consumed by target roles + SC within a single subsystem
   - **`--layer=platform`** (b2 / c2 / umbrella WP): **cross-system SC** — DP.SC.020 retention, DP.SC.012 onboarding, DP.SC.003 learning, hypothesis G-K1. Additionally check B3-to-B2 SC (team↔ecosystem) — often not formalized; flag if so.
   - **Learning pipeline** (`pilot:`): FORM.089 sections (specialization SC)
   - **Cohort pipeline**: SC from MAP.002 for wave-rollout, adoption, lifecycle
2. Apply a health test to each SC:
   ```
   - "Working?" (event freshness, consumers present, no active incidents)
   - "Broken?" (explicit open incident, no events for N days, negative feedback)
   - "Partial?" (some consumers receive it, others do not)
   ```
   **For `--layer=platform`** — additional test: "Broken at the handover?" — one subsystem produces output, the other does not accept it (gap between Bot and GitHub App, between Profiler and Stage Evaluator, etc.).
3. Mark SC-failing and SC-partial items as bottleneck candidates.

**Output:** **SC-status map** (format depends on `--layer`):

**For `--layer=intra`:**
```
| SC ID         | Promise                                  | Status       | Signal                                      |
|---------------|------------------------------------------|--------------|---------------------------------------------|
| DP.SC.020     | Personal guide delivery                  | ⚠️ Partial  | 5/9 pilots have not activated repo          |
| DP.SC.132     | Learner diagnostics                      | ✅ Works    | cp_assessments recorded daily               |
| DP.SC.044     | Event ingest                             | ⚠️ Partial  | subscription.contract_event = 0 rows        |
```

**For `--layer=platform` (cross-system path):**
```
| SC          | Cross-system path                                  | Status       | Weak link                                       |
|-------------|-----------------------------------------------------|--------------|--------------------------------------------------|
| DP.SC.020   | Bot → /personal-guide-start → GitHub App → repo    | ⚠️ Partial  | handover Bot↔GitHub App (6/9 not activated)     |
| G-K1        | Bot → Onboarding → Profiler → Stage Eval → Nudge   | ❌ FAIL     | Nudge missing (WP-117 not started)               |
| DP.SC.112   | YooKassa → Bot → CRM → Access Manager              | ✅ Works    | stable                                           |
```

### Phase 3 — Identify constraint

**Input:** SC-status map + work structure from System Card.

**Action:**
1. For each SC-failing/partial item and each structure block (direction / phase / WP / subsystem / handover) — signal-scan using TameFlow signals (ordered by predictive value):

| # | Signal | Trigger | Applies to |
|---|--------|---------|------------|
| 1 | Queue accumulation rate | Δ queue length / 7d ≥30% growth | all |
| 2 | Flow Efficiency drop | touch/lead <15% or Δ −10pp/week | all |
| 3 | Dependency fan-in / handover count | >3 handovers in one user journey = policy issue | all |
| 4 | Buffer consumption rate | CCPM fever chart: Yellow → monitor, Red → act | all |
| 5 | Policy freeze markers | NLP search: "requires approval", "we always do it this way", "the rule is" | all |
| 6 | Cognitive freeze | growing open questions without resolution, signs of procrastination | all |
| 7 | **Cross-system handover count** | handovers >3 per user journey across C2 subsystems = systemic | **`--layer=platform` only** |
| 8 | **Coupling tightness (SOTA.011)** | SC of one layer depends on the internal implementation of another = tight coupling, candidate handover-constraint | **`--layer=platform` only** |

2. Select top-3 candidates by combined signal score.
3. Classify each candidate:
   - **Trichotomy (Tendon):** Work Flow / Work Process / Work Execution
   - **Class:** Policy / Resource / Cognitive
   - **For `--layer=platform`** — additionally **Locus** (where the constraint sits): `Subsystem` (one C2 subsystem is the bottleneck) / `Handover` (both subsystems work, but SC breaks between them) / `Role(B3)` (subsystem exists, but the team role is unassigned or overloaded)
4. FILTER: remove items that are not agent-actionable (external block, no actionable steps in 2–4h, done block).

**Output:** **Constraint Brief draft** (top-3 + classification + signals; for `--layer=platform` also Locus).

### Phase 4 — Choose TOC tool

**Input:** Constraint Brief draft.

**Action — Decision tree:**

```
[All --layer values]

Weakest stage is obvious and data is available?
  → Five Steps (linear)

≥2 policy markers OR cognitive-freeze signal is high?
  → Five Steps + EC

2 candidates are equal, no clear "weaker" one?
  → EC (core conflict)

"Exploit" intuitively means "hire/buy" (instinct toward Elevate)?
  → EC first (marker: policy-constraint)

Solution is obvious but side-effects are a risk?
  → Five Steps + NBR

[--layer=platform only]

Locus = Subsystem is missing (no WP exists for the required SC)?
  → Five Steps + WP Gate Ritual (a new WP to create the subsystem is needed)

Locus = Handover between 2 subsystems?
  → EC required: D = "fix subsystem A" vs D' = "fix subsystem B"
  → + Coupling-analysis SOTA.011 at --depth=3: can the handover be eliminated entirely?

Locus = Role(B3) overloaded?
  → EC: D = "hire" vs D' = "automate the role"
  → NBR required (risk of heavy-coordination overhead)

All subsystems are stable but cross-system SC is not fulfilled?
  → Goldratt S&T Tree: missing assumptions (no SC, promise not recorded)
```

**If EC:** Quality gate ≥2 assumptions per side:
```
A (Common Goal): ...
B (Need): ...      C (Need): ...
D (Want): ...      D' (Want): ...
Assumptions D→B: ...
Assumptions D'→C: ...
Injection: ... (in assumption, not in action)
```
Empty / abstract assumptions → retry or fall back to Five Steps. EC applies to actions only, not to values.

**NBR (required after injection):** 3 negative branches + trim:
```
1. [risk 1] → trim: [how to neutralize]
2. [risk 2] → trim: [how to neutralize]
3. [risk 3] → trim: [how to neutralize]
```

**Output:** **TOC tool trace** (tool + EC details if applied + NBR trims).

### Phase 5 — Compose stage map

**Input:** Constraint Brief + TOC tool trace + dependency list (including external).

**Action:**
1. Identify the stages of reaching the target state (removing the constraint):
   - A stage = a system state, not an action ("≥5 pilots activated" ≠ "activate pilots")
   - Inside each node — parallel work items following the **strict 4-category template** (see below)
   - Between nodes — hard dependency ("otherwise we cannot proceed", not "would be nice")
2. Inside each stage, distribute parallel work items across the **4 canonical TOC/Dettmer categories** (always show all 4; empty = "—"):
   - **Technical (Platform/Technical)** — code, infrastructure, architecture, integrations, CI/CD, data pipelines
   - **Process (Organizational/Process)** — processes, communications, coordination between roles, user testing, onboarding
   - **Policy (Policy/Governance)** — standards, architecture decisions, approvals, policy changes
   - **Cognitive (Cognitive/Capability)** — training, documentation, mental models, building distinctions
3. Identify external dependencies — work in other WPs, repos, or from external suppliers (separate block; always show)
4. **For `--layer=platform`** — parallel **Locus** axis for each stage: Subsystem / Handover / Role(B3) — who specifically changes
5. Build the graph (DP.WP.016 format): nodes = stages, edges = hard_dependency, external edges explicit
6. Topological sort is required (no cycles)

**Strict template principle:** all 4 categories are always shown, even when empty ("—"). Analogy: an aircraft safety checklist — the "check landing gear" item remains even for a seaplane, so it is visible that the check was not skipped. The strict template prioritizes audit reliability over brevity.

**Output:** **Stage Dependency Map** (DP.WP.016 format) — in chat as markdown + optionally in `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/WP-NNN/stage-map.md`:

```markdown
## Stage Dependency Map: <target> (layer: intra | platform)

### Stage 1: <noun-artifact label>
**Goal:** <system state after this stage>

**Work categories (strict template — always 4):**

**1. Technical (Platform):**
- work item A
- work item B (WP-NNN)

**2. Process:**
- —

**3. Policy:**
- work item C → requires /archgate

**4. Cognitive:**
- —

**External dependencies:** <target in another repo | none>

[For --layer=platform only — additional axis:]

**Locus:**
- Subsystem: <subsystem X> — change within a single system
- Handover: <A↔B> — change in the gap between systems
- Role(B3): <role> — change in the team

### → Stage 2: <label>
> Can start only after Stage 1 is complete (reason: <reason>)
...
```

---

## Output (full artifact, printed to chat)

```markdown
## System Card
**System type:** learning_pipeline | work_pipeline_intra | work_pipeline_platform | cohort_pipeline
**Target:** <target-ref>
**Layer:** intra | platform
**Structure:** <directions A–I | phases | C2 subsystems + handovers>
**Subsystems in scope:** <N — only when layer=platform>
**Data freshness:** <date + flags>

## SC-status map (Phase 2 SC-first)
[--layer=intra:]
| SC | Promise | Status | Signal |
| --- | --- | --- | --- |
| DP.SC.NNN | ... | ✅/⚠️/❌ | ... |

[--layer=platform — cross-system path:]
| SC | Cross-system path | Status | Weak link |
| --- | --- | --- | --- |
| DP.SC.020 | A → B → C → D | ⚠️ | handover B↔C |

## Constraint Brief
**Bottleneck:** <block / direction / phase / subsystem / handover / role>
**Trichotomy:** Work Flow | Work Process | Work Execution
**Class:** Policy | Resource | Cognitive
**Locus:** Subsystem | Handover | Role(B3)  [only when layer=platform]
**Affected SC:** [DP.SC.NNN, ...]

### Signal-scan
- Queue accumulation: <Δ over 7d or "no data">
- Flow Efficiency: <% or "no data">
- Dependency fan-in: <N handovers>
- Policy markers: <keywords or "none">
- Buffer: <status or "no data">
- Cognitive freeze: <indicators or "none">
- Handover count (cross-system): <N per user journey>          [only when layer=platform]
- Coupling tightness (SOTA.011): low | medium | high           [only when layer=platform]

## TOC tool: Five Steps | EC | Five Steps + EC | + Coupling-analysis

[If EC:]
### EC — core conflict
**A:** ...    **B:** ...    **C:** ...    **D:** ...    **D':** ...
**Assumptions D→B:** ...
**Assumptions D'→C:** ...
**Injection:** ...

### NBR
1. <risk> → trim: ...
2. <risk> → trim: ...
3. <risk> → trim: ...

## Stage Dependency Map (DP.WP.016)

### Stage 1: <label>
**Goal:** ...

**Work categories (strict template — always 4):**

**1. Technical (Platform):** ...
**2. Process:** ...
**3. Policy:** ...
**4. Cognitive:** ...

**External dependencies:** ...

**Locus:** Subsystem | Handover | Role(B3)  [only when layer=platform]

### → Stage 2: <label>
> Can start only after Stage 1 is complete (reason: ...)
...

## Alternatives (P2/P3 candidates)
- ...

## Skipped (not agent-actionable)
- ...

**First-stage budget: ~Nh**

---
Proceed with Stage 1 "<label>" or start with alternative P2 "<...>"?
```

---

## Anti-patterns

1. **WP scan without SC-first** — starting from a list of pending WPs without checking functional promises. Risk: mistaking the delivery channel for the product.
2. **Stage Map with dates/hours** — the format is structural, not temporal. Dates → premature commitment.
3. **Soft dependencies in edges** — only `hard_dependency`. "Would be nice to do first" means they belong in the same stage or are independent.
4. **Skip Subordinate → Elevate** ("hire more people" as the first conclusion) — exploit capacity first.
5. **Policy mis-classified as Resource** — hiring when the rule needs to change. Apply the discriminator from Schragenheim.
6. **Moving Herbie without a policy diagnosis** — if the bottleneck has migrated 2+ times → it is policy-driven, not resource-driven.
7. **EC with empty assumptions** — retry or fall back to Five Steps.
8. **Five Steps on cognitive freeze** — do not speed up the flow; simplify the challenge or build the Skill.
9. **Output >1 screen for Constraint Brief** — compress; do not expand the full tree (Stage Map may be longer).
10. **EC on values** (D/D' = "flexibility" vs "stability") — reformulate as actions.
11. **Stage Dependency Map without external dependencies** — if a stage genuinely depends on work in another WP, add an explicit external edge.
12. **Stage Map with an empty category and no "—" (soft template)** — it is impossible to distinguish "forgot to think about it" from "decided to skip it". Strict template: always 4 categories; empty = "—".
13. **[platform only] Reducing the platform to a single system** — picking one C2 subsystem as the bottleneck without checking cross-system SC. Symptom: answer "WP-117 = bottleneck" with no explanation of which SC it closes.
14. **[platform only] B3-blindness** — a bottleneck in a role (bus-factor individual) is missed because roles are not in MAP.002. Force: explicitly check B3 in Phase 3.
15. **[platform only] Handover-blindness** — both subsystems work, but SC breaks between them. Force: handover = a separate unit of analysis in Locus.
16. **[platform only] "Hire a manager" as the first Elevate for a Role-constraint** — Role(B3) is resolved through role automation (subsystem), not hiring. Force: EC is required for a Role-constraint.
17. **[platform only] Coupling debt accumulation** — the Subordinate plan does not account for coupling debt after the fix (SOTA.011). Force: `--depth=3` with Coupling Model for a Handover-constraint.

---

## Calibration (after each run)

Save to `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/bottleneck-pick-runs/<YYYY-MM-DD>-<target>.yaml`:

```yaml
date: YYYY-MM-DD
target: <target-ref>
layer: intra | platform
system_type: learning_pipeline | work_pipeline_intra | work_pipeline_platform | cohort_pipeline
subsystems_in_scope: N                    # only when layer=platform
sc_failing: [DP.SC.NNN, ...]              # from Phase 2
identified_constraint:
  location: <block | subsystem | handover | role>
  trichotomy: work_flow | work_process | work_execution
  class: policy | resource | cognitive
  locus: subsystem | handover | role_b3   # only when layer=platform
instruments_used: [five_steps, ec, nbr, coupling_analysis]
stage_dependency_map:
  num_stages: N
  has_external_deps: true | false
  categories_filled: [platform, process, policy, cognitive]  # which of the 4 are non-empty
action_taken: <what was done>
was_correct: null          # filled in on Week Close
observed_throughput_change_after_2w: null
bottleneck_shifted_to: null                # filled in after 2 weeks
```

After 5–10 runs → analyze precision on Week Close, recalibrate signal weights.

---

## Integration

- **Bottleneck = architecture decision** (Policy type with alternatives) → propose `/archgate`
- **Stage Map contains an open-loop work item ≥3h** → propose the Decomposer (`/decompose`) to break it down into physical Artifacts
- **Bottleneck = no covering WP** → propose WP Gate ritual
- **Bottleneck-shift detection** (re-run against the same target after a fix) → DP.M.061 layer reassessment (tech/operational/usage/behavioral)

---

## Related documents (Pack)

- **DP.ROLE.054** — Constraint Analyst (methodology carrier)
- **DP.SC.045** — Constraint Analysis promise (what is delivered to the consumer)
- **DP.WP.016** — Stage Dependency Map format
- **DP.M.061** — Bottleneck-Shift Detection (supporting method after constraint removal)
- **PD.PRINC.046** — Mental Model as Constraint (Tendon)

---

## Staging

`STAGING.md`: S-42, `status: testing`
Promotion criteria: ≥2 smoke tests (passed) + ≥1 calibration session + pilot accepted ≥3 decisions without redirect + Pack Artifacts formalized (Phase 11 complete).

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
