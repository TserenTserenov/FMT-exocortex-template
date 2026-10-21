---
agents: single
argument-hint: ''
browser_safe: false
description: Month Close protocol. Stage 7 of the VDV v9 cascade (PD.METHOD.008).
  Triggered on the first Monday of the month, before the Strategy Session.
gates_enforced: []
gates_rationale: operational skill; WP Gate applicable only when creating a new WP,
  not for operational calls
gates_required: []
interaction: multi-step
layer: L1
name: month-close
routing:
  deterministic: false
  executor: opus
status: active
triggers:
  phrases: []
  slash:
  - /month-close
version: 1.0.0
---

# Month Close (monthly closing protocol)

> **Role:** R1 Strategist (execution), R23 Verifier (Haiku, checklist). **Budget:** 30–45 min.
> **Trigger:** first Monday of the month, before the Strategy Session of week 1.
> **Principle:** Month Close = aggregation of 4–5 Week Closes + re-evaluation of phase/caliber. It does not repeat Week Close — it builds on its outputs.
> **Position in VDV v9:** stage 7 "Monthly Closing". Input = Report W{N} of the previous month + Strategy.md. Output = Strategy.md § Monthly Results (R1-RN) + `archive/MonthClose YYYY-MM.md`.
> **SKILL.md = L1 platform file.** The user does not edit it directly — only via `extensions/`.

## When to use

Month Close protocol. Stage 7 of the VDV v9 cascade (PD.METHOD.008). Triggered on the first Monday of the month, before the Strategy Session.

## BLOCKING: step-by-step execution

Month Close is a protocol. Execute it ONLY step by step via TodoWrite.
**Step 0 — FIRST action:** create the task list right now (before any other action).
Each algorithm step → a separate task (pending → in_progress → completed).
Proceed to the next step ONLY after marking the current one complete. If a step is impossible → mark it blocked (do not skip silently).

## Preconditions (check BEFORE starting)

1. **Is today the first Monday of the month?** If not — STOP, suggest running on the correct day. Exception: a missed Month Close for the previous month (run before mid-month with an explicit period specified).
2. **Was the previous week's Week Close completed?** Report W{N-1} exists in `current/` or `archive/`. If not — STOP, run `/week-close` first.
3. **Is the previous month's Month Close archived?** `archive/MonthClose YYYY-MM.md` exists (for months after MVP). If not (first run in May 2026) — skip this check.

## Algorithm

### 0. Extensions (before)
Load: `bash .claude/scripts/load-extensions.sh month-close before`. Exit 0 → `Read` each file from the output (alphabetic) → execute as the first steps. Exit 1 → skip. Supports `extensions/month-close.before.md` AND `extensions/month-close.before.<suffix>.md`.

### 1. Data collection (agent)

**1a. Period.** Define the month boundaries: `YYYY-MM-01 .. YYYY-MM-{last}` (in practice — the last Week Close of the previous month).

**1b. Commits for the month.**

```bash
for repo in $(ls ${IWE_WORKSPACE:-$HOME/IWE}/); do
  if [ -d ${IWE_WORKSPACE:-$HOME/IWE}/$repo/.git ]; then
    count=$(git -C ${IWE_WORKSPACE:-$HOME/IWE}/$repo log --since="$MONTH_START" --until="$MONTH_END" --oneline --no-merges 2>/dev/null | wc -l)
    [ "$count" -gt 0 ] && echo "$repo: $count"
  fi
done
```

**1c. Week Reports for the month.** Collect `current/Report W{N}.md` for 4–5 weeks → list of closed/deferred Work Products, multipliers, weekly TOSes.

**1d. Monthly drift.** `bash ${IWE_SCRIPTS:-$HOME/IWE/scripts}/iwe-drift.sh` → identify pairs where lag grew over the month.

**1e. Decision log.** Canonical file: `${IWE_GOVERNANCE_REPO:-DS-strategy}/decisions/decision-log-YYYY-MM.md` (WP-109 Phase 7, one file per month). Before reading, perform a compatible migration: if the canonical file does not exist but `${IWE_GOVERNANCE_REPO:-DS-strategy}/exocortex/decisions/decision-log-YYYY-MM.md` does, create `decisions/` and move the old file there; if both exist, do not merge or silently overwrite — notify the pilot of the discrepancy and read the canonical file. If the file is missing or contains no entries for the month, record "no decisions registered for the month" and continue; a missing file on an empty month is not a Month Close error.

