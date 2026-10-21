---
gate: auto
step: jump
title: Jump Handler (return to step 3)
---

# Jump Handler

## Purpose

Called when the pilot decides during a session to return to step 03 (Dissatisfactions) after completing steps 04+.

## Invariant

If the pilot returns to step 03, steps 04 (strategic alignment) AND 05a/05b/05c (calibration) must be re-checked, because V_scope depends on Dissatisfactions.md.

## Algorithm

1. **Regenerate step 03** with the following warning:
   > "Returning to Dissatisfactions. Note: this resets steps 4 (strategic alignment) and 5a/5b/5c (calibration). Those steps must be completed again after updating Dissatisfactions."

2. **After step 03 is complete:**
   - Tell the pilot: "Dissatisfactions updated. Continue from step 04 (strategic alignment)?"
   - **STOP — wait for the pilot's response. Do not read the step 04 file until the next turn.**
   - After confirmation: do not skip 04 → 05a → 05b → 05c

3. **Soft gate B:**
   - If the pilot wants to skip 04/05 without re-checking → warn:
     > "Strategic alignment and calibration depend on Dissatisfactions. Skipping = risk of misalignment. Are you sure?"
   - If the pilot insists → record the decision in WeekPlan ("jump: skipped 04-05 per pilot request")

## Prohibition

Do NOT add this logic inside steps 04/05. The Jump Handler is the only place for this logic.
