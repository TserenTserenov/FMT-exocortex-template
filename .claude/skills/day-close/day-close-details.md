# Day Close — Details (lazy-load)

> Load when details on a specific step are needed.
> Main protocol: `day-close/SKILL.md`

---

## Step 0b: Digest + Execution Phase Model (issue #234)

**Purpose.** Day Close at the tail of a long session makes ~25–40 tool calls, and each call re-sends the entire day's conversation as input (~100K-token session × 30 calls ≈ 3M input tokens). The digest + sub-agent context isolation decouples closing cost from session size: ~1 digest call + 2 isolated sub-agents.

**Replacement map (digest section → what it replaces in SKILL.md):**

| Digest § | Replaces in SKILL.md |
|----------|----------------------|
| 1 commits today | Step 1 — `git log` loop over repos |
| 2 dirty repos | Step 10b — `check-dirty-repos.sh` |
| 3 open-sessions.log | Step 2d — reading the log |
| 4 memory drift hits | Step 4b — grep |
| 5 index health | Step 4c — running `check-index-health.py` |
| 6 lesson/memory stats | Step 4 — scan |
| 7 WakaTime | Step 6 |
| 8 peer sessions today | Step 6 prerequisite (`sessions/00-index.md`) |
| 9 DayPlans in current/ | Step 3 — lookup |
| 10 done WP contexts in inbox/ | Step 3 — lookup |
| 11 WeekReport presence | Step 2f — precondition |

**Sub-agent execution phases.** The parent session executes ONLY: digest → dispatch → pilot review → dispatch → Verification. The parent itself does not re-read governance files or make edits.

- **Phase B — executor.** ONE general-purpose sub-agent (sonnet). Prompt includes: (a) full digest, (b) today's date, (c) instruction: "Read `.claude/skills/day-close/SKILL.md`, execute steps 1–7 via TodoWrite, applying the replacement map below. Skip step 0 — the parent has already executed it. Table Formatting: `.claude/rules/formatting.md`. Git: stage only specific files, do NOT commit. Return: draft summary (step 7), list of edited files, blockers." Attach the replacement map.
- **Phase C — review (parent).** Show the draft to the pilot verbatim (step 8). Corrections → approval.
- **Phase D — finalizer.** Second sub-agent (sonnet): approved draft + corrections + list of Phase B files. Executes steps 9, 10, 10b, then postconditions in a single call: `bash "$IWE_SCRIPTS/day-close-prepare.sh" --verify` (replaces the two inline-grep checks 9a/9b + the repeat dirty-scan; patterns are locale-tolerant). Any FAIL → write the missing content / commit+push → repeat until exit 0. Returns `--verify` output + commit SHAs.
- **Phase E — Verification (parent).** Step 11: the parent dispatches the R23 verifier (haiku) — sub-agents cannot spawn sub-agents. Pass the checklist, approved draft, both file lists, and `--verify` output.

**TodoWrite:** the parent tracks phases 0b/B/C/D/E as tasks; each sub-agent tracks its own SKILL steps with its own TodoWrite — the step-by-step Blocking rule is observed.

**Fallback:** Agent tool is unavailable or sub-agent failed twice → execute steps inline in the parent (legacy), still using digest data.

## Step 0c: Strategy_day guard (issue #286)

**Problem this step solves.** `/day-open` on a strategy day (Monday by default, `day_open.strategy_day` in `day-rhythm-config.yaml`) does not create a DayPlan — the plan lives entirely in WeekPlan (`day-open/SKILL.md` step 4). Before this step, `/day-close` was unaware of this exception: steps 1, 2b, 3, and 9a unconditionally required a DayPlan, and postcondition 9a ("Day summary" found by grep) was structurally unreachable — there was no file to write to. The protocol could not finish with `completed`.