**1f. Memory file metrics (WP-217 Phase 10.2).**

```bash
bash ${IWE_SCRIPTS:-$HOME/IWE/scripts}/memory-health.sh
bash ${IWE_SCRIPTS:-$HOME/IWE/scripts}/memory-bleed.sh
```

If the HOT limit is exceeded → lower the horizon in the frontmatter of the relevant files BEFORE proceeding. Demotion candidates from the bleed report → record in `MonthClose YYYY-MM.md § T-checklist T23`.

**1g. Stable inputs (PD.METHOD.008 stage 7, inputs 5+6).** Read `${IWE_GOVERNANCE_REPO:-DS-strategy}/docs/Dissatisfactions.md` (unsatisfied needs list) + `${IWE_GOVERNANCE_REPO:-DS-strategy}/docs/Projects.md` (project list P1-P6). Without these, the project review (Step 4) and new-R promotion (Step 9) lack context.

### 2. Monthly multiplier

> Aggregation of weekly multipliers — NOT an average of daily values.

1. **WakaTime for the month** — total physical time across all days of the month
2. **Budget closed for the month** — sum of `Budget closed` from all Week Reports of the month
3. **Monthly multiplier** = Budget closed / WakaTime. Format: `N.Nx`
4. **Trend** — compare with the previous month (growth / decline / stable)

### 3. Metrics retrospective (human + agent)

**3a. Strategic position phase (PD.FORM.078).**

Current declaration in Strategy.md § Monthly state: [Development / Chaos / Ceiling / Pivot]. Verify against the 5 signals in PD.FORM.078:
- Did the transition signals recorded at the start of the month materialize?
- Is the phase stable, shifted, or does it require revision?
- Decision: keep / shift → record in `MonthClose YYYY-MM.md`.

**3b. Personal caliber (PD.CHR.007).**

Current caliber in Strategy.md (example: 3, target 4 by end of 2026). Questions:
- Did any events or results during the month signal growth?
- The gap across three dimensions (horizon / bus factor / public presence) — which one narrowed?
- Recalculation: keep / raise by 0.5 / require additional actions.

### 4. Project review P1-P6 (human)

Using `docs/Projects.md`, for each active project:
- Which monthly R-results advanced P?
- P stalled (0 hours over the month) → signal: is P still relevant? Is it time to decompose or close it?
- Hour balance across P — is there a skew, and does it match the strategy?

Output: 1–2 paragraphs in `MonthClose YYYY-MM.md § Project review`.

### 5. Monthly R-questionnaire (human)

Open `memory/r-questionnaire.md` → section "Month Close — 6 additional questions" → answer sequentially (M1-M6).

**Special status of M6 (decommission):** the answer is a list of T-actions for transitioning to dormant/archived. Before the question, the agent runs `bash ${IWE_SCRIPTS:-$HOME/IWE/scripts}/iwe-drift.sh` + reads `sync-manifest.yaml § activity_checks:` → presents candidates.

Time: 20–30 min.

### 6. Monthly T-checklist (agent + human)

Open `memory/t-checklist.md` → section "Month Close" → execute T23–T25:

- **T23 Monthly Lesson Hygiene.** NOT the daily/weekly rotation (that is already done in Day/Week Close). The monthly scale means **merging thematic files, removing empty categories, verifying that `lessons_*.md` files have not grown beyond the limit**. Review the MEMORY.md "Lessons" section and thematic `lessons_*.md` files. MEMORY.md "Lessons" limit: ≤8 lines.
- **T24 Protocol audit for skippable steps.** Review `memory/protocol-*.md` and `.claude/skills/*/SKILL.md` — identify steps that the agent regularly skips (per `behaviour-report.sh`) or that the human bypasses silently. Decision: delete / rewrite / keep as-is.
- **T25 Decommission triage.** Apply decisions from Step 7 (add-on). T25 here is a pointer, not a duplicate. See Step 7 below.

### 7. Add-on: Decommission triage (WP-226 Phase 2) — T25 implementation

> Step 5 M6 collects candidates → **Step 7 applies** the decisions → Step 6 T25 = pointer to this step. Single execution point (avoid triple runs).

