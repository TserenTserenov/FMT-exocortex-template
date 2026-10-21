---
agents: single
argument-hint: <task description> | --list | --interrupt <session_id> | --finalize
  <session_id>
browser_safe: false
description: Peer Session DP.SC.154 where Kimi = writer, Claude = Peer partner. Launched
  with a simple phrase. Includes Opening and Closing, turn-loop, escalations, Decision
  Gate (record vs implement → Review → verify → deploy), deferred finalization, and
  Verification.
gates_enforced: []
gates_rationale: operational skill; WP Gate applicable only when creating a new WP,
  not for operational calls
gates_required: []
interaction: multi-step
layer: L1
name: kimi-peer-writer
routing:
  deterministic: false
  executor: sonnet
status: active
triggers:
  phrases:
  - start peer-session
  - launch a dialog with Claude
  - peer-session
  - together with Claude
  - with Claude
  - bring in Claude
  slash:
  - /peer-writer
version: 1.3.0
---

# Kimi Peer Writer (DP.SC.154)

Task: $ARGUMENTS

> **Architecture:** I (Kimi) = writer, Claude = Peer partner.
> Claude is called via `claude-peer-adapter.sh` directly — Bash tool, stdin pipe.
> `list_peer_statuses` (Local Gateway) — file coordination, **not** a Claude CLI availability check.
> Gateway offline ≠ Claude unavailable.

---

## When to use

Peer Session DP.SC.154 where Kimi = writer, Claude = Peer partner. Launched with a simple phrase. Includes Opening and Closing, turn-loop, escalations, Decision Gate (record vs implement → Review → verify → deploy), deferred finalization, and Verification.

## Scope boundary — does not replace decisions reserved for the pilot (found 2026-07-07)

> Peer Session is suitable for: technical decisions, design, code review, finding a compromise between approaches, preparing candidates for a decision.
> **NOT suitable** for decisions that the process explicitly reserves for a human (for example, R15 Validator in `/apply-captures` — accept/reject/defer knowledge candidates; R1 Strategist — monthly priorities). Agreement between two agents does not constitute a pilot decision, even when unanimous and well-reasoned.
>
> If a task inside a peer session requires such a decision — the writer must stop and ask the pilot directly in the current chat (not via a turn file), before recording the result. See `.claude/skills/apply-captures/SKILL.md` section "R15 = live pilot, not an agent" and `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/bugs/bug-2026-07-07-r15-decisions-bypassed-pilot.md` — the precedent that prompted this Constraint.

## Step 0. Mode

Determine mode from `$ARGUMENTS`:

- `--list` → read `${IWE_GOVERNANCE_REPO:-DS-strategy}/sessions/00-index.md`, print table. Stop.
- `--interrupt <id>` → go to **Step 5 (interrupt mode)**. Stop after.
- `--finalize <id>` → go to **Step 6 (finalize mode)**. Stop after.
- Otherwise → new Session, continue to Step 0b.

---

## Step 0a. Preflight Gate (WP-484 Phase 33 item G, mandatory BEFORE any other action)