**Check (at the start of the algorithm, before step 1).** `date +%A` is locale-dependent (under `ru_RU.UTF-8` it returns a non-English day name, so a comparison against the English name from the config will never match — this same bug was previously found and fixed in `day-open-scaffold.sh`; the same pattern is used here: numeric day of week `date +%u` (1=Mon…7=Sun, locale-independent) + name-to-number map):
```bash
T="${IWE_TEMPLATE:-$HOME/IWE/IWE}"
# issue #541 hvost 3 (Evgenii, cold-review 26.08): the former bare `python3 -c` with
# stderr suppression silently returned "monday" even when the actual
# day-rhythm-config.yaml named a different day — on a host without PyYAML this was
# not an error but incorrect logic indistinguishable from normal operation. find-python3.sh
# prints a clear reason to stderr on failure (we do not suppress it here);
# the monday fallback remains — this is a soft guard, not a reason to fail entirely.
PY3="$(bash "$T/.claude/lib/find-python3.sh")"
STRATEGY_DAY_NAME=$([ -n "$PY3" ] && "$PY3" -c "
import yaml
d = yaml.safe_load(open('${IWE_GOVERNANCE_REPO:-DS-strategy}/exocortex/day-rhythm-config.yaml'))
print((d.get('day_open') or {}).get('strategy_day', 'monday'))
" || echo monday)
case "$STRATEGY_DAY_NAME" in
  monday)    STRATEGY_DOW=1 ;;
  tuesday)   STRATEGY_DOW=2 ;;
  wednesday) STRATEGY_DOW=3 ;;
  thursday)  STRATEGY_DOW=4 ;;
  friday)    STRATEGY_DOW=5 ;;
  saturday)  STRATEGY_DOW=6 ;;
  sunday)    STRATEGY_DOW=7 ;;
  *)         STRATEGY_DOW=0 ;;
esac
TODAY_DOW=$(date +%u)
if [ "$TODAY_DOW" = "$STRATEGY_DOW" ]; then
  echo "strategy_day: true"
fi
```

