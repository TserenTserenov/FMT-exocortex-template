---
description: Work Protocol — step-by-step instructions for the ritual
domains:
- protocol
horizon: warm
name: 'Protocol: work'
originSessionId: 9a0e726a-951e-4408-9e02-94d7eeffbf74
owner: platform
schema_version: 1
status: active
type: protocol
valid_from: 2026-04-10
---
# Work Protocol (ORZ Fractal)

> **Two scales:** Day and Session.
> **Source:** CLAUDE.md § 2 (slim) → this file. **CGUS (WP-481 F5):** step order = attention-retention order, NOT execution order. `[[gate]]`/`[[gate:AR.NNN]]` = precondition (blocking); `[[narrative]]` = demonstration order (skippable). Entering mid-flow is normal when gates are satisfied.


## § Scale: Day (Day Work)

> **Active:** between Day Open and Day Close. Meta-rules for the entire day.
> **Role:** R1 Strategist (rules) + R6 Encoder (session execution)

### Day Rules

| # | Rule | Essence |
|---|------|---------|
| 1 | **Slot 1 = self-development** [[narrative]] | Do not move to routine tasks until the self-development slot is completed or consciously skipped. The slot = what is important (raising the baseline); only a genuine urgent event interrupts it (a pipeline-stopping threat: prod/billing is down, a blocker for others). A deadline, accumulated routine, or strong "burning urgency" is NOT a reason to interrupt the slot (TVS model [[Current ≠ Important ≠ Urgent (TVS)]] / [[Deadline ≠ Urgency]]) |
| 2 | **Sessions = ORZ** [[gate:AR.005]] | Every session within the day is a full cycle: Open → Work → Close (§ Session below). Do not skip opening and closing. |
| 3 | **Pomodoros** [[narrative]] | Settings from `memory/day-rhythm-config.yaml` → `pomodoro`. Default: 25 min work → 5 min break. After 4 pomodoros — long break of 15–30 min. |
| 4 | **Break reminder** [[narrative]] | If a session exceeds `session_alert_minutes` (default 50 min) without a break → the agent reminds: *"Time for a break. 5 minutes."* |
| 5 | **Check against the plan** [[narrative]] | Between sessions: "Am I still on the day plan?" If not — make a conscious decision, not a drift. |
| 7 | **Resource vs Policy check** [[gate:resource-policy]] | Before adding a resource (hire, buy, automate): has the constraint been identified (Identify ✅)? Are non-bottlenecks subordinated (Subordinate ✅)? If not → return to those steps (MIM.FM.010, MIM.FM.011). |
| 6 | **Strategy day** [[narrative]] | Check `day-rhythm-config.yaml → day_open.strategy_day`. If today is a strategy day — do not skip the strategy session. |


## § Scale: Session (Session Work)

> **Trigger:** After completing the Opening Protocol (§ Session). Active throughout the Work stage.

## 1. Know Your Services (blocking) · [[gate:services-map]]

**MANDATORY. BEFORE starting work on a task.**

1. Identify which method descriptions (services) from [DP.MAP.002](../../Github/PACK-digital-platform/pack/digital-platform/07-map/DP.MAP.002-iwe-service-catalog.md) the task touches.
2. Do you know? → Name them (for example: "Working with S01 Day Plan, S04 Note Review"). Proceed to step 2.
3. Do not know? → **STOP.** Check MAP.002. Propose options for approval.
4. Task is not related to any service (new feature, research)? → Say: "New service / not related to existing ones." Continue working, but at Close verify whether a row needs to be added to MAP.002.

## 1a. Microstep Live Beat (MicrostepLiveBeatPass) · [[narrative]]

> **Link to WDW:** WDW = completeness contract for a unit; microstep = attention contract.
> **Link point — "Output":** the post-event report closes both disciplines.

### Input

- Trigger: the event takes >1 minute, consists of multiple tool calls, modifies a file/state, or as a safety measure — every 180 seconds of silence.
- Context: current WP, pilot's last message, open changes.

### Action

Take **one** step, keeping focus on **one** object being checked.

- What am I doing right now?
- What result does this step lead to?
- What is next?

### Output

1. **Post-event report** in chat (before the next step):
   *"Done [X] → [observable result]. Next step: [Y]."*
2. **Single-line ledger** (one line, not a journal):
   `HH:MM | step | outcome` — in the WP working file or ORZ.

### Boundaries

- **Not double bookkeeping:** the ledger is a tick only; it does not duplicate the full report.
- **Does not apply** to trivial actions <15 seconds and read-only searches.
- **The 180-second timer is a safety net**, not a substitute for the event-based report.

