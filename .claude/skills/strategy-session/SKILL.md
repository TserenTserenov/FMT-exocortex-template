---
agents: single
browser_safe: false
description: Strategy Session — dispatcher. Day-0 (marker IWE-INITIAL-NEEDED or no
  Strategy.md/WeekPlan) → initial flow (goals, dissatisfactions, first WeekPlan).
  First session of a calendar month → full monthly flow (strategic alignment + caliber
  lens). All other days → short weekly flow (requires a draft from session-prep).
  Triggers — "let's run a strategy session", "first strategy session", "strategy session",
  "let's strategize".
gates_enforced: []
gates_rationale: operational skill; WP Gate applicable only when creating a new WP,
  not for operational calls
gates_required: []
interaction: multi-step
layer: L1
name: strategy-session
routing:
  deterministic: false
  executor: opus
status: active
triggers:
  phrases: []
  slash:
  - /strategy-session
version: 1.0.0
---

# Strategy Session — Dispatcher

> One Skill, three modes. Mode selection is based on the presence of Artifacts in `{{GOVERNANCE_REPO}}/` and the calendar position of the Session.

## When to use

Strategy Session — dispatcher. Day-0 (marker `IWE-INITIAL-NEEDED` in Strategy.md or no Strategy.md/WeekPlan) → initial flow (goals, dissatisfactions, first WeekPlan). First session of a calendar month → full monthly flow (strategic alignment + caliber lens, ~45–60 min). All other sessions → short weekly flow (requires a draft from session-prep, ~15–20 min). Triggers — "let's run a strategy session", "first strategy session", "strategy session", "let's strategize".

## Strategy Hub and the Session

The personal Strategy Hub is an active system. In a standard Configuration it consists of the person as the decision owner, a configured AI Environment, and a deployed physical workspace. A specific agent, the entire AI Environment, or the workspace can be replaced, provided the decision-making order and access to prior priorities, commitments, and records continue. Strategist and Planner are Roles within the Hub's work; one or both may be performed by an assigned Role Performer. A Role name does not transfer to AI the authority to approve the person's decisions.

Distinguish three types of work: a separate system creates and then helps evolve the Hub's structure; the created Hub prepares and runs the first Session; after that, the Hub regularly checks direction, plan, and results. Role Performers execute assigned work; the Hub receives execution facts. A **completed Session** is time-bounded work. Name a separate temporary system for running a Session only when its own composition, connections, boundary, and capacity to act are shown; in most cases the Hub in session Configuration is sufficient. An agenda document, a plan, or a session record is not the Session itself.

For a practical launch, record two distinct Work milestones. **Hub created** means the person, available tools, and physical workspace are connected in a stable way that supports making and preserving decisions about direction and plan. **Hub ready for the first Session** means that, in addition, initial observations, a place for records, a decision owner, and a working meeting script are available. Readiness is checked after creation; the absence of an agenda does not cancel the existence of an already-created Hub.

In a full Session there is one Hub with different assignments within it. The table below gives an overview of Phases 0–8; the Step files below specify the order and skip conditions. The output of a Phase may be a decision or an update to an existing record rather than a separate Work Product.

| Full Session Phase | Assignment within Hub | Input | Action | Expected Output |
|---|---|---|---|---|
| 0. Opening | Performer organizes, person confirms | Draft plan and agenda | Check readiness and route | Processing order |
| 1. Week Review | Planner checks, person decides | Previous plan and facts | Review plan and result | Decisions on carry-over and stop |
| 2. Inbox Processing | Strategist processes, person decides | Notes and open questions | Identify questions for decision | Processed inbox |
| 3. Dissatisfactions | Strategist clarifies, person confirms | Observations and prior records | Clarify significant gaps | Updated dissatisfactions |
| 4. Strategic Alignment | Strategist compares, person decides | Strategy, results, and gaps | Revisit priorities | Decisions on monthly frame |
| 5. Calibration | Assigned performer measures, person decides | State and intent data | Discuss measurement and recommendation | Decision and measurement record |
| 6. Planning | Planner assembles, person approves | Priorities, Work Products, and time budget | Select and allocate budget | Work Product pool and week draft |
| 7. Non-recurring items | Performer depends on item | Special agenda points | Process individual cases | Recorded decisions |
| 8. Approval | Person approves, performer saves | Week draft and decisions | Verify and finalize | Approved week plan |