**If strategy_day:**
- Steps 1, 2b, 3 (archiving today's DayPlan — archive old DayPlans in `current/` regardless), 9a — mark as **not applicable**, not FAIL (postcondition 9a is not checked at all and does not count toward "All ✅").
- Day summary — record only in WeekReport (step 9b), same as a regular day: facts only (Work Product results, commits, multiplier). Do NOT copy plan lines into WeekReport.
- Day Close checklist: corresponding items (DayPlan row statuses, DayPlan archiving, "Day summary written to DayPlan", Handoff validation from DayPlan) — N/A for today, they do not block "All ✅".

## Step 1: Data Collection

```bash
for repo in $(ls ${IWE_WORKSPACE:-$HOME/IWE}/); do
  if [ -d ${IWE_WORKSPACE:-$HOME/IWE}/$repo/.git ]; then
    commits=$(git -C ${IWE_WORKSPACE:-$HOME/IWE}/$repo log --since="today 00:00" --oneline --no-merges 2>/dev/null \
      | grep -vE "^(docs|chore|ci|style|perf|test)(\\(|:| )" \
      | grep -vE "memory/|\.claude/rules/|template-sync|backup|reindex" \
      || true)
    [ -n "$commits" ] && echo "=== $repo ===" && echo "$commits"
  fi
done
```

Match commits against the "Today's plan" table in DayPlan → determine statuses.

---

## Step 2f: WeekReport — Rules for Recording Summaries

- File: `${IWE_GOVERNANCE_REPO:-DS-strategy}/current/WeekReport W{N} YYYY-MM-DD.md`
- Add a new `<details><summary><b>Summary {Day} {Date}</b></summary>` section **before** previous "Summary" sections (reverse chronology: today → older)
- Content: commits by repo, Work Product statuses for the day, carry-over blockers
- **strategy_day (Monday without DayPlan):** record the day summary in WeekReport as a regular day — facts only (Work Product results, commits, multiplier). Do NOT copy plan lines into WeekReport.
- **Rule OPT-5:** WeekPlan = intentions only; WeekReport = facts only.

---

## Step 4b: Memory Drift Scan — Algorithm

```bash
grep -nE "waiting|dep:|blocker|blocked:|stopped|waiting for approval" \
  $HOME/.claude/projects/*/memory/MEMORY.md 2>/dev/null
```

For each matched pattern:
1. Identify the Work Product number (WP-NNN) from the line context
2. Find the WP context: `ls ${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/WP-{N}-*.md` (if archived → `archive/wp-contexts/`)
3. Read the "What we learned" / "Remaining" / final status section
4. If a closing indicator is present (`DONE`, `RESOLVED`, `✅`, `fixed`, `closed`, `dropped`) → update MEMORY.md, announce: *"Memory drift: [fact] is stale → updated"*
5. If WP context not found → *"Memory drift: WP-N — context not found, check manually"*

Announce when 0 changes: *"Drift-scan: checked N patterns, no stale facts found"*

---

## Step 4c: Index Health Check — Algorithm

> Catches bloat in index files (MEMORY.md, WP-REGISTRY.md, MAPSTRATEGIC.md, *-registry.md, *-index.md, *-catalog.md).
> Rule: an index = hook line + link to source-of-truth only, not a content dump (see algorithm below).

```bash
T="${IWE_TEMPLATE:-$HOME/IWE/IWE}"
PY3="$(bash "$T/.claude/lib/find-python3.sh")" && "$PY3" "$T/.claude/scripts/check-index-health.py"
```

For each FAIL/WARN in the report:
1. Open the file, inspect the specific lines/cells from the report
2. Diagnose: is this a context dump (a problem) or a methodological table (a genre)?
   - Dump → move context to source-of-truth (inbox/WP-NNN-*.md, WeekPlan, a separate `*-changelog.md`); leave only hook + link in the index
   - Genre (matrix table, catalog of domain entities) → add a note at the top of the file: `<!-- index-health: skip-cells -->` or `<!-- index-health: skip -->` with justification
3. If FAIL is in a Pack file — do not clean automatically, only mark skip with justification

Announce when 0 WARN/FAIL: *"Index-health: N files OK, M skip"*.

---

## Step 6: IWE Multiplier — Algorithm

1. **WakaTime** — physical time for the day:
   - **Closing date ≠ calendar date of the call** (for example, `/day-close` is called after midnight for the previous day) → do NOT try `--today` at all; go straight to Neon fallback with an explicit date in SQL (issue #732: `--today` in `wakatime-cli` returns data for the day of the CALL, not the day being closed, and as of the last check on 15.07 the CLI had no flag to retrieve data for a specific date — same class of bug previously fixed for Day Open, WP-299 Ph4 p.3).
   - Closing date = calendar date of the call → CLI: `~/.wakatime/wakatime-cli --today` (on Windows the binary is named `wakatime-cli-windows-amd64.exe`: search by mask `~/.wakatime/wakatime-cli*`)
   - Neon fallback: `SELECT payload->>'human_readable', payload->>'total_seconds' FROM learning.public.domain_event WHERE event_type='coding_time' AND account_id='{DT_USER_ID}' AND external_id='wakatime:{DT_USER_ID}:{YYYY-MM-DD}'`
   - If Neon is also empty → mark as "pending Neon", recalculate in the next session

2. **Budget closed — calculate BY ACTUAL (BLOCKING):**
   - **Step 2.0 (prerequisite):** open `<governance-repo>/sessions/00-index.md`, filter rows for today (`grep "$(date +%Y-%m-%d)"`), compile the full list of peer sessions with turn counts. Without this the calculation is understated ×2.
   - done → full budget (or proportional to phases for umbrella Work Products)
   - partial → % completion × budget; if overplanned work is done within a planned Work Product — record the actual
   - not started → 0h
   - **ad-hoc peer sessions (no Work Product tag in DayPlan):**
     - 2–4 turns → 0.25–0.5h
     - 5–7 turns → 0.75–1h
     - 8+ turns → 1–1.5h
   - Minor edits without a peer session (budget "—" / merged) → 0.25h

3. **Day multiplier** = Budget closed / WakaTime. Format: `N.Nx`

4. **Sanity check (BLOCKING):** multiplier <1.5x with ≥10 peer sessions → recalculate. Show the pilot 3 methods (letter SKILL / actual / compromise) and ask which to record.
   Lesson: `lessons_multiplier_peer_sessions_uncounted.md`

---

## Step 7: Draft Summary — Structure

**a) Overview:** "what was done" table (Work Product × status)

**b) What I learned:** captures in Pack, Distinctions, insights

