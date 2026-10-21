---
gate: user
step: 05b
title: 'Caliber: Recommendation'
---

# Step 05b: Caliber — Recommendation

## IPO

| | |
|---|---|
| **Input** | Measurements from step 05a (V_scope, A_scope, D_scope, qualitative status, `ready_for_next_document`) |
| **Action** | Declare a growth recommendation, propose a Work milestone |
| **Output** | Pilot decision: create a Work milestone / remind_monthly / dismiss |

## Instructions for Claude

1. **Declare a recommendation for a document in the adjacent category above D_scope** (only if `ready_for_next_document: true` from step 05a). If `false` — formulate a recommendation for an action that reinforces the current pattern, not a document.

2. **Reminder logic** (read the tracker):
   - `proposed` session 1 → declare recommendation as a Work milestone
   - `proposed` session 2 → remind: "still in a growth zone — shall we create a Work milestone?"
   - `proposed` session 3 → ask for frequency: create / `remind_monthly` / `dismissed`
   - `remind_monthly` >4 weeks → remind: "one month ago: [X] — has anything changed?"
   - `dismissed` → do not remind (return only when new evidence appears in V_scope, A_scope, or D_scope)
   - `remind_monthly` >12 months → auto-`dismissed`

3. **No more than one up-level Artifact in focus**
   - If the tracker already contains a `proposed`/`in-progress` document in a category above D_scope — do NOT add a second one
   - Anti-imitation (`PD.FORM.091 §8` "Substituting vision with creation")

4. **Anti-pattern:** "You have S0 in NEP — let's write a Business Constitution." Correct approach: recommendations follow from readiness (D_scope + local gate), not directly from vision (V_scope).

5. **Question for the pilot:**
   > "Continue to caliber tracking / adjust / skip?"
