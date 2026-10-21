---
consumer: Pilot (IWE Creator), Strategist, Artifactor, Navigator, Diagnostician (special case
  for the learning pipeline)
created: YYYY-MM-DD
id: DP.SC.NNN
layer: L4-Personal
name: System Constraint Analysis (TOC)
name_en: Constraint Analysis (TOC)
name_ru: System Constraint Analysis (TOC)
related:
  realizes: []
  uses:
  - DP.ROLE.NNN
  - DP.WP.NNN
  - .claude/skills/bottleneck-pick
status: draft
summary: 'The consumer (pilot / Strategist / Artifactor / Navigator) receives three
  artifacts as output of the five-phase VDV cascade: a System Card (pipeline system
  classification), a Constraint Brief (constraint description with trichotomy + class),
  and a Stage Dependency Map (work plan as a dependency graph without dates or hours).
  SC-first: functional promise viability is verified before pending Work Product structure.'
type: sc
updated: YYYY-MM-DD
---

<!--
Template (IWE/pack-templates/).

This is a service clause transfer from the author's Pack (WP-313 Phase11, 20 May 2026).
When adapting to your own Pack:
1. Replace `DP.SC.NNN` with the next available L4-Personal number (001-099)
2. Replace `DP.ROLE.NNN` with your Constraint Analyst role number
3. Replace `DP.WP.NNN` with your Stage Dependency Map format number
4. Set `created` / `updated` to today's date
5. Remove this HTML comment before committing
-->

# [DP.SC.NNN] System Constraint Analysis (TOC)

## Rule (invariant)

> What MUST always hold. Violation = SC failure.

- **Pipeline system identification is required.** Without classification (learning pipeline / work pipeline / cohort pipeline), signal-scan does not start.
- **SC-first order.** Phase 2 "Scan promises" executes BEFORE Phase 3 "Identify constraint". Document-centric analysis (what is pending in the Work Product) without prior verification of the consumer's functional promises is an anti-pattern.
- **Trichotomy + class are required.** Trichotomy (Tendon): Work Flow / Work Process / Work Execution. Class: Policy / Resource / Cognitive.
- **NBR after any EC injection.** 3 negative branches + trim of each.
- **Stage Dependency Map — no dates or hours.** Structural dependency only.
- **External dependencies — explicit.** If a stage depends on work in another Work Product / repo / external supplier — an explicit external edge is required.
- **Calibration record is required.** Each application → YAML in `{{GOVERNANCE_REPO}}/inbox/bottleneck-pick-runs/<date>-<target>.yaml`.
- **PII must not be written to the Calibration record.** Cohort pilot names, raw correspondence text, and email addresses are not stored.

---

## Promise

**To whom:**
- **Pilot (IWE Creator)** — primary consumer: "opened WP-NNN → received a justified bottleneck selection → stage plan → acted"
- **Strategist** — when selecting priority focus items at a strategy session
- **Artifactor** — in sequence: the Analyst identifies stages, the Artifactor decomposes each into physical artifacts
- **Navigator** — when answering a pilot's question "where to start"
- **Diagnostician** — a specialized variant for the learning pipeline

**Why:**
- Justified selection free of cognitive biases (sunk cost, sexy work bias, recency)
- Protection against substituting the product with the delivery channel
- Stage boundaries serve as input for decomposition into physical artifacts

**What they receive:** Three artifacts as output of the five-phase VDV cascade:

```
{
  "system_card": {
    "type": "learning_pipeline | work_pipeline | cohort_pipeline",
    "target": "<target-ref>",
    "promises": ["<service_clause_id>: status", ...],
    "current_state": {...}
  },
  "constraint_brief": {
    "description": "...",
    "trichotomy": "work_flow | work_process | work_execution",
    "class": "policy | resource | cognitive",
    "tool_selected": "five_steps | ec | five_steps_ec_nbr"
  },
  "stage_dependency_map": {
    "stages": [...],
    "edges": [...]
  }
}
```

**Trigger:** Explicit call of `/bottleneck-pick --target <ref>` by the pilot or another role.

**Response time:** ≤15 min for experienced use; up to 30 min on first applications.

**Failure mode:**
- Target not found / empty / done Work Product → STOP with a clear reason
- Data is stale (>7 days) → ⚠️ on signal-scan, do not stop
- EC does not converge → fallback to Five Steps

---

## Usage scenarios

### Scenario 1: Umbrella Work Product (lead)

The pilot opens an umbrella Work Product with N directions → `/bottleneck-pick --target WP-NNN --horizon wave-1` → the Analyst returns the bottleneck direction selection + Stage Dependency Map with stages (parallelism within a node, hard dependencies between nodes).

### Scenario 2: Epic with phases

The pilot manages an epic with N phases → `/bottleneck-pick --target WP-NNN --horizon wave-1` → selection of the next phase with signal-scan justification; NBR safeguards for risky injections.

### Scenario 3: Strategy session (Strategist)

Weekly strategy session → `/bottleneck-pick --target {{GOVERNANCE_REPO}} --scope direct+related` → diagnosis of "which work direction is currently the bottleneck" as input for priority focus discussion with the pilot.

### Scenario 4: Pilot learning pipeline (Diagnostician specialization)

The Diagnostician receives the request "what is my current stage and what should I fix first" → `/bottleneck-pick --target rcs-profile:<account_id> --horizon next-stage` → specialized signal-scan across RCS slots (stage_raw, Δ baseline, gap to next stage, dependency between slots) → slot selection + skip entry for the next stage.

---

## Related documents

- `DP.ROLE.NNN` Constraint Analyst — method owner (in your Pack)
- `DP.WP.NNN` Stage Dependency Map — output format (in your Pack)
- `.claude/skills/bottleneck-pick/SKILL.md` — algorithm carrier tool
