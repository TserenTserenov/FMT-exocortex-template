---
gate: user
step: 06a
title: 'Plan: candidate pool'
---

# Step 06a: Plan — candidate pool

## IPO

| | |
|---|---|
| **Input** | WeekPlan draft, active R{N} for the month, carry-over items, inbox proposals, new Work Products from calibration (05b), "Focus: {month}" section from `docs/Strategy.md` (WP-518, 08.09.2026 — previously it was silently assumed that step 04 had already read it earlier in the same Session; found on 07.09 that this is not always the case) |
| **Action** | Build the candidate pool and assign priorities |
| **Output** | Candidate pool with priorities (🔴/🟡/🟢/⚪) |

## Instructions for Claude

> Method: `PD.METHOD.017` Work Product Selection.

0. **Mandatory cross-check against the monthly frame (WP-518, 08.09.2026) — by analogy with the already-mandatory pass through `Backlog.md` in step 07.** Observed live on 07.09: an entire week-rebuild Session never once cross-checked against the already-approved September plan (`docs/Strategy.md`, "Focus: {month}" section), even though step 04 formally exists for exactly that purpose — the Session simply did not walk through steps 00→08 end-to-end.

   - Read the active "Focus: {month}" section in `docs/Strategy.md` (or `current/monthly-priorities.md` if present in the installation — that file is the SoT for the monthly frame).
   - Optional accelerator (not included in the Template delivery, issue #1100): if `$IWE_SCRIPTS/strategy-focus-hash.sh` is present in the installation, run `bash "$IWE_SCRIPTS/strategy-focus-hash.sh" "<path to Strategy.md>"` and record the result as `gate_reviews.06a.monthly_context_hash` in the WeekPlan. This does not prove you understood the text — only that the pool presentation is tied to a specific, hash-pinned version of the "Focus" section at the time of presentation (do not confuse with a cognitive guarantee).
   - If the Script is absent in this installation (normal for a clean install) — do not block: notify the pilot "monthly frame cross-check performed without machine version binding" and continue without a hash.

1. **Candidate pool** — go through the proposed Work Products from the session-prep draft:
   - (a) active R{N} for the month
   - (b) carry-over items with prioritization
   - (c) proposals from inbox triage (step 02)
   - (d) new Work Products from calibration (step 05b, if created)

   **Hypothesis stake (if a hypotheses log `current/hypotheses-log.md` is connected in the installation):** for each Work Product in the pool, mark which hypothesis it stakes on (entry number or "no stake"). A Work Product with no stake and no direct link to an active R{N} for the month is a candidate for "not taking" in step 06b and is not taken silently by default. If the log is absent in the installation → skip this item; it does not block the pool.

2. **Work mode (triad) — two independent axes; do not conflate.**

   **Axis 1 — mode (Current / Important / Urgent):** for each Work Product, determine the mode using the Pipeline model (see the Distinction [[Current ≠ Important ≠ Urgent]]):
   - 🔥 **Urgent** — a threat to Pipeline stoppage (production is down, billing is broken, blocking other agents/users, data loss, security-critical). **Only this.** Urgent items are normally NOT planned into the week — they interrupt and are fixed immediately; if one appears in the pool, the Pipeline is already stopped.
   - 🟡 **Important (development)** — raises the norm above the previous baseline (new capability, modernization, strategic R{N}). This is the core of a strategic week: important work is systematically displaced by routine and false-urgency, so it must be protected deliberately.
   - 🟢 **Current (routine)** — standard operational work that keeps the Pipeline at its planned norm (support, routine tasks, operational non-event processing).

   **Axis 2 — deadline (orthogonal to mode):** is there an agreed handoff moment? A deadline can apply to ANY of the three modes and does not by itself make a Work Product urgent (see [[Deadline ≠ Urgency]]). Mark deadlines with a separate label `⏰ by DD.MM`; do not use deadlines to elevate the mode.

   **Critical check (common error):** "deadline is approaching" ≠ "urgent". Strong dissatisfaction / high motivation ≠ "urgent" — that is important. Urgent = only a physical threat to Pipeline stoppage.

3. **Priority = function of mode + deadline + Theory of Constraints.** Order of inclusion in the week: real 🔥urgent (if not yet closed) → 🟡important under the week's Theory of Constraints and active R{N} → 🟡important with a near ⏰deadline → 🟢routine (the minimum necessary to hold the norm). The goal of the week is to protect the 🟡important quota, not to let routine and ⏰deadlines displace development.

4. **Data freshness and machine confirmation (WP-518, 08.09.2026).**

   **Base path — manual (clean Template installation, no week Scripts present).**
   You assemble the pool yourself from the sources in item 1 using the explicitly stated selection rule (priority + link to active R{N} for the month). This is your judgment, not a deterministic code-based selection, so:

   - State the selection rule you used to the pilot and warn them: free LLM judgment may diverge from the stated rule (found on 07.09: 6 excluded Work Products were themselves P1) — the pilot reviews the pool composition visually, without relying on the rule statement.
   - There is no machine version binding (`content_hash`) or `reason_code` per record in a manual assembly. If the pilot asks why a specific Work Product did not make it into the pool — answer honestly from your selection rule; do not fabricate a reference to a non-existent selection code.
   - Before presenting the pool, check the freshness of the governance repo checkout yourself (`git status` / `git fetch`): manual assembly from a stale tree produces an out-of-date pool. If you are behind — synchronize first and rebuild the pool.

   **Optional accelerators — only if installed.** The Scripts `week-open-scaffold.sh`, `week_pool_manifest.py`, and `week-open-llm-fill.py` are not included in the Template delivery (issue #1100) — they are tooling for a specific installation. If the draft came from `week-open-scaffold.sh`, the table composition has already been resolved deterministically by code (`week_pool_manifest.py`), not by your judgment — and different rules apply:

   - If the header of the "Weekly Plan" section contains a line beginning with `⚠️ working tree` (all 4 banner variants — lagging / diverged / `git fetch` failed / no upstream branch — start identically; check by prefix, not by specific wording) — **STOP**: tell the pilot that the pool composition may be out of date, suggest synchronizing the checkout, and rebuilding the draft from scratch. Do not continue confirmation on this banner.
   - Show the pilot the pool table as-is. If the pilot asks why a specific Work Product did not make it into the pool — do not fabricate a reason: the selection already has a `reason_code` on each record (created by code, not by you); explain the meaning of `cap_exceeded_rank_N_of_M` (no room in the shortlist by priority) as-is, including the honest caveat — alignment with the monthly focus is NOT currently part of the ranking (open item WP-518), only priority + Work Product number.
   - If the pool composition changed during the conversation (the pilot manually asked to add/remove a Work Product) — the pool must be rebuilt from scratch using the Script, not edited by hand in the table: otherwise `content_hash` will no longer match the composition actually shown, and step 08 will fail on the cross-check (`strategy-session-checks-runner.sh`, if installed — see step 08).

   **Pilot confirmation — a recorded fact on any path, not a formality.** After the discussion, wait for a LITERAL response from the pilot on the presented pool (not a silent move to the next step) and record the following in WeekPlan frontmatter `gate_reviews.06a`:
   - `pilot_decision: approved | changes_requested | rejected`
   - `pilot_quote`: a short verbatim quote of the pilot's response
   - `status`: `reviewed` (not `confirmed` — that field belongs to the file as a whole, step 08)
   The `content_hash` field exists only on the scripted path — it is written automatically by `week-open-llm-fill.py`; do not overwrite it manually.

5. **Question for the pilot:**
   > "Continue to budgeting / adjust / skip?"
