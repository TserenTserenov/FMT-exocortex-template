# Day Open — Details (lazy-load)

> Load when details on a specific step are needed.
> Main protocol: `day-open/SKILL.md`

---

## Step 0: Extensions (before)

```bash
bash .claude/scripts/load-extensions.sh day-open before
```
Exit 0 → `Read` each file from output (alphabetic) → execute contents as the first steps.
Exit 1 → skip.
Supports `extensions/day-open.before.md` AND `extensions/day-open.before.<suffix>.md`.

---

## Step 1: Yesterday

Read yesterday's DayPlan (`archive/day-plans/` or `current/`). Extract:
- The "Results" section → 1–3 outcomes
- The "Start tomorrow with:" section / carry-over Work Items → **priority input** for Step 2
- Unresolved issues from "Requires Attention"

**Context economy (issue #207):** A DayPlan of 80–150 lines — do NOT read in full. Only three blocks are needed: frontmatter (`Read` first ~10 lines) + sections "Results", "Start tomorrow with:", "Requires Attention" (extract with `grep`/`awk` by heading, or `Read` with offset to the specific sections). Read the full file only if the structure is non-standard and the target sections are not found.

Fallback: file not found → skip, work from commits.

Yesterday's commits across all `$IWE_WORKSPACE/*/` repos. Cross-reference with DayPlan.

---

## Step 1b: GitHub Issues

`gh issue list` across all repos (including nested). Filter: 2 days. Link to Work Items by keywords.
**Actionable only:** skip read-only and upstream repos without push access.

**The sweep runs via script, not agent (issue #207):** the "New tasks in repositories" section is populated by `day-open-scaffold.sh` (`render_repo_issues`) — it skips directories without `.git` and without a GitHub remote, and caches the response for 1 hour. Manual iteration over repos via `gh` is not needed — it doubles token usage on empty repos.

**Critical FMT issues (detector):**
```bash
bash $IWE_SCRIPTS/fmt-critical-alert.sh --no-telegram
```
Outputs a markdown table of open issues labeled `critical`/`deadline` in IWE. If `TG_BOT_TOKEN` and `TG_CHAT_ID` are configured — remove `--no-telegram` to duplicate alerts to Telegram (MVP detection chain for weekend P0). Source: peer-session 2026-06-01-18.

---

## Step 1c: Inbox Triage

**Sources:**
- `<governance-repo>/inbox/fleeting-notes.md` — recent notes
- `<governance-repo>/inbox/captures.md` — knowledge candidates (if present)
- `<governance-repo>/inbox/extraction-reports/*.md` with `status: pending-review` — Extractor reports (if present)

**Note categorization** per PD.FORM.083 (8 categories): NEP / Task / Hypothesis / Domain Knowledge / Implementation Knowledge / Draft / Personal Data / Noise. Full reference → `roles/strategist/prompts/note-review.md`. Do NOT delete.

**Carry-over notes from yesterday's DayPlan:** check the inbox itself (`inbox/fleeting-notes.md`), not the commit history. Notes awaiting a decision: bold or marked `✅proposed` (in the first line of the note; the bold may have been lost); deferred `🔄` notes do not count. Until the pilot makes a decision (strikes through the note or asks to remove it), carry that note into the "Note Review" section again. Write "No notes awaiting pilot decision" only when the inbox contains neither bold notes nor notes marked `✅proposed`.

**Hyperlinks to notes (BLOCKING):** every note in the "Note Review" section of the DayPlan must be a markdown link to its source (`inbox/fleeting-notes.md` for notes awaiting a decision, including those marked `✅proposed`; `archive/notes/Notes-Archive.md#L<line>` for notes already closed by pilot decision; `inbox/captures.md` for knowledge). Reason: without a link, the substance of a note is lost within a day; a note awaiting decision lives in the inbox, a closed note lives in the archive. Row format: `["title"](path#L<line>) (DD Mon HH:MM)`.

**Knowledge notes = candidates (BLOCKING):** notes in the "Domain Knowledge" category without an explicit "To Extractor" marker in the body → add to the DayPlan "Note Review" section as a **Extractor Candidates** table with columns "Note | Type | Proposed Pack | Action". The decision to "hand over / keep" is made by the user during the live review. Note-Review writes to `captures.md` ONLY when an explicit marker is present. Reason: `captures.md` is the Extractor queue; adding any knowledge there implies tacit consent to formalization, which Note-Review is not authorized to give.

---

## Step 2: Plan for Today

**Input Priority (strict order):**
1. **Carry-over from Day Close (BLOCKING):** ALL Work Items from the "Start tomorrow with:" section → into the plan without trimming. This is a user decision — Day Open does not filter or shorten this list.
2. **WeekPlan (REQUIRED):** read WeekPlan → ALL in_progress and pending Work Items → check each: relevant today? Has a date/deadline today? Overdue? → add.
   **Context economy (issue #207):** WeekPlan 13+ KB — for Step 2 and Budget Spread, only the Work Item table is needed (the "Weekly Plan" section with columns # / name / h / status). Read it directly (`Read` to the section or `grep`/`awk` on the table), not the whole file.
   **Budget Spread** (if `budget_spread.enabled: true` in day-rhythm-config.yaml): for each Work Item with budget ≥ `threshold_h`:
   - `days_left` = remaining working days from `budget_spread.working_days` (list of day-of-week codes: mon/tue/wed/thu/fri/sat/sun), including today; key absent → fall back to Mon–Fri (issue #902 — the user's work week was hardcoded in the rule; for users who work weekends, the daily budget was inflated by 1.5×)
   - `daily_slot` = round(budget_week / days_left, `rounding`)
   - No budget in WeekPlan → skip, add to "Requires Attention"
   - Work Item already in plan (carry-over) → take max(carry_over_budget, daily_slot)
   - Otherwise → add with daily_slot
   - Do not limit to "2–4 items" — the day plan reflects the actual workload
3. **MEMORY.md → "Work Items for the current week":** verify — are there any Work Items missing from WeekPlan (ad-hoc, reopened)?
4. `day-rhythm-config.yaml → mandatory_daily_wps` — mandatory Work Items (check that they are in the plan; if not → add)

**Slot 1 = self-development.**
Mandatory Work Items absent from WeekPlan → "Requires Attention".

---

## Step 4c: Calendar (Day Mode)

**Single source — calendar connector** (MCP calendar tools; names depend on the installation and contain "calendar" case-insensitively, e.g. `mcp__claude_ai_Google_Calendar__*`): retrieve the list of calendars, then events for each calendar for the day. Classification and format are the same as described below for the script.

The script below is a **fallback for installations without a connector** (issue #581). A response of "Google credentials not configured" means the key file `~/.secrets/google-calendar` is absent, not that the calendar is empty: when the connector is working, creating that file is not required.

```bash
bash $IWE_SCRIPTS/server-calendar.sh YYYY-MM-DD
```

**What the script does (fallback):**
1. Queries ALL calendars from `calendar_ids` (no shortcuts — see `feedback_calendar_query_day_open`).
2. Filters by `visibility == "private"` only (not by name).
3. Classifies:
   - **Meetings** — multiple attendees, duration >30 min, no task markers.
   - **Reminders / Tech operations** — markers 🔧 ✅ ⏰ 🔔 📋 ❗ or keywords (backup, check, remind, smoke, test), or ≤30 min with no attendees.
4. Status relative to current time: ⏳ upcoming / 🔄 in progress / ✅ completed.
5. Calculates free blocks ≥1h within 09:00–22:00.

**Format in DayPlan:** two tables (Meetings + Reminders) per the `memory/templates-dayplan.md` template.

---

## Step 4c-alt: Weekly Calendar (Week Mode, strategy_day)

If today is `strategy_day` (from `day-rhythm-config.yaml`):
```bash
bash $IWE_SCRIPTS/server-calendar.sh --week YYYY-MM-DD
```
Output → insert into WeekPlan section **"Weekly Calendar W{N}"** (template `memory/templates-dayplan.md`). This allows meetings and tech operations to be accounted for during planning.

---

## Step 5: IWE Overnight (traffic light)

**Check for IWE updates:**
```bash
(cd "$IWE_TEMPLATE" && bash update.sh --check --fast 2>&1)
```
`--fast` (issue #230, v2.5.0) compares only the Manifest version — one second instead of 2+ minutes for a full file-by-file comparison across 300+ files. For the full list of changes — run `bash update.sh --check` (without `--fast`) separately, not as part of Day Open.
If an update is available → "Requires Attention": "IWE update available → `/iwe-update`".

**Check Base repos (FPF, SPF, ZP):**
```bash
for repo in FPF SPF ZP; do
  dir="$IWE_WORKSPACE/$repo"
  [ -d "$dir/.git" ] && (cd "$dir" && git fetch --quiet 2>/dev/null && behind=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0) && [ "$behind" -gt 0 ] && echo "$repo: $behind new commits" || echo "$repo: up to date")
done
```
If new commits exist → "Requires Attention": "[repo] updated upstream → `git -C "$IWE_WORKSPACE/[repo]" pull --rebase`". After pulling FPF/SPF — run local reindex of the MCP index, if installed.

---

## Step 5a2: Video

If `day-rhythm-config.yaml → video.enabled: true`:
1. Scan directories from `video.directories` for files with extensions from `video.extensions`
2. Show ONLY new recordings from today (`-mtime 0`). Do not notify about older files.
3. New files found → "N new video recordings today (X GB)". None → "0 new recordings today"
4. `video.enabled: false` → skip

---

## Step 5c: Content Editor (DP.ROLE.033 / DP.SC.127)

`config: content_editor.enabled` (day-rhythm-config.yaml) — `true` → execute; otherwise (including missing section, issue #804) → skip.
1. Read all `<governance-repo>/drafts/D-NNN-*.md` — frontmatter (`created`, `ttl`, `updated`) + body.
2. Read the active week's WeekPlan — R-table (initiatives) + S-table (dissatisfactions).
3. Evaluate each draft: (a) strong idea — thesis in 1–2 sentences; (b) relevance — matches ≥1 R or S by content; (c) freshness — `updated`/`created` ≤14 days and TTL not expired; (d) completeness — has an introduction + main body.
4. Select top 3 → add a "Content Editor" section to the DayPlan: table D-ID / name / R/S link / reason.
5. List of stalled drafts (TTL expired) separately below the table. Do not archive — only display.
6. Signal: check the repo from `config.content_editor.index_repo` for posts with status from `config.content_editor.index_ready_status`. If ≥ `config.content_editor.publish_signal_threshold` → "Requires Attention": "N ready posts in Index — start the publication cycle (C3)?"
7. The top 3 is rebuilt every day — do not cache yesterday's recommendations.

---

## Step 6: World (news)

If `day-rhythm-config.yaml → news.enabled: true`: Feeds/WebSearch from configured sources. **Source links are required** (URL).

### 6a: News Lens (Haiku sub-agent)

After collecting headlines, call a sub-agent (Haiku, context isolation) with the prompt:

> You are a news scout. You are given a list of headlines and a list of the user's active Work Items.
> Task: write 2–4 sentences on "What from this matters for work today?"
> Reply in English only. Do not list all the news — synthesize only.
> Input:
> NEWS: {headlines with topics}
> ACTIVE WORK ITEMS: {top-5 Work Items by priority from DayPlan}

Sub-agent output → **"Summary:"** field at the start of the "World" section:

```
**Summary:** <2-4 sentences of synthesis>

**AI/LLM:** [Headline 1](url) · [Headline 2](url) · ...
**Engineering:** [Headline 1](url) · ...
**World events:** [Headline 1](url) · ...
```

Sub-agent unavailable / timeout → skip "Summary", show links only.

---

## Step 6b2: CVU Markup

The CVU model — Current · Valuable · Urgent (see distinctions [[Current ≠ Valuable ≠ Urgent (CVU)]]).

When assembling the day plan, mark each Work Item/block with a CVU mode:
- **Valuable (development)** — schedule in the most protected slot (morning, after breakfast): higher probability of completion. At least one Valuable block per day is required — otherwise Urgent accumulates.
- **Current (routine)** — operational work, in the second half of the day.
- **Urgent** — only when there is a risk of stopping the Pipeline; not scheduled in the day plan in advance, it enters the plan during the day. Check for a new task: "Can it wait until the next strategy session?" Yes → fleeting note, NOT urgent. No → add to today's work plan. A deadline or "burning" issue does not make something urgent by itself ([[Deadline ≠ Urgency]]).

---

## Step 7a2: Session Log Template

Write the session log: `<governance-repo>/sessions/YYYY-MM-DD.md`:

```markdown
---
type: session-log
date: YYYY-MM-DD
week: W{N}
agent: Strategist / Coder
---

# Session Log: YYYY-MM-DD

## Day Open
- DayPlan: `current/DayPlan YYYY-MM-DD.md`
- Carry-over: [list from yesterday's "Start tomorrow with:"]

## Day Sessions
> Filled in during Day Close: list of Quick Close sessions + key Work milestones

## Day Close
> Added during Day Close: link to `archive/day-plans/DayPlan YYYY-MM-DD.md` + 3 plan options for tomorrow
```

If the file already exists (double Day Open) — do not overwrite, skip.
