---
gate: user
step: '04'
title: Strategic Alignment
---

# Step 04: Strategic Alignment

## IPO

| | |
|---|---|
| **Input** | `docs/Strategy.md`, hypothesis verdict package, MonthClose data (if the gate triggered in step 00), and `context/session-context-YYYY-MM-DD.md` from session-prep |
| **Action** | Align the strategy, its key monthly hypotheses, and current Work Products; update Strategy.md based on pilot decisions |
| **Output** | Monthly frame version in Strategy.md, key monthly hypotheses, and decisions on discrepancies |

## Instructions for Claude

1. **Read:**
   - `docs/Strategy.md` — yearly focuses, monthly results, System of Interest, and key monthly hypotheses; this is the sole owner of the monthly frame
   - The hypothesis verdict package from step 01
   - `context/session-context-YYYY-MM-DD.md` (if present — Digital Twin + Guide snapshot from session-prep; format and consent precondition — [../appendix/dt-guide-prep.md](../appendix/dt-guide-prep.md)). If consent is denied/null, the file is absent → degraded mode ([../appendix/consent-check.md](../appendix/consent-check.md)).
   - MonthClose summary (if step 00 triggered)

2. **If this is the first session of the month:**
   - Align the strategy focus with MonthClose data (multiplier, phase, R results, insights)
   - What was confirmed, what was rejected, what carried over

3. **Discuss with the pilot:**
   - Discrepancies between the strategy and current Work Products
   - Adjustments to Strategy.md
   - 1–3 key hypotheses for the current month: keep, replace, or drop; each must have an `H-NNN` identifier, a verifiable criterion, and a link to an R-result

4. **R→P linkage (if Projects.md exists):**
   - Each monthly R-result must reference a P-project
   - Check the `P` column (P1–P6)
   - Discrepancies → revisit the linkage

5. **Question for the pilot:**
   > "Continue to the caliber lens / adjust / skip?"
