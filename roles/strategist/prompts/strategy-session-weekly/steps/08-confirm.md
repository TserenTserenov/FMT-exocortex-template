---
gate: user
step: 08
title: Confirmation and Synchronization
---

# Step 08: Confirmation and Synchronization

## IPO

| | |
|---|---|
| **Input** | WeekPlan draft, updated Strategy.md, Dissatisfactions.md |
| **Process** | Pilot confirms the plan → synchronize all Artifacts |
| **Output** | Confirmed WeekPlan (`status: confirmed`), updated MEMORY, MAPSTRATEGIC, cleared inbox |

## Instructions for Claude

1. **Confirmation:**
   - Pilot confirms the plan
   - **Verify WeekPlan before confirmation (REQUIRED, WP-484 Phase47).**
     The default path is manual (standard for a clean install): verify that
     every Work Product in the WeekPlan has a TVS mode color assigned, a weekly
     TOC is formulated, and an explicit "not taking" list is present. If anything
     is missing, work through it with the pilot, fix it, and re-verify.
     The optional accelerator applies only when installed: if
     `[ -f "$IWE_SCRIPTS/strategy-session-checks-runner.sh" ]`,
     run `bash "$IWE_SCRIPTS/strategy-session-checks-runner.sh" "<path to WeekPlan>"`;
     a red result blocks the transition to `status: confirmed`. The Script is not
     included in the template distribution (issue #409) — its absence is not a
     blocker: notify the pilot that "automated WeekPlan verification is not
     available on this install, proceeding with manual check" and continue
     with the manual path.
   - Change `status: draft` → `status: confirmed` in the WeekPlan

2. **Synchronization (REQUIRED):**
   - **MEMORY.md** → section "Work Products of the current week" via `bash "$IWE_SCRIPTS/memory-active-wp-update.sh"`
   - **Strategy.md** — if work has been added that is not reflected in the strategy
   - **MAPSTRATEGIC.md** — if an item from MAPSTRATEGIC is taken into work → `in-progress`; if a Phase is complete → `done`
   - **Clear** from `fleeting-notes.md` any notes for which the pilot has already made a decision (notes marked `✅proposed` without a decision must not be touched; see the "Note Cleanup" procedure in `note-review.md`), and clear processed files from `inbox/`

3. **Commit:**
   - Commit changes to the governance repository and all affected repositories

4. **Result:**
   - Confirmed WeekPlan W{N} (`status: confirmed`)
   - Updated Strategy.md, MEMORY.md, MAPSTRATEGIC.md
   - Cleared inbox

---

Session complete.
