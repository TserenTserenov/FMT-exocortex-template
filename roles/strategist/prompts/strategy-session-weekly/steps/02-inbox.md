---
gate: user
step: '02'
title: Inbox Triage
---

# Step 02: Inbox Triage

## IPO

| | |
|---|---|
| **Input** | `inbox/fleeting-notes.md` + recent files for the week + bot QA report |
| **Action** | Classify each item: add to plan / capture / delete / defer |
| **Output** | Inbox decisions, updated `fleeting-notes.md` |

## Instructions for Claude

1. **Read the sources:**
   - `inbox/fleeting-notes.md`
   - All files from `inbox/` (except .DS_Store and .docx)
   - Bot QA report: `DS-agent-workspace/scheduler/feedback-triage/` (most recent by date)

2. **For each item**, the pilot decides:
   - **Add to the week plan** → add to the candidate pool (step 06a)
   - **Capture to Pack** → record via `/ke` or write into the Pack
   - **Delete** → apply immediately
   - **Defer** → mark `🔄` with a review date

3. **Weekly Inbox Triage aggregation:**
   - Collect all `🔄` notes (ideas pending for more than 7 days)
   - Collect unaccepted suggestions from previous Note Reviews
   - Form 3 buckets: ✅ Archive / 📌 Proposals for the work plan / ❓ Pending decision

4. **Question for the pilot:**
   > "Continue to weekly energy plan / adjust / skip?"