A short weekly Session uses only the required Phases from this route; the first Session is not an abbreviated repeat of this route and is described in §2. The seven stages of the general work cycle between Sessions operate at a different scale — they are not a list of Steps within one meeting.

## Algorithm

### Step 0. Working copy of the governance repository (BLOCKING — before extensions and any writes)

> If the setup includes `session-guard.sh` (canon under freeze), writes go only from an isolated copy and are published via `ds-publish.sh` (the "Canon under freeze" rule in `{{GOVERNANCE_REPO}}/CLAUDE.md`). If session-guard is not in the setup, the freeze is disabled (empty `IWE_FROZEN_CANONICAL_PATH`), or the governance repository has no `origin` (a setup without GitHub: `open --isolate` without `--base-sha` fetches the base via `git fetch origin main`, and there is nowhere to publish), work as before in the found working copy and save using the standard method. These are two explicit branches below — not a silent skip. ALL write paths are built from `GOV_WT`, not from the canon.

```bash
CANON="{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}"
GUARD="${IWE_SCRIPTS:-}/session-guard.sh"
[ -f "$GUARD" ] || GUARD="{{WORKSPACE_DIR}}/scripts/session-guard.sh"
[ -f "$GUARD" ] || GUARD="$CANON/scripts/session-guard.sh"
[ -f "$GUARD" ] && GUARD_MODE=required || GUARD_MODE=absent
CANON_C=$(cd -- "$CANON" 2>/dev/null && pwd -P) || { echo "ERROR: canon $CANON is not accessible" >&2; exit 1; }
CANON_COMMON=$(git -C "$CANON_C" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || { echo "ERROR: $CANON_C is not a git repository" >&2; exit 1; }
if [ -f "$CANON_C/scripts/lib/governance-repo-path.sh" ]; then
  CAND=$(. "$CANON_C/scripts/lib/governance-repo-path.sh" && resolve_active_worktree) \
    || { echo "ERROR: resolve_active_worktree failed" >&2; exit 1; }
else
  CAND=$(git rev-parse --show-toplevel 2>/dev/null) || CAND=""
fi
CAND_C=""; CAND_COMMON=""
if [ -n "$CAND" ]; then
  CAND_C=$(cd -- "$CAND" 2>/dev/null && pwd -P) || { echo "ERROR: could not normalize path $CAND" >&2; exit 1; }
  CAND_COMMON=$(git -C "$CAND_C" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || CAND_COMMON=""
fi
# candidate is valid only if its common git directory matches the canon (same governance repository)
if [ -n "$CAND_C" ] && [ "$CAND_COMMON" = "$CANON_COMMON" ]; then GOV_WT="$CAND_C"; else GOV_WT=""; fi
# isolation is needed only when origin exists (normally open --isolate fetches the base via git fetch origin main;
# offline you can supply a verified local commit via --base-sha) and freeze is not disabled
# (empty IWE_FROZEN_CANONICAL_PATH disables it in session-guard.sh itself): otherwise work as before
GUARD_OFF=""
if [ "$GUARD_MODE" = required ]; then
  if [ "${IWE_FROZEN_CANONICAL_PATH+x}" = x ] && [ -z "$IWE_FROZEN_CANONICAL_PATH" ]; then
    GUARD_OFF="freeze disabled: IWE_FROZEN_CANONICAL_PATH is empty"
  elif ! git -C "$CANON_C" remote get-url origin >/dev/null 2>&1; then
    GUARD_OFF="governance repository has no origin: nothing to fetch (git fetch origin main) and nowhere to publish"
  fi
  [ -z "$GUARD_OFF" ] || GUARD_MODE=absent
fi
if [ "$GUARD_MODE" = required ]; then
  if [ -z "$GOV_WT" ] || [ "$GOV_WT" = "$CANON_C" ]; then
    echo "NOT ISOLATED: canon is under freeze, writes are blocked. Open a copy: (cd -- \"$CANON_C\" && bash \"$GUARD\" open --isolate --wp <WP-N>), then repeat this step inside the copy: (cd -- \"<worktree_path>\" || exit 1; <step 0 block unchanged>)" >&2
    LOCAL_BASE_SHA=$(git -C "$CANON_C" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)
    if [ -n "$LOCAL_BASE_SHA" ]; then
      echo "If origin is unreachable: verify the local commit: git -C \"$CANON_C\" show -s --format='%H %s' \"$LOCAL_BASE_SHA\"" >&2
      echo "Then add --base-sha $LOCAL_BASE_SHA to the open command; no network is needed with this flag. The local revision may be behind origin." >&2
    fi
    exit 2
  fi
  echo "GOV_WT=$GOV_WT mode=isolated"
else
  [ -n "$GOV_WT" ] || GOV_WT="$CANON_C"
  echo "GOV_WT=$GOV_WT mode=legacy (${GUARD_OFF:-session-guard not found: no freeze}, working as before)"
fi
```

