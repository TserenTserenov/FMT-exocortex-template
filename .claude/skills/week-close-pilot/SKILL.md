---
browser_safe: false
description: Run the pilot-facing Week Close protocol with progress review and carry-over.
layer: L3
name: week-close-pilot
routing:
  deterministic: false
  executor: sonnet
status: active
triggers:
  phrases: []
  slash:
  - /week-close-pilot
version: 1.0.0
---
## Guard

Check before execution:
```bash
IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
if [ ! -d "$IWE_ROOT/DS-personal-guide" ]; then
  echo "⚠️ DS-personal-guide not found in $IWE_ROOT. This Skill requires the DS-personal-guide repository."
  exit 0
fi
```


# Skill: /week-close-pilot — pilot personal guide Week Close

> **Role:** R27 Navigator (combined with pilot's internal reflection)  
> **Trigger:** user explicitly calls `/week-close-pilot`. (issue #409: the line promised an auto-call from a non-existent `week-close.sh` before the main Close — no such automation exists in the delivery; the call is manual only)
> **Output:** archived weekly, hypothesis for the new week, first daily of the day  
> **Time:** ~15–20 min  
> **Integrations:** Tailor (R27) for personal guide rendering, Memory (indicators + learning domain_events)

---

## Execution order

### Step 1: Identify weeks and pilot

1. Read the current date.
2. Determine:
   - **Current week:** W{N} (ISO week number)
   - **Previous week:** W{N-1}
   - **Pilot:** `${PILOT_NAME:-Pilot}` (`DS-personal-guide` repository on GitHub)
   - **Account ID:** from `DT_USER_ID` (env) or `dt_read_digital_twin` path `1_declarative/1_1_identity`

**Output:** Two week labels, ready for Step 2.

---

### Step 2: Read data for the previous week

Collect three data sources for W{N-1}:

**2a) Current weekly file:**
- Path: `DS-personal-guide/weekly/<YYYY-Www>.md` (current year, ISO week)
- This is the pilot's weekly for the previous week, recording Work Products, rhythm, and the opening hypothesis
- Read it in full (sections: Hypothesis, Work Products, Rhythm, Metrics, What happened)

**2b) Domain events for the past 7 days:**
- Source: Neon DB `learning.domain_event` (query: `WHERE occurred_at > now() - interval '7 days' ORDER BY occurred_at DESC`)
- Fields: `event_type, payload, occurred_at, account_id`
- Filter: `account_id = %s::uuid` (value from `DT_USER_ID` env)
- Result: list of events (typically 30–50 events per week — activity-hub records)
- Context formatting: summary **in 3–5 bullet points** (example: "5 Work Products opened, 2 Work Products closed, 15+ commits, WakaTime ~32h, Day Close 4 times")

**2c) Pilot RCS profile (baseline + confidence):**
- Source: Neon DB `indicators.calculated_profile`
- Fields: `W` (worldview), `M1` (self-development methods), `M2` (IWE/ORZ), `M3` (domain), `M4` (systems), `IT` (infrastructure), `A` (agency)
- Each slot: `value` (1–5) + `confidence` (0–100%)
- Result: compact table with delta from the previous week (if history is available)

**Output:** Three data blocks ready for Step 3.

---

### Step 3: Reflection dialog with the pilot

Run a **synchronous** dialog with the pilot. The goal is to **convert data into insights** (not just display metrics).

**Questions (choose 2–3, not all):**

1. **"What stands out to you in this week's numbers?"** (point to 1–2 metrics from Step 2b that deviate from the trend)
2. **"What got in the way beyond what was planned?"** (listen for weekly context — disruptions, urgent tasks, interface issues)
3. **"Hypothesis for the new week: what do you want to change?"** (based on the answers above + RCS bottleneck from Step 2c)

**Dialog format:**
- Post each question as a separate message (do not bundle multiple questions together)
- Wait for the pilot's response
- Based on the response, ask a follow-up or move to the next question
- **Do not ask anything after completion:** the algorithm continues automatically

**Output:** 2–3 insights, hypothesis for the new week.

---

### Step 4: Archive the previous weekly

Move the previous weekly from `weekly/` to `history/`:

1. Read `DS-personal-guide/weekly/<YYYY>-Www.md` (for W{N-1})
2. Prepend a **Results section** to the top of the file:
   ```markdown
   ## Results W{N-1}
   
   **Archived on:** YYYY-MM-DD  
   **Status:** closed  
   **Actual vs. hypothesis:** [from Step 3 dialog]  
   **Insights:** [brief conclusions from the dialog]  
   **Recommendation for W{N}:** [hypothesis]
   ```
3. Move the file: `weekly/<YYYY>-Www.md` → `history/<YYYY>-Www-results.md`
4. Commit to git: `git add history/`, `git commit -m "Archive W{N-1}: results + hypothesis for W{N}"`

**Output:** previous weekly archived, git committed.

---

### Step 5: Generate hypothesis for the new week

Based on insights from Step 3, create a **brief hypothesis** for W{N}:

Form (fill in the blanks based on the dialog):
- **Key question:** [What does the pilot want to focus on this week?]
- **Why now:** [From last week's context / RCS bottleneck]
- **Key result:** [One observable outcome by end of week]
- **Lever:** [Which of the 7 slots (W/M1–M4/IT/A) will be strengthened this week?]

Save as a variable for Step 6.

**Output:** hypothesis ready.

---

### Step 6: Write a new weekly for W{N}

Call `personal_write` (MCP tool) to create the file:

- **path:** `weekly/<YYYY>-Www.md` (for W{N})
- **content:** use the template from `monthly-theme-template.md` + hypothesis from Step 5
- **Sections:**
  - Hypothesis (4–6 lines from Step 5)
  - Work Products (2–3 specific Artifacts that should appear)
  - Rhythm (slots W/M1–M4, planned time)
  - Metrics (which metrics to track for the week)
  - Comment (what to check at the end of the week)

**Output:** new weekly written to the `DS-personal-guide` repository.

---

### Step 7: Write a daily for the first day of week W{N}

Call `personal_write` for the daily file:

- **path:** `daily/YYYY-MM-DD.md` (for Monday of W{N})
- **content:** scaffold with empty Day Open slots (calendar, day plan, first item from the weekly)

**Output:** daily created, pilot ready for Day Open on Monday.

---

### Step 8: Report

Send **one** summary message (no questions):

```
✅ W{N-1} closed
• Weekly archived with results
• Hypothesis for W{N}: [brief phrase, max 10 words]
• New weekly ready: <YYYY>-Www.md
• Daily for Monday {date} created

→ Ready for Day Open
```

**Output:** Skill complete.

---

## Safeguards

- ⛔ **Step 3 without dialog:** If the pilot does not respond to a question, move to the next question after 20s (do not wait indefinitely)
- ⛔ **Incomplete data at Step 2:** If the weekly is not found or the DB is unavailable — report this and exit the Skill (do not generate data from nothing)
- ⛔ **Double archiving:** Verify the weekly has not already been archived in a previous run (check git history)

---

## Connections

- **Entry point:** `protocol-close.md` (week-close step 1 calls this Skill as step 0)
- **Exit point:** results are ready for `/day-open` on Monday of W{N}
- **Tailor:** The Skill calls `personal_write` (built-in Integration), which runs `render-pilot-guides.py` in the background (F28.7)
- **Memory:** RCS profile is read via MCP (`get_tailor_context`), events from the learning DB via SQL
