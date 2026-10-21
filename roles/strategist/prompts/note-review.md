Execute the "Note Review" scenario for the Strategist role (R1).


## Context

- **Notes:** {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/[fleeting-notes.md](https://github.com/{{GITHUB_USER}}/{{GOVERNANCE_REPO}}/blob/main/inbox/fleeting-notes.md)
- **DIS:** {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/docs/Dissatisfactions.md
- **Strategy:** {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/docs/Strategy.md
- **Week Plan:** {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/current/WeekPlan W*.md
- **Extractor Inbox:** {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/captures.md
- **MEMORY:** ~/.claude/projects/{{CLAUDE_PROJECT_SLUG}}/memory/MEMORY.md

## Precondition

> ⛔ **Automatic runs are disabled (template owner decision, July 2026).** The Synchronizer scheduler (`scheduler.sh`) no longer calls this scenario. Notes are reviewed manually. In a live session with the pilot (for example, from the "Note Review" section of Day Open), all steps execute. Running from the terminal (`strategist.sh note-review`) runs without chat and only applies `✅proposed` markers and writes proposals (steps 1–9 and 11); step 10 (archive) and cleanup run only in a live session, on the pilot's explicit command.
> Notes have accumulated over one day (or several days).
> If there are no new notes (bold, without the `✅proposed` marker and without `🔄`) — report this and stop.

## Principles

1. **Note Review does NOT make decisions** — it only classifies and proposes
2. **Proposals are written to the END of target documents** — the Strategist (Day-Plan, 4:00) reads them and takes them into account
3. **Human approval is required** — proposals are recommendations, not actions
4. **Knowledge → Extractor inbox** — Note Review does not write to a Pack directly
5. **Each review is a decision record:** a note leaves `fleeting-notes.md` only together with a record in `archive/notes/Notes-Archive.md` of the form "**Review:** YYYY-MM-DD — **Pilot decision:** …". An archive record without a pilot decision is not permitted (template owner decision, July 2026)

## Note Markers

| Appearance in file | Meaning | On cleanup |
|---|---|---|
| `**Title**` | New, not yet processed | Stays |
| `**Title** 🔄` | Unclear — revisit during strategy work | Stays |
| `**Title** ✅proposed` | Classified, proposal recorded — awaiting pilot decision | Stays until the pilot closes it |
| `Title` (plain, no bold) | Bold removed manually (or legacy note format) — treated as closed | → Notes-Archive.md (only via the safety script, record labeled "auto-cleanup") |
| `~~Title~~` | Closed by the pilot manually (including noise) | → Notes-Archive.md (on review, on pilot command) |

## Process

#### 1. Read the notes

- Open `{{GOVERNANCE_REPO}}/inbox/fleeting-notes.md`
- Identify **bold notes without `✅proposed` and without `🔄`** (`**text**`) — these are new notes to process
- Notes with `✅proposed` — already processed; do not reclassify; leave as-is
- Notes with `🔄` — also review, but do not reprocess (unless there is new context)
- If there are no new notes → report "No new notes" and stop

#### 2. Read the context

- `{{GOVERNANCE_REPO}}/docs/Dissatisfactions.md` — current DIS entries (S* strategic, O* operational)
- `{{GOVERNANCE_REPO}}/current/WeekPlan W*.md` — work items and week priorities
- `{{GOVERNANCE_REPO}}/docs/Strategy.md` — yearly focuses, monthly priorities
- MEMORY.md — work item statuses
- Bot QA report: `DS-agent-workspace/scheduler/feedback-triage/` (latest by date) — **structured report** from the feedback_triage DB (auto-classification by bot). Notes (✏️) and urgent items (high/critical) appear at the top of the file. Real-time alerts have already been sent by the bot → Note Review only checks clusters (≥3 in one cluster → flag)

#### 3. Classify each note

> Eight categories (PD.FORM.083). One note = one category (primary).

| # | Category | Criterion | Where Note Review writes |
|---|---|---|---|
| 1 | **DIS** | Dissatisfaction, discomfort, "want to change", emotion | → proposal appended to Dissatisfactions.md |
| 2 | **Task** | Specific action, "do tomorrow", "need to check", bug/feature request for any tool | → proposal appended to WeekPlan / DayPlan |
| 3 | **Hypothesis** | A prediction about the world with a verifiable verdict: "if X, then Y", "it should be true that Z". There is an answer to "what could falsify this?" — otherwise it is a Task | → draft of 4 fields (statement, confidence %, falsification criterion, review date — PD.FORM.083 §3) appended to `current/hypotheses-log.md`. The pilot confirms/edits at the review — Note Review does not write the final version itself |
| 4 | **Domain Knowledge** | Pattern, Distinction, Method, rule — applicable beyond a specific implementation | → candidate in DayPlan "Note Review" (with a proposal to pass to the Extractor). Write to `captures.md` ONLY if the note explicitly says "to Extractor" / "to captures" / "to Pack" |
| 5 | **Implementation Knowledge** | How a specific system works, an architectural choice | → Task: document it (WeekPlan) |
| 6 | **Draft** | Seed for a post/article, reflection with concepts | → recommendation appended to WeekPlan (section "Note Review Proposals"). The file is NOT created — only after approval |
| 7 | **Personal Data** | Contact, phone, email, token, account, credentials | → {{GOVERNANCE_REPO}}/personal/*.md |
| 8 | **Noise** | Test entry, duplicate, accidental entry, link without context, already done / resolved | → mark `✅proposed (noise)` (only the pilot strikes through the note) |

**Classification rules:**
- If DIS + Task → prioritize DIS (emotion takes precedence over action)
- **Bot note** → absorbed into Task (category 2). No separate category
- **Idea 🔄** → absorbed into Task ("think about X") or Noise. The 🔄 marker is no longer used
- **Hypothesis vs. Task:** "think about X" without a falsification criterion → Task, not Hypothesis. A predictive statement with an explicit "if… then…" or a quantitative expectation and a review date → Hypothesis
- **Draft vs. Domain Knowledge:** Knowledge = fact/rule for Pack. Draft = seed for a post. One note can produce both — record in BOTH places
- Links without context → Noise
- **Urgent tasks:** contains a deadline ("today", "tomorrow", a date) → Task with a deadline marker. If deadline = tomorrow → DayPlan. If deadline = this week → WeekPlan
- **Personal Data → personal/:** contact → `personal/contacts.md`, account/URL → `personal/accounts.md`, token/password → `personal/secrets.md`, other → `personal/reference.md`

**Relevance check (required before classification):**
- Cross-reference the note against today's commits (`git log --since="00:00" --all --oneline` across all {{WORKSPACE_DIR}}/ repos) and the current WeekPlan
- If the task from the note **is already done** (there is a commit or the work item is done) → Noise (`✅proposed (noise)`); do not pull into the plan
- If the problem from the note **is already resolved** → Noise
- If the note references a situation that **has changed** during the day → evaluate with the updated context in mind
- The user may have written the note in the morning but completed everything by evening — do not generate unnecessary proposals
- **Cross-reference with work items (for ALL categories):** Before classifying any note — check MEMORY.md: does the intent of the note match an existing work item? Check not only the work item name but also the result descriptions (✅ lines). Example: a note "Create a role description standard" is covered by work item #N (DP.D.033 Role-Centric Architecture) — even if the work item is in_progress, the specific result is done. If covered → Noise (`✅proposed (noise)`, state the reason "Implemented: work item #N, artifact" in parentheses in the marker and in the step 9 report). Rule: **a note whose intent is already implemented = Noise, regardless of the work item status**
- **Personal tasks:** Notes with a specific action and deadline (including personal, household, family tasks) → category **Task**. Record in WeekPlan with a deadline. Do NOT discard as "irrelevant". The weekly plan includes ALL tasks: work + personal. Personal task numbering: P1, P2, …

#### 4. Mark notes in fleeting-notes.md

> **Template owner decision (July 2026):** classification is a proposal, not a decision. The note stays visible to the pilot every day until the pilot closes it — removing bold and moving to the archive are not permitted automatically, for any category (including Noise and Personal Data).

Update each note based on the classification results:

| Category | Before | After |
|---|---|---|
| DIS | `**Title**` | `**Title** ✅proposed` |
| Task | `**Title**` | `**Title** ✅proposed` |
| Hypothesis | `**Title**` | `**Title** ✅proposed` |
| Domain Knowledge | `**Title**` | `**Title** ✅proposed` |
| Implementation Knowledge | `**Title**` | `**Title** ✅proposed` |
| Draft | `**Title**` | `**Title** ✅proposed` |
| Personal Data | `**Title**` | `**Title** ✅proposed` |
| Noise | `**Title**` | `**Title** ✅proposed (noise)` |

"Bot note" and "Idea" no longer appear as rows in this table — both categories are absorbed (see classification rules above); a note that reaches this step has already been reclassified. The `🔄` marker is not used.

**`✅proposed`** — the note has been classified and the proposal has been recorded in the target document (step 5), but the original entry stays in `fleeting-notes.md` until the pilot makes an explicit decision. On a subsequent review, do not reclassify a note already marked `✅proposed` (it has already been processed) — only display it as-is. Only the pilot can remove a note from the file (by direct command or by striking it through as `~~Title~~`), or Note Review can do so during a live conversation with the pilot on the pilot's explicit command — not during an autonomous run.

#### 5. Write proposals to target documents

For each note classified as DIS / Task — append a block to the **END** of the corresponding document.

**Proposal block format (at the end of the document):**

```markdown

---

## Proposals (Note-Review, YYYY-MM-DD)

- [ ] **[category]:** "brief note text"
      Source: note DD Mon, HH:MM
      Proposal: [specific action — what to add/change]

- [ ] **[category]:** "brief note text"
      Source: note DD Mon, HH:MM
      Proposal: [specific action]
```

**Where to write:**

| Category | Target document |
|---|---|
| DIS | `{{GOVERNANCE_REPO}}/docs/Dissatisfactions.md` |
| Task (for tomorrow / with deadline) | `{{GOVERNANCE_REPO}}/current/DayPlan*.md` (nearest) or `WeekPlan W*.md` |
| Task (this week) | `{{GOVERNANCE_REPO}}/current/WeekPlan W*.md` |
| Task (strategic) | `{{GOVERNANCE_REPO}}/docs/Strategy.md` |
| Personal Data | `{{GOVERNANCE_REPO}}/personal/` (contacts / accounts / secrets / reference) |

> **"Nearest DayPlan" means only an already-existing file in `current/`.** If `current/DayPlan *.md` is empty (Day Close has already moved today's plan to `archive/day-plans/`), do NOT create a new file in `current/` — doing so resurrects an already-closed day, and the next Day Open finds a foreign (yesterday's) plan there and blocks the commit. Write the proposal to the end of the already-archived file (`archive/day-plans/DayPlan {date}.md`) or, if it is clearly about tomorrow, to `WeekPlan`. Incident: July 10, 23:03 — Note Review recreated the already-archived `current/DayPlan 2026-07-10.md`, and it remained there until the morning of July 11, blocking automatic Day Open.

> The Strategist (Day-Plan, 4:00) reads these documents and SEES the proposals.
> The user can look at the end of the document and see "what they are based on".

#### 6. Record knowledge (Domain Knowledge)

> **Routing rule (BLOCKING, amended 2026-04-17):** by default, knowledge goes into **DayPlan as a candidate**, not into captures.md. The user decides during Day Open / in a live review — whether to pass it to the Extractor or not.
> Write to `captures.md` ONLY if the note text **explicitly** contains a marker: "to Extractor", "to captures", "to Pack", "formalize", "this to Extractor" (or synonyms).
> Reason: captures.md is the Extractor queue; it must contain only what the user has consciously sent there. Note Review does not decide for the user.

**If the marker is present → write to `{{GOVERNANCE_REPO}}/inbox/captures.md`:**

```markdown
### [brief knowledge description]

**Source:** fleeting-notes.md, DD Mon HH:MM
**Type:** pattern / distinction / method / rule / failure mode
**Context:** [which note, what situation]

> Quote from the note or paraphrase

**Suggested Pack:** [Pack repo name, if known]
```

**If the marker is absent → write to the end of the nearest `DayPlan*.md` in the "Note Review Proposals" section:**

```markdown
- [ ] **Knowledge (Extractor candidate):** "brief note text"
      Source: note DD Mon, HH:MM (stays in `fleeting-notes.md` until pilot decision)
      Suggested Pack: [Pack repo name]
      Action: [ ] pass to Extractor | [ ] keep as-is (archive only)
```

> The Extractor checks `captures.md` periodically and processes it. Writing to Pack happens only after user approval.
> **Do not duplicate:** if the knowledge is already in `captures.md` from a previous note, do not create a new candidate in DayPlan.

#### 5a. Draft entry in the hypothesis log (category "Hypothesis")

> Note Review does NOT write the final hypothesis — only a 4-field draft. The pilot confirms the final falsification criterion at the review.

For notes classified as "Hypothesis" — append a record to the end of `{{GOVERNANCE_REPO}}/current/hypotheses-log.md` (format and rules — `memory/lpf-hypothesis-log.md`):

```markdown
## H-NNN

- **Statement:** [verifiable prediction from the note]
- **Confidence:** [if the pilot stated a % — use it; otherwise leave `[TBD — pilot fills in]`]
- **Falsification criterion:** [draft — what could falsify this; if the note contains no explicit criterion, propose the most likely option with the label "draft, requires confirmation"]
- **Review date:** [if a deadline is stated in the note — use it; otherwise `[TBD — pilot sets]`]
- **Status:** draft (not confirmed by pilot)
- **Source:** fleeting-notes.md, DD Mon HH:MM
```

> If the record still contains `[TBD]` entries — it does NOT move to "under review" status until the pilot confirms it (otherwise the review date will never be meaningful).

#### 6a. Recommendation for a draft (category "Draft")

> **IMPORTANT:** Note Review does NOT create drafts directly. It only generates a recommendation. The draft is created by the user after approval (in DayPlan or an interactive session).

For notes classified as "Draft" — write a recommendation to the end of the current WeekPlan (section "Note Review Proposals").

**Recommendation format:**
```
- "brief note text" → recommend draft: [proposed title]. Concepts: [list]. Target: stub | pack | work-item
```

> **Guards:** ≤5 drafts = normal. 6–10 = ⚠️ warning in the recommendation. >10 = 🛑 do not recommend new drafts.

#### 7. Record personal data in personal/

For notes classified as "Personal Data" — append a record to the corresponding file:

| Data type | File |
|---|---|
| Phone, email, person's contact | `{{GOVERNANCE_REPO}}/personal/contacts.md` |
| Account, login, service URL | `{{GOVERNANCE_REPO}}/personal/accounts.md` |
| Token, API key, password | `{{GOVERNANCE_REPO}}/personal/secrets.md` |
| Address, credentials, other | `{{GOVERNANCE_REPO}}/personal/reference.md` |

> **secrets.md** — listed in .gitignore, not committed. Do not record full card numbers or PINs.

#### 8. Check inbox/ (without cleanup)

> **Note Review does NOT clean up inbox/.** Full cleanup is the responsibility of Session-Prep (Mon 4:00).
> Note Review only checks: if it sees anything unusual (unknown file, error) — log it in the report (step 9).

> **Do not touch:** `fleeting-notes.md` (except for the markers in step 4 and removal of notes the pilot has struck through — step 10), `WP-*.md`, `extraction-reports/`, `captures.md`.

#### 9. Display the report and continue

Before committing — output a brief report:

```
**Note-Review (DD Mon):** N notes processed
- Tasks: [list] → WeekPlan / DayPlan
- Hypotheses: [list] → draft in hypotheses-log.md (awaiting pilot confirmation)
- Knowledge (with "to Extractor" marker): [list] → captures.md
- Knowledge (without marker): [list] → candidate in DayPlan "Proposals" (awaiting user decision)
- Drafts: [list] → recommendations in WeekPlan (awaiting approval)
- DIS: [list] → Dissatisfactions.md
- Noise: [list] (test, duplicate, already done, link without context)
```

> **No chat — only markers and proposals (template owner decision, July 2026):** a run from `strategist.sh` executes steps 1–9 and 11, archives nothing and deletes nothing on its own (after it, only the safety script runs: it removes notes without bold, without `🔄`, and without the `✅proposed` marker); the scheduler does not call it. Approval requires only an explicit word from the pilot in a live session; silence ≠ consent.
>
> **Do NOT create `inbox-triage.md`.** All proposals have already been written to the target documents (steps 5–7). Day-Plan reads them from there directly.

#### 10. Write a copy to the archive — only on the pilot's decision, in a live session (the note in fleeting-notes.md does not remove itself)

> **Template owner decision (July 2026):** removing a note from `fleeting-notes.md` is not Note Review's decision. A note marked `✅proposed` stays in the file every day until the pilot removes it. Step 10 only writes a copy to the archive for history/search purposes, and only for a note on which the pilot has stated a decision; "no decision" blocks archiving. When running from `strategist.sh` (without chat), the runner prepends the line "MODE: script run without chat; skip step 10 and archive, only markers and proposals" to the prompt — if you see it, skip this step.

**Append to archive** — a copy of the note on which the pilot stated a decision → `archive/notes/Notes-Archive.md`:

```markdown
## YYYY-MM-DD — Note-Review

Note title
<sub>date, time</sub>
Additional context (if any)
**Category:** DIS / Task / Hypothesis / Domain Knowledge / Implementation Knowledge / Draft / Personal Data / Noise
**Review:** YYYY-MM-DD — **Pilot decision:** [verbatim or brief; field is required]

---
```

This step does NOT edit `fleeting-notes.md`, except for applying `✅proposed` in step 4 above and removing notes that the pilot has struck through (paragraph below).

**Notes the pilot has already struck through (`~~Title~~`)** — this is the pilot's explicit signal "closed, can be removed". Only such notes: copy to the archive (same format; in the "Pilot decision" field — "struck through by pilot") → delete the block from `fleeting-notes.md` using the Edit tool → verify by reading the file that the block is actually gone. Leave all other notes (including those just marked `✅proposed` in this same run) untouched.

#### 11. Commit

- Commit changes to {{GOVERNANCE_REPO}} (fleeting-notes.md with markers + documents with proposals + personal/ + archive: only records based on pilot decisions)
- If there were entries for the Extractor → commit {{GOVERNANCE_REPO}}/inbox/captures.md
- **secrets.md** is NOT committed (.gitignore) — but changes to it are saved locally
- Push

**Result:**
- fleeting-notes.md: new notes → marked `✅proposed` (remain in the file until the pilot closes them)
- Target documents: proposals appended to the end (for the Strategist and the user)
- Extractor inbox: knowledge recorded (for processing)
- personal/: personal data recorded in the appropriate files
- inbox/: processed files archived or deleted
- archive/notes/: only notes with a pilot decision, with a category and a "Pilot decision" field

---

## Note Cleanup (manual, on pilot command)

> **Trigger:** a "clean up notes" / "remove this note" command from the pilot, or the pilot has struck through a note (`~~Title~~`). This is the primary path for physically removing a note from `fleeting-notes.md` (apart from step 10 for notes the pilot has struck through, and the safety script `cleanup-processed-notes.py`, which archives notes without bold, without `🔄`, and without the `✅proposed` marker) — automation does not decide what to remove on its own (template owner decision, July 2026).

1. Read `fleeting-notes.md`
2. Find notes the pilot explicitly asked to remove in this command, or notes already **struck through** by the pilot (`~~Title~~`)
3. Move them to `archive/notes/Notes-Archive.md`:

```markdown
## YYYY-MM-DD — Cleanup

Note title
<sub>date, time</sub>
Additional context (if any)
**Category:** DIS / Task / Hypothesis / Domain Knowledge / Implementation Knowledge / Draft / Personal Data / Noise
**Review:** YYYY-MM-DD — **Pilot decision:** [verbatim or brief; for struck-through notes — "struck through by pilot"]

---
```

4. Delete the moved notes from `fleeting-notes.md`
5. **Bold** notes (`**text**`), notes marked `✅proposed` (bold or not), and `🔄` notes — stay, until the pilot names them explicitly
6. Commit and push

---

## Relationship to Other Processes

| Process | How it relates to Note Review |
|---|---|
| **Day Open** | The "Note Review" section shows all notes awaiting a pilot decision (bold or marked `✅proposed`, including non-bold ones; deferred `🔄` notes are not shown); the pilot makes the decision |
| **Day-Plan** (4:00) | Reads documents with Note Review proposals → takes them into account when building DayPlan |
| **Day Close** | Status sync, independent of Note Review |
| **Session-Prep** (Mon) | Reads ALL documents, including proposals. Can aggregate unresolved items |
| **Strategy-Session** | Processes 🔄 notes, reviews draft-list.md (TTL check), prioritizes drafts |
| **Extractor** | Reads {{GOVERNANCE_REPO}}/inbox/captures.md → formalizes → Pack (after user approval) |
| **Draft-list** | Note Review recommends drafts → WeekPlan (section "Note Review Proposals"). Strategy-Session reviews draft-list.md (TTL and priorities) |
| **Week Close** | Checks `hypotheses-log.md` — records with "under review" status and a past review date (per `memory/lpf-hypothesis-log.md`). Drafts with "draft" status (not confirmed by the pilot) are not included in the check |
