---
agents: none
argument-hint: status | opt-in [scope] | opt-out | revoke
browser_safe: false
description: Manage consent in learning.tracking_consent — opt-in / opt-out / status
  / revoke. Required for the stage_evaluator worker (WP-253 Block 2). GDPR-compatible.
gates_enforced: []
gates_rationale: operational skill; WP Gate applicable only when creating a new WP,
  not for operational invocations
gates_required: []
interaction: one-shot
layer: L1
name: consent
routing:
  deterministic: true
  executor: script
  optimization_priority: 1
  script_path: scripts/iwe-consent.sh
status: active
triggers:
  phrases: []
  slash:
  - /consent
version: 1.0.0
---

# Consent — tracking consent management

> **Purpose:** the pilot manages their own consent for behavioral data processing (events: day_plan_*, wp_*, w_reflections, etc.). Without `opt_in=TRUE`, the `stage_evaluator` worker skips the pilot.
>
> **Architectural principle:** consent is stored in `learning.tracking_consent` (BC = `learning`, not persona). This is an aggregation permission, not personal data.

## When to use

Manage consent in learning.tracking_consent — opt-in / opt-out / status / revoke. Required for the stage_evaluator worker (WP-253 Block 2). GDPR-compatible.

## Arguments

- `status` (default) — show the current consent state
- `opt-in [scope1,scope2,...]` — grant consent (default scope: `stage_evaluation`)
- `opt-out` — revoke consent (opt_in=FALSE, history is preserved)
- `revoke` — delete the row entirely (GDPR right to erasure)

## Algorithm

### Step 1. Call the routing Script

```bash
bash "$IWE_SCRIPTS/route-task.sh" --skill consent --args "$ARGUMENTS"
```

The Script reads `IWE_OWNER_ORY_UUID` from the Environment. It writes via the `consent_writer` Role (Migration 113); fallback to `DATABASE_URL_LEARNING_DIRECT`.

### Step 2. Interpret the result

The Script reports success via stdout (exit 0) or an error via stderr (non-zero exit).

### Step 3. Return the response to the pilot

Print the Script's stdout to the pilot without modification.

## Available scopes

- `stage_evaluation` — Mastery stage Assessment via RCS indicators (FORM.089)
- `club_activity` — club activity tracking (WP-296, post/topic)

## Examples

```bash
/consent status
/consent opt-in                              # default: stage_evaluation
/consent opt-in stage_evaluation,club_activity
/consent opt-out                             # preserves data, disables processing
/consent revoke                              # deletes the row entirely
```

## Distinction: opt-out vs revoke

- **opt-out** — the pilot says "stop processing," but data is retained for Audit. The worker skips.
- **revoke** — the pilot exercises the right to erasure (GDPR). The row is deleted; a new opt-in is required to re-enable.

> **Note:** deletion of *production data* (events, reflections, transitions) is a separate process handled by `anonymization_worker`. This command only manages the record in `tracking_consent`.

## Dependencies

- Migration `113-consent-writer-grants.sql` (in the Infrastructure Repository's migrations directory)
- Privacy spec: `B7.3.6-stage-evaluation-privacy-spec.md` (Data-Governance) in your ecosystem-development Repository, if one exists

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
