Execute the Week Review scenario for the Strategist role (R1).

> **Trigger:** Automatic — Mon 00:00 (midnight Sun→Mon, launchd).
> Records the results of the closing week in a separate WeekReport file and creates a post for the club. Serves as input for session-prep (Mon 04:00).
> **Split (WP-297 OPT-5, issue #596):** weekly facts live in `WeekReport W{N} YYYY-MM-DD.md`; WeekPlan holds intentions only. Previously this scenario wrote facts directly into the WeekPlan section ("deprecated 2026-03-25" incorrectly claimed a separate file was unnecessary — WP-297 reversed that decision, but three Strategist role files did not pick up the change).


## Context

- **WeekPlan:** {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/current/WeekPlan W*.md

## Algorithm

### 1. Data Collection (Strategist collects independently)

```bash
# For EACH repo in {{WORKSPACE_DIR}}/:
git -C {{WORKSPACE_DIR}}/<repo> log --since="last monday 00:00" --until="today 00:00" --oneline --no-merges
```

- Iterate over ALL repositories in `{{WORKSPACE_DIR}}/`
- Load the current WeekPlan from `{{GOVERNANCE_REPO}}/current/`
- Match commits to Work Products (WPs) from the WeekPlan
- Determine the status of each WP: done / partial / not started

### 2. Statistics

- Completion rate: X/Y WPs (N%)
- Total commits
- Active days (days with commits)
- By repository (table)
- By system (Creator, Ecosystem, IT Platform, Bot)

### 3. Insights

- What went well
- What can be improved
- Blockers (if any)
- Carry-over to next week

### 3b. Content Plan for Next Week

1. Collect Content ideas accumulated during the week (from draft-list.md, captures, Close reports)
2. Match against the publications backlog from Marketing Strategy §7
3. Propose 2–3 publications for next week:
   - What to adapt (source)
   - For whom (segment C1/C2/C3)
   - Where (Habr / LinkedIn / TG)
4. Record the content plan in the "Results W{N}" section of the WeekReport (Step 5)

### 4. Club Post Format

- Use the `weekly-review.md` template (if available)
- Add hashtags
- Format: compact, readable, with metrics

### 4a. Commit Guard Session

> WP-561 Ph25. On 28.09 the model opened a session with a fabricated `wp: week-review-w39`, and a commit 17 minutes later failed for all users whose files overlapped with its scope. The wrapper script now opens the session; the model itself does not open it.

For this run, the wrapper script has already opened the service guard session (`week-review`, scope `current/`) and will close it automatically. Do not open your own session (`session-guard.sh open`): it is denied on a frozen directory, and the guard rejects a fabricated `--wp` value. In the governance repository, modify and commit only files under `current/`; the club post (Step 6) belongs to the Knowledge Index repository (`DS-Knowledge-Index`), not governance, and is not covered by this session. Do not bypass a guard rejection (`--force`, `--no-verify`, editing hooks): include the exact rejection text verbatim in the final response. The wrapper script verifies that the weekly report was pushed to the server and will alert the owner if it was not.

### 5. Saving Results to WeekReport

> **WeekPlan does not contain results** (WP-297 OPT-5) — only the intentions for the next week. Facts from the closing week go into a separate file.

1. Determine `{N}` and the week date from the name of the closing `{{GOVERNANCE_REPO}}/current/WeekPlan W{N} YYYY-MM-DD.md` (same week, same `{N}`, same date — WeekPlan/WeekReport files for the same week are paired).
2. Create (or, if it already exists, append to) `{{GOVERNANCE_REPO}}/current/WeekReport W{N} YYYY-MM-DD.md` with frontmatter `type: week-report`, `week: W{N}`, `created: YYYY-MM-DD`.
3. Write the section `## Results W{N}` there: metrics, table by repository, WP statuses, insights, carry-over, content plan (format — see template below).
4. Commit to {{GOVERNANCE_REPO}}

### 5b. Extensions (before publishing the post)

> issue #884: user extensions `week-close.before.*` cancelled Steps 6–7 only in the interactive Skill `/week-close` — this nightly scenario did not read them at all, so cancelled behavior (for example, "do not publish the weekly results post") recurred every week.

Load: `bash .claude/scripts/load-extensions.sh week-close before`. Exit 0 → `Read` each file from the output (alphabetic): if at least one cancels publication of the weekly results post (for example, `no-weekly-post`), skip Steps 6 and 7 entirely, record in the log why ("week-close.before.<suffix>: publication cancelled by extension"), and proceed to Step 8. Otherwise execute Steps 6–7 as normal. Exit 1 → no extensions, execute Steps 6–7 as normal.

> **Scope of this step:** the `before` hook is treated HERE ONLY as the decision "publish the post or not" — unlike the interactive `/week-close` (SKILL.md Step 0), which executes the contents of the found files as full initial steps. An extension with a different meaning (not about publication) is not executed here — the decision belongs to the pilot, not to this automatic scenario.

### 6. Create Club Post (auto-publish)

> The weekly results post is published automatically at Mon 07:14 MSK. The Strategist creates it immediately with `status: ready`.

1. Switch to **the Author role (R4)** and, based on the "Results W{N}" section in the WeekReport (Step 5), compose the club post.

   - § 2 — naming standard for weekly results
   - § 3 — post format: audience `community`, structure for the tag `weekly-results` (4 levels of impact, first-person voice, 400–700 words)

   The Strategist is responsible for **data** (metrics, facts, comparisons). The Author is responsible for **presentation** (voice, structure, style).

   **Required data from Strategist → Author:**
   - Weekly metrics (commits, completion rate, comparison with previous week)
   - Key facts (what was actually done)
   - Carry-over → W{N+1} (from WeekReport, section "Results W{N}" → "Carry-over")
   - Focus for next week (from the next WeekPlan — intentions, not facts from the closing week)

   The Author uses carry-over and focus for the post's closing section — "ideas for next week".

   Choose the best title independently (in automatic mode there is no user available for selection).


3. Frontmatter:

```yaml
---
type: post
title: "..."
audience: community
status: ready
created: YYYY-MM-DD
target: club
source_knowledge: null
tags: [weekly-results, W{N}]
content_plan: null
---
```


**Template for the "Results W{N}" section in WeekReport:**

```markdown
## Results W{N}: DD Mon — DD Mon YYYY

### Metrics
- **WPs:** X/Y completed (N%)
- **Commits:** N across M repos
- **Active days:** N/7

### By Repository

| Repo | Commits | Main changes |
|------|---------|--------------|
| ... | ... | ... |

### WPs

| # | WP | Status | Comment |
|---|----|--------|---------|
| ... | ... | done/partial/⬜ | ... |

### Insights
- ...

### Carry-over
- ...

### Content Plan W{N+1}

> Source: Content ideas for the week + backlog from Marketing Strategy §7

| # | Topic | Source | Segment | Channel |
|---|-------|--------|---------|---------|
| ... | ... | post/draft | C1/C2/C3 | Habr/LinkedIn/TG |
```

### 7. Recording the Post Link in WeekPlan

> **REQUIRED.** After creating the post — record the link in the current WeekPlan.

1. Open the current `{{GOVERNANCE_REPO}}/current/WeekPlan W{N}*.md`
2. Find the "Content Plan W{N}" section (or create it if absent)
3. Add the line:

```markdown
```

4. Commit together with the other changes

> This link allows: (a) the Strategist to see in session-prep which post was created, (b) the user to review the post before publication, (c) day-plan to know that content is ready.

Result:
- "Results W{N}" section in WeekReport — as input for session-prep
- Post link in WeekPlan — for tracking

### 8. Week Close: MEMORY.md Maintenance

> Additional steps on top of Week Review. Described in `protocol-close.md § Week`.

**Live file (the sole write target for 8a–8c):** `~/.claude/projects/{{CLAUDE_PROJECT_SLUG}}/memory/MEMORY.md` (the same path that `note-review.md` already uses, also accessible via symlink `{{WORKSPACE_DIR}}/memory/MEMORY.md`). `{{GOVERNANCE_REPO}}/exocortex/MEMORY.md` is a Backup for restoring on a new machine; synchronization into it is one-way (live → exocortex), do not touch it here: an edit made only in `exocortex/` is lost at the next sync, and the agent in the next Session continues reading the live file with the week that should have been replaced (issue #708).

#### 8a. Lesson Rotation

For each lesson in MEMORY.md → "Lessons" section:
1. Was it applied in the last 2 weeks? (there was an Incident, a mention in Close reports, or the lesson is < 2 weeks old)
2. **Yes** → keep
3. **No** → move to `memory/lessons-archive.md` (not loaded automatically)
4. Goal: ≤15 current lessons in MEMORY.md

#### 8b. Fresh WP Table

1. Remove ALL WPs from the previous week W{N-1} from MEMORY.md
2. Populate the W{N} table from the new WeekPlan:
   - in_progress and pending → carry over
   - done → do NOT carry over (already in WP-REGISTRY)
3. Update the heading: `W{N}: DD Mar – DD Mar`

#### 8c. Memory File Audit

1. Line limits:
   - Reference files (hard-distinctions, navigation, roles, sota) ≤ 100
   - Protocol files (protocol-*) ≤ 150
   - MEMORY.md ≤ 100
2. Outdated entries → update or delete
3. Result: report "Memory audit: N files, M total lines, K updated"