- Exit code 0 → **write the absolute path `GOV_WT` into your reply to the user** (session context): independent Bash invocations do not share variables, and `cd` in a subshell does not change the directory of the parent.
- Exit code 2 (`NOT ISOLATED`) → write nothing. Open a copy from the canon, take `worktree_path` from the `open --isolate` output, and repeat the Step 0 block inside the copy. `<CANON_C>` and `<GUARD>` are the paths from the `NOT ISOLATED` message. Change directory only inside a subshell `( … )`: a top-level `cd` is blocked by the `destructive-guard.sh` hook.
  ```bash
  (cd -- "<CANON_C>" && bash "<GUARD>" open --isolate --wp <WP-N>)
  ```
  ```bash
  (cd -- "<worktree_path>" || exit 1
  <step 0 block unchanged>
  )
  ```
  Offline (`git fetch origin main` fails): check the local commit using the command from Step 0 and use the ready-made command with `--base-sha` that `session-guard.sh` prints. It creates a copy from the specified commit without contacting `origin`. The pilot can separately decide to disable the freeze by setting `IWE_FROZEN_CANONICAL_PATH` to empty and switching to `legacy` mode.
  On failure → notify the pilot and stop (fail-closed); do not write to the canon. Exit code 1 → resolver or path error: show the message and stop.
- EVERY subsequent write block starts with an explicit assignment and check of `GOV_WT` and runs in a subshell inside the copy (git — `git -C "$GOV_WT" …`, files — absolute paths from `$GOV_WT`):
  ```bash
  GOV_WT="<recorded absolute path>"; : "${GOV_WT:?}"
  (cd -- "$GOV_WT" || exit 1
  <write commands>
  )
  ```
