Execute the "Strategy Session" scenario for the Strategist role (R1).


## Context

- **HUB (personal plans):** $GOV_WT/current/
- **Strategy documents:** $GOV_WT/docs/ (Strategy.md, Dissatisfactions.md, Session Agenda.md)
- **Inbox:** $GOV_WT/inbox/
- **`$GOV_WT`:** the working (isolated) copy of the governance repository; determined by Step 0 of the strategy-session Skill (`.claude/skills/strategy-session/SKILL.md`); build all paths from it, not from the canonical `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}`; publish via `ds-publish.sh` using the publish block in Step 0 of the Skill (all commits in the copy that are absent from `origin/main`, in order; `--branch main` — only for the publisher that knows it from the file text (heuristic: branch from the `--branch` argument parser)), only in isolated mode (in legacy mode without session-guard — use the standard installation method); each write block follows Step 0 of the Skill: `GOV_WT="<path>"; : "${GOV_WT:?}"`, then commands in a subshell `(cd -- "$GOV_WT" || exit 1` … `)`, with no top-level `cd` (blocked by the `destructive-guard.sh` Hook)
- **SPOKE (repo plans):** {{WORKSPACE_DIR}}/*/WORKPLAN.md
- **MEMORY:** ~/.claude/projects/{{CLAUDE_PROJECT_SLUG}}/memory/MEMORY.md

## Precondition

> **The WeekPlan draft has already been created** by the session-prep scenario (Mon 04:00).
> If no draft exists — notify the user and suggest running session-prep.

## Process

> Interactive Session. The user drives it through Claude Code.

#### 0. If this is the first Session of the month — read last month's archive (BLOCKING)

- Check: is today the first Strategy Session of the current month? (Condition: session date ≤ 7th of the month AND the session log (`iwe_sessions_dir`, or `$GOV_WT/sessions` if absent; search both `sessions/YYYY-MM-*.md` and `sessions/YYYY-MM/`) contains no Strategy Session entry for this month)
- If yes:
  1. Find the most recent `$GOV_WT/archive/MonthClose YYYY-MM.md` (for last month)
  2. Read BEFORE Step 1 (mandatory): multiplier, phase, caliber, project revision, decision insights, R-questionnaire, carry-over
  3. Read `$GOV_WT/archive/multiplier-trend.md` (if present) for trend dynamics
  4. Use this data as context during the strategic alignment check (Step 5) and plan formation (Step 6)
- If no (second or later Session of the month) — skip and proceed to Step 1

#### 1. Session Opening

- Find `WeekPlan W*.md` with `status: draft` in `{{GOVERNANCE_REPO}}/current/`
- Show the user a brief summary: agenda, key questions, carry-over
- If today is the first Session of the month — also mention the key figures from MonthClose (multiplier, phase, ✅/🔄 R)
- Ask: "Shall we follow the agenda, or are there urgent items?"

#### 2. Review of the Previous Week

- Work through the "Last week's results" block from the draft
- Discuss with the user: what worked, what did not, and why
- Record conclusions and adjustments

#### 3. Inbox Processing

- Work through the "Inbox" block from the agenda
- For each inbox item: the user decides — add to plan / capture / delete / defer
- Apply decisions immediately (deletion, transfer)

#### 4. Dissatisfactions (NEP)

- Work through the "NEP" block from the agenda
- Close resolved dissatisfactions, discuss new ones
- Update Dissatisfactions.md based on user decisions

#### 5. Strategic Alignment Check

- Work through the "Strategic alignment check" block from the agenda
- **If this is the first Session of the month:** align the new strategy's focus with MonthClose data (multiplier, phase, R results, decision insights) — what was confirmed, what was rejected, what carried over
- Discuss divergences between the strategy and current Work Products
- Update Strategy.md based on user decisions

#### 5b. Caliber Lens (lifework pack)

> Implements Phase 2b of the `PD.METHOD.008` method (strategy session). The Strategist recommendation algorithm is `PD.METHOD.018` § Strategist Recommendation Mechanism. The three fields (V_scope/A_scope/D_scope) and the prohibition on arithmetic are defined in `PD.FORM.091 §6.1`.

1. **Read the tracker:** `$GOV_WT/Lifework/Caliber-artifacts-tracker.md` (if the file does not exist — create it from the Template `{{WORKSPACE_DIR}}/IWE/templates/strategy-skeleton/Lifework/Caliber-artifacts-tracker.md`)
2. **Classify vision → V_scope:** for each PERSISTENT dissatisfaction (NEP) — assign a `PD.FORM.090` category using the verification questions in `PD.FORM.091 §6.1` (1. Self — does it concern the person themselves? 2. Inner circle — does it concern lasting close relationships? 3. Outer circle — does it concern a team/clients/professional network? 4. Community — does it concern a sustained community/direction? 5. Society — does it concern an institution/culture/country? 6. Humanity and generations — does it concern humanity/future generations? FORM.027 9–10 alone does not yield V_scope=6). V_scope = the highest category reached. No persistent NEP in any row → `V_scope = unconfirmed`. One NEP fits multiple rows → status `ambiguous`, clarify through dialogue
3. **Confirm action → A_scope:** the maximum coverage category (`PD.FORM.090`) with an observable produced change or accepted responsibility (completed projects, decisions, external results, Diagnostician confirmation). A lifework document is not required for this Assessment. No confirmed actions yet → `A_scope = unconfirmed` (not "zero")
4. **Audit documentation → D_scope:** the highest category with a mature lifework document — maturity defined by `PD.METHOD.018` § Transition Conditions (the required period varies by transition: ≥6 months for 1→2 and 2→3, ≥1 year for 3→4 and 4→5, ≥3 years for 5→6 — not a single uniform period). Read from `$GOV_WT/Lifework/` (personal documents live there). If the folder is absent or empty → `D_scope = none`; this is NOT a reason to immediately suggest writing a document — the first work object for a new participant is a safe, reversible personal project at level 1 with an observable trace (an action, not a document); the document Template (`lifework-self-charter-template.md` from `PACK-personal/.../lifework-templates/`) is offered only when the turn reaches Step 7 below
5. **Verify completeness of lower D_scope invariants** (`PD.FORM.090 §6`): are all levels 1..D_scope present? Gaps at the bottom → recommend "catch up downward," STOP here (a gap below is higher priority than moving up)
6. **Compare V_scope and A_scope → qualitative status** (ordinal comparison on a single scale, not arithmetic): equal → `aligned`; V one category higher → `adjacent_frontier`; V two or more categories higher → `vision_ahead`; A higher than V → `action_ahead`; V_scope or A_scope = unconfirmed → `unconfirmed`; ambiguous category at Step 2/3 → `ambiguous`
7. **Check local readiness for the next document** (`PD.METHOD.018` § Transition Conditions + § Local Document Gate): has the previous document completed its own test period per the Transition Conditions table (not a single uniform period — see Step 4) AND is the real pattern of the next category already observable in A_scope? The table also provides qualitative transition conditions (size and stability of the circle), not only duration. Mastery stage (`PD.FORM.080`) calibrates support volume only — it does not open or close this readiness. When ready — recommend a document of the adjacent category above D_scope; otherwise — recommend an action at the current level, not a document
8. **Reminder logic** (reading the tracker):
   - `proposed` 1st Session → announce the recommendation as a Work Product
   - `proposed` 2nd Session → remind: "still in the growth zone — shall we set a Work Product?"
   - `proposed` 3rd Session → ask about frequency: create now / `remind_monthly` / `dismissed`
   - `remind_monthly` > 4 weeks → remind: "one month ago: [X] — has anything changed?"
   - `dismissed` → do not remind (return only when new evidence appears in V_scope, A_scope, or D_scope)
   - `remind_monthly` > 12 months → auto-`dismissed`
9. **No more than one up-level Artifact in focus.** If the tracker already contains a `proposed`/`in-progress` document at a category above D_scope — do NOT add a second one. Anti-imitation (`PD.FORM.091 §8` "Substituting creation for vision")
10. **Update the tracker** with the Session date, V_scope/A_scope/D_scope, qualitative status, recommendation status, and next reminder

**Anti-pattern:** "You have S0 in NEP → let's write a Business Constitution." Correct approach: recommendations follow readiness (D_scope + local gate), not vision (V_scope) directly. High V_scope with low A_scope/D_scope is a normal growth state (status `vision_ahead`), not a reason for imitation.

#### 6. Weekly Plan Formation

- Work through the proposed Work Products from the draft
- The user adjusts: adds/removes Work Products, changes budgets, priorities
- Update the Work Product table in WeekPlan

#### 7. Irregular Blocks (if present in the agenda)

- Work through any irregular blocks from the agenda (Retrospective, Architecture, document Review, etc.)
- Record the outcomes

#### 8. Approval and Synchronization

- The user confirms the plan
- Change `status: draft` → `status: confirmed` in WeekPlan
- Update WORKPLAN.md in the target repositories (back-synchronization)
- **MANDATORY:** Update MEMORY.md → section "Current week's Work Products" (current Work Product list + statuses)
- **MANDATORY:** If work has been added that is not reflected in Strategy.md → update Strategy.md (monthly priorities, phases, Q1 results)
- **MANDATORY:** Clear from fleeting-notes.md any notes for which the pilot has already made a decision (notes marked `✅proposed` with no decision — do not touch; procedure — "Note Cleanup" in `note-review.md`), and clear processed files from inbox/
- **MANDATORY:** Back-synchronize MAPSTRATEGIC.md — if an item from MAPSTRATEGIC has been taken into work (a Work Product created) → update the phase status in `<repo>/MAPSTRATEGIC.md` (mark as in-progress, add a link to the Work Product). If the phase is complete (Work Product done) → mark as done.
- Commit changes in {{GOVERNANCE_REPO}} and in all affected repositories

**Output:** approved WeekPlan W{N} (`status: confirmed`), updated Strategy.md, WORKPLAN.md, MEMORY.md, MAPSTRATEGIC.md, cleared inbox.
