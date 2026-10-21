---
agents: none
argument-hint: <quality 1..5> [depth 1..3]
browser_safe: false
description: Record a W-reflection (worldview slot RCS) in learning.w_reflections.
  Used by Diagnostician R28 (MIM.R.009) or invoked by the user after a reflective
  session. Affects the Disciplined → Proactive gate (FORM.089 §5.2).
gates_enforced: []
gates_rationale: operational skill; WP Gate applicable only when creating a new WP,
  not for operational calls
gates_required: []
interaction: one-shot
layer: L1
name: w-reflection
routing:
  deterministic: true
  executor: script
  optimization_priority: 1
  script_path: scripts/iwe-w-reflection.sh
status: active
triggers:
  phrases: []
  slash:
  - /w-reflection
version: 1.0.0
---

# W-Reflection — Recording the Worldview Indicator

> **Purpose:** populate `learning.w_reflections` to calculate `W.idx` in the SR algorithm (FORM.089 §5).
> **When to invoke:** after a reflective session (dialogue with Diagnostician R28, individual self-analysis, review of a worldview error). Not for routine mood logging — this is calibration.
> **Effect:** W ≥ 4 is required for the Disciplined → Proactive transition (gate D→P).

## When to use

Record a W-reflection (worldview slot RCS) in learning.w_reflections. Used by Diagnostician R28 (MIM.R.009) or invoked by the user after a reflective session. Affects the Disciplined → Proactive gate (FORM.089 §5.2).

## Arguments

- `$1 = quality_score` — 1..5 per rubric:
  - 1 — surface (statement without causes)
  - 2 — descriptive ("what happened" present, "why" absent)
  - 3 — analytical (causes, consequences)
  - 4 — systemic (self viewed as a system, agency)
  - 5 — meta-systemic (self viewed as a role within a Supersystem)
- `$2 = depth_level` (optional, default 2) — 1..3:
  - 1 — surface
  - 2 — medium (standard)
  - 3 — deep (>30 min analysis)

## Algorithm

### Step 1. Invoke the routing Script

```bash
bash "$IWE_SCRIPTS/route-task.sh" --skill w-reflection --args "$ARGUMENTS"
```

The Script reads `IWE_OWNER_ORY_UUID` from the Environment (account_id) and writes to `learning.w_reflections` via the `w_reflection_writer` Role (Migration 112). If the writer URL is absent, it falls back to `DATABASE_URL_LEARNING_DIRECT`.

### Step 2. Check the exit code

Exit codes and their meanings are described in the **Output** section below.

### Step 3. Return the response to the pilot

On exit 0 — print the OK string from stdout. On a non-zero exit — print the error.

## Output

- exit 0 + `[w-reflection] OK: account=... quality=N depth=M` — success
- exit 1 — invalid arguments
- exit 2 — `IWE_OWNER_ORY_UUID` or DB URL is missing
- exit 3 — database error (constraint violation, network)

## Example

```bash
/w-reflection 3        # quality=3, depth=2 (default)
/w-reflection 4 3      # quality=4, deep
```

## Dependencies

- Migration `112-w-reflection-writer-grants.sql` (in the Infrastructure Repository migrations directory)
- Logic source: [`PD.FORM.089-learner-rcs.md`](../../../PACK-personal/pack/personal-development/02-domain-entities/formalizations/PD.FORM.089-learner-rcs.md) §5
- Reader: `learning.stage_evaluator` worker (WP-253 Block 2 Phase 1.3)

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
