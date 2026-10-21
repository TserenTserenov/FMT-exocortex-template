---
gate: skip-if-empty
step: '07'
title: Irregular Blocks
---

# Step 07: Irregular Blocks

## IPO

| | |
|---|---|
| **Input** | `docs/Session Agenda.md`, session agenda, urgent topics from the pilot (step 00) |
| **Action** | Process irregular blocks: Retrospective, Architecture, document review, and others |
| **Output** | Results of irregular blocks are recorded |

## Instructions for Claude

1. **Read** `docs/Session Agenda.md`

2. **Identify applicable blocks:**
   - **Backlog.md scan (required):** read `docs/Backlog.md` → active entries. Hard-trigger fired? → raise as a discussion block. Soft-trigger due? → mention as a candidate. Neither fired → skip silently.
   - Retrospective (if ≥4 weeks have passed since the last one)
   - Architecture decision (if an open ArchGate exists)
   - Document review (if the pilot brought one)
   - Urgent topics from the pilot (if any were raised at step 00)

3. **If there are no blocks:**
   - State: "No irregular blocks — skipping." **STOP — wait for the next message. Do not proceed to the next step until the pilot responds.**

4. **If blocks exist:**
   - Work through each block with the pilot
   - Record the results

5. **Question for the pilot:**
   > "Continue to approval / adjust / skip?"
