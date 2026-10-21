Execute the "Strategy Session Preparation" scenario for the Strategist role (R1).


## Context

- **HUB (personal plans):** {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/current/
- **Strategy documents:** {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/docs/ (ALL files: Strategy.md, Dissatisfactions.md, Session Agenda.md)
- **Inbox:** {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/ ([fleeting-notes.md](https://github.com/{{GITHUB_USER}}/{{GOVERNANCE_REPO}}/blob/main/inbox/fleeting-notes.md) + recent files for the week)
- **Active Work Products:** `bash {{WORKSPACE_DIR}}/scripts/active-wp-sweep.sh` (aggregator across `{{GOVERNANCE_REPO}}/inbox/WP-*.md` + git activity 7d — ~15s, not a manual scan)
- **Strategic maps:** {{WORKSPACE_DIR}}/*/MAPSTRATEGIC.md (if present in the repo)
- **MEMORY:** ~/.claude/projects/{{CLAUDE_PROJECT_SLUG}}/memory/MEMORY.md

## File naming in current/

```
{{GOVERNANCE_REPO}}/
├── current/
│   ├── WeekPlan W{N} YYYY-MM-DD.md    # week plan (Mon date)
│   └── DayPlan YYYY-MM-DD.md          # day plan
├── archive/                            # old files
├── docs/                               # Strategy.md, Dissatisfactions.md, Session Agenda.md
├── inbox/                              # fleeting-notes.md + incoming
```

`current/` contains only active files. Old files are moved to `{{GOVERNANCE_REPO}}/archive/`.

## Precondition

> **Week results are already recorded** by the week-review scenario (Mon 00:00, 4 hours before session-prep) in the "Results W{N-1}" section of the current WeekPlan.
> Session preparation does NOT collect commits itself — it reads the results section from WeekPlan.

## Process

> Output — a WeekPlan draft with the session agenda in `current/`.
> Agenda structure follows the `docs/Session Agenda.md` template.

#### 1. Read last week's results (→ "Last Week Review" block)

- Find the "Results W{N-1}" section in the current `WeekPlan W*.md` in `{{GOVERNANCE_REPO}}/current/`
- Extract: completion rate, carry-over, insights

> If the results section is not found — report an error and collect commits independently (fallback).

#### 2. Process inbox (→ "Inbox and Fleeting Notes Review" block)

- Read `{{GOVERNANCE_REPO}}/inbox/fleeting-notes.md`
- Read ALL files from `{{GOVERNANCE_REPO}}/inbox/` (except .DS_Store and .docx)
- Read the bot QA report: `DS-agent-workspace/scheduler/feedback-triage/` (latest by date) — **structured report** from feedback_triage DB: remarks (✏️) first, urgent (high/critical) second, problem clusters third. Auto-triage has already been performed by the bot → Session-Prep checks clusters (≥3 = **urgent** → WP-debt) and marks them resolved
- For each note/file, determine: → into the week plan? → capture into a Pack? → onto the agenda for discussion? → delete?
- **Weekly Inbox Triage aggregation:**
  > This is NOT a duplicate of the note review (Note-Review runs only on demand). Note-Review classifies notes and writes proposals into target documents. Session-Prep aggregates the week's results from those documents and adds unsatisfied questions.
  1. Collect ALL remaining `🔄` notes (ideas pending for >7 days)
  2. Collect all unaccepted proposals from previous Note-Reviews (if still in WeekPlan)
  3. Form the `📋 Inbox Triage (weekly)` block with 3 buckets:
     - ✅ Archive: notes whose tasks were closed during the week (based on results in WeekPlan)
     - 📌 Proposals for Work Products: from task-notes + from `🔄` items that gained scope
     - ❓ Needs decision: `🔄` items without scope, unaccepted proposals, contested items
  4. Include this block in WeekPlan (agenda section)
- **WP Context Files** (`WP-*.md`): process separately:
  - Check: is the Work Product still active? Compare `status` in the WP file frontmatter with MEMORY.md
  - If frontmatter and MEMORY.md differ — **trust MEMORY.md** (source of truth for status)
  - If the Work Product is done/merged/drop → it will be archived in step 8.5 (Session-Prep is the sole owner of this responsibility)
  - If the Work Product is active — account for "Current state" when forming WeekPlan (blockers, next steps)
- Form an agenda block with recommendations for each inbox item

#### 3. Check dissatisfactions (→ "Dissatisfactions" block)

- Read `{{GOVERNANCE_REPO}}/docs/Dissatisfactions.md`
- Check: which operational dissatisfactions are resolved (can be closed)?
- Check: are there strategic dissatisfactions without a linked Work Product this week?
- Form an agenda block with proposals

#### 4. Strategy alignment + MAPSTRATEGIC aggregation (→ "Strategic Alignment" block)

- Read `{{GOVERNANCE_REPO}}/docs/Strategy.md` — annual focus areas, Q1 goals, monthly priorities
- Read `{{WORKSPACE_DIR}}/*/MAPSTRATEGIC.md` (if the file is present in the repo)
- **Aggregate** phases from MAPSTRATEGIC.md → update the "Current phases (MAPSTRATEGIC)" section in Strategy.md
- Update "Monthly priorities" — statuses based on results in WeekPlan
- Check: do current Work Products align with the strategic direction?
- Flag discrepancies (Work Products not linked to strategy, or strategy without Work Products)

#### 5. Aggregate active Work Products

> Source: `bash {{WORKSPACE_DIR}}/scripts/active-wp-sweep.sh`
>
> The script scans all `inbox/WP-*.md`, cross-checks git activity for 7 days,
> and returns a markdown table of active Work Products with statuses and budgets in seconds —
> do not manually read `WORKPLAN.md` in each repo (those files barely exist anywhere,
> and `{{GOVERNANCE_REPO}}`/CLAUDE.md itself labels them a deprecated anti-pattern;
> manual scanning stretched session-prep to 30+ minutes instead of seconds, WP-484 20.07).

- Run `active-wp-sweep.sh` and use the output as input for forming the plan
- Flag discrepancies with the HUB plan for discussion at the session

#### 6. Check irregular blocks (Session Agenda)

- Read `{{GOVERNANCE_REPO}}/docs/Session Agenda.md`
- Determine: which irregular blocks apply this week? (retrospective, architecture, document review, etc.)
- If any — add to the agenda
- **Month Close (issue #616):** use the "First Mon of month: yes/no" line from the system context at the start of this prompt — do not infer this yourself; the last Mon of a month and the first Mon of the next are easy to confuse without an actual calendar check.

#### 6.5. Weekly content plan (→ "Content Plan" section in WeekPlan)

- Execute the process from `prompts/content-plan.md`
- Collect events, results, fleeting notes, ready drafts → 5–10 posts
- Include the output in the WeekPlan draft as a `## Content Plan W{N}` section

#### 7. Form the WeekPlan draft

- Select Work Products from monthly priorities + active-wp-sweep + carry-over + inbox
- **No standalone tasks.** Everything = Work Product. Personal tasks (taxes, invoices, documents) also receive a Work Product number and WP context file. Without a number, a task is lost during carry-over.
- **Status update:** For each Work Product in the table, check `inbox/WP-{N}-*.md` (WP context file). If present — take status and description from it (source of truth for progress). WP context file > carry-over.
- Form a table with budget
- Form the strategy session agenda (all blocks from steps 1–6)
- Formulate questions for discussion with the user

#### 8. Save the draft (REQUIRED)

1. Move the previous `WeekPlan W*.md` from `current/` to `archive/week-plans/`
2. Move the previous `DayPlan *.md` from `current/` to `archive/day-plans/` (if present)
3. Move the previous `WeekReport W*.md` from `current/` to `archive/week-reports/` (issue #596: created by week-review.md, Mon 00:00, before this step — must already be in `current/` by the time session-prep runs)
4. Move the previous `SchedulerReport *.md` from `current/` to `archive/scheduler-reports/` (if present and not current)
5. **Archive WP context files (safety net — Close already archives done files):**
   - For each `inbox/WP-*.md`, compare status with MEMORY.md (source of truth)
   - `status: done` / `merged` / `drop` still in inbox? → move to `archive/wp-contexts/` (Close missed it)
   - If WP file frontmatter does not match MEMORY.md → update frontmatter before moving
6. **Full inbox/ cleanup (weekly, sole owner — Session-Prep):**
   - `extraction-reports/` — respect `status` in frontmatter (invariant: "a capture does not disappear without a decision"):
     - `status ∈ {applied, rejected, no-pending}` and older than 7 days → **archive** to `archive/extraction-reports/` (same convention and cleanup owner as captures below; do NOT delete — the report is the second half of the same audit trail "capture → decision", issue #507)
     - `status ∈ {pending-review, partially-applied, deferred}` → **do not touch** (awaiting processing via `/apply-captures`)
     - No frontmatter or no `status` field → leave as-is (treat as pending-review)
   - `captures.md` — entries with `[processed ...]` older than 14 days → **archive** to `archive/captures/captures-{period}.md` (do NOT delete — this is the audit trail of the Pack entry). Entries with `[rejected ...]` older than 14 days → archive to the same location.
   - Entries **without** a `[processed]` or `[rejected]` tag → leave as-is (not yet processed by Extractor)
   - Other files (not fleeting-notes.md, not captures.md, not active WP-*) → "Still needed?" No → delete or move to `archive/notes/`
7. Create `current/WeekPlan W{N} YYYY-MM-DD.md` (Mon of the current week)
8. Commit to {{GOVERNANCE_REPO}}

**WeekPlan format:**

```markdown
---
type: week-plan
week: W{N}
date_start: YYYY-MM-DD
date_end: YYYY-MM-DD
status: draft
agent: Strategist
---

# WeekPlan W{N}: DD Mon — DD Mon YYYY

---

## Last Week Results W{N-1}

> Source: "Results W{N-1}" section from the previous WeekPlan

**Completion rate:** X/Y Work Products (N%)

**Carry-over:**
- #N — what remains

**Key insights:**
- ...

> Full results: see "Results W{N-1}" section in the previous WeekPlan (archive)

---

## Strategy Session Agenda

### Standard items
- [ ] Last week review (see above)
- [ ] 📋 Inbox Triage (weekly) — see below
- [ ] Dissatisfactions: [close X, discuss Y]
- [ ] Strategic alignment: [discrepancies, phases]

---

## 📋 Inbox Triage (weekly)

> Weekly note aggregation. Source: fleeting-notes.md + unconsumed triage files.

### ✅ Archive (resolved during the week)
- ~~"note text"~~ → closed in Work Product #N / commit abc

### 📌 Work Product proposals
- "note text" → propose Work Product for the week (budget ~Xh)
- "note text 🔄" → scope clarified: [specific action]

### ❓ Needs decision
- "note text 🔄 (>7 days)" — idea requiring discussion at the session
- "unaccepted proposal from last week" — repeat or delete?

### Irregular blocks (if applicable)
- [ ] ...

### Discussion questions
1. ...

---

## Monthly priorities
[updated priorities]

---

## Week plan W{N}

| # | Work Product | Budget | Status | Deadline | Repo |
|---|-----|--------|--------|---------|------|
| ... | ... | ... | pending | ... | ... |

**Week budget:** ~Nh

---

## Monday plan

| # | Work Product | Budget | Priority |
|---|-----|--------|-----------|
| — | **Strategy session: approve plan** | 1h | required |
| ... | ... | ... | ... |

---

*Created: YYYY-MM-DD (Session preparation, draft)*
```

**Output:** WeekPlan draft (`status: draft`) with the session agenda in `current/`.

> Next step: strategy session with the user → dispatcher `.claude/skills/strategy-session/SKILL.md` (`prompts/strategy-session.md` — deprecated, pre-split into weekly/monthly, do not use).

---

## Post-session sync (performed by Strategist after WeekPlan approval)

> **Rule:** After the strategy session, update Strategy.md and the statuses of all referenced WP context files. This ensures data does not go stale between sessions.

1. **Strategy.md** — update "Monthly priorities" (statuses, budgets, new priorities)
2. **inbox/WP-NNN.md** — for each Work Product mentioned in WeekPlan:
   - Update `status:` (done/in_progress/pending)
   - Add new Work Products (if any emerged during the session)
3. **MEMORY.md** — sync the "Work Products for the current week" table
4. Commit all changes
