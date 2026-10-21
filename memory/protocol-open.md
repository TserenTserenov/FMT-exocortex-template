---
description: ORI Protocol — step-by-step instructions for the ritual
domains:
- protocol
horizon: warm
name: 'Protocol: open'
originSessionId: 9a0e726a-951e-4408-9e02-94d7eeffbf74
owner: platform
schema_version: 1
status: active
type: protocol
valid_from: 2026-04-07
---
# Protocol Open (ORI Fractal)

> **Two scales:** Day and Session. The trigger determines the scale.
> **Source:** CLAUDE.md § 2 (slim) → this file. **CGUS (WP-481 Phase5):** the step order below is the order of attention, NOT the order of execution. `[[gate]]`/`[[gate:AR.NNN]]` = precondition "work cannot proceed without this" (blocking); `[[narrative]]` = demonstration order (skippable). Entering mid-flow is normal if all gates are satisfied.

## § Scale: Day → skill `/day-open`

> **Trigger:** "open" / "open day". Full algorithm → `.claude/skills/day-open/SKILL.md`. **Execution:** step-by-step via TodoWrite (each step = task, blocking). Same as Close.

> **Yesterday's WakaTime (pending-multiplier):** in step 1 "Yesterday" — check for a `day_close` record for yesterday in Neon (`domain_event WHERE event_type='day_close' AND external_id='day-close-{yesterday}'`). If absent: call WakaTime API `summaries?start={yesterday}&end={yesterday}` → recalculate multiplier → append to domain_event. Reason: `--today` CLI does not return data for the previous day (WP-299 Phase4 p.3).

## § Scale: Session (Session Open)

> **Trigger:** Any task (except Day Open/Close). **Role:** R6 Encoder. **Handoff:** WP context file = Human→Agent handoff; "Remaining" = Agent→Agent handoff.

### Step 0. Router (DP.ROLE.059) — before WP Gate · [[narrative]]

> **Apply if:** the incoming request contains a routing tag (`skill=X`, `/X`, explicit executor hint).
> **Skip (go to WP Gate):** free-form text without an explicit tag — determine the Work Product first.

```bash
: "${IWE_WORKSPACE:?source .iwe-paths before protocol-open}"
: "${IWE_SCRIPTS:?source .iwe-paths before protocol-open}"
IWE_EXECUTOR_CATALOG="$IWE_WORKSPACE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/executor-catalog.yaml" \
bash "$IWE_SCRIPTS/route-task.sh" --skill <skill-name>
```
**If a tag is provided** → the Router finds `executor` in executor-catalog.yaml → launches the appropriate path:
- `executor: script` → direct call to script_path (no LLM); `haiku|sonnet|opus` → pass the task to the required model via SKILL.md; `mcp-direct` → call MCP tool directly

**If no tag** → call `/artifactor` (DP.ROLE.058) — converts the raw request into a structured request with a routing tag:

```bash
python3 "${IWE_SCRIPTS:-$HOME/IWE/scripts}/artifactor.py" "$REQUEST"
# exit 0 → JSON (routing_tag) · 1 → INSUFFICIENT_INPUT (clarify with pilot) · 2 → NO_KEYWORD_MATCH (LLM classification from SKILL.md)
```
Return the result (`structured request` with `routing_tag`) to the Router. Artifactor trigger: the request is vague, no clear skill, no Work Product binding. **Do not call the executor directly from the Artifactor.**

### WP Gate (blocking) · [[gate:AR.001]]

**BEFORE ANY ACTION.**

1. Read MEMORY.md → "Work Product of the current week". Match? → Yes: step 3. No: step 2b.
2b. Not found in MEMORY.md → grep WP-REGISTRY.md (full list). Found → step 3. Not found → STOP.

**PROHIBITED before verification:** reading code, investigating, planning.

#### Match — proceed

1. Reference the Work Product number.
2. **DayPlan Gate:** before any search or creation of a DayPlan, read
   `${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/exocortex/day-rhythm-config.yaml`
   → `day_open.strategy_day`. If the file is absent, unreadable, cannot be parsed
   as YAML, or the value is not in the map below → **inventory/STOP for the
   DayPlan action only**: do not search for, create, or modify DayPlan; state the
   reason to the pilot. Only a missing key has a safe default of `monday`.
   Compare the value to today's day using locale-independent `date +%u` and
   the full map `monday=1, tuesday=2, wednesday=3, thursday=4, friday=5,
   saturday=6, sunday=7`. Match → gate does not apply: do not search for or create a DayPlan. No match → only then check DayPlan; if the Work Product is absent → add a row. [[gate]]