For each candidate from Step 5 M6:
1. Check: does the action have a measurable trace (entry in `sync-manifest.yaml § activity_checks:`)? If not — update the manifest before deciding.
2. Actual frequency over 3 windows: `bash ${IWE_SCRIPTS:-$HOME/IWE/scripts}/iwe-drift.sh --activity` → counter.
3. Human decision:
   - **active → dormant:** move to the "Dormant actions" section of the relevant checklist, mark `dormant_from: YYYY-MM-DD`
   - **dormant → archived:** move to `${IWE_GOVERNANCE_REPO:-DS-strategy}/archive/retired-actions.md` with a reason
   - **dormant → active (reactivation):** return to the main checklist, mark `reactivated_from: YYYY-MM-DD`, add a reason.
4. Record decisions in `MonthClose YYYY-MM.md § Decommission`.

### 8. Add-on: Decision log review (WP-226 Phase 2)

> Review of the month's decisions from the WP-109 Phase 7 decision register.

1. Open the canonical file already prepared in step 1e: `${IWE_GOVERNANCE_REPO:-DS-strategy}/decisions/decision-log-YYYY-MM.md`. If the file is missing or contains no decisions for the month — record in `MonthClose YYYY-MM.md § Decision log review`: "No decisions registered for the month" and proceed to step 9; the "minimum 1 insight" requirement below applies only when the log contains decisions.
2. For each decision of the month, answer:
   - **Turned out correct / incorrect / too early to judge?**
   - If incorrect: what signal was missed? → candidate for `memory/feedback_*.md` as a lesson.
   - If too early to judge: when to revisit? → record in trigger.
3. Write conclusions in `MonthClose YYYY-MM.md § Decision log review` — minimum 1 insight (if there is nothing to write, that itself signals decisions are not being tracked).

### 9. Update Strategy.md § Monthly results (human)

1. Closed R{N} — mark done, brief summary ("what was achieved", "what remains").
2. Deferred R{N} — move to the next month (with an explicit reason: "not achieved due to X").
3. New R{N} for the next month — from the Strategy.md § "Draft: {next month}" → promote to "Focus".
4. If the phase shifted (step 3a) → update the "Monthly state — strategic position phase" section.
5. If caliber shifted (step 3b) → update the "Personal caliber" section.

**EXTENSION POINT (month-close after):** `bash .claude/scripts/load-extensions.sh month-close after` — exit 0 → `Read` each file from the output (alphabetic) → execute. Exit 1 → skip. Supports `extensions/month-close.after.md` AND `extensions/month-close.after.<suffix>.md`.

### 10. Write `MonthClose YYYY-MM.md`

Create `${IWE_GOVERNANCE_REPO:-DS-strategy}/archive/MonthClose YYYY-MM.md` using the template (see "Report template" section below). All sections filled in, all placeholders replaced.

### 11. Commit ${IWE_GOVERNANCE_REPO:-DS-strategy}

```bash
(cd ${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}
# Do NOT use `git add -A`: in a shared clone (multi-agent) it sweeps other agents' pre-staged changes → mis-attribution
# (see sessions/2026-06/2026-06-20-39-*). List month-close artifacts EXPLICITLY:
MONTH_FILES=(
  "archive/MonthClose YYYY-MM.md"
  "docs/Strategy.md"
  # + archive/retired-actions.md, decisions/decision-log-YYYY-MM.md,
  #   memory/t-checklist.md — add those actually edited in this month-close
)
git add "${MONTH_FILES[@]}"
git commit -m "month-close: close YYYY-MM" -- "${MONTH_FILES[@]}"
)
```

Push on explicit trigger "push".

### 12. Verification (Haiku R23)

Launch a Haiku sub-agent in the R23 Verifier role (context isolation).
Pass: (1) the Month Close checklist below, (2) `MonthClose YYYY-MM.md`, (3) changes to Strategy.md.
On ❌ — fix before showing to the user.

---

## Report template `MonthClose YYYY-MM.md`