- Publishing at the end: `mode=isolated` → commit in `GOV_WT`, then publish from the copy; do not commit to the canon. The target branch is resolved from `origin/HEAD` of the copy (`main` if it is not the governing branch — e.g. `master`; falls back to `main` if the symlink is not found, #1209) and passed to the publisher explicitly (`--branch <DEFAULT_BRANCH>`): `session-guard.sh open --isolate` creates a copy from that same branch on its own `session-isolate/<agent>-<session>` branch, which does not exist on the server. `--branch` is passed only to publishers that support it: `update.sh` does not replace an already-present `scripts/ds-publish.sh` (the installation's own publisher or an old template copy), and such a publisher is called without `--branch` as before. Whether a publisher supports `--branch` is determined by the `knows_branch` function (heuristic): the function looks for a `--branch` argument-parsing pattern at the start of a line (also `-b|--branch)`, `--branch=*)`); comments, usage text, and `git status --branch` are not counted. A false negative (a wrapper that passes `"$@"`) is safe: the publisher is called as before. A false positive is not safe, so the pattern is narrow. The publisher is taken from the copy; from the canon if it is absent in the copy (`update.sh` places `scripts/ds-publish.sh` in the canon without committing, so a copy from `origin/main` does not contain it) or if the copy's publisher does not support `--branch` but the canon's publisher does. If neither has it → non-zero exit and a message: run `update.sh`. Publisher without `--branch` fails → suggest to the pilot to replace `scripts/ds-publish.sh` in the governance repository with the template version `seed/strategy/scripts/ds-publish.sh`. The publisher transfers one commit per call, so the block publishes all commits in the copy that are not on `origin/main`, from oldest to newest, and stops on the first failure. An already-published commit is skipped; repeating the block is safe. The publisher does not transfer merge commits (exit code 2): the block stops on the first such commit, so "all commits" means ordinary commits. Uncommitted changes in the copy are not published: the block prints one line "WARNING…"; the exit code is not affected. No commits → one line "Nothing to publish", no publication message. Cannot retrieve the commit list (git error) → exit code 1 and a message, not "Nothing to publish".
  ```bash
  GOV_WT="<recorded absolute path>"; : "${GOV_WT:?}"
  knows_branch() { grep -qE -e '^[[:space:]]*[(]?([^|)#[:space:]]+[[:space:]]*[|][[:space:]]*)*"?--branch(=[^|)[:space:]]*)?"?[[:space:]]*[|)]' "$1" 2>/dev/null; }
  PUB="$GOV_WT/scripts/ds-publish.sh"; CANON_PUB="{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/scripts/ds-publish.sh"
  if ! knows_branch "$PUB" && knows_branch "$CANON_PUB"; then PUB="$CANON_PUB"; fi
  [ -f "$PUB" ] || PUB="$CANON_PUB"
  [ -f "$PUB" ] || { echo "ERROR: publisher ds-publish.sh not found in copy or canon. Run update.sh (it delivers the publisher) and retry publishing; commits remain in the copy $GOV_WT" >&2; exit 1; }
  # issue #1209: hardcoded "main" below broke installs whose governance repo
  # defaults to e.g. "master" (same class as the session-guard.sh --isolate fix,
  # #1097/#1195 pattern). Resolve once from the already-fetched copy's remote
  # HEAD symref (no network call); "main" only as fallback when it's missing.
  DEFAULT_BRANCH="$(git -C "$GOV_WT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/origin/##' || true)"
  DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
  git -C "$GOV_WT" rev-parse -q --verify "origin/$DEFAULT_BRANCH" >/dev/null || { echo "ERROR: copy $GOV_WT has no origin/$DEFAULT_BRANCH, nothing to compare against for publishing" >&2; exit 1; }
  COMMITS=$(git -C "$GOV_WT" rev-list --reverse "origin/$DEFAULT_BRANCH..HEAD") || { echo "ERROR: could not retrieve commit list for copy $GOV_WT" >&2; exit 1; }
  [ -z "$(git -C "$GOV_WT" status --porcelain)" ] || echo "WARNING: copy has uncommitted changes — they are not published: commit them" >&2
  [ -n "$COMMITS" ] || { echo "Nothing to publish: copy has no commits ahead of origin/$DEFAULT_BRANCH"; exit 0; }
  for c in $(printf '%s\n' "$COMMITS"); do
    if knows_branch "$PUB"; then bash "$PUB" "$GOV_WT" normal --reason "strategy-session" --from-commit "$c" --branch "$DEFAULT_BRANCH" || exit $?
    else bash "$PUB" "$GOV_WT" normal --reason "strategy-session" --from-commit "$c" || exit $?; fi
  done
  ```
  `mode=legacy` → save using the installation's standard method (commit and push using the installation's own tools; if the repository has no `origin`, a commit is sufficient); use `ds-publish.sh` only if it is present.

### Step 0.1. Extensions (before)
`GOV_WT="<recorded path>" bash .claude/scripts/load-extensions.sh strategy-session before` → Exit 0: read each file and execute; extensions work with this `GOV_WT` root. Exit 1: skip.

## Step 1. Determine Mode

First check `$GOV_WT/docs/Strategy.md` for the `IWE-INITIAL-NEEDED` marker. This marker is present in the delivered strategy template until the first Session is completed. If the marker is present — select **initial**, even if the Strategy.md and WeekPlan templates already exist; do not proceed to the calendar-month check.

If the marker is absent, check for the presence of at least one of:

- `$GOV_WT/docs/Strategy.md`
- `$GOV_WT/current/WeekPlan W*.md`