3. **Sync Gate (Work Product context update).** Read the context of the Work Product and related Work Products → synchronize open phases with what has actually been completed. **Goal:** eliminate duplicate work, false blockers, and incorrect estimates in the Ritual. [[gate]]

   **Race-guard:** if the state file `.claude/state/wp-sync-<N>.done` exists AND its mtime is less than 8 hours old — skip (sync was already performed in this session). If the file exists but mtime is older than 8h — treat as stale: `rm -f` and restart. Check: `find .claude/state/wp-sync-<N>.done -mmin -480 2>/dev/null` (empty output = no file or stale → run; non-empty = fresh → skip).

   **Step 3a — Bundle.** Run the deterministic context collector:
   ```bash
   bash "${IWE_WORKSPACE:-$HOME/IWE}/.claude/scripts/wp-sync-bundle.sh" WP-N > /tmp/wp-sync-bundle-$$.md
   ```
   Exit 0 → read the output. Exit 1 → Work Product not found → proceed to Ritual with note "context not found". Exit 2 → parse error → proceed to Ritual, raise stderr in "Requires Attention".
   Exit 4 → wp-num.sh library not found: installation error, not "Work Product not found"; notify pilot and update the template.

   **Step 3b — Override (optional).** `bash .claude/scripts/load-extensions.sh protocol-open sync` — exit 0 → `Read` files (alphabetic); they override the default behavior of step 3c. Exit 1 → default.

   **Step 3c — Default branch behavior (if 3b did not override):**
   - **Branch A — trivial case** (≤1 related Work Products AND no drift signals): the main agent reads the current Work Product context itself and patches markers (`[ ]` → `[x]` for subtasks referencing closed related Work Products).
   - **Branch B — non-trivial** (≥2 related Work Products OR drift signals present): delegate via Task tool to sub-agent `wp-sync-actualizer` (Sonnet 4.6, context isolation). Pass to prompt: WP-N number + bundle content. Sub-agent returns a unified diff in `---ORIGINAL---`/`---REPLACEMENT---` format. Main agent applies via Edit.
   - **Branch C — conflict** (sub-agent returned a "Requires Attention" section instead of a diff, or found "PASS" in one related Work Product vs "FAIL" in another on the same metric): do NOT apply automatically; raise in the Ritual "Requires Attention" section.

   **Step 3d — Cleanup:** `rm -f /tmp/wp-sync-bundle-$$.md`, `touch .claude/state/wp-sync-<N>.done`.

4. → Ritual.

#### No match — STOP

