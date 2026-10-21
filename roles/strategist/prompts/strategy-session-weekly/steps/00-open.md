---
gate: skip-if-empty
step: '00'
title: Session Opening
---

# Step 00: Session Opening

## IPO

| | |
|---|---|
| **Input** | WeekPlan draft (`status: draft`) created by session-prep. Flag: "first session of the month?" |
| **Process** | Check MonthClose gate. Display agenda summary. Ask: "Follow the agenda or is there something urgent?" |
| **Output** | Pilot confirms agenda or requests urgent topic → reorder steps accordingly |

## Instructions for Claude

1. **MonthClose gate (monthly dispatcher only):**
   - If today is ≤ the 7th of the month AND `sessions/` contains no Strategy Session record for the current month:
     - Find the latest `archive/MonthClose YYYY-MM.md` (previous month)
     - Read: multiplier, phase, caliber, project revision, insights, R-questionnaire, carry-over
     - Read `archive/multiplier-trend.md` (if present)
     - Save the MonthClose summary for Step 04 (strategic alignment)
   - If this is not the first session of the month → skip and report: "MonthClose gate: skip"

2. **Display summary:**
   - Find `WeekPlan W*.md` with `status: draft` in `current/`
   - Brief overview: agenda, key questions, carry-over
   - If MonthClose gate triggered — add key figures (multiplier, phase)

3. **Question for the pilot:**
   > "Shall we start with the agenda, or are there urgent topics?"
   - Urgent topic → record the topic as an unscheduled block (Step 07). **STOP — wait for the next message.**
   - Follow the agenda → say "Starting Step 01". **STOP — wait for the pilot's next message. Do not read the Step 01 file until the next Work turn.**