If at least one is present — check AS A SECOND STEP whether this is the first Strategy Session of the calendar month. Two valid layout formats are recorded (issue #608, same root as #545 in day-open-scaffold.sh): flat files for Strategy/Day sessions (`sessions/YYYY-MM-DD.md`) and a month subfolder for peer sessions (`sessions/YYYY-MM/`) — both addresses must be searched; otherwise the flat layout (the default per `memory/routing-vocab.md`) always returns "not found" and the monthly check never triggers:
```bash
GOV_WT="<recorded path>"; : "${GOV_WT:?}"
(cd -- "$GOV_WT" || exit 1
SESSIONS_DIR=$(source "{{WORKSPACE_DIR}}/scripts/lib/common.sh" 2>/dev/null && iwe_sessions_dir 2>/dev/null) || SESSIONS_DIR="$GOV_WT/sessions"
grep -rl "strategy-session\|Strategy Session" \
  "$SESSIONS_DIR/$(date +%Y-%m)-"*.md \
  "$SESSIONS_DIR/$(date +%Y-%m)/" 2>/dev/null
)
```
First session of the month = session date ≤ the 7th of the month AND the search above returns nothing. The session log is taken from `iwe_sessions_dir` (a shared log outside the copy); if absent, from `$GOV_WT/sessions`.

> **Found by platform Audit on 17.08.2026:** before this fix, the dispatcher only knew about initial/weekly — the monthly variant (`strategy-session-monthly.md`) was implemented but never called by anything except a rare manual escalation from the weekly-stop-gate. As a result, Steps tied exclusively to monthly (strategic alignment, the caliber lens/lifework pack, inbox processing) effectively never ran for any user. This Step is a routing fix, not new functionality.
>
> **Known Constraint (policy, not a bug; peer-reviewed with Codex on 17.08.2026):** the trigger is idempotent with respect to a SUCCESSFUL run (a session file is written to `sessions/`), but not with respect to an interrupted/aborted run before the file is written — the next attempt in the same month will again see "no records" and go to monthly again. This is a deliberate trade-off: at-least-once per month is better than zero-times (the bug this fix addresses). Tightening to exactly-once is a separate Work Product when a live signal appears that duplicate monthly sessions are actually causing problems.

| State | Mode | Next |
|-----------|-------|-------------|
| `IWE-INITIAL-NEEDED` marker present in Strategy.md | **initial** (day-0) | §2 of this file; presence of templates does not change the route |
| Neither Strategy.md nor WeekPlan exists | **initial** (day-0) | §2 of this file |
| Strategy.md and/or WeekPlan exists and this is the first session of the calendar month | **monthly** (full variant) | `roles/strategist/prompts/strategy-session-monthly.md` |
| Strategy.md and/or WeekPlan with `status: draft` exists, not the first session of the month | **weekly** | `roles/strategist/prompts/strategy-session-weekly.md` |
| Strategy.md exists but no draft WeekPlan | weekly without draft | notify user: "no draft — run session-prep?" |

The presence or absence of the two files selects the Session route but does not prove the Hub exists: files may have survived after the Hub dissolved or may be absent when other storage is used. For the initial flow, first check the Hub's construction per §2.0.

---

## Step 2. Initial Flow (Day-0)

> Goal: get the user started from scratch. No session-prep, no previous-week Review — they do not exist yet.

### 2.0. Creating the Hub before the First Session

This is preparatory work done by a separate Hub-creation system, not the first Phase of the Session. With the same person and available tools, establish: who owns the decisions; which physical workspace is currently deployed; which AI Environment or tools are available; where the strategy, dissatisfactions, Work Product registry, and week plan are stored; who is assigned the Roles of Strategist and Planner; how to continue after replacing the agent or Environment. First confirm whether the minimum Hub structure meets the criterion above; if not — help assemble it. Then separately check readiness for the first Session: initial observations, available records, a decision owner, and a meeting script. Prepare any missing items together with the person before moving to 2.1. IWE installation, Hub creation, and the first Session do not become one event simply because they are performed in sequence.

Say to the user:

> "This is the first Strategy Session. We will go through 4 Steps: goals → dissatisfactions → first WeekPlan → MEMORY.md."

### 2.1. Goals (5 min)

Ask:
- "Who do you want to be in one year?"
- "What do you want to learn?"
- "What are 2–3 major goals for the next 3–6 months?"

Write the answers to `$GOV_WT/docs/Strategy.md` using the structure:
- Vision (1 year)
- Goals for the horizon (3–6 months)
- Principles (what matters to me)

### 2.2. Dissatisfactions (5 min)

Ask:
- "What is getting in the way right now? Where is the gap between the current state and the desired state?"
- "What regularly irritates you or drains your energy?"

Write to `$GOV_WT/docs/Dissatisfactions.md` as a list: each dissatisfaction = 1–2 lines.

### 2.3. First WeekPlan (10 min)

Based on the goals and dissatisfactions, propose 3–5 candidate Work Products for the coming week. Until the person confirms the selection, these are options, not accepted commitments. For each:
- Name (noun-artifact)
- Budget (hours)
- Artifact criterion (what will exist when it is done)

After the person's decision, write the selected Work Products to `$GOV_WT/current/WeekPlan W{N}.md` (where N is the ISO week number). Until approved, the plan remains a draft.

### 2.4. Update MEMORY.md (2 min)

In `~/.claude/projects/{{CLAUDE_PROJECT_SLUG}}/memory/MEMORY.md`, add a section "Work Products for the current week" with the list from 2.3.

### 2.5. Closing the Initial Session

Only after the person explicitly approves the first WeekPlan, remove the `IWE-INITIAL-NEEDED` marker from `$GOV_WT/docs/Strategy.md`. If the Session was interrupted or the plan remained a draft, keep the marker so the next invocation returns to the initial flow.

Say: "Done. Tomorrow morning you can say 'open the day' — the assigned Role Performer will prepare the day plan. Every Monday at 04:00 a draft is automatically prepared for the next Session."

**Extensions (after):** `bash .claude/scripts/load-extensions.sh strategy-session after` → Exit 0: read each file and execute. Exit 1: skip.

---

## BLOCKING: one step at a time

> Violating this rule makes the Session pointless — the pilot does not provide their data, and decisions are made without them.

**After completing ANY step — STOP.** Do not read the next step; do not continue. Wait for the pilot's message. Proceed to the next step only after their reply. This rule applies even after compaction, even if the gate is `auto`, even if "the next action is obvious".

---

## Step 3. Weekly Flow

If mode = weekly:

Load `{{IWE_TEMPLATE}}/roles/strategist/prompts/strategy-session-weekly.md`
(if the file is absent → `bash update.sh`) and follow it in full — start with its
own "Session Overview" gate and the canonical step table
(00 → 01 → 07 → 03 → weekly-stop-gate → 06a → 06b → 08). That file already
implements the Backlog pass (Step 07, with a stop-gate) and dissatisfaction
processing (Step 03) — do not repeat or anticipate those here in the dispatcher text.
The switch to the full Session (`strategy-session-monthly.md`) happens ONLY after
Step 03, on the weekly-stop-gate signal (a revision of the week's Work Product
composition is needed) — not before, and not based on a separate dispatcher
heuristic. (Do not add dispatcher prose about Review/dissatisfactions/stop-criteria
here — only the delegation above; found live on 20.10.2026, WP-518 F17, third repeat
of the same class of gap on 12.10/19.10/20.10 — full history → `inbox/WP-518/WP-518.md` F17.)

**Day orientation — ask the pilot EVERY week (found 01.09.2026, WP-484 F148 — without
an explicit "Day Budget" question, the DayPlan budget was automatically calculated as the
sum of portfolio estimates and reached several hundred hours, which is physically
impossible for a single day):**
- "How many physical hours per day is it realistic to plan for this week?" — record in
  `current/priorities.yaml: phys_hours`. If the pilot does not give a new number — keep
  the previous value (do not ask again with the same question every Session if the answer
  is already stable).
- "How many Work Product hours (sum of the `h` column) is it reasonable to pack into
  ONE day's plan?" — keep this as a Constraint when packing the day, alongside the
  WIP limit (8–15 items): the day must not receive multi-week estimates for several
  Work Products in full — only a realistic daily portion.

Both numbers are the pilot's orientation for the whole week (not taken from a calendar
and not computed automatically by a script): the pilot stated directly on 01.09.2026
that this is a conscious choice, not something that can be derived from data.

**Extensions (after):** `bash .claude/scripts/load-extensions.sh strategy-session after` → Exit 0: read each file and execute. Exit 1: skip.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
