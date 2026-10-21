---
gate: user
step: '03'
title: Dissatisfactions (NEP)
---

# Step 03: Dissatisfactions (NEP)

## IPO

| | |
|---|---|
| **Input** | `docs/Dissatisfactions.md` + new signals from inbox (step 02) and irregular blocks (step 07) |
| **Action** | Close resolved NEPs, discuss new ones, update Dissatisfactions.md |
| **Output** | Updated Dissatisfactions.md, decisions on new NEPs |

## Instructions for Claude

1. **Read** `docs/Dissatisfactions.md`

   **File is missing or empty** → this is an empty input (`extensions/strategy-cycle/SPEC.md` §5), not a build error: skip steps 2–3, and explicitly note in the output "NEP block is empty (file not found)" — distinguish this case from "file exists but data was not collected" (for example, the pilot did not maintain the registry that week), which must be noted separately as "NEP block not updated", not silently skipped.

2. **Check:**
   - Which operational NEPs are resolved (can be closed)?
   - Are there strategic NEPs with no link to a Work Product this week?
   - New NEPs from inbox / irregular blocks
   - **Stale entries with no movement for 8+ weeks** (by the last-modified date of the entry in `Dissatisfactions.md`) — collect as a separate list, do not skip silently

3. **Discuss with the pilot:**
   - Close resolved NEPs
   - Formulate new ones
   - Verify links to Work Products
   - **For each stale entry — a forced choice from the pilot:** close / reformulate / keep with an explicit review trigger (not "leave as-is" without a date or event — that is just re-aging the entry)

4. **Update** `Dissatisfactions.md` according to the pilot's decisions

5. **Question for the pilot:**
   > "Continue to strategic alignment / adjust / skip?"
