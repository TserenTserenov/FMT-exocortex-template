---
agents: single
argument-hint: ''
browser_safe: false
description: Week Close protocol. 7-day retrospective + carry-over to the new week
  + platform steps (backup, dirty repos).
gates_enforced: []
gates_rationale: operational skill; WP Gate applicable only when creating a new WP,
  not for operational calls
gates_required: []
interaction: multi-step
layer: L1
name: week-close
routing:
  deterministic: false
  executor: sonnet
status: active
triggers:
  phrases: []
  slash:
  - /week-close
version: 1.2.0
---

# Week Close (weekly closing protocol)

> **Role:** Planner (DP.ROLE.066) runs the weekly ritual; Strategist (R1) joins on priority review trigger (DP.SC.051). **Budget:** ~30 min.
> **Principle:** SKILL.md = L1 platform file. The user does not edit it directly — only via `extensions/`.
> **Text style:** the pilot reads the week retrospective and the new WeekPlan → synthesize all text in conversational style (S0 base + S1 author, source DP.SC.050): plain language, no machine labels, main point first, Role Performer codes and paths are not the subject.

## When to use

Week Close protocol. 7-day retrospective + carry-over to the new week + platform steps (backup, dirty repos).

## BLOCKING: step-by-step execution

Week Close is a protocol. The blocking requirement is an observable property: **no step is skipped silently**; each step is marked complete before moving to the next.
**Step 0 — FIRST action:** record the list of steps right now (before any other action) — in TodoWrite, or if unavailable, as explicit numbering in the response.
The default tool is TodoWrite: each algorithm step → a separate task (pending → in_progress → completed). **TodoWrite unavailable** (on models newer than Sonnet 4.6, the client does not provide this tool by default — enable it with `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` in the `env` settings, issue #1216) → notify the pilot in one line, track steps with explicit numbering ("Step X of Y: <name> — done"), record the substitution in the closing report (issues #561, #563).

## Algorithm

### 0. Extensions (before)
Load: `bash .claude/scripts/load-extensions.sh week-close before`. Exit 0 → `Read` each file from the output (alphabetic) → execute as the first steps. Exit 1 → skip. Supports `extensions/week-close.before.md` AND `extensions/week-close.before.<suffix>.md`.

### 1. Collect data for 7 days

**Commits:**
```bash
for repo in $(ls {{WORKSPACE_DIR}}/); do
  if [ -d {{WORKSPACE_DIR}}/$repo/.git ]; then
    commits=$(git -C {{WORKSPACE_DIR}}/$repo log --since="last monday 00:00" --until="today 00:00" --oneline --no-merges 2>/dev/null)
    [ -n "$commits" ] && echo "=== $repo ===" && echo "$commits"
  fi
done
```

**Week calendar:**
```bash
bash {{WORKSPACE_DIR}}/scripts/server-calendar.sh --week $(date -v-mon +%Y-%m-%d 2>/dev/null || date -d "last monday" +%Y-%m-%d)
```
Compare planned meetings/tasks against actuals: what happened, what was rescheduled, what was cancelled. For tasks with reports (🔧 backup stress-test, etc.) — verify the artifact exists.

Match commits and the calendar against Role Performer items in WeekPlan → assign statuses (done/partial/not started).

### 2. Headless week-review (if launchd Mon 00:00 is enabled)

> **Conditional step:** if launched via `strategist.sh week-review` (Mon 00:00 launchd) — the algorithm runs through `{{IWE_TEMPLATE}}/roles/strategist/prompts/week-review.md`. In interactive mode `/week-close` (Sunday evening) — execute the following steps manually.

### 3. Retrospective (closed/partial/not_started/blocked)

**3a.** Closed Role Performer items: what was done, key artifacts, weekly multiplier.
**3b.** Partial: % completion, what remains, carry-over to W+1.
**3c.** Not started: reason, carry-over or close.
**3d.** Blocked: blocker, ETA for unblocking.

### 4. Weekly metrics

- Completion rate: X/Y Role Performer items (N%)
- Total commits, active days
- WakaTime weekly total (physical time)
- Budget closed (sum of done × budget + partial % × budget)
- Weekly multiplier = Budget closed / WakaTime
- **Hypothesis calibration (WP-496, from step 6a):** N entries reviewed for the week; of those with confidence ≥80% — the share that was confirmed (threshold: ≥0.9 of stated confidence, otherwise "confidence overestimated" — flag explicitly in WeekReport). If no reviews happened this week — do not calculate, skip the line.

### 5. Carry-over → W+1

Incomplete Role Performer items with pending/in_progress statuses → carry over to the new WeekPlan W{N+1} (created automatically by session-prep at Mon 04:00, or manually).

### 5b. Pending phases inside active Role Performer items (B-005)

> **Why:** carry-over §5 operates at the Role Performer item level (status: in_progress → carry-over). Pending **phases** inside phase tables of context files can be lost: if the parent item is `in_progress` — a pending phase is not surfaced automatically; if the parent moved to `done` — the phase is lost along with the context file.

```bash
bash ${IWE_SCRIPTS}/pending-phases-sweep.sh
```

The script scans all `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/WP-*.md` with `status: in_progress` (or no explicit status), extracts phase-table rows with status `⏳ pending` / `pending`, and outputs a summary in the format:

```
WP-NNN: pending phases (M):
  Px — <phase description>
  Py — <phase description>
```

For each pending phase, decide: **(a)** do it this week → add to W{N+1} as an explicit item; **(b)** re-assess (blocker? outdated?); **(c)** leave as-is (if waiting for an external event — record the expected trigger).

If the script is not present — fallback: `grep -l "status: in_progress" {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/WP-*.md` → for each, run `grep -E "⏳.*pending|Phase[0-9]+.*pending"`.

### 6. Captures and lessons

- Review `inbox/fleeting-notes.md` for the week → route any unprocessed items.
- Session lessons → MEMORY.md + thematic `lessons_*.md` (if present).
- Week drift-scan: what in MEMORY.md has become outdated over the past 7 days.
- **Transfer completeness check before archiving (WP-5, 2026-07-10):** `bash {{IWE_SCRIPTS}}/check-wp-transfer-completeness.sh --all "${IWE_ROOT:-$HOME/IWE}"` against `inbox/WP-N/` — outputs `results_not_captured` flags (set on close without a filled `results_in`) and files in subfolders not accounted for in the main context file. For each warning — the pilot decides: (a) knowledge transfer is genuinely needed, find the destination; (b) file is technical/outdated, can be left; (c) fill in `results_in` retroactively. Does not block Close.

### 6a. Hypothesis log review (LPF, WP-496)

> Regulation: `memory/lpf-hypothesis-log.md`. Log: `{{GOVERNANCE_REPO}}/current/hypotheses-log.md`.

1. Read `hypotheses-log.md` — filter entries with status "under review" AND review date ≤ today. Entries with status "draft" (not confirmed by pilot Note-Review) — skip; they are not in the review cycle.
2. For each matching entry: compare the falsification criterion against available evidence (week commits, `domain_event`, infrastructure logs, facts from retrospective §3-4 of this protocol).
3. Propose a verdict: confirmed / refuted / partially confirmed / not applicable (if the criterion condition was physically not met — e.g., a dependent artifact was not delivered — the hypothesis is not testable, not "refuted").
4. The pilot approves or edits the verdict → record as a **new** entry at the end of the log with a reference to the original (`Review H-NNN`). Do not edit the original entry.
5. For each verdict — an explicit action (update confidence going forward / add a step to a checklist / create a Role Performer item / record a pattern candidate — §6 Capture-to-Pack). A verdict without an action is "dangling"; do not close the week with dangling verdicts.
6. If there are no entries due for review — mark explicitly "hypothesis review: 0 entries with a due date" in WeekReport (do not skip the step silently).

### 6b. Proactive card archiving cadence check (WP-545 Phase 3)

> **Why:** the Close protocol (§5c) is reactive: it proposes archiving only when the agent happens to touch a specific card. Precedent WP-7 — the archive mechanism existed but was unused for 2 months until a card was noticed manually. This step closes the gap: it scans all of `inbox/` unconditionally every week.

```bash
S="${IWE_SCRIPTS:-$HOME/IWE/scripts}"
PY3="$(bash "$S/lib/find-python3.sh")" && "$PY3" "$S/archive-cadence-sweep.py" --format md
```

Criterion (same as in §5c, not reinvented): `created` >14 days AND card >400 lines, with no `inbox/WP-N/WP-N-archive.md` present. Pilot refusal (`archive_declined: YYYY-MM-DD`) is respected for 14 days from the timestamp.

Output — a list of candidates, items on cooldown, and (diagnostically) discrepancies between the `archive:` field and the actual file. **Do not archive automatically** — only insert the list into WeekReport (§8) as an explicit recommendation; the pilot decides on each card at the next opening (via the §5c reactive mechanism).

### 7. Platform steps

#### 7a. Backup health check

> Required step before backup. Runs `iwe-backup-check.sh` (WP-317 supplement).
> **issue #880:** `backup_enabled: false` in `params.yaml` → the user manages their own backup via a custom extension (`week-close.after.*.md`) — skip 7a and 7b entirely, do not run the built-in check/backup at all.

```bash
grep -qE '^backup_enabled:[[:space:]]*false([[:space:]]*(#.*)?)?$' "${WORKSPACE_DIR}/params.yaml" 2>/dev/null && BACKUP_DISABLED=1 || BACKUP_DISABLED=0
```

`BACKUP_DISABLED=1` → skip 7a and 7b, proceed to 7c. Otherwise:

```bash
bash ${IWE_SCRIPTS}/iwe-backup-check.sh
```

If it returns ❌ (exit 2) — resolve critical gaps BEFORE backup (backup older than 14 days, no backup directory — default is iCloud, or `backup_dir` from `params.yaml` if set).  
If it returns ⚠️ (exit 1) — record warnings in WeekReport, continue.  
If ✅ (exit 0) — backup is healthy.

#### 7b. IWE backup to iCloud

> Conditional step: macOS with iCloud Drive only, and only if `BACKUP_DISABLED=0` (see 7a). Run ONLY if 7a did not return ❌.

```bash
${IWE_SCRIPTS}/backup-icloud.sh
```

Archive of all IWE files (excluding `.git`, `node_modules`, `.venv`) → iCloud Drive. Keeps the last 4 archives.

#### 7c. Uncommitted files scan

```bash
${IWE_SCRIPTS}/check-dirty-repos.sh
```

If dirty repos are found → commit and push BEFORE completing Week Close.

#### 7d. Memory Validate (T22b, WP-217 Phase 10.2)

```bash
bash ${IWE_SCRIPTS}/memory-bleed.sh
```

**Violations** (HOT limit, orphans, superseded_by without a reference) → fix before the Week Close commit.
**Horizon downgrade candidates** → informational; the user decides at the next Month Close.

#### 7e. Memory maintenance (T, SC.024.3 §5)

> Health check for static context load. Flags are informational; the user decides.

```bash
IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
MEMORY_DIR="$IWE_ROOT/memory"
echo "=== distinctions.md ===" && wc -l {{WORKSPACE_DIR}}/.claude/rules/distinctions.md
echo "=== MEMORY.md ===" && wc -l "$MEMORY_DIR/MEMORY.md"
echo "=== memory/ files (mtime >14d) ===" && find "$MEMORY_DIR" -name "*.md" -mtime +14 -not -name "MEMORY.md" -not -path "*/archive/*" | sort
```

| Metric | Threshold | Action |
|--------|-----------|--------|
| distinctions.md lines | **> 150** | Drift flag (threshold is synchronized with the executable `verify-context-budget.sh` — issue #736, same file, same canon; not two diverging numbers). Record in Week Report, add a task to the tech debt backlog. |
| MEMORY.md lines | **> 200** | Limit exceeded flag. Propose archiving old feedback to `archive/`. |
| memory/*.md not accessed > 14d | **> 5 files** | Propose downgrading `horizon: warm` (user decides at Month Close). |

#### 7f. Hindsight health check (only when explicitly connected)

> Hindsight is an optional L2 extension. Week Close checks an already-connected
> service but does not start it automatically and does not treat the absence
> of the service as a closing error.

```bash
HINDSIGHT_CONFIGURED=0
[ -f "$HOME/.iwe/hindsight.env" ] && HINDSIGHT_CONFIGURED=1
[ "${IWE_HINDSIGHT_RETAIN:-}" = "1" ] && HINDSIGHT_CONFIGURED=1

if [ "$HINDSIGHT_CONFIGURED" -eq 0 ]; then
  echo "N/A: Hindsight not configured (optional extension)"
elif ! command -v docker >/dev/null 2>&1; then
  echo "⚠️ Hindsight is connected but Docker is unavailable — run only after user decision"
else
  echo "=== Hindsight container ==="
  docker ps --format "table {{.Names}}\t{{.Status}}" | grep iwe-hindsight || \
    echo "⚠️ Container not running — run only after user decision"
  echo "=== Hindsight log (last 20) ==="
  tail -20 "$HOME/.iwe/hindsight.log" 2>/dev/null || echo "⚠️ No log file"
  if docker ps --format "{{.Names}}" | grep -qx iwe-hindsight; then
    docker exec iwe-hindsight ls -lh /data/hindsight.db
  fi
fi
```

**Checks when Hindsight is connected:**
- Container `iwe-hindsight` → status `Up`; if not running — notify the user, do not start automatically.
- Log has no `FAIL` entries for the week. If FAIL entries exist → `docker logs iwe-hindsight` → diagnose (OpenAI key? network? disk?)
- DB size: if >100MB → rotation flag.
- **Whitelist review:** do any skills created this week need to be added to `RECALL_SKILLS`?

### 8. Record results in WeekReport (split, OPT-5)

> **Split (WP-297 OPT-5):** week facts live in `WeekReport W{N}`, not in WeekPlan. WeekPlan contains intentions only.

1. Open the current `WeekReport W{N} YYYY-MM-DD.md` (if it does not exist — create it during the next session-prep, see CLAUDE.md §9 split rule).
2. Fill in the "Results W{N}" section (structure — see `roles/strategist/prompts/week-review.md`).
3. Also fill in the **"Role Performer ↔ Dissatisfaction cross-reference"** section in WeekPlan W{N}: for each closed Role Performer item — which dissatisfaction was resolved / which R-result was advanced? This is the input for Strategy Session W{N+1}. **Do not leave a placeholder row** (`| ... | ... |`) without at least one real row — go through the list of closed Role Performer items (step 5) and for each check `docs/Dissatisfactions.md` for an explicit link (the "Related Role Performer" field in the dissatisfaction registry, or a back-reference in the Role Performer context); no link → "none" in the column, not a blank row.
4. Fill in the **"Recommended changes to dissatisfactions and Strategy"** section in WeekPlan W{N} — what was learned this week → what to change in `Dissatisfactions.md` / `Strategy.md`.

### 9. Extensions (after)

Load: `bash .claude/scripts/load-extensions.sh week-close after`. Exit 0 → `Read` each file from the output (alphabetic) → execute. Exit 1 → skip. Supports `extensions/week-close.after.md` AND `extensions/week-close.after.<suffix>.md`.

### 10. Week quality assessment (WP-310 Gap-A)

Ask the user: **"Rate the quality of the week 1-5:  
1 = mechanical (running on autopilot, mind was not engaged)  
2 = surface-level (aware of what happened and what was done — no pattern analysis)  
3 = normal (deliberate, patterns visible, no breakthroughs)  
4 = good (concrete decisions, something understood in a new way)  
5 = breakthrough (understanding of the system changed, key decisions made)"**

Answer N → include `q:N` in the commit message for the next step.  
If the user skips → commit without `q:`.

### 11. Commit the governance repo

```bash
(cd {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}
git status --short
# NOT git add -A/git add ./git add -u — AGENTS.md CRITICAL (may capture work of other agents)
# Stage ONLY files modified in steps 1-10 (into an array for pathspec):
WC_FILES=(<each file by explicit path: WeekPlan, WeekReport, WP-REGISTRY, inbox/WP-*.md, etc.>)
git add "${WC_FILES[@]}"
git diff --cached --name-only  # verify scope — week-close files only
# pathspec after `--`: commit ONLY own files, do not sweep others' index
git commit -m "week-close: W{N} results q:{score}" -- "${WC_FILES[@]}"
git push
)
```

### 12. Verification (Haiku R23)

Run sub-agent Haiku in role R23 Verifier (context isolation).
Pass: checklist, week results, list of updated files.

---

## Week Close Checklist

- [ ] All changes committed and pushed (across all repos)
- [ ] 7-day retrospective: closed/partial/not_started/blocked items resolved
- [ ] Metrics calculated (completion rate, multiplier)
- [ ] Carry-over → W+1 (or explicitly "none")
- [ ] Pending phases of active Role Performer items swept (`pending-phases-sweep.sh` or fallback grep) — decisions recorded
- [ ] Card archiving cadence checked (`archive-cadence-sweep.py`) — list in WeekReport
- [ ] Backlog `docs/Backlog.md` reviewed in the next Strategy Session (either triggers activated, or explicitly "B-NNN lives without triggers")
- [ ] Captures routed, lessons recorded
- [ ] Week drift-scan: outdated facts updated
- [ ] Backup health check (iwe-backup-check.sh) completed
- [ ] iCloud backup completed (if macOS)
- [ ] Dirty repos: 0 (or explicitly ignored)
- [ ] Memory maintenance: distinctions.md/MEMORY.md/memory/*.md checked, flags recorded (or "healthy")
- [ ] W{N} results recorded in WeekPlan
- [ ] Extensions `.after.md` executed (if present)
- [ ] Hindsight: `N/A` (not configured), or if explicitly connected — container/log/DB size checked; no auto-start occurred
- [ ] Week quality rating q:N set (1-5) and included in commit message
- [ ] Governance repo committed
- [ ] Week peer sessions: WP Gate checked (sessions from 2026-06-09 only):
  ```bash
  find ${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/sessions -type f -name "peer-prompt.md" \
    | awk -F/ '{d=$(NF-1); match(d,/^[0-9]{4}-[0-9]{2}-[0-9]{2}/); print substr(d,RSTART,RLENGTH) " " $0}' \
    | awk '$1 >= "2026-06-09" {print $2}' \
    | xargs -I{} sh -c 'grep -q "Opening (WP Gate)" "{}" || echo "WP-GATE-MISS: {}"'
  # Record misses in inbox/bugs/bug-YYYY-MM-DD-wp-gate-miss.md or "no misses"
  ```

All ✅ → "Week closed." Otherwise — specify what remains.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
