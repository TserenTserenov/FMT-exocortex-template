---
description: How to capture, synchronize, and use memory about recurring agent errors
name: Процесс учёта косяков агента (Agent Fault Profile)
owner: user
schema_version: 1
status: draft
type: process
valid_from: 2026-05-15
---

# Agent Fault Tracking Process

> **Why:** An agent (Claude, Kimi, GPT) operates with a limited context window. After compaction or between Sessions, it "forgets" its errors — and repeats them. The user spends time making the same corrections over and over.
>
> **Solution:** Runtime memory for agent faults. The agent reads its own errors before a Session — like a pilot reading a checklist before takeoff.

---

## Principle

**Agent Fault Profile ≠ User Profile.**

| | User Profile | Agent Fault Profile |
|---|---|---|
| **What** | User preferences | Agent errors |
| **Who writes it** | User + agent (with consent) | User or the agent itself |
| **Who reads it** | Agent | Agent (self-directed!) |
| **Example** | "I dislike morning calls" | "I often replace the 24-point checklist with my own version from memory" |

---

## 5-Step Process

### Step 1. Detection (during the session)

**Who:** User or agent (self-correction).

**Triggers:**
- User says: "You skipped X", "This came up before", "Why again?"
- Agent detects a discrepancy itself (stale data, missed Protocol step)

**Capture immediately:** a short note in the chat or a mental note for Step 2.

---

### Step 2. Capture (at the end of the session or the same day)

**Who:** User (recommended) or agent (if self-correction).

**Where:** `exocortex/feedback_YYYY-MM-DD-topic.md`

**Format:**

```markdown
---
name: "Short pattern name"
description: "What the fault is and in which situations it appears"
type: feedback
valid_from: YYYY-MM-DD
originSessionId: <session id>
---

## Rule N: Title

> Clear instruction: what to do / what not to do.

**Log:**
- YYYY-MM-DD: context (WP-NNN, action, consequences).
- YYYY-MM-DD: recurrence, clarification.
```

**Example:**
```markdown
---
name: "Day Close — full checklist SKILL.md"
description: "Agent replaces the 24-point checklist with a simplified version from memory"
---

## Rule: Do not invent a checklist for R23

When verifying Day Close, pass the full checklist text from SKILL.md lines 156-179 to sub-agent Haiku R23 — do not use a self-generated version.

**Log:**
- 2026-04-24: I produced a 10-point checklist instead of 24. WakaTime, Memory Drift, and apply-captures were omitted.
```

---

### Step 3. Synchronization (weekly or on trigger)

**Who:** Agent (automatically or on command).

**Command:**
```bash
python3 scripts/sync_feedback_to_memory.py
```

**What happens:**
- Scans all `feedback_*.md` files in `exocortex/` and `memory/`
- Extracts rules and logs
- Calculates recurrence frequency (trust_score)
- Writes to SQLite: `exocortex/agent-fault-profile/iwe_memory.db`

**Idempotency:** re-running does not create duplicate records.

---

### Step 4. Reminder (before each session)

**Who:** Agent (automatically via protocol-open).

**Command:**
```bash
bash scripts/agent_fault_remind.sh close   # or open / work
```

**What happens:**
- SQLite returns the top-3 faults by trust_score
- 🔴 (≥0.8) = critical, frequently recurring
- 🟡 (0.65–0.79) = attention required
- 🟢 (<0.65) = note for awareness

**The agent embeds the reminders into the system prompt** — like a sticky note.

---

### Step 5. Retrospective (weekly, in Week Close)

**Who:** User + agent.

**Questions:**
1. Which faults recurred this week?
2. Are there new patterns not yet captured in feedback?
3. Which 🔴 faults dropped to 🟡 (agent has learned)?

**Action:**
- New faults → Step 2 (capture)
- Resolved faults → add `superseded_by` to the frontmatter of the feedback file

---

## Scripts

| Script | Purpose | Dependencies |
|--------|---------|-------------|
| `sync_feedback_to_memory.py` | Parses feedback → SQLite | Python 3, sqlite3 (stdlib) |
| `agent_fault_remind.py` | Returns top-N reminders | Python 3, sqlite3 (stdlib) |
| `agent_fault_remind.sh` | Convenience wrapper | bash |

**Zero external dependencies.** Runs on any Mac/Linux system with Python 3.

---

## Effectiveness Metrics

How to confirm the process is working:

| Metric | How to measure | Target |
|--------|---------------|--------|
| **Checklist completeness** | Compare 3 sessions with remind vs. 3 without | ≥30% fewer omissions with remind |
| **Time spent on corrections** | Measure how many minutes the user spends on "you did it again…" | <5 min/session |
| **Number of 🔴 faults** | `agent_fault_remind.py --stats` | Does not grow for 2 consecutive weeks |
| **Fault trust score** | Trend for a specific rule | Decreases after capture |

---

## Integration with Work Sessions

**Before protocol-open:**
```bash
bash scripts/agent_fault_remind.sh open
```
→ Insert output into the system prompt.

**After protocol-close:**
```bash
# If faults occurred — record them via checklist_memory.py
# or create a feedback file manually
```

**In Week Close:**
```bash
python3 scripts/sync_feedback_to_memory.py
bash scripts/agent_fault_remind.sh --stats
```
→ Review the trend in the strategy session.

---

## Rollout Checklist

- [ ] Create the first feedback file (capture a fault from the most recent session)
- [ ] Run `sync_feedback_to_memory.py` (verify that SQLite was created)
- [ ] Run `agent_fault_remind.sh work` (view the top-3)
- [ ] Run 1 session with reminders active (verify the agent sees them)
- [ ] After 5 days: smoke test (3 sessions with remind vs. 3 without)
- [ ] After 2 weeks: Retrospective + decision on whether to promote to Template

