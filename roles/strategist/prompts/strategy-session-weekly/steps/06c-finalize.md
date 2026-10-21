---
gate: user
step: 06c
title: 'Plan: Finalization'
---

# Step 06c: Plan — Finalization

## IPO

| | |
|---|---|
| **Input** | Budget + TOS (step 06b), candidate list |
| **Process** | Cross-check Work milestone↔Unmet Need, finalize the WeekPlan table |
| **Output** | Updated Work milestone table in WeekPlan |

## Instructions for Claude

1. **Cross-check Work milestone↔Unmet Need↔hypothesis** — for each selected Work milestone, state the source:
   - `R{N}` — monthly priority
   - `S-UMN-X` — unmet need
   - `carry` — carry-over
   - A Work milestone without a source is a signal: "why are we doing this?" — requires a decision now.
   - If the Work milestone tests or changes the main monthly hypothesis, add `H-NNN`.
     If no such link exists, explicitly state that the Work milestone supports the current norm rather than testing a strategic bet.

2. **Finalize the table:**
   Update the Work milestone table in WeekPlan with columns:
   `🚦 / # / Work milestone / Budget / Source / Status / Deadline / Repo`

3. **Question for the pilot:**
   > "Continue to irregular blocks / adjust / skip?"