**c) Recognition:** what went well, what was difficult but done

**d) Nothing forgotten?**
- Uncommitted changes: `${IWE_SCRIPTS}/check-dirty-repos.sh`
- Self-development hours (WP-310 Ph13c): is the `/slot` for today recorded? Ask "How many hours?", offer buttons 0/0.5/1/2/3/4. Suggest the command `/slot N` in the bot.
- Unrecorded thoughts? (ask the user)
- Promises to anyone? (ask the user)

**e) Videos for the day:** if `video.enabled: true` → check for new videos

**f) Draft list:** Pack enriched → propose a draft?

**g) Head start for tomorrow:**
- Where to begin in the morning
- Incomplete Work Products: a concrete next action for each

**h) Morning Priorities (`current/priorities.yaml`, restored in issue #270):**
- Ask the pilot: "What are your 1–3 morning priorities for tomorrow? Provide WP-IDs in order of importance (first = most important). To skip, say 'skip'."
- If the pilot sets priorities → overwrite `${IWE_GOVERNANCE_REPO:-DS-strategy}/current/priorities.yaml`:
  ```yaml
  # Morning priorities for today — update in the evening or morning
  # Order = descending priority (first = most important)
  # Empty list = fallback to yesterday's carry-over in Day Open
  last_updated: "YYYY-MM-DD"
  today:
    - WP-NNN
    - WP-MMM
  ```
  where `last_updated` = the day AFTER the day being closed (the day for which priorities are set). When closing "today" this is tomorrow; when retroactively closing day N (after midnight, on day N+1) this is N+1, not tomorrow's date: `date -v+1d -j -f %Y-%m-%d "$CLOSE_DATE" +%Y-%m-%d 2>/dev/null || date -d "$CLOSE_DATE + 1 day" +%Y-%m-%d`. An empty list is written as `today: []`, not `null`.
- If the pilot skips → do NOT change the file, but explicitly write the line "priorities not updated (skipped by pilot)" in the closing report (issue #944: silent skipping is invisible — this is exactly how the file froze). Day Open does not carry the stale list into DayPlan: if the list is more than 3 days old (overridable via `PRIORITIES_STALE_DAYS`) it will show one line "priorities are stale" and use yesterday's carry-over.
- Add the file to the change list for the final-step commit (if it was overwritten).

---

## Step 9: Recording Summaries — Postconditions

**Day summary template:** `memory/templates-dayplan.md § Day summary template`

**Validation of "Start tomorrow with" (ADR-207):** field is not empty + every pending Work Product is mentioned + a concrete next action (not "continue work").

**Postcondition 9a:**
```bash
TODAY=$(date +%Y-%m-%d)
# NOTE (bug-2026-07-10, found Day Close 10.07): the original version piped the path
# through `xargs`, which splits arguments on spaces — but DayPlan filenames ALWAYS
# contain a space ("DayPlan YYYY-MM-DD.md"), so xargs received two non-existent
# tokens and the postcondition silently failed regardless of the actual file content.
# Direct variable reference in quotes does not split the path.
F="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/archive/day-plans/DayPlan ${TODAY}.md"
if grep -q "Day summary" "$F" 2>/dev/null && grep -q "${TODAY}" "$F" 2>/dev/null; then
  echo "9a OK"
else
  echo "9a FAIL: summary not found in DayPlan ${TODAY}"
fi
```

**Postcondition 9b:**
```bash
TODAY=$(date +%Y-%m-%d)
DAY_NUM=$(date +%-d)
( grep -rl "Summary.*${DAY_NUM}" ${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/current/WeekReport\ W*.md 2>/dev/null \
  || grep -rl "Summary.*${DAY_NUM}" ${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/current/WeekPlan\ W*.md 2>/dev/null ) \
  | grep -q . && echo "9b OK" || echo "9b FAIL: summary not found in WeekReport or WeekPlan"
```

Result `*a/*b FAIL` → do NOT mark the step completed; return to recording.