## 2. Capture-to-Pack + Draft (at every Work milestone) · [[narrative]]

> Work milestone = a subtask is complete, a pattern is discovered, a decision is made, an optimization is done.

At every Work milestone ask: **is there knowledge to record? Is there a seed for a post? Is there a content idea?**

| Knowledge type | Destination | When | Via KE? |
|----------------|-------------|------|---------|
| Rule for all repos (1–3 lines) | `{{HOME_DIR}}/IWE/CLAUDE.md` | Immediately | No |
| Rule for one repo (1–3 lines) | `<repo>/CLAUDE.md` | Immediately | No |
| Domain (architecture, patterns) | Corresponding Pack | Close | Yes (KE) |
| Distinction, method, FM, WP | Corresponding Pack | Close | Yes (KE) |
| Implementation (protocols, processes, configs) | DS docs/, PROCESSES.md, protocol-*.md | Immediately/Close | No |
| FAQ (domain question) | `DP.IWE.002 §11` (Pack) + README §FAQ | Immediately | No |
| FAQ (practical question) | `LEARNING-PATH §11` (Quick Ref) | Immediately | No |
| Major lesson | `memory/<topic>.md` | Close | No |
| Post seed (coherent reasoning) | `DS-strategy/drafts/draft-list.md` + `drafts/` | Close | No |
| **Content idea** (topic + audience segment) | `DS-strategy/drafts/draft-list.md` | Immediately | No |

> **Temporal metadata (bi-temporal):** When writing a memory file, add `valid_from: YYYY-MM-DD` to the frontmatter. When a fact becomes outdated, add `superseded_by: <file or description>` instead of deleting it. This allows a machine to distinguish a fresh fact from a stale one. Fields are optional — add them incrementally without breaking existing files.

> **MEMORY.md write contract (S-53):** full Write is forbidden; read first → narrow Edit of your own line → verify; with parallel live sessions — use a mkdir lock; after editing — local git commit in memory/. Full text → `memory/memory-lifecycle-spec.md §7.5`.