```markdown
---
type: month-close-report
period: YYYY-MM
closed: YYYY-MM-DD
closer: R1 Strategist
verified: R23 Verifier
---

# Month Close YYYY-MM

## Overview
- Period: YYYY-MM-01 .. YYYY-MM-{last}
- WakaTime for month: {h}
- Budget closed: {h}
- Multiplier: {N.Nx} (previous month: {N.Nx})
- Commits: {N}
- Closed Work Products: {N}
- Deferred Work Products: {N}

## Strategic position phase (PD.FORM.078)
- Declaration at month start: {Development | Chaos | Ceiling | Pivot}
- Actual: {confirmed | shifted to Y}
- Signals: {what was observed}
- Decision: {keep Development / shift to Y}

## Caliber (PD.CHR.007)
- Current: {N}
- Gap: {horizon / bus factor / public presence — what moved}
- Recalculation: {keep N / raise to N+0.5}

## Project review
- P1 Creator: {h, moved / stalled, reason}
- P2 Ecosystem+MIM: {...}
- P3 Platform+IWE: {...}
- P4 Bot: {...}
- P5 Personal development: {...}
- P6 Inner circle: {...}
- Balance: {skew toward X, matches / does not match strategy}

## R-questionnaire (M1-M6)
- **M1:** ...
- **M2:** ...
- **M3:** ...
- **M4:** ...
- **M5:** ...
- **M6 Decommission:** {list of T-actions for dormant/archived transitions}

## Decommission (applied transitions)
| Action | Was | Became | Reason |
|--------|-----|--------|--------|
| T-NN | active | dormant | 3 windows without triggering |
| ... | | | |

## Decision log review
- Decision X (YYYY-MM-DD): {turned out correct / incorrect / too early to judge}
- ...
- **Insight:** {1+ conclusion}

## Monthly R{N} results (copy from Strategy.md)
- R1 ...: {done | deferred | changed}
- R2 ...: ...

## Foundation for next month
- R1' {draft}
- R2' {draft}
- Red line: {primary goal}

## T-checklist (T23-T25)
- [x] T23 Lesson Hygiene: {what was changed in MEMORY.md}
- [x] T24 Protocol audit: {which steps were revised}
- [x] T25 Decommission triage: {see table above}
```

---

## Month Close checklist

- [ ] First Monday of the month (or explicit justification for the delay)
- [ ] Previous week's Week Close completed
- [ ] Commits for the month collected across all repos
- [ ] Monthly multiplier calculated + comparison with previous month
- [ ] Strategic position phase reviewed (PD.FORM.078)
- [ ] Caliber recalculated (PD.CHR.007)
- [ ] Project review P1-P6 completed
- [ ] R-questionnaire M1-M6 answered (answers in `MonthClose YYYY-MM.md`)
- [ ] T-checklist T23-T25 completed
- [ ] Decommission triage applied (transition table)
- [ ] Decision log review: minimum 1 insight
- [ ] Strategy.md § Monthly results updated (R{N} closed, deferred, new ones created)
- [ ] Strategy.md § Next-month draft promoted to Focus
- [ ] If phase/caliber shifted — corresponding Strategy.md sections updated
- [ ] `archive/MonthClose YYYY-MM.md` created, all sections filled in
- [ ] ${IWE_GOVERNANCE_REPO:-DS-strategy} committed
- [ ] R23 verification completed (or explicitly skipped)

All ✅ → "Month closed. Ready for the Strategy Session of week 1." Otherwise — indicate what remains.

---

## Relationship to other ORZ scales

- **Does not replace `/week-close`** — Month Close depends on a fresh Week Report from the previous week. Run `/week-close` first, then `/month-close`.
- **Precedes the Strategy Session of week 1** — its input is the just-updated Strategy.md + `MonthClose YYYY-MM.md`. Do not merge into one session: they use different roles (R23 Verifier for Close, R1 Strategist for Session) and produce different artifacts.
- **Trigger outside the cascade:** the Strategy Session of the first week of the month requires Month Close to be completed beforehand. The DayPlan for the first Monday contains two lines: "Month Close YYYY-MM" (0.75h) and "Strategy Session W{N}" (1–2h).

## Relationship to Pack

- **PD.METHOD.008 § VDV v9 cascade** — canonical source for stage 7 "Monthly Closing"
- **PD.FORM.078** — strategic position phases (step 3a)
- **PD.CHR.007** — personal caliber (step 3b)
- **DP.SC.024** — IWE maintenance promise; scenario SC.024.4 "Monthly maintenance" is implemented by this skill

## History

- 2026-04-24: skill created (WP-196 Phase 12.2 + WP-226 Phase 2 add-ons). First run — May 4, 2026, closing April.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
