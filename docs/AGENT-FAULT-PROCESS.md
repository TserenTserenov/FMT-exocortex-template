---
description: How to record, synchronize, and use memory of recurring agent faults
name: Agent Fault Accounting Process (Agent Fault Profile)
owner: user
schema_version: 1
status: draft
type: process
valid_from: 2026-05-15
---

# Agent Fault Accounting Process

> **Why:** An agent (Claude, Kimi, GPT) operates within a limited context. After compaction or between Sessions, it "forgets" its mistakes — and repeats them. The user spends time on the same corrections repeatedly.
>
> **Solution:** Runtime memory of agent faults. The agent reads its own fault history before a Session — the way a pilot reads a checklist before takeoff.

---

## Principle

**Agent Fault Profile ≠ User Profile.**

| | User Profile | Agent Fault Profile |
|---|---|---|
| **What** | User preferences | Agent faults |
| **Who writes** | User + agent (with consent) | User or the agent itself |
| **Who reads** | Agent | Agent (for itself!) |
| **Example** | "I do not like morning calls" | "I often replace the 24-point checklist with my own from memory" |

---

## 5-Step Process

### Step 1. Detection (during the Session)

**Who:** User or agent (self-correction).

**Triggers:**
- The user says: "You missed X", "We already covered this", "Why again?"
- The agent itself notices a discrepancy (stale data, skipped Protocol step)

**Record immediately:** a short note in the chat or a mental note for Step 2.

---

### Step 2. Recording (at the end of the Session or the same day)

**Who:** User (recommended) or agent (if self-correction).

**Direct recording:** the unified platform CLI requires the fault owner to be named explicitly; the model does not infer it from a self-report:

```bash
python3 scripts/agent-fault/iwe_checklist_memory.py record \
  --severity major \
  --fault agent skipped the required checklist \
  --source-citation AGENTS.md:exact-rule-citation \
  --subject-kind runtime \
  --subject-id claude-code
```

**Batch recording:** `exocortex/feedback_YYYY-MM-DD-topic.md`, then an explicit import in Step 3.

**Format:**

```markdown
---
name: "Short pattern name"
description: "What the fault is and in which situations it occurs"
type: feedback
valid_from: YYYY-MM-DD
originSessionId: <session id>
---

## Rule N: Name

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

When verifying Day Close, pass the full checklist text from SKILL.md lines 156-179 to sub-agent Haiku R23 — do not use a custom version.

**Log:**
- 2026-04-24: I composed a 10-point checklist instead of 24. WakaTime, Memory Drift, and apply-captures were omitted.
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
- Counts recurrence frequency (trust_score)
- Passes records to the unified CLI as `system:feedback-import`
- Writes only to the private SQLite database: `exocortex/agent-fault-profile/iwe_memory.db`

**Idempotency:** running the command again does not create duplicate records.

---

### Step 4. Reminder (before each Session)

**Who:** Agent (automatically via protocol-open).

**Command:**
```bash
export IWE_FAULT_SUBJECT_KIND=runtime
export IWE_FAULT_SUBJECT_ID=claude-code
bash scripts/agent_fault_remind.sh close   # or open / work
```

**What happens:**
- SQLite returns the top-3 active faults for the specified subject only
- 🔴 (≥0.8) = critical, recurring frequently
- 🟡 (0.65–0.79) = attention required
- 🟢 (<0.65) = note for awareness

**The agent embeds the reminders in the system prompt** — like a sticky note.

---

### Step 5. Retrospective (weekly, in Week Close)

**Who:** User + agent.

**Questions:**
1. Which faults recurred this week?
2. Are there new patterns not yet captured in feedback?
3. Which 🔴 faults dropped to 🟡 (agent has learned)?

**Action:**
- New faults → Step 2 (recording)
- Resolved faults → add `superseded_by` to the frontmatter of the feedback file

---

## Scripts

| Script | Purpose | Dependencies |
|--------|---------|-------------|
| `scripts/agent-fault/iwe_checklist_memory.py` | Sole SQLite writer/reader | Python 3, sqlite3 (stdlib) |
| `sync_feedback_to_memory.py` | Thin wrapper for explicit feedback-import | Python 3 |
| `agent_fault_remind.py` | Compatible wrapper for remind/`--stats` | Python 3 |
| `agent_fault_remind.sh` | Compatible shell wrapper | bash |

**Zero external dependencies.** Works on any Mac/Linux system with Python 3.

The Profile and SQLite database receive `0700`/`0600` permissions; a local `.gitignore` protects all runtime files. If the database is already tracked by Git, the CLI blocks access and displays a manual `git rm --cached` command — it does not modify the index itself. A normal write operation does not create a Markdown Audit. A full snapshot is created only explicitly:

```bash
python3 scripts/agent-fault/iwe_checklist_memory.py export
```

A threshold-filtered selection of active faults can be retrieved without creating a missing database:

```bash
python3 scripts/agent-fault/iwe_checklist_memory.py escalation-check \
  --threshold 3 \
  --subject-kind runtime \
  --subject-id claude-code
```

Local Python consumers must not import the legacy `DB_PATH` or `init_db`. The public function `read_faults(...)` of the canonical Module reads only the exact subject, returns immutable records, and does not create a Profile.

A new installation receives the four legacy script names as thin wrappers over the canonical CLI. On update, they are replaced only as a single package: absent files, already-matching files, or byte-for-byte known platform versions are all acceptable. An unknown file, a symbolic link, or a remaining import of the old Module halts Migration before any write and displays the manual verification steps.

---

## Effectiveness Metrics

How to determine that the process is working:

| Metric | How to measure | Target |
|--------|---------------|--------|
| **Checklist completeness** | Compare 3 Sessions with remind vs 3 without | With remind: ≥30% fewer omissions |
| **Time spent on corrections** | Measure how many minutes the user spends on "you did it again..." | <5 min/Session |
| **Number of 🔴 faults** | `agent_fault_remind.py --stats` | Does not grow for 2 consecutive weeks |
| **Fault trust score** | Trend for a specific rule | Decreases after recording |

---

## Integration with Work Sessions

**Before protocol-open:**
```bash
export IWE_FAULT_SUBJECT_KIND=runtime
export IWE_FAULT_SUBJECT_ID=claude-code
bash scripts/agent_fault_remind.sh open
```
→ Insert output into the system prompt.

**After protocol-close:**
```bash
# If faults occurred — call /agent-fault with an explicit subject
# or manually create a feedback file for the next explicit import
```

**In Week Close:**
```bash
python3 scripts/sync_feedback_to_memory.py
IWE_FAULT_SUBJECT_KIND=runtime \
IWE_FAULT_SUBJECT_ID=claude-code \
  bash scripts/agent_fault_remind.sh --stats
```
→ Review trends in the strategy Session.

---

## Implementation Checklist

- [ ] Create the first feedback file (record a fault from the last Session)
- [ ] Run `sync_feedback_to_memory.py` (verify that SQLite was created)
- [ ] Set `IWE_FAULT_SUBJECT_KIND`/`IWE_FAULT_SUBJECT_ID`
- [ ] Run `agent_fault_remind.sh work` (see the top-3 faults for your subject)
- [ ] Run 1 Session with reminders (verify that the agent sees them)
- [ ] After 5 days: smoke-test (3 Sessions with remind vs 3 without)
- [ ] After 2 weeks: Retrospective + decision on delivering to the Template