> **All lines are captures.** In the Close report, list ALL destinations, not only Pack (HD #29: domain → Pack, implementation → DS).

> **Agent initiative (capture_autonomy from params.yaml):**
> - `manual` — wait for an explicit user command
> - `propose` *(default)* — the agent MAY and MUST announce a Capture without a command when a pattern/decision/distinction is discovered. Announcement: *"Capture: [what] → [where]. Record?"* — user confirms
> - `auto` — the agent announces and records without confirmation

> **Announcements at a Work milestone:**
> - *"Capture: [what] → [where]"*
> - *"Content idea: [topic] → [segment C1/C2/C3]"* — a publication idea from current work. Aggregated in Week Review → next week's content plan.
> - *"Verify: [artifact] → /verify"* — the artifact is created and needs verification. Run `/verify` on request or defer to Close.

## 2a. Decision Capture (at every Work milestone, WP-109 F7) · [[narrative]]

> **Adjacent to Capture-to-Pack.** At a Work milestone, if the **user** (not the agent) made a decision — record it.
> **Source:** PD.SOTA.003 (Decision Register). ArchGate: 6✅/1⚠️/0❌.

### BLOCKING: user decisions only [[gate:decision-capture]]

**Record ONLY forks where the user made the choice.** Agent decisions within its own work — implementation, code structure, test selection, an ArchGate the agent runs itself — **do NOT record**. That is agent work, not a human fork.

**Why:** 10 Apr 2026 — the agent cluttered `decision-log-2026-04.md` with 78 entries, of which only 2 were real user decisions. The rest were operational/architectural agent decisions made during implementation. The purpose of the log is to track the user's decision fatigue, not to serve as an agent self-report.

**Test (apply to every candidate entry):** "If the user had not said this / had not rejected this / had not chosen this — would the agent have made the choice itself?" Yes → **do NOT record**. No → record.

**When in doubt — do NOT record.**

### What to record

**At the Work milestone ask:** *"Was there a user decision?"* If yes — classify and record it.

| event_type | When | cognitive_weight |
|------------|------|-----------------|
| `decision_approve` | User confirmed a **non-trivial** agent proposal, after which the agent would not have acted without confirmation | 1 |
| `decision_reject` | User rejected / asked to redo | 3 |
| `decision_redirect` | User redirected the task (different WP, different agent, change of course) | 3 |
| `decision_architectural` | **User** chose an architecture / rejected an ArchGate option | 5 |
| `decision_strategic` | **User** made a decision about priorities, scope, budget, or strategy | 5 |

**What NOT to record (typical agent errors):**
- Agent ran an ArchGate itself → do not record (that is agent work)
- Agent chose a pattern / implementation / filename / test structure → do not record
- Agent discovered a bug and fixed it → do not record
- Agent created a WP on its own initiative → do not record
- Agent reformulated a phase, did cleanup, reorganized code → do not record
- Trivial user confirmations ("ok", "yes, do it", "fine") → do not record

### Format and recording rules

**Timezone:** `Asia/Nicosia` (UTC+3). Time format: `HH:MM`.

**Timestamp = actual time** the decision was made, not a narrative label. Verify against one of these sources: (a) git commit time (`git show -s --format=%ai <hash>`), (b) tool call / user message time in the current session, (c) if you cannot verify — **do not write the entry** ("when in doubt — do not record" rule). **Do NOT write labels** such as "night", "evening", "evening-2/3/5" without an HH:MM anchor.

**Why (10 Apr 2026):** in the cluttered log, 78 entries from previous sessions were marked "night 01:30", "evening-2 21:00", "evening-5 16:50", but the actual commits for those sessions were at 18:49, 12:38 during the day, etc. Agents wrote narrative labels based on the **order entries were added to the file**, not the actual event time. This turns the log into a narrative rather than an accounting system.

**Sort order:** **newest on top**. A new entry is inserted ABOVE the first existing section/entry, not at the end of the file.

**Recording (two places, append-only):**
1. **File** (immediately at the Work milestone): `${IWE_GOVERNANCE_REPO:-DS-strategy}/decisions/decision-log-YYYY-MM.md`. Before the first entry:
   - create the `decisions/` directory if it does not exist;
   - if the old directory `${IWE_GOVERNANCE_REPO:-DS-strategy}/exocortex/decisions/` exists, process **all** its `decision-log-*.md` files: move any file whose canonical counterpart does not yet exist in `decisions/`; if a counterpart already exists, do not merge or silently overwrite — notify the pilot of the conflict;
   - if the file still does not exist — create it with the header `# Decision Log — <month>`, then a blank line and the note `> Registered decisions by WP`.

   Line format: `- **HH:MM** [type/weight] WP-N: Decision summary. Alt: ...`. Read the header (10 lines) → find the top `### YYYY-MM-DD` section → if today's date exists, insert the new line **first** within the section; if not — create a new `### YYYY-MM-DD` section **above** all existing sections.
2. **DB** (when a connection is available): inline INSERT into `development.user_events` (source=`exocortex`, F3b pattern).

> **DB = authoritative** for cognitive budget. File = for humans. Drift is acceptable.

**Nudge:** after recording — check `SUM(cognitive_weight)` for today. If ≥70% of `cognitive_budget.daily_decision_points` (see `day-rhythm-config.yaml`; if the key is absent, the default value is **15**, an initial uncalibrated value) → warn:
> *"N decisions today (weight M/threshold). Recommendation: closed-loop session or break."*

<!-- YOUR CUSTOM CHECKS HERE -->

## 2b. Verification on Milestone (optional + auto-trigger) · [[narrative]]

> At a Work milestone, if a significant artifact was created (Pack entity, method description, architectural decision):

**Question:** *"Artifact [X] created. Verification needed? (yes / at Close / no)"*

| Response | Action |
|----------|--------|
| **Yes** | Run `/verify [artifact]` now |
| **At Close** | Add to the Verification Gate list (Close step 3b) |
| **No** | Skip (trivial / closed-loop with tests) |

> **Do not block work.** Verification at a Work milestone is a proposal, not a blocker. The main check happens at Close.

### Auto-trigger: after ArchGate (S56)

> If an ArchGate occurred in the session (EMOGSSB profile, verdict "passes ArchGate") AND **code** (not only .md) was changed after it → Claude **automatically** runs `/verify archgate` after implementation is complete.
>
> **How to distinguish code from text:** check the extensions of modified files. Code = `.py`, `.ts`, `.tsx`, `.js`, `.sh`, `.sql`, `.yaml`, `.yml`, `.json`, `.css`, `.html`. Text = `.md`. If only `.md` → code verification is not needed.
>
> **Announcement format:** *"ArchGate occurred in this session. Code was changed. Running Verifier (archgate)."*

> Announce: *"Capture: [what] → [where]"*

### Creative Pipeline (4 stages, TTL)

```
Note (7d) → Draft (7d) → Prepared piece (14d) → Post
```

| Stage | Storage | TTL | Outputs |
|-------|---------|-----|---------|
| Note | `fleeting-notes.md` | 7 days | captures / draft / WP / archive |
| Draft | `DS-strategy/drafts/` | 7 days | captures / prepared piece / WP / archive |
| Prepared piece | `DS-Knowledge-Index` status: draft | 14 days | post (published) / archive |

> **Draft ≠ Prepared piece.** Draft is personal (DS-strategy). Prepared piece is public (DS-Knowledge-Index).
> **Prepared piece ≠ Post.** A prepared piece is published but not promoted. A post is actively promoted.
> **Pack → post:** KE added ≥3 entities on a topic → propose a draft for a post.
> **Guards:** ≤5 drafts = normal. 6–10 = ⚠️ warning. >10 = 🛑 blocked (do not add new ones).

## 2b. Video → Captures and Content (C4+C5) · [[narrative]]

> **Trigger:** Command "transcribe video" / `/transcribe <file>` or auto when `video.auto_transcribe.enabled: true` and duration > `min_duration_minutes`.
> **Dependency:** skill `/transcribe` (MLX Whisper, Apple Silicon). Model: `IWE_WHISPER_MODEL`, otherwise local directory `~/.local/share/mlx-whisper/mlx_models/large-v3` (if the model is present and `config.json` exists), otherwise Hugging Face repository `mlx-community/whisper-large-v3-mlx`.

### C4: Transcription → Captures

1. Read `memory/day-rhythm-config.yaml` → `video.auto_transcribe`
2. Transcribe via skill `/transcribe <file>` (default `distil-large-v3`, for maximum quality — `large-v3`)
3. Result → `<video_dir>/transcripts/<filename>.txt`
4. Extract captures from the transcript:
   - WP mentions (WP-N) → captures linked to the WP
   - Decisions, ideas, distinctions → `captures.md`
   - Announce: *"Capture (video): [what] → [where]"*

### C5: Video → Posts

> **Trigger:** After C4 (transcript available) + `video.content.suggest_posts: true`.

1. Analyze the transcript for coherent reasoning segments (>3 min on a single topic)
2. Propose post seeds:
   - *"Video `file.mp4` contains reasoning about [topic] (~X min). Propose a draft?"*
3. If the user agrees → create a draft in `DS-strategy/drafts/` following the creative pipeline (§2)
4. Link the draft to the source video (reference in frontmatter)

## 2c. Skill Discovery (at Work milestones) · [[narrative]]

> Adjacent to Capture-to-Pack. At every Work milestone ask: **is there a repeatable action worth formalizing as a skill?**

**Skill candidate criteria:**
1. The action repeats ≥3 times across different sessions
2. It has a clear input ($ARGUMENTS) and output (artifact/decision)
3. The algorithm is stable (does not change from session to session)

**If all three apply → propose:** *"Skill candidate: [name] — [what it does]. Formalize as `.claude/skills/[name]/SKILL.md`?"* [[gate:skill-discovery]]

**Destination:** IWE/.claude/skills/ (primary source) → sync → working {{HOME_DIR}}/IWE/.claude/skills/

## 2d. Critical Document Review (Q-bundles + two-level review) · [[narrative]]

> For critical Pack artifacts, architectural decisions, and normative texts.

**Two-level review:**
1. **Executor** creates the artifact
2. **Independent reviewer** (another agent or `/verify` with context isolation) reviews with the right to block

**Q-bundles (explicit quality sets):**
- The reviewer specifies **concrete rubrics** for the check, not general evaluations
- ❌ "quality looks stronger" → ✅ "term X is ambiguous (HD #46), connection to SC-03 is not traceable"
- The set of rubrics depends on the artifact type (Pack entity, architecture, method description)

**When to apply:** Pack entities, ArchGate decisions, method descriptions (PROCESSES.md). Do not apply to trivial/closed-loop tasks.

**Source:** ailev, "Process for AI-agent text production" (2026-03-27).

## 3. Pre-action Gates

| Moment | Check |
|--------|-------|
| Before starting work on a task | Which services (MAP.002) are affected? No answer → STOP [[gate:services-map]] |
| Before `git commit` in a repo with CLAUDE.md | Read the repo's CLAUDE.md → exit protocol [[gate:AR.010]] |
| Before proposing an architectural decision | ArchGate (§5) [[gate:AR.003]] |
| Before committing after a system change | **Capture-back:** `grep memory/` for mentions of the changed system → update stale records. Announce: *"Capture-back: [system] → memory/[file]"* [[gate:capture-back]] |

## 4. General Work Rules

- **Pull-before-Commit (DS-strategy):** `git pull --rebase` → modify → `commit` → `push`. [[gate:AR.006]]
- **No Obsidian (DS-strategy):** Browse via VS Code, NOT Obsidian. [[narrative]]
- **Push:** Unpushed commits → MUST ask "Push?". [[narrative]]


*Created: 2026-02-23*
