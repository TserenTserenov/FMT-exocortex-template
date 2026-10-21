---
gate: user
step: 05c
title: 'Caliber: Tracking'
---

# Step 05c: Caliber — Tracking

## IWE

| | |
|---|---|
| **Input** | Pilot decision from step 05b + current tracker |
| **Action** | Update Caliber-artifacts-tracker, record status |
| **Output** | Updated tracker, next reminder scheduled |

## Instructions for Claude

0. **Check consent** before writing — [../appendix/consent-check.md](../appendix/consent-check.md). If `denied`/`null` — do NOT write tracking/domain_event, proceed to self-declarations.

1. **Update the tracker** (`Lifework/Caliber-artifacts-tracker.md`):
   - Session date
   - V_scope, A_scope, D_scope, qualitative status (from 05a)
   - Recommendation status: `proposed` / `remind_monthly` / `dismissed` / `in-progress` / `done`
   - Next reminder (date or `null`)

2. **If the pilot decided to create a Work Product** — generate the WP file and include it in the pool (step 06a)

3. **Question for the pilot:**
   > "Continue to plan formation / adjust / skip?"