The same check that `~/.kimi-code/skills/session-open/SKILL.md` already performs for standalone Kimi Sessions (Phase 33, 31.07) — before this fix, Kimi-writer peer sessions had NO check that the Session was opened legitimately (the same class of gap as Phase 28). The Script is provided by the Template; call it using the path convention (HD #566 — only the hardcoded `$HOME/IWE/scripts/...` was phantom; the Script itself exists and is in the Manifest):

```bash
bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/kimi-standalone-preflight.sh"
```

- Exit ≠ 0 (`ERROR: Kimi standalone session is NOT OPEN`) → **STOP.** Do not proceed to Step 0b, do not open WP Gate, do not create `meta.yaml`/`00-writer.md`, do not touch files. Show the pilot the open command from the Script's stderr (`bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" open --wp WP-N --task "..." --agent kimi`) and wait until the Session is opened explicitly.
- Exit 0 (including with a stale-Session warning) → continue to Step 0b.

## Step 0b. Opening (WP Gate — new Session only)

Find the WP for the task: read `${IWE_GOVERNANCE_REPO:-DS-strategy}/WP-REGISTRY.md` (grep by keywords) and `${IWE_GOVERNANCE_REPO:-DS-strategy}/current/WeekPlan W{N}.md`.

Announce to pilot:
```
Opening peer session (DP.SC.154)
Role: Writer (Kimi) | Peer partner: Claude
Task: <task>
WP: WP-NNN "<name>" | or: not found in plan
Method: turn-loop ≤10 turns | Peer model: Sonnet
```

If the WP is **not found** in the week plan → full WP Gate Ritual (`memory/protocol-open.md §Session`):
announce the Artifact + wait for pilot confirmation → **proceed to Step 1 only after "yes"**.

If WP is found → continue without waiting.

---

## Step 1. Initialization

```bash
SESSIONS_DIR="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/sessions"
TODAY=$(date +%Y-%m-%d)
MONTH=$(date +%Y-%m)
DAY=$(date +%d)
DAY_DIR="$SESSIONS_DIR/$MONTH/$DAY"
mkdir -p "$DAY_DIR"
NUM=$(printf "%02d" $(( $(find "$DAY_DIR" -maxdepth 1 -type d -name "${TODAY}-[0-9][0-9]-*" 2>/dev/null | wc -l | tr -d ' ') + 1 )))
```

Slug = first 4 Latin words from the task in lowercase separated by hyphens (non-Latin characters and the date are removed). No date in the slug — it is already in SESSION_ID. If there are no Latin characters → `session`.

`SESSION_ID="${TODAY}-${NUM}-${SLUG}"`
`SESSION_DIR="${DAY_DIR}/${SESSION_ID}"`

**1.1 Create directory:**
```bash
mkdir -p "$SESSION_DIR"
```

**1.2 Write `meta.yaml`** (Write):
```yaml
task_id: ""
date: "<TODAY>"
session_id: "<SESSION_ID>"
start_time: "<ISO-8601 UTC>"
end_time: ""
writer_agent: "kimi-headless"
peer_agent: "claude-code"
peer_cmd: "claude-peer-adapter"
peer_model: "sonnet"
status: "started"
turns_count: 0
turns_limit: 10
escalations_count: 0
extensions: []
result_path: ""
task_description: "<task>"
implementation_pipeline: false
review_iterations: 0
verify_status: ""
deploy_shas: {}
# Two-axis model (WP-367 Phase 5, DP.SC.154 v4):
roles: {}            # {agent_id: [DP.ROLE.NNN, ...]} after consensus in Opening
discovery_turns: 0   # number of turns spent on role-discovery (not counted in turns_limit)
ad_hoc_roles: {}     # {role_name: {agent_id, rationale, first_used_turn}} — for cascade audit
swap_history: []     # [{turn, from, to, reason}] — SWAP_WRITER transition log
```

**If the pilot did not assign roles** at Session launch — the initiator (writer/Kimi) in turn 0 proposes their own content role and the Peer partner's role (see DP.SC.154 section "Session Opening: Sequential role-discovery"). Discovery turns (0–2) **do not count** toward `turns_limit: 10`.

**In-session ad-hoc role signal** (DP.SC.154 v4, Pack-extension cascade level 1). When using an ad-hoc role (not in Pack `DP.ROLE.NNN`/`MIM.R.NNN`/`VR.R.NNN`), Kimi-writer **must immediately** announce to the pilot:

```
Taking ad-hoc role "<name>". No such role exists in the Pack catalog.
Responsibilities: <one line>. Method: <one line>.
Suggesting a WP to formalize (~30 min).
Choose:
  A. Create now → separate WP "pack-gap-<name>".
  B. Defer → will continue as ad-hoc; sentinel will remind at Week Close.
```

The entry in `meta.yaml.ad_hoc_roles` is written regardless of the choice (for backup level 2). If A is chosen — after the Session the writer opens a separate WP.

**1.3 Add a row to `sessions/00-index.md`** at the top of the table (first row after `|---|`):
```
| <TODAY> | <SESSION_ID> | <task ≤50 chars> | kimi / claude-code | 0 | 0 | started | — |
```

---

## Step 2. Writer turn 00-writer.md

Write `${SESSION_DIR}/00-writer.md` (Write):

```markdown
---
turn: 0
role: writer
agent_id: kimi-headless
timestamp: <ISO-8601 UTC>
consensus: none
---

<My initial position — task analysis, theses, specific questions for the Peer partner.
NOT a retelling of the task. A position with arguments.>
```

Show the pilot a brief summary: what was written in 00-writer.md.

---

## Step 3. Turn loop

Variables: `TURN=1`, `ESCALATIONS=0`, `DONE=false`.

### 3.1 Call Claude

Read all previous turns from `SESSION_DIR` in numbered order.
Compose prompt:

```
CRITICAL: Your task is ONLY to write one peer turn to stdout with frontmatter.
Prohibited: editing files, committing, git push, creating files in SESSION_DIR.
Your entire response = one turn in stdout. Nothing else.

You are the Peer partner (peer agent) in a dialogue Session (DP.SC.154).
Session: <SESSION_ID>
Turn: <TURN> of 10
Task: <task>

Read all log files in <SESSION_DIR> in order (00-writer.md, 01-peer.md, ...).

Write your turn to stdout with frontmatter:
---
turn: <TURN>
role: peer
agent_id: claude-code
timestamp: <ISO-8601 UTC>
consensus: none | proposed | reached | escalate
---

<Your response>

Critic rule: find AT LEAST ONE thesis or assumption of the writer you disagree with. Do not yield after the first objection — hold your position with arguments. If everything is genuinely OK — explain specifically why, not just "I agree".

Markers (strictly at the start of the line):
CONSENSUS: <summary> — if you believe agreement has been reached
ESCALATE_TO_USER: <reason> — if the writer is ignoring a material objection
```

Before calling Claude, the writer adds a minimal textual Projection of previous turns and facts to the prompt. Claude does not read `SESSION_DIR` and does not use tools.

Call Claude via Bash:
```bash
PEER_FILE="${SESSION_DIR}/$(printf '%02d' $TURN)-peer.md"
echo "<prompt>" | bash "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/claude-peer-adapter.sh" \
  > "$PEER_FILE" 2> "${PEER_FILE%.md}.err"
```

If the file is empty or exit ≠ 0 → notify pilot: "Claude did not respond. Retry or abort?"

### 3.2 Show pilot

Read `$PEER_FILE`. Output key theses from Claude (not the full turn verbatim — a brief summary with quotes of key positions).

### 3.3 Check markers

**ESCALATE_TO_USER:**
If `grep -q "^ESCALATE_TO_USER:" "$PEER_FILE"`:
- Extract reason: `grep "^ESCALATE_TO_USER:" "$PEER_FILE" | sed 's/^ESCALATE_TO_USER: //'`
- `ESCALATIONS += 1`
- Write `${SESSION_DIR}/escalation-$(printf '%02d' $((ESCALATIONS-1))).md`:

```markdown
---
escalation_number: <N>
turn: <TURN>
timestamp: <now>
reason: "<reason>"
pilot_response: ""
---

# Escalation <N> (turn <TURN>)

**Reason:** <reason>
**Claude's turn:** <PEER_FILE>
**Pilot response:** (enter below)
```

- Notify pilot: "Claude escalates: <reason>. Your decision is needed."
- Wait for pilot response, write it to `pilot_response` in the escalation file.
- Update `meta.yaml`: `escalations_count: <ESCALATIONS>` (Bash sed).

**CONSENSUS:**
If `grep -q "^CONSENSUS:" "$PEER_FILE"`:
- Extract summary.
- `DONE=true`, go to **Step 3.5 (Decision Gate)** — NOT to Step 4 directly.

### 3.4 Writer turn

If `TURN >= 10` → `DONE=true`, go to Step 4.

Write `$(printf '%02d' $((TURN+1)))-writer.md` (Write):
```markdown
---
turn: <TURN+1>
role: writer
agent_id: kimi-headless
timestamp: <now>
consensus: none
---

<My turn: response to Claude's arguments + incorporating the pilot's direction>
```

`TURN += 1` → return to 3.1.

---

## Step 3.5. Decision Gate (after consensus)

> **When triggered:** `DONE=true` via CONSENSUS marker in Step 3.3 (not via `TURN >= 10` — that goes directly to Step 4).
> **Purpose:** consensus ≠ implementation. This is a **legitimate choice question** for the pilot (scope of work choice, not yes/no on a ready solution). Exception to P5 — the pilot confirmed: "I need to sign off here" (trigger 2026-05-30, WP-367 Phase 5).
> **Required:** before the request — **a plain-language consensus summary** so the pilot can make an informed choice. A request without the summary is a mechanical "choose A/B" with no context.

Extract consensus summary (`grep "^CONSENSUS:" "$PEER_FILE" | sed 's/^CONSENSUS: //'`).

**Plain-language summary** — mandatory. Format (no technical terms, codes, or paths):

```
Consensus reached.

What was discussed: <one phrase>
What was agreed: <2-3 lines in plain language — the essence of the decision>
What is proposed for implementation: <list of changes, one line each; no files or paths>
Estimated implementation time: ~<N>h (including Review + smoke + deploy)
Impact on other users: <if any — what is delivered and how; if none — "local only">
```

After the summary — choice question:

```
What next?
  A. Record only → Step 4 (report.md + commit + close).
     Implementation — separate WP/Phase in a future Session.
  B. Implement now → Review → verify → deploy → Step 4.
```

Wait for pilot response. Write choice to `meta.yaml` (Bash sed):
```yaml
implementation_pipeline: false | true
```

- **A** → `IMPLEMENTATION=false`, go to Step 4.
- **B** → `IMPLEMENTATION=true`, go to Step 3.6.

**Default if pilot is silent:** B (implement now), per rule 11 "finish > defer". Apply only if the pilot has not responded within a reasonable time.

**Triggers automatic-defer** (no pilot request — go directly to A):
1. Implementation requires a new WP (new scope not covered by the current WP).
2. An ArchGate is required (new system-level architectural decision).
3. Context has fully switched (different part of the system; new framing needed).

When a trigger fires — announce to pilot with summary (NOT a request), then go to Step 4.

---

## Step 3.6. Implementation Pipeline (optional)

> **Activated:** only when `IMPLEMENTATION=true` in Step 3.5.
> **Principle:** Kimi-writer applies the decision → cold-context Claude via bash pipe performs code review → writer fixes → Claude via bash pipe runs smoke (writer has no Skill tool) → deploy → "Implementation and Verification" section in report-draft.md.
> **Architectural Constraint:** Kimi-headless has no Agent/Skill tools. All external agent calls go through `claude-peer-adapter.sh` (stdin pipe) — this is an intentional asymmetry with `/peer-conversation`.

### 3.6.1 Implementation

Announce to pilot:
```
Implementing consensus <SESSION_ID>
Files: <list of files with absolute paths>
Repos: <repo names, separated by " · ">
Method: Edit/Write tools directly
```

Writer (Kimi) applies changes via Edit/Write. Prohibited:
- Modifying files outside the announced list without a new announcement.
- Committing at this stage (commit — Step 3.6.5 only).

Record the list of changed files in `CHANGED_FILES` (one path per line).

### 3.6.2 Code Review (cold-context via bash pipe)

Review Iteration variables: `REVIEW_ITER=1` on first entry, incremented in 3.6.3.

Call Claude as code reviewer via the same adapter used for the turn-loop:

```bash
: "${REVIEW_ITER:=1}"
REVIEW_FILE="${SESSION_DIR}/review-$(printf '%02d' "$REVIEW_ITER").md"
REVIEW_PROMPT=$(cat <<EOF
CRITICAL: Do NOT use Write/Edit. Output markdown to stdout.
Your entire response = one report in stdout. Nothing else.

Cold-context code review of peer Session <SESSION_ID> results.
You are an independent reviewer who has not seen the dialogue. Context is below.

Consensus summary: <CONSENSUS_SUMMARY>

Changed files:
<CHANGED_FILES>

You have no file tools and no access to the Session directory — all relevant code is already inserted above in `<CHANGED_FILES>` (diff and file fragments, added by the writer before the call).
Check against the checklist:
1. asyncio runtime: look for 'wait_for(coro)' without 'shield' → coroutine reuse. Fire-and-forget tasks reading/writing one DB row from different places.
2. Shell ordering: function call BEFORE function definition. Is 'set -u' respected?
3. SQL race: cross-file writers to the same row without atomicity (UPDATE ... RETURNING / SELECT FOR UPDATE).
4. Lock enforcing: on collision — 'exit N' or 'log WARN && continue'? If advisory — is that intentional or a bug?
5. Consensus-specific context: <supplement from summary if there are invariants>.

Return a report in the format:
## Critical (must fix before deploy)
- <file:line-range>: <issue> | fix: <concrete fix>
## High / ## Medium / ## OK

Do not suggest refactoring or style changes — runtime bugs and checklist violations only.
EOF
)

echo "$REVIEW_PROMPT" | bash "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/claude-peer-adapter.sh" \
  > "$REVIEW_FILE" 2> "${REVIEW_FILE%.md}.err"
```

Add a precise diff and the necessary file fragments to `REVIEW_PROMPT`. Do not pass directories: Claude receives only a textual Projection.

### 3.6.3 Review Outcome

Read `$REVIEW_FILE`. Show the pilot a brief summary (Critical + High count + one example).

**If there are Critical items:**
- Apply fixes (Edit) → `REVIEW_ITER += 1` → return to 3.6.2 (new review-NN.md).
- Iteration limit: 3. On the 3rd — `ESCALATE_TO_USER:` + escalation-NN.md.

**If only High/Medium:**
- Ask pilot: "There are N High and M Medium findings. Fix now or after deploy?"
- Write to meta.yaml (`review_iterations: <N>`, `unresolved: <count>`).

**If only OK:**
- Continue to 3.6.4.

### 3.6.4 Smoke Verification (via bash pipe to Claude)

Kimi-writer has no Skill tool — `/verify` is called via Claude as a proxy:

```bash
VERIFY_FILE="${SESSION_DIR}/verify-01.md"
VERIFY_PROMPT=$(cat <<EOF
CRITICAL: Do NOT use Write/Edit for files outside a temporary smoke script. Output result to stdout.
Your entire response = one report in stdout. Nothing else.

Run smoke test for changes from peer Session <SESSION_ID>.

Changed files:
<CHANGED_FILES>

Consensus invariants (what must work):
<list from 3.5>

Use the built-in /verify skill (Skill tool: skill=verify, args=...).
If /verify is not applicable (e.g., CLI-only without UI) — write and run a targeted smoke test (pytest fixture / curl call / minimal python script).
Return:
- PASS / FAIL
- On FAIL: traceback + first line showing the cause
- The command that was run
EOF
)

echo "$VERIFY_PROMPT" | bash "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/claude-peer-adapter.sh" \
  > "$VERIFY_FILE" 2> "${VERIFY_FILE%.md}.err"
```

Claude in this call does not run smoke tests: it can only evaluate the provided text. The writer runs the executable check locally using a separate Protocol.

**Result:**
- PASS → go to 3.6.5.
- FAIL → show traceback to pilot, ask "fix and retry or escalate?"
  - "fix" → Edit → return to 3.6.2 (Review after fixes) or 3.6.4 (if fix is targeted, with pilot agreement).
  - "escalate" → ESCALATE_TO_USER + escalation-NN.md.

### 3.6.5 Deploy

For each Repository in the list of changed files:

```bash
(cd <repo path>
git status --short
# pathspec after `--`: commit ONLY own files. Bare `git commit` sweeps up
# others' pre-staged content from the shared index (mis-attribution, see 2026-06-20-39).
git add <specific files — NOT git add . and NOT git add -u>
git commit -m "<type>(<scope>): <short description>

Refs: peer-session <SESSION_ID>
Review iters: <REVIEW_ITER>
Verify: PASS" -- <same specific files>
git push
)
```

Write the commit SHA for each Repository to `DEPLOY_SHAS` (map: repo → sha).

**If push fails:**
- Do NOT bypass hooks (`--no-verify` is prohibited by rule 6 of CLAUDE.md).
- Record in logs, notify pilot, ESCALATE_TO_USER.

### 3.6.6 Outcome addition to report-draft.md

Write `${SESSION_DIR}/_outcome.md` (Write) — service file for the synthesizer:

```markdown
## Implementation and Verification

**Changed files:**
<CHANGED_FILES with one-line description each>

**Code review iterations:** <REVIEW_ITER>
**Unresolved (deferred):** <count High/Medium or "none">

**Smoke verification:** PASS | FAIL (with a note on what was fixed)

**Deploy:**
- <repo1>: commit <sha1>
- <repo2>: commit <sha2>

**Open tasks after deploy:** <list or "none">
```

This file will be included by the synthesizer (Step 4.2) as a mandatory section when `implementation_pipeline: true`.

---

## Step 3.7. Reflection before finalization (WP-484, pilot decision 30.07)

> **Why here:** a peer session is also a work Session; the reflection question is mandatory just as it is in a regular Quick Close (Phase 18) — the same gap was found and closed on 30.07 in `peer-conversation/SKILL.md` (Claude-writer); this is the same fix for the symmetric case (Kimi-writer, Claude-Peer partner). The threshold and wording are identical — Claude (Peer partner) remains the one with a live channel to the pilot and access to Skill/Bash, so the step below is executed by the Peer partner, not the writer.

**Threshold:** the same formula as in `peer-conversation/SKILL.md` §3.7 (reuses the fixed `gather-session-facts.sh`, WP-484 Phase 26, date parsing — do not reinvent):
```bash
START_TIME=$(grep '^start_time:' "$SESSION_DIR/meta.yaml" | sed -E 's/^start_time: *"?([^"]*)"?$/\1/')
NOW_EPOCH=$(date -u +%s)
START_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$START_TIME" +%s 2>/dev/null \
    || date -u -d "$START_TIME" +%s 2>/dev/null \
    || echo "$NOW_EPOCH")
DURATION_MIN=$(( (NOW_EPOCH - START_EPOCH) / 60 ))
```
If `DURATION_MIN ≤ 15` — skip, go to Step 4 silently.

If `duration_min > 15`:

1. Show the pilot a brief result (2–3 lines, the essence of the Session, not a retelling of turn files).
2. Ask: "What from this Session is worth remembering for the future — not about the task itself, but about how the work went?" (verbatim from Phase 18, `CONCEPT-night-cycle.md §18`).
3. Write the response (issue #409: the Script may not be present on every installation — do not block on absence):
   ```bash
   LEDGER_SCRIPT="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/ledger-append.sh"
   if [ -f "$LEDGER_SCRIPT" ]; then
     bash "$LEDGER_SCRIPT" day "$(date +%F)" session_reflection "{\"wp\": \"<WP-NNN>\", \"answer\": <escaped response>}" kimi-peer-writer
   else
     echo "ledger-append.sh is not available on this installation — reflection not written to daily ledger"
   fi
   ```
4. Tell the pilot: "You are free; I will close the Session from here" — continue with Step 4 without further pilot involvement.

Skipped response — do not block: `"answer": "no response"`, continue with Step 4.

---

## Step 4. Finalization

### 4.1 Update meta.yaml

```bash
TURNS_DONE=$(find "$SESSION_DIR" -maxdepth 1 -name "[0-9][0-9]-*.md" | wc -l | tr -d ' ')
END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmpf=$(mktemp)
sed "s/^status:.*/status: \"completed\"/" "$SESSION_DIR/meta.yaml" |
  sed "s/^end_time:.*/end_time: \"$END_TIME\"/" |
  sed "s/^turns_count:.*/turns_count: $TURNS_DONE/" |
  sed "s/^escalations_count:.*/escalations_count: $ESCALATIONS/" > "$tmpf"
mv "$tmpf" "$SESSION_DIR/meta.yaml"
```

### 4.2 Synthesize report-draft.md

> **Architectural Constraint:** Kimi-writer uses a bash pipe via `claude-peer-adapter.sh` because Kimi does not have access to the Claude Agent tool. Claude-writer (Skill `/peer-conversation`) uses the Agent tool — this is an intentional Distinction, not drift.

Run Claude as synthesizer via bash pipe (context isolation via stdin):
```bash

python3 - "$SESSION_DIR" "$SESSION_ID" <<'PYEOF'
import sys, os, glob, subprocess, datetime

session_dir, session_id = sys.argv[1:3]

# Read meta
meta_path = os.path.join(session_dir, 'meta.yaml')
meta = {}
with open(meta_path, encoding='utf-8') as f:
    for line in f:
        if ':' in line and not line.strip().startswith('#'):
            k, v = line.split(':', 1)
            meta[k.strip()] = v.strip().strip('"').strip("'")

writer_agent = meta.get('writer_agent', '')
peer_agent = meta.get('peer_agent', '')
start_time = meta.get('start_time', '')
escalations_count = meta.get('escalations_count', '0')
task_desc = meta.get('task_description', '')

# Gather turns
turn_files = sorted(glob.glob(os.path.join(session_dir, '[0-9][0-9]-*.md')))
turns_text = ''
for tf in turn_files:
    fname = os.path.basename(tf)
    with open(tf, encoding='utf-8') as f:
        body = f.read()
    turns_text += f'\n\n=== {fname} ===\n{body}'

outcome_path = os.path.join(session_dir, '_outcome.md')
outcome_text = ''
if os.path.exists(outcome_path):
    with open(outcome_path, encoding='utf-8') as f:
        outcome_text = f.read()

# Consistency guard: _outcome.md is absent but meta says implementation_pipeline: true
if not outcome_text and meta.get('implementation_pipeline', 'false').lower() == 'true':
    import re as _re
    with open(meta_path, encoding='utf-8') as _f:
        _mc = _f.read()
    _mc = _re.sub(r'^implementation_pipeline:.*$', 'implementation_pipeline: false', _mc, flags=_re.MULTILINE)
    with open(meta_path, 'w', encoding='utf-8') as _f:
        _f.write(_mc)
    meta['implementation_pipeline'] = 'false'

synth_prompt = f"""You are a synthesizer of dialogue results between two agents (DP.SC.154).
Session task: {task_desc}

Below is the full transcript of the dialogue (turns in numbered order):
{turns_text}

Read `meta.yaml` in the same directory — extract `roles`, `ad_hoc_roles`, `discovery_turns` for §1.5.

{('Additionally — implementation outcome (source for §6):' + chr(10) + outcome_text) if outcome_text else 'Implementation pipeline was not run — §6 omit.'}

CRITICAL: Do NOT use Write/Edit. Output markdown to stdout — it will be written to report-draft.md.
Do not wrap in ```markdown``` — write markdown directly.
Invariant: result_class=agreed → §4 is non-empty; not-agreed → §4 = "Consensus not reached".
§6 is mandatory if _outcome.md is present; omit if absent.
Verify anchors are mandatory for code references (file:line-range). Tags [synthesized] in §4.

STYLE: conversational for the pilot (DP.SC.050 A1-A11). Rewrite, do not copy turn files. Replace technical terms with plain language, remove machine markers (PASS, SHA, exit), use active voice.

---
schema_version: 1
session_id: {session_id}
generated_at: {datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', '')}Z
writer: {writer_agent}
peer: {peer_agent}
duration_min: <(end_time − start_time) in minutes, integer>
escalations_count: {escalations_count}
result_class: agreed | partial | escalated | not-agreed
confidence: low | med | high
confidence_basis: <required if confidence <= med; otherwise omit>
ttl_event: <"until merge PR-NNN" | "until WP-NNN" | "until pilot cancels" | omit>
cost_usd: <if known; otherwise omit>
cost_source: api | estimated | missing
roles: <from meta.yaml: roles — {{agent_id: [DP.ROLE.NNN, ...]}} or omit if empty>
ad_hoc_roles: <from meta.yaml: ad_hoc_roles — {{role_name: {{agent_id, rationale, first_used_turn}}}} or omit if empty>
discovery_turns: <from meta.yaml: discovery_turns, integer; omit if 0>
---

# Final Report

## Algorithm

## 1. Original task
- **Task:** <verbatim quote from pilot's assignment>
- **Writer's initial position:** <if recorded in 00-writer.md; omit if not>

## 1.5 Participant roles
Omit if `roles` is empty and `ad_hoc_roles` is empty.

**Formal roles:**
- Writer: <writer_agent>
- Peer partner (critic): <peer_agent>

**Content roles:**
- <agent_id>: <role> (source: Pack `DP.ROLE.NNN` | ad-hoc | not assigned)
- ...

**Ad-hoc roles (if any):**
- "<name>" — <agent_id>, <rationale>, first used in turn <first_used_turn>

**Discovery:** <discovery_turns> turns spent on role alignment (not counted in limit).

## 2. Positions by topic
For each topic (raised by both parties and influenced the outcome):

**Topic N: <formulation>**
- Initiator: writer | peer partner
- **Writer:** thesis → justification → anchor (file:line-range / Pack-ID)
- **Peer partner:** thesis → justification → anchor
- Evolution (opt.): if position changed — turn and reason
- Resolution: what was accepted + whose argument prevailed

## 3. Rejected alternatives
Omit if empty. Only alternatives argued by both parties OR rejected with a counter-argument.
- Alternative → reason for rejection → reference to turn

## 4. Recorded decision
- <Actionable formulation> [synthesized]
- **Main argument:** <one line>
- **Confidence:** low | med | high (if ≤ med — justification required)
- **TTL event:** <event binding or omit>

Invariant: agreed → non-empty; not-agreed — "Consensus not reached".

## 5. Open questions and escalations
Omit if empty.
- <Question or escalation>
- Status: needs-decision | needs-verification | deferred
- Reference: escalation-NN.md or NN-peer.md (if available)

## 6. Implementation and Verification
Omit if `implementation_pipeline: false` in meta.yaml.
If true — mandatory section, source = `_outcome.md` in the same directory.
- **Changed files:** list with one-line description of each
- **Code review iterations:** <N>
- **Unresolved:** <count High/Medium or "none">
- **Smoke verification:** PASS | FAIL
- **Deploy:** repo → commit SHA (for each affected Repository)
- **Open tasks after deploy:** list or "none"
- **References:** review-NN.md, verify-NN.md

## 7. Metadata and navigation
- **Log:** links to all NN-writer.md / NN-peer.md in order
- **Related Artifacts:** Pack IDs, files (PRs, specifications) — if mentioned
- **Cost:** $X (source: api / estimated / missing) — omit if missing
"""

import tempfile
with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False, encoding='utf-8') as tmp:
    tmp.write(synth_prompt)
    tmp_path = tmp.name

report_file = os.path.join(session_dir, 'report-draft.md')
gov_repo = os.environ.get('IWE_GOVERNANCE_REPO', 'DS-strategy')
adapter = os.path.expanduser(f'~/IWE/{gov_repo}/scripts/claude-peer-adapter.sh')

# synth_prompt above already inlines the full transcript, meta.yaml fields and
# _outcome.md into stdin — claude-peer-adapter.sh is a text-only reviewer by
# contract (WP-458) and unconditionally rejects --add-dir (exit 64). Passing
# it here made every synthesis call fail deterministically, not just under
# some failure condition; found via code review, confirmed by Codex reading
# the same two files independently, peer-session
# 2026-08-04-08-wp7-f44-sandbox-review. stderr is now captured (not
# discarded) so a future regression leaves an actual diagnostic in the
# fallback stub below instead of the same generic guess every time.
stderr_path = tmp_path + '.err'
try:
    with open(tmp_path, 'r', encoding='utf-8') as stdin_f, \
         open(report_file, 'w', encoding='utf-8') as stdout_f, \
         open(stderr_path, 'w', encoding='utf-8') as stderr_f:
        try:
            result = subprocess.run(
                ['bash', adapter],
                stdin=stdin_f,
                stdout=stdout_f,
                stderr=stderr_f,
                timeout=180
            )
        except (subprocess.TimeoutExpired, OSError):
            # Any launch failure, not just a timeout, folds into the same
            # returncode=1 path below — that branch already reads and cleans
            # up stderr_path; a narrower except here left it leaking on the
            # rarer OSError case (found in cold review, same peer-session).
            result = subprocess.CompletedProcess(args=[], returncode=1)
finally:
    os.unlink(tmp_path)

if result.returncode != 0 or os.path.getsize(report_file) == 0:
    stderr_tail = ''
    if os.path.exists(stderr_path):
        with open(stderr_path, encoding='utf-8') as f:
            stderr_tail = f.read()[-2000:]
        os.unlink(stderr_path)
    now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', '') + 'Z'
    with open(report_file, 'w', encoding='utf-8') as f:
        f.write(f"""---
session_id: {session_id}
generated_at: {now}
note: synthesis not performed (Claude unavailable, returned empty result, or timeout >180s)
---

# Final Report

Transcript: see turn files in the Session directory.
Retry synthesis: `/peer-writer --finalize {session_id}`

## Diagnostics (adapter stderr, for debugging — not for pilot)

```
returncode: {result.returncode}
{stderr_tail if stderr_tail else '(stderr empty)'}
```
""")
    sys.exit(1)
else:
    if os.path.exists(stderr_path):
        os.unlink(stderr_path)
PYEOF
```

> **Fallback:** the `report-draft.md` stub is written from inside the python block above (lines `if result.returncode != 0 or os.path.getsize(report_file) == 0`). No external bash fallback is needed — `sys.exit(1)` notifies the shell, but the Skill continues to Step 4.3 (the stub is already on disk). The stub now carries the return code and the adapter's stderr tail — the "Diagnostics" section is a service section (for debugging); the synthesizer does not see it and does not carry it into the final report.md.

### 4.2a Deferred finalization rule (post-2026-05-22)

> **Invariant:** `report.md` — final version only. Until an explicit Close signal from the pilot the file is named `report-draft.md`.

**On consensus (turn ≤ 10):**
- Do not rename to `report.md`.
- **Close-signal detector:** if the pilot's most recent message contains any of: `close it`, `let's close`, `done`, `close`, `wrap it up` — treat as a Close signal and proceed directly to finalization WITHOUT the choice question.
- Otherwise — ask the pilot: "Consensus reached. Shall we close the Session or do you need a follow-up?"
- If the pilot says "let's close" (or Close signal) → execute:
  ```bash
  mv "$SESSION_DIR/report-draft.md" "$SESSION_DIR/report.md"
  ```
  then proceed to Step 4.3.
- If the pilot requests follow-up → continue the turn-loop, and on the final Close append `## Addendum (turns N–M, <timestamp>)` to the same `report-draft.md`, then rename.

**On follow-up:**
```markdown
## Addendum (turns N–M, <timestamp>)

### Turn N — <topic>
...
```

**In `meta.yaml`:**
```yaml
extensions:
  - turns: [4, 5, 6]
    reason: "verification R23 + multiplier recalculation"
    appended_at: "2026-05-23T04:25"
```

**Prohibited:**
- Creating `report-v1.md`, `report-v2.md` — one Session = one report.
- Creating supplement directories — `sessions/YYYY-MM/DD/<id>/` = single namespace.
- Continuing to write `-writer.md`/`-peer.md` when `status: completed` — the status changes only after the Close signal.

### 4.3 Update sessions/00-index.md

Find the row with `<SESSION_ID>` and replace it entirely:
```
| <TODAY> | <SESSION_ID> | <task ≤50> | kimi / claude-code | <TURNS> | <ESCALATIONS> | completed | [report.md](<MONTH>/<DAY>/<SESSION_ID>/report.md) |
```
(Bash awk — safe for strings containing `|`.)

### 4.4 Closing (Opening/Closing — Session file next to the Session directory)

Slug part (without date and number): `SESSION_SLUG=$(echo "$SESSION_ID" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-//')`

Write `${IWE_GOVERNANCE_REPO:-DS-strategy}/sessions/<MONTH>/<TODAY>-<SESSION_SLUG>.md` (Write) — Quick Close file is flat under the monthly directory, without DD/ (symmetric with session-guard.sh; DD/ is for peer-session directories only):
```markdown
---
date: <TODAY>
type: peer-session
writer: kimi-headless
peer: claude-code
duration_h: <(end_time - start_time) in hours, 1 decimal>
artifacts: sessions/<MONTH>/<DAY>/<SESSION_ID>/report.md
session_id: <SESSION_ID>
wp: <WP-NNN or unknown>
---

# Key insight

<1-2 lines from §4 of report.md — the recorded decision>
```

### 4.5 Commit + push

```bash
(cd "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}"

# Pre-commit guard
test ! -f "$SESSION_DIR/report-draft.md" \
  || { echo "FAIL: report-draft.md exists — mv to report.md was not performed"; exit 1; }
test -f "$SESSION_DIR/report.md" \
  || { echo "FAIL: report.md is missing"; exit 1; }
CLOSE_FILE="sessions/$MONTH/${TODAY}-${SESSION_SLUG}.md"
test -f "$CLOSE_FILE" \
  || { echo "FAIL: close file $CLOSE_FILE is missing"; exit 1; }
INDEX_COUNT=$(grep -cF "| $SESSION_ID |" "sessions/00-index.md" || echo 0)
test "$INDEX_COUNT" -eq 1 \
  || { echo "FAIL: 00-index.md: expected 1 entry for $SESSION_ID, found $INDEX_COUNT"; exit 1; }

# pathspec after `--`: commit ONLY Session files (mis-attribution, 2026-06-20-39)
# PR flow (WP-436 Phase 2): push to feature branch + auto-merge PR → branch protection on main.
PATHS=("sessions/$MONTH/$DAY/$SESSION_ID/" "sessions/00-index.md" "sessions/$MONTH/${TODAY}-${SESSION_SLUG}.md")
BRANCH="peer/$SESSION_ID"
git checkout -b "$BRANCH" 2>/dev/null || git checkout "$BRANCH"
git add "${PATHS[@]}"
git commit -m "feat(peer): $SESSION_ID (kimi-writer) — <task brief>" -- "${PATHS[@]}"
git push origin "$BRANCH"
gh pr create --title "feat(peer): $SESSION_ID" \
  --body "Peer Session DP.SC.154. Kimi (writer) + Claude (peer)." \
  --base main --auto-merge 2>/dev/null \
  || echo "WARN: gh pr create failed — merge manually or check gh auth"
)
```

Notify pilot: "Session complete. Report: `sessions/$MONTH/$DAY/$SESSION_ID/report.md`"

---

## Step 5. Interrupt mode

On `--interrupt <session_id>`:

1. Extract month and day from the id: `MONTH=$(echo "$session_id" | cut -c1-7)`, `DAY=$(echo "$session_id" | cut -c9-10)` → find `sessions/$MONTH/$DAY/$session_id/meta.yaml`.
2. Update (Bash sed): `status: interrupted`, `end_time: <now>`, `turns_count: <number of files>`.
3. Find the row with `<session_id>` in `sessions/00-index.md` and replace it: status → `interrupted`, report → `—`.
4. Commit + push.

---

## Step 6. Finalize mode

On `--finalize <session_id>`:

1. Extract month and day: `MONTH=$(echo "$session_id" | cut -c1-7)`, `DAY=$(echo "$session_id" | cut -c9-10)`. Verify that the directory `sessions/$MONTH/$DAY/$session_id` exists and contains at least `00-writer.md`.
2. Read `meta.yaml` — extract `task_description`, `start_time`, `escalations_count`.
3. Execute **Step 4.2** (synthesize report-draft.md via `claude-peer-adapter.sh`) with the same invariants and fallback.
4. Update `meta.yaml` (Bash sed): `status: completed`, `end_time: <now>`, `turns_count: <number of files>`.
5. Update the row in `sessions/00-index.md`: status → `completed`, report → link.
6. Commit + push.

Used to recover interrupted Sessions without restarting the turn-loop.

---

## Report Verification

To check any existing report.md, write in chat:
"verify report for Session `<session_id>`"

Run a sub-agent (Sonnet, context isolation): read all Session files + report.md, check against schema_version=1 invariants (frontmatter, §4 non-empty when agreed, verify anchors).

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