1. "This task is not in the weekly plan."
2. Display Work Product table; ask: artifact, formulation, repo, budget
3.5. **Suggest links to active Work Products.** Read WeekPlan W{N}.md → grep for thematic intersections. Table: Work Product / strength (🔴 strong / 🟡 medium / 🟢 weak) / type (handoff, dependency, product consequence, validation case). If no links >🟢 — mark "Work Product is isolated" (signal: revise the formulation).
4. Suggest reordering if budget is constrained
5. Record **in 4 places** (atomically): MEMORY.md, WP-REGISTRY.md, WeekPlan, WP context file (`verification_class: trivial|closed-loop|open-loop|problem-framing`)
5a. **Post-step (conditional): external tracker.** If an external tracker MCP is connected (e.g. Linear → `mcp__linear__create_issue`) — create the issue AFTER the local record. MCP absent or unavailable is a normal state, not an error: do not roll back the local record; note "external tracker: not connected" in the step report (issue #321)
5b. **Ritual → files bridge (WP-505):** the "Target State Transition" and "Hypothesis" declared in the Ritual must appear in the card's frontmatter (`state_transition:`, `hypothesis:`) and in the "Bet" column of the registry (if it exists). Creation — only via `create-wp.sh --state "…" --hypothesis H-NNN`; if `docs/state-axes-registry.yaml` is present, the script blocks creation without `--state`.
6. Numbering: sequential integers only (74, 75…). Letter suffixes are prohibited.

#### Exceptions (no Work Product required)

- ≤15 min, questions with no file changes, emergency bug fixes
- Second task under an exception → *"This is growing into a Work Product. Record it?"*

### Alignment Ritual

**Step 1.** Declare: [[gate:AR.001]]
> **User role:** [from the 4 roles HD #31]
> **Claude role:** [DP.ROLE.001]
> **Work:** [what] — the specific subject of the current reasoning (not "the whole project" unless the question is about the whole project); if relevant — the window/context in which the answer applies.
> **Work Product:** [artifact]
> **Target state transition:** `{axis, from→to}` — permission/belonging/engagement/mastery (WP-457, State-Transition Gate). Reference to `states-map-draft.md` or declared FSM-owner; cross-axis — mark `provisional` until ArchGate (Phase9). Optional: `signal` — observable confirmation of the transition (example: `"no spontaneous logouts for 2 weeks"`).
> **Hypothesis:** `H-NNN` from `current/hypotheses-log.md` or "—" (explicit "no bet" — infrastructure/tech debt). Which hypothesis log entry this Work Product serves (WP-505).
> **Mode (CIU):** [current / important / urgent] — per the pipeline model ([[Current ≠ Important ≠ Urgent (CIU)]])
> **Class:** [verification_class]
> **Method:** [how]
> **Estimate:** ~Xh
> **Model:** [current] — recommend [model]
> **Links:** [table 🔴/🟡/🟢 or "isolated Work Product"]

**Gates BEFORE action (cognitive, not machine — peer session 2026-06-15-13, Block ARTF).** Before registering or placing anything, run the ready gate — do not do it by hand: (a) **Work Product/phase name** = noun-artifact via Artifactor (`/decompose`) + §9, not a verb-action; (b) **placement/transfer** of artifact — verify against Routing Gate `DP.KR.001 §5` (meta `0.*` = transit, not a knowledge home; permanent homes = Packs + cores A/B/C). This is a reminder, not enforcement: the real locks are name-warn in commit-msg + (follow-up) server-side placement gate.

**CIU mode (pipeline model):** current = standard operational work (maintains the norm); important = raises the norm above its previous level (development, R{N}); urgent = threat of pipeline stoppage (prod/billing down, blocker). "Urgent" is NOT assigned by deadline or by how "pressing" something feels ([[Deadline ≠ Urgency]]) — only by a physical threat of stoppage. True urgent work usually does not go through the Ritual (it interrupts and gets fixed), but is recorded after the fact.

**Verification class** (HD #32):

| Class | Verification | Mode | Model |
|-------|-------------|------|-------|
| trivial | Not required | Autonomous | Haiku |
| closed-loop | Tests | Autonomous | Sonnet |
| open-loop | Costly, deferred | Collaborative, Captures | Opus |
| problem-framing | Unknown | Exoskeleton: 3 questions BEFORE solution | Opus |

**Model switching:** Entire session → `/model` (user only). Sub-agent → only downward (Opus→Sonnet/Haiku, Sonnet→Haiku).

**Step 1c. Exoskeleton mode** (problem-framing): 3 questions (What? Why? Constraints?) → 2–3 approach options → user selects. [[narrative]]

**Step 2.** Wait for alignment confirmation. [[gate:AR.001]]

**Step 3.** Identify files/repo. Context file (`<governance-repo>/inbox/WP-{N}/WP-{N}.md`, e.g. DS-strategy) — read. Trust hierarchy: code → documents → WP context. [[narrative]]

**Step 4.** Register in `<governance-repo>/inbox/open-sessions.log` (e.g. DS-strategy): `YYYY-MM-DD HH:MM | WP-N | model | description`. Exceptions — do not register. [[gate]]

**Step 4.5. Decomposer (automatic).** If class ∈ {open-loop, problem-framing} AND estimate ≥3h → run `/decompose` inline (without asking the user). Insert the stage map into the WP context file (section `## Stages` at the end of the file). If class is trivial/closed-loop OR estimate <3h → skip silently. [[narrative]]

**EXTENSION POINT (protocol-open after):** `bash .claude/scripts/load-extensions.sh protocol-open after` — exit 0 → `Read` each file from output (alphabetic) → execute. Exit 1 → skip. Supports `extensions/protocol-open.after.md` AND `extensions/protocol-open.after.<suffix>.md`. [[gate]]

> Continuing work on the same Work Product — no repeat Ritual required.

## Umbrella Work Products

- **#N-dev** (development) + **#N-debt** (tech debt). Context file = backlog (10–20 items).
- Task ≥4h or separate lifecycle → episodic Work Product.

## Issue Funnel (→ WP-debt)

- **Auto-triage (Grade 1):** helpful=false → Haiku classify → `feedback_triage` DB → TG alert
- **Review (Grade 3):** structured report + 2 file intakes
- **Direct command:** "record note: X" → fleeting-notes.md

<!-- DayPlan/WeekPlan templates moved to skill /day-open (lazy loading, saves ~8K tokens) -->
