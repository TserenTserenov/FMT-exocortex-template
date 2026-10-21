---
agents: single
argument-hint: <task description> [--peer kimi|codex|hermes|claude[,vendor2,...]] |
  --list | --interrupt <session_id> | --finalize <session_id>
browser_safe: false
description: Multi-turn dialog between the writer (Claude) and one or more Peer partners
  (any combination of kimi/codex/hermes/claude-headless) on a pilot task (DP.SC.154).
  Runs a turn-loop (2 participants) or round-loop (3+, WP-509), detects CONSENSUS/ESCALATE,
  and after consensus executes a Decision Gate (record vs. implement → Review → verify
  → deploy), then synthesizes report.md via the Agent tool.
gates_enforced: []
gates_rationale: operational skill; WP Gate applicable only when creating a new WP,
  not for operational calls
gates_required: []
interaction: multi-step
layer: L1
name: peer-conversation
routing:
  deterministic: false
  executor: sonnet
status: active
triggers:
  phrases:
  - start peer-session
  - start a dialogue with Kimi
  - start a dialogue with Codex
  - peer-session
  slash:
  - /peer-conversation
version: 1.5.7
---

# Peer Conversation (DP.SC.154)

Task: $ARGUMENTS

> **Architecture:** I (Claude) = writer always (Skill tool is available only to me in this Session). Peer partner(s) — the `--peer` parameter (default `kimi`), a list of one or more registered vendors (§0v). With 2+ peers (N>2 total participants) — extension WP-509, see §0v and §3r.
> Each peer is called via its own `<vendor>-peer-adapter.sh` directly — Bash tool, stdin pipe. The shared contract defines stdin, stdout, and exit code values 0–7 when the adapter uses them (§0v.1). **The peer is not allowed to write files using its own tools inside `SESSION_DIR`** — stdout only (a file-write vs. stdout-capture race corrupts the log, found in WP-509 2026-07-30).
> `list_peer_statuses` (Local Gateway) — file coordination, **not** a peer CLI availability check.
> Gateway offline ≠ peer unavailable.

---

## When to use

Multi-turn dialog between the writer (Claude) and one or more Peer partners (any combination of registered vendors — Kimi, Codex, Hermes, a second Claude instance headless) on a pilot task (DP.SC.154). With one peer — turn-loop (a pair of turns). With two or more peers — round-loop (WP-509): each round every participant speaks, with an explicit role-discovery phase (rounds 0–2), reply validation against 4 criteria, a retry limit, and result classification `agreed|partial|escalated|not-agreed`. Detects CONSENSUS/ESCALATE; after consensus — Decision Gate (record vs. implement → Review → verify → deploy), then synthesizes report.md via the Agent tool.

## Scope boundary — does not replace decisions reserved for the pilot (found 2026-07-07)

> A Peer Session is suitable for: technical decisions, design, code review, finding a compromise between approaches, preparing decision candidates.
> **NOT suitable** for decisions that the process explicitly assigns to a human (for example, R15 Validator in `/apply-captures` — accept/reject/defer Knowledge candidates; R1 Strategist — monthly priorities). Agreement between two agents is not a pilot decision, even if unanimous and well-reasoned.
>
> If a task inside the Peer Session requires such a decision — the writer must stop and ask the pilot directly in the current chat (not via a turn file) before recording the result. See `.claude/skills/apply-captures/SKILL.md` section "R15 = live pilot, not agent" and `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/bugs/bug-2026-07-07-r15-decisions-bypassed-pilot.md` — the precedent that caused this Constraint.
>
> **This warning does not enforce the Constraint by itself (found at the Workshop 11–12.10.2026, the fifth recurrence of the same error class in three months — 07.07, 24.07, 21.09, 11–12.10).** The text is read once at the start of the Skill, but the violation happens many Steps later — at Step 3.6.1 (Implementation), when agreement at the Decision Gate (Step 3.5, the question about METHOD/scope — "record or implement now") is silently treated as a decision about the CONTENT of a reserved document that was never shown to the pilot. A mechanical stop inside the implementation step itself → see "Content Gate" in Step 3.6.1.

## Step 0. Mode

Determine the mode from `$ARGUMENTS`:

- `--list` → read `${IWE_GOVERNANCE_REPO:-DS-strategy}/sessions/00-index.md`, print the table. File does not exist → explicitly report "session index not yet created (the first Peer Session will create it, step 1.3); see past sessions in the sessions/YYYY-MM/DD/ tree" — do not stay silent (issue #568). Stop.
- `--interrupt <id>` → go to **Step 5 (interrupt mode)**. Stop after.
- `--finalize <id>` → go to **Step 6 (finalize mode)**. Stop after.
- Otherwise → new Session, continue to Step 0v.

---

## Step 0v. Peer selection (`--peer`)

> **Added 2026-07-29** (ArchGate: option "parameterize" vs. "separate skill per vendor" — evolvability blocked copy-paste, see `sessions/2026-07/2026-07-29-*-wp401-peer-vendor.md`). **Extended 2026-07-30 (WP-509):** list of N>1 peers instead of one.

Extract `--peer <vendor1,vendor2,...>` from `$ARGUMENTS` (comma-separated, no spaces). No flag → `PEER_VENDORS=(kimi)` (backward compatibility with versions before 1.4.0). Single vendor without comma → `PEER_VENDORS=(<vendor>)`, behavior identical to version 1.4.0 — do not create a separate code path for a single peer; `PEER_COUNT=${#PEER_VENDORS[@]}` controls branching (turn loop §3 when `PEER_COUNT==1`, round loop §3r when `PEER_COUNT>=2`).

**Vendor Registry** (the single mapping location — OwnerIntegrity; a new vendor is added only here):

| `PEER_VENDOR` | Adapter | `peer_agent` (meta.yaml) | Supports `--add-dir` | Supports `--model` | Special flag |
|---|---|---|---|---|---|
| `kimi` | `scripts/kimi-peer-adapter.sh` | `kimi-headless` | yes | yes | — |
| `codex` | `scripts/codex-peer-adapter.sh` | `codex` | yes | yes | — |
| `hermes` | `scripts/hermes-peer-adapter.sh` | `hermes` | **no** | **no** | `--session-id <id>` instead |
| `claude` | `scripts/claude-peer-adapter.sh` | `claude-code-headless` | **no** | yes | text-only; context in stdin |

Validate each element of `PEER_VENDORS` individually. Unknown `PEER_VENDOR` in the list → STOP **on that element, not on the whole list**: tell the pilot which specific vendor is not recognized ("Peer `<vendor>` is not registered. Known vendors: kimi, codex, hermes, claude."), offer to continue with the remaining recognized vendors or abort entirely. Adding a new vendor — edit the table above and write `<vendor>-peer-adapter.sh` per the §0v.1 contract.

**§0v.1 Shared adapter contract** (for adding a new vendor; WP-516 Ph4–Ph5). The shared contract defines observable behavior, not the command line of a specific CLI:

- **Request and response.** The adapter reads all of stdin and passes its content to the model without silent truncation; if a limit is reached, it rejects the call before invoking the CLI, logging the request length to stderr without the actual text. On success, stdout contains exactly one reply. CLI service banners, logs, and diagnostics do not appear there. The first non-empty line of a peer reply is `---`, followed by a closing `---` and the substantive body. A response that is empty after stripping whitespace yields code `1`; if the adapter implements a separate category `7`, it is used only for an empty response. Invalid frontmatter with a non-empty response yields code `1`. Writer calls that do not need a peer reply may explicitly set `IWE_PEER_PLAIN=1`; this is an Integration Layer exception, not a filter-bypass mode.
- **Arguments.** The maximum cross-vendor set is `-p`, `--model <name>`, `--add-dir <directory>`; the §0v table restricts support per vendor. An unknown or unsupported flag is rejected with a diagnostic; a foreign model name is mapped to a supported one or explicitly rejected. `--permission-mode` is excluded: vendors have no common safe semantics, and a caller-chosen value could weaken the read-only mode. For `claude`, `--add-dir` is also prohibited per WP-458.
- **Adapter exit codes.** `0` — successful reply; `1` — general error, including CLI failure/non-zero exit, invalid format, CLI refusal, or timeout; `2` — content filter error or violation; `3` — hard PII block; `4` — `--add-dir` payload too large; `5` — a call with the same session key is already in progress; `6` — confirmed authentication error; `7` — empty response after whitespace stripping. `0`/`1` are mandatory; categories `2`–`7` are optional, but when used they carry only the meaning defined here. Raw CLI codes in the range `2`–`7` do not pass outward without classification. Steps 3.1/3r.1 treat any non-zero code as an absent peer reply.
- **Access and deadline.** By default there is no access to the writer's file tree: text mode disables tools in the actual CLI Configuration and runs in an empty working directory. Permitted `--add-dir` provides only a filtered, read-only copy of the directory; the original path does not become the working root. For any file context, PII, `.agentignore`, and content filtering run before the CLI; if a required filter is absent or fails, the call is stopped. The writer prepares the text Projection for a vendor without file access in accordance with sensitive-content rules; the adapter does not promise to sanitize arbitrary stdin unless that sanitization is implemented in it. A new adapter defines a configurable timeout; on expiry it returns code `1` and terminates the entire CLI process group if the CLI spawns child processes. It also defines a concurrent-call protection key for the same session and checks for a lock before invoking the CLI. The presence of these mechanisms in already-registered vendors is verified separately.
- **IWE Integration boundary.** Auth method selection, statuses, logging, availability checks, and session binding belong to IWE Integration. Binary lookup goes through an explicit variable, PATH, and known installation paths where available. For a new adapter, acceptance tests cover: long prompt, invalid flag/model, CLI banner and empty response, timeout with process-group termination, collision, PII, and both access modes. This is a Requirement for new adapters, not an assertion that all registered vendors have these mechanisms: they are verified separately. The live write-prohibition is confirmed via a controlled attempt together with a sandbox Configuration check; the absence of a file in one test does not prove absolute isolation.

**Minimal adapter skeleton** (final output of WP-516 Ph5). This is an illustrative scaffold for `scripts/<vendor>-peer-adapter.sh`, not a ready-to-run file and not a registration of a new vendor. It deliberately fails before calling the CLI until the vendor-specific filters, locking, and sandbox are implemented; copying it alone does not qualify the adapter for inclusion in the §0v table.

```bash
#!/usr/bin/env bash
set -uo pipefail
die() { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }
tmp_root=$(mktemp -d) || die 'cannot create temporary directory'
trap 'rm -rf -- "$tmp_root"' EXIT
prompt_file="$tmp_root/prompt"
reply_file="$tmp_root/reply"
model=''
add_dirs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) shift ;;
    --model|--add-dir)
      flag="$1"
      [ "$#" -ge 2 ] && [ -n "$2" ] || die "$flag requires a value"
      case "$2" in -*) die "$flag requires a value, got another flag" ;; esac
      if [ "$flag" = --model ]; then model="$2"; else add_dirs+=("$2"); fi
      shift 2 ;;
    *) die "unknown or unsupported flag '$1'" ;;
  esac
done
cat > "$prompt_file" || die 'cannot read complete stdin'
[ -s "$prompt_file" ] || die 'empty prompt' 1

# Implement for the vendor and verify BEFORE invoking the CLI. Each stub
# stops the call: it cannot be replaced by passing the source directory directly.
filter_prompt_and_context() { die 'content and PII filters not implemented' 2; }
acquire_session_lock() { die 'session lock not implemented' 1; }
run_vendor_read_only_with_deadline() { die 'read-only CLI sandbox not implemented' 1; }
filter_prompt_and_context "$prompt_file" "${add_dirs[@]}"
acquire_session_lock "$model"
run_vendor_read_only_with_deadline "$model" "$reply_file"

grep -q '[^[:space:]]' "$reply_file" || die 'empty peer response' 7
if [ "${IWE_PEER_PLAIN:-0}" != 1 ]; then
  first_line=$(awk 'length { print; exit }' "$reply_file")
  fences=$(grep -c '^---$' "$reply_file" || true)
  [ "$first_line" = '---' ] && [ "$fences" -ge 2 ] || die 'missing peer frontmatter'
  awk '/^---$/ { fences++; next } fences >= 2 && /[[:alnum:]]/ { body = 1 } END { exit !body }' \
    "$reply_file" || die 'empty peer response body' 7
fi
cat "$reply_file" || die 'cannot emit peer response'
```

In the Template, adapters and source filters live in `${IWE_TEMPLATE:-$HOME/IWE/IWE}/scripts/`. A separate governance Repository may contain standalone copies of adapters and filters; changing the source does not deliver them there automatically. Such divergence requires a separate transfer with a content diff (`content-diff`). For the writer of this Skill, `ADAPTER_PATH[$vendor]="${IWE_TEMPLATE:-$HOME/IWE/IWE}/<adapter from table>"` and `PEER_AGENT_ID[$vendor]="<peer_agent from table>"` (bash associative arrays; call order = `PEER_VENDORS` order). Used everywhere below instead of hard-coding `kimi-peer-adapter.sh`/`kimi-headless`. (issue #830)

**§0v.2 Vendor capability check (WP-509 Ph5).** After building `ADAPTER_PATH`, before announcing peers:

1. **Duplicates** in the list (`--peer codex,codex`) → reject: N participants cannot be substituted by repeated calls to the same peer; tell the pilot, stop until the list is corrected.
2. **Check each `vendor`** (accumulate available ones in `remaining`):
   ```bash
   remaining=()
   for vendor in "${PEER_VENDORS[@]}"; do
     ok=true
     if [[ ! -x "${ADAPTER_PATH[$vendor]}" ]]; then ok=false; fi  # adapter missing or not executable
     if [[ "$vendor" == hermes ]] && ! command -v hermes >/dev/null 2>&1; then ok=false; fi  # hermes CLI unavailable
     $ok && remaining+=("$vendor") || :  # unavailable — candidate for removal (step 3)
   done
   ```
   Do NOT make a live probe call to the CLI: errors will surface when the adapter contract is invoked (exit ≠ 0, Step 3.1/3r.1); do not add vendor-specific knowledge beyond `hermes` to the Skill (otherwise Step 0v diverges from the adapters).
3. **Unavailable vendor** → tell the pilot which one and why (no adapter / no CLI), offer to continue with the remaining or abort — same UX as for an unregistered vendor (stop on element, not on list).
4. **Normalization after removals (atomic):**
   ```bash
   PEER_VENDORS=("${remaining[@]}")
   PEER_COUNT=${#PEER_VENDORS[@]}
   round_order=("${PEER_VENDORS[@]}")
   ```
   Mode is re-selected: `PEER_COUNT>=2` → round-loop (§3r), `==1` → turn-loop (§3 — the scenario "codex,hermes requested, only codex remained" runs as a classic two-participant dialog, not a truncated round), `==0` → unconditional stop with a message to the pilot.

Announce to the pilot:
```
Peer: <PEER_VENDOR> (<peer_agent>)                    # PEER_COUNT == 1, as before
```
or when `PEER_COUNT >= 2`:
```
Peers (<PEER_COUNT>):
  1. kimi (kimi-headless)
  2. codex (codex)
```

---

## Step 0b. Opening (WP Gate — new sessions only)

Find the WP for the task: read `${IWE_GOVERNANCE_REPO:-DS-strategy}/WP-REGISTRY.md` (grep by keywords) and `${IWE_GOVERNANCE_REPO:-DS-strategy}/current/WeekPlan W{N}.md`.

Announce to the pilot:
```
Opening Peer Session (DP.SC.154)
Role: Writer (Claude) | Peer(s): <PEER_VENDOR (PEER_AGENT_ID)>[, ...]
Task: <task>
WP: WP-NNN "<title>" | or: not found in plan
Method: turn-loop ≤10 turns (PEER_COUNT==1) | round-loop ≤rounds_limit rounds (PEER_COUNT>=2, WP-509)
```

If WP is **not found** in the week plan → full WP Gate Ritual (`memory/protocol-open.md §Session`):
announce the Artifact + wait for pilot confirmation → **proceed to Step 1 only after "yes"**.

If WP is found → continue without waiting.

**Determining the recommended writer model (WP-394 Ph4.6):**
```
# informational — pilot selects model at Claude Code startup, not auto-applied here
verification_class = from WP context or from task description
WRITER_MODEL_RECOMMENDED = "sonnet"   # default: closed tasks with tests/clear verification
if verification_class in ("open-loop", "problem-framing"):
    WRITER_MODEL_RECOMMENDED = "opus"
```
Announce to the pilot:
```
Recommended writer model: <WRITER_MODEL_RECOMMENDED>
(Task class: <verification_class>. Select the model at Claude Code startup.)
```

**Agent routing hint (WP-383, informational — not enforcement).**
Each work class has a recommended initiator/agent. This is a hint to the pilot, not a block:

| Work class | Recommended agent |
|--------------|---------------------|
| Cleanup / Formatting / Triage | Kimi (cheap, fast) |
| Shallow Verification (format/checklist/drift) | Kimi |
| Deep Verification (cross-file invariant) | Claude (statefulness) |
| Multi-file implementation / tight-loop | Claude (holds Session state) |
| Design / scope / planning | strong model (Claude/Opus or Kimi) |

**Escalation trigger (logged, not blocking):** if the pilot chooses an agent against the hint 2 times in a row — record the signal "routing table is outdated or classification is wrong" in `inbox/WP-383/routing-drift.log` (create on first trigger). Do not block the pilot's choice.

> Table source: `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/WP-383/routing-design-v1.md §3`. The Kimi statefulness gap is closed by auto-forwarding git-diff in `kimi-peer-adapter.sh` (§8).

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

Slug = the first 4 Latin words from the task in lowercase, hyphen-separated (non-Latin characters and dates are removed). No date in the slug — it is already in SESSION_ID. If there are no Latin words → `session`.

`SESSION_ID="${TODAY}-${NUM}-${SLUG}"`
`SESSION_DIR="${DAY_DIR}/${SESSION_ID}"`

**1.0 Session-guard open (WP-398, mandatory, BEFORE any Write/Edit in the session).** Synchronizes the Peer Session with the `session-guard.sh` Scope gate — without this, the commit at Step 4.5 will be blocked by the pre-commit Hook (mtime of session files is older than the semaphore). The WP comes from Step 0b (found, or "day-close"/"unknown" if no WP is assigned):

```bash
IWE_AGENT=claude-code bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" open \
  --wp "<WP-NNN from Step 0b>" --agent claude-code --close-path peer-session \
  --task "<task in one line>" --slug "$SESSION_ID"
```

> **Do not hard-code `~/IWE/scripts/session-guard.sh`.** The peer session 2026-07-31-16-wp484-new-order-cutover initially introduced such a hard-code following the pattern from `day-close/SKILL.md`, but a cold Review found that for a typical Template user `setup.sh` does NOT copy the root `scripts/` directory — only the scripts directory inside the Template exists, and `${IWE_SCRIPTS:-...}` resolves there intentionally (issue #266, commit `835d5ea` — that same hard-code was already fixed once with this fallback). The hard-code in `day-close/SKILL.md` is undocumented debt waiting for the same breakage at Promotion, not a pattern to copy. For author-mode the divergence is real (the FMT copy of `session-guard.sh` is behind the root copy by the WP-484 Thread 1 fixes) — but it is fixed by syncing `template-sync.sh` (with a separate pilot approval, S-33) or a personal edit to `~/.iwe-paths`, not by hard-coding a file that is promoted to all Template users.

If the command fails (exit ≠ 0) — do not block the Session: tell the pilot in one line "session-guard open failed (<reason>), continuing without semaphore — manual unblock via touch/note-file may be needed at Step 4.5" and proceed. The session-guard creates its own ORZ scaffold file at `sessions/<MONTH>/<TODAY>-<CLEAN_SLUG>.md` — the same path as the closing file from Step 4.4/4.5.0 (before 2026-08-03 these two places incorrectly assumed different paths, see the note at Step 4.4); Step 4.5.0 writes the final content into this same file rather than creating a new one.

**1.1 Create the directory:**
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
writer_agent: "claude-code"
personality: "<unassigned|UUID>"   # WP-510 Patch 4, layer 3: writer_agent = constructive implementation; personality = which AI persona (if there is an authoritative record in `current/AI Personalities Registry.md` for the current host/runner) led the session. Look up by host/runner in the registry — do not invent; no unambiguous match → "unassigned". Routing label, not a memory access grant.
peer_agent: "<first PEER_AGENT_ID from §0v>"      # backward-compat (PEER_COUNT==1: single value); full list — peer_agents
peer_cmd: "<first PEER_VENDOR>-peer-adapter"       # backward-compat; full list — peer_cmds
peer_agents: ["<PEER_AGENT_ID>", "..."]   # WP-509: in PEER_VENDORS order, length 1 when PEER_COUNT==1 (duplicates peer_agent); §4.2 reads ONLY this field for report.md peer: when PEER_COUNT>=2
peer_cmds: ["<vendor>-peer-adapter", "..."]   # WP-509: same length/order as peer_agents
round_order: ["<vendor>", "..."]   # WP-509: fixed round order (= PEER_VENDORS), only when PEER_COUNT>=2
write_token_holder: "writer_agent"   # WP-509: current write token holder; default = writer_agent, changed only via a confirmed ACCEPT_HANDOFF (see §3r.3)
peer_model: ""
status: "started"
turns_count: 0
turns_limit: 10        # PEER_COUNT==1: turn limit, unchanged from v4
rounds_limit: 6        # WP-509: round limit, applies only when PEER_COUNT>=2, does NOT override turns_limit
round_skips: {}        # WP-509: {round_NN: [vendor, ...]} — who did not respond/skipped a round; excluded from the "consensus from everyone" requirement in §3r.3
participant_status: {}  # WP-509: {vendor: active|failed} — final participant status after retries exhausted
max_peer_attempts: 2    # WP-509: retry limit for a single peer in one round
peer_attempts: {}      # WP-509: {vendor: N} — call counter for the current round
peer_failures: []      # WP-509: [{round, vendor, reason}] — recorded participant failures
handoff_history: []    # WP-509: [{round, from, to, reason}] — OFFER_HANDOFF/ACCEPT_HANDOFF log (write token, DP.SC.154 "Write token ≠ process_position")
escalations_count: 0
extensions: []
result_path: ""
task_description: "<task>"
implementation_pipeline: false
review_iterations: 0
verify_status: ""
deploy_shas: {}
writer_model_recommended: "sonnet"  # informational — pilot selects model at startup, not auto-applied; opus only for open-loop|problem-framing
# Sequential role-discovery (WP-367) — filled during Opening:
# If the pilot specified roles explicitly — populate `roles` immediately.
# If not — the initiator in turn 0 populates `proposed_roles` in the 00-writer.md frontmatter;
#           after agreement (turn 2) transfer them to `roles`.
roles: {}            # final: {agent_id: [DP.ROLE.NNN, ...]} after consensus
discovery_turns: 0   # how many turns were spent on role-discovery (not counted in turns_limit)
# Two-axis model (WP-367 Ph5, DP.SC.154 v4):
ad_hoc_roles: {}     # {role_name: {agent_id, rationale, first_used_turn}} — for cascade audit
swap_history: []     # [{turn, from, to, reason}] — SWAP_WRITER transition log
```

**If the pilot did not assign roles** at Session start — the initiator in turn/round 0 proposes a Role for itself and for **each** peer (see DP.SC.154 section "Session Opening: Sequential role-discovery"; when `PEER_COUNT>=2` — section "Role-discovery for N>2"). Discovery turns/rounds **are not counted** in `turns_limit`/`rounds_limit`.

**In-session ad-hoc role signal** (DP.SC.154 v4, Pack-extension cascade level 1). When using an ad-hoc Role (not in Pack `DP.ROLE.NNN`/`MIM.R.NNN`/`VR.R.NNN`) the agent **must immediately** announce it to the pilot — format:

```
Taking ad-hoc role "<name>". No such role exists in the Pack catalog.
Responsibilities: <one line>. Method: <one line>.
Proposing to create a WP for formalization (~30 min: passport + scenarios + templates).
Choose:
  A. Create now → separate WP "pack-gap-<name>" via create-wp.sh.
  B. Defer → I will continue as ad-hoc; the guardian will remind you at Week Close.
```

The entry in `meta.yaml.ad_hoc_roles` is written regardless of the choice (for back-up at level 2 — Week Close audit). If the pilot chose A — after the Session the writer opens a separate WP and performs the formalization.

**1.3 Add a row to `sessions/00-index.md`** at the top of the table (first row after `|---|`). The "Agents" column — when `PEER_COUNT>=2` peers are joined with `+`:

> **File does not exist — create it now** (issue #568: installation does not create the index, and before this fix the step was silently skipped — eight sessions in a row with no entries at all). Temporary measure until WP-526 (the MC family will migrate the index to snapshot mechanics — remove this block when migrating). The created file must honestly declare its incompleteness directly inside itself (not in stdout — output is lost, and the file is read weeks later):
> ```bash
> IDX="${IWE_GOVERNANCE_REPO:-DS-strategy}/sessions/00-index.md"
> if [ ! -f "$IDX" ]; then
>   mkdir -p "$(dirname "$IDX")"
>   {
>     echo "# Peer Session Index"
>     echo ""
>     echo "<!-- index regenerated on $(date +%Y-%m-%d): created empty by peer-conversation step 1.3 (issue #568) — sessions before this date exist on disk but are NOT backfilled here; the folder tree sessions/YYYY-MM/DD/ is the authoritative record -->"
>     echo ""
>     echo "| Date | Session | Task | Agents | Turns | Escalations | Status | Report |"
>     echo "|------|--------|--------|--------|------|-----------|--------|-------|"
>   } > "$IDX"
> fi
> ```

```
| <TODAY> | <SESSION_ID> | <task ≤50 chars> | claude-code / <PEER_VENDOR1>[+<PEER_VENDOR2>...] | 0 | 0 | started | — |
```

---

## Step 2. Writer turn 00-writer.md

Write `${SESSION_DIR}/00-writer.md` (Write):

```markdown
---
turn: 0
role: writer
agent_id: claude-code
timestamp: <ISO-8601 UTC>
consensus: none
---

<My opening position — task analysis, theses, specific questions to the peer(s).
When `PEER_COUNT>=2` — propose a substantive Role to each peer individually (not just a "role for the group"), with per-peer reasoning (DP.SC.154 "Role-discovery for N>2").
NOT a retelling of the task. A position with arguments.>
```

Show the pilot a brief summary: what was written in 00-writer.md.

---

## Step 2.5. Role-discovery for N>2 (PEER_COUNT >= 2, WP-509)

> **Skip if PEER_COUNT == 1.** For two participants, discovery reduces to proposing roles in 00-writer.md and agreeing in the turn-loop.

After 00-writer.md, run **rounds 0–2**, which **are not counted** in `rounds_limit`.

### 2.5.1 Round 0 — writer proposes roles

In 00-writer.md (Step 2) the writer already proposes a substantive Role for each peer. Additionally, write to the frontmatter of `00-writer.md`:
```yaml
proposed_roles: { "<PEER_AGENT_ID>": "<role_name>", ... }
suggested_initiator_role: "<role_name>"
```

### 2.5.2 Round 1 — each peer confirms or disputes their role

Call each peer in `round_order` order with a prompt similar to §3r.1, but with the sole task of:
- reading 00-writer.md;
- agreeing with the proposed Role, suggesting a change, or requesting clarification from the pilot;
- explicitly confirming that they understand the Constraint "reply in stdout only, no file operations in SESSION_DIR".

Reply format:
```yaml
---
turn: 0
role: peer
agent_id: <PEER_AGENT_ID>
content_role: <agreed/proposed role>
process_position: peer
timestamp: <ISO-8601 UTC>
consensus: none
role_accepted: true | false | clarify
---

<Reasoning for accepting the role or request for clarification>
```

If `role_accepted: clarify` — the writer clarifies with the pilot and repeats round 1 only for that participant (does not count as a separate discovery round).

### 2.5.3 Round 2 — recording agreed_roles

The writer writes `01-writer.md` (turn: 0, role: writer) with the final roles table:
```yaml
---
turn: 0
role: writer
agent_id: claude-code
consensus: none
agreed_roles: { "<PEER_AGENT_ID>": "<role_name>", ... }
writer_role: "<role_name>"
discovery_turns: 1   # how many additional passes of round 1 were needed
---
```

Update `meta.yaml`:
```yaml
roles: { "claude-code": ["<writer_role>"], "<PEER_AGENT_ID>": ["<role_name>"], ... }
discovery_turns: <N>
```

Only after this proceed to **Step 3r (ROUND=1)** with substantive rounds.

---

## Step 3. Turn loop (PEER_COUNT == 1)

> **When `PEER_COUNT >= 2` — skip this step entirely, go to Step 3r (round loop, WP-509).** This step is unchanged from version 1.4.0 — one peer, behavior identical.

Variables: `TURN=1`, `ESCALATIONS=0`, `DONE=false`.

### 3.1 Call the peer

Read all previous turns from `SESSION_DIR` in numbering order.
Compose the prompt:

```
You are a peer agent in a dialog session (DP.SC.154).
Session: <SESSION_ID>
Turn: <TURN> of 10
Task: <task>

The context Projection below is the only source about the session. Do not read files or use tools:
<minimal text Projection of previous turns and verifiable facts>

Write your reply to stdout with frontmatter:
---
turn: <TURN>
role: peer
agent_id: <PEER_AGENT_ID>
timestamp: <ISO-8601 UTC>
consensus: none | proposed | reached | escalate
---

<Your response>

Critic rule: find AT LEAST ONE thesis or assumption from the writer that you disagree with. Do not yield after the first objection — hold your position with arguments. If everything is genuinely OK — explain specifically why, not just "I agree".

Markers (strictly at the start of a line):
CONSENSUS: <summary> — if you believe agreement has been reached
ESCALATE_TO_USER: <reason> — if the writer is ignoring a significant objection
```

Call the peer via Bash — flags depend on the vendor (table §0v):

```bash
PEER_FILE="${SESSION_DIR}/$(printf '%02d' $TURN)-peer.md"
if [ "$PEER_VENDOR" = "hermes" ]; then
  # hermes-peer-adapter.sh does not accept --add-dir/--model — uses its own --session-id.
  # Do NOT confuse with the Peer Session $SESSION_ID: the adapter always sends the
  # passed --session-id as `--resume <id>` to the hermes CLI — on the very first call
  # of this Peer Session, Hermes does not yet have a dialog with the Peer Session ID
  # (these are two separate identifier namespaces); `hermes chat --resume <nonexistent>`
  # fails silently (set -euo pipefail in the adapter suppresses its own diagnostics before
  # they can print) — found live 2026-07-31/08-01, WP-484/WP-509.
  # The native Hermes session_id is read FROM DISK (the last written NN-peer.md),
  # not from a shell variable — the agent makes each call as a separate Bash tool, and
  # variables do not survive across tool-call boundaries (found in code review 01.08).
  HERMES_LAST_ID=$(grep -h "^session_id: " "${SESSION_DIR}"/[0-9][0-9]-peer.md 2>/dev/null | tail -1 | sed 's/^session_id: //')
  if [ -z "$HERMES_LAST_ID" ]; then
    echo "<prompt>" | bash "$ADAPTER_PATH" > "$PEER_FILE" 2>/dev/null
  else
    echo "<prompt>" | bash "$ADAPTER_PATH" --session-id "$HERMES_LAST_ID" > "$PEER_FILE" 2>/dev/null
  fi
else
  printf '%s\n' "<prompt with minimal text Projection>" | bash "$ADAPTER_PATH" \
    > "$PEER_FILE" 2> "${PEER_FILE%.md}.err"
fi
```

If the file is empty or exit ≠ 0 → tell the pilot: "<PEER_VENDOR> did not respond. Retry or abort?"

### 3.2 Show the pilot

Read `$PEER_FILE`. Output the key theses from the peer (not the full reply verbatim — a brief summary + quotes of key positions).

### 3.3 Check markers

**ESCALATE_TO_USER:**
If `grep -q "^ESCALATE_TO_USER:" "$PEER_FILE"`:
- Extract the reason: `grep "^ESCALATE_TO_USER:" "$PEER_FILE" | sed 's/^ESCALATE_TO_USER: //'`
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
**Peer turn:** <PEER_FILE>
**Pilot response:** (enter below)
```

- Tell the pilot: "<PEER_VENDOR> escalates: <reason>. Your decision is needed."
- Wait for the pilot's response, write it to `pilot_response` in the escalation file.
- Update `meta.yaml`: `escalations_count: <ESCALATIONS>` (Bash sed).

**CONSENSUS:**
If `grep -q "^CONSENSUS:" "$PEER_FILE"`:
- Extract the summary.
- `DONE=true`, go to **Step 3.5 (Decision Gate)** — NOT directly to Step 4.

### 3.4 Writer turn

If `TURN >= 10` → `DONE=true`, go to Step 4.

Write `$(printf '%02d' $((TURN+1)))-writer.md` (Write):
```markdown
---
turn: <TURN+1>
role: writer
agent_id: claude-code
timestamp: <now>
consensus: none
---

<My turn: response to the peer's arguments + incorporating the pilot's direction>
```

`TURN += 1` → return to 3.1.

---

## Step 3r. Round loop (PEER_COUNT >= 2, WP-509)

> **Skip if `PEER_COUNT == 1`** — the classic Step 3 applies there.

Variables: `ROUND=1`, `ESCALATIONS=0`, `DONE=false`. Round order = `PEER_VENDORS` in `--peer` order (recorded in `meta.yaml.round_order` at Step 1.2).

### 3r.1 Call each peer in round order

`WRITE_TOKEN_HOLDER` — read from `meta.yaml.write_token_holder` (the default written at Step 1.2 = `writer_agent`: the writer holds the write token until no `ACCEPT_HANDOFF` has occurred). The value is passed into the prompt explicitly — peers are not expected to read `meta.yaml` themselves to find the current holder.

For each `vendor` in `round_order` (sequentially, not in parallel — each subsequent peer sees the replies of previous peers in the same round), compose the prompt:

```
You are a peer agent in a dialog session (DP.SC.154, N>2 participants).
Session: <SESSION_ID>
Round: <ROUND> of <rounds_limit>
Task: <task>
Current write token holder: <WRITE_TOKEN_HOLDER>

For Claude: pass a minimal text Projection of all necessary turns and facts for this round in its stdin. It does not read the session log and does not use tools. For other peers, use their own contract.

IMPORTANT: reply in stdout only. Do not use your file tools on any
file in this directory — this creates a race with stdout capture and corrupts the session log.

Write your reply to stdout with frontmatter:
---
turn: <ROUND>
role: peer
agent_id: <PEER_AGENT_ID>
content_role: <agreed role or proposal if not yet agreed>
process_position: peer
timestamp: <ISO-8601 UTC>
consensus: none | proposed | reached | escalate
---

<Your response>

Critic rule: find AT LEAST ONE thesis you disagree with — your own or another peer's.

Markers (strictly at the start of a line):
PASS — if you have nothing to add in this round (not an error, an explicit right to remain silent)
CONSENSUS: <summary> — if you agree with the outcome
ESCALATE_TO_USER: <reason> — if a significant objection has been ignored
OFFER_HANDOFF: <agent_id> — <reason> — if you want to offer your write token to another (only if you currently hold it)
ACCEPT_HANDOFF — if you accept an OFFER_HANDOFF directed at you
REQUEST_HANDOFF: <reason> — a non-binding request to the holder
```

Call the peer via Bash (prompt — to a temp file, not inline `echo` — the same B7.7c risk as in §0v.1):

```bash
PEER_FILE="${SESSION_DIR}/$(printf '%02d' $ROUND)-peer-${vendor}.md"
PROMPT_FILE=$(mktemp)
# write the prompt (see template above) into $PROMPT_FILE
if [ "$vendor" = "hermes" ]; then
  # Same contract and same trap as in Step 3.1 (turn-loop) — hermes does not accept
  # --add-dir, and the passed --session-id is always treated as --resume. The native
  # hermes session_id is read FROM DISK (the last written NN-peer-hermes.md),
  # not from a shell variable — the agent makes each call as a separate Bash tool, and
  # variables do not survive across tool-call boundaries (found in code review 01.08).
  HERMES_LAST_ID=$(grep -h "^session_id: " "${SESSION_DIR}"/[0-9][0-9]-peer-hermes.md 2>/dev/null | tail -1 | sed 's/^session_id: //')
  if [ -z "$HERMES_LAST_ID" ]; then
    cat "$PROMPT_FILE" | bash "${ADAPTER_PATH[$vendor]}" > "$PEER_FILE" 2>/dev/null
    STATUS=$?
  else
    cat "$PROMPT_FILE" | bash "${ADAPTER_PATH[$vendor]}" --session-id "$HERMES_LAST_ID" > "$PEER_FILE" 2>/dev/null
    STATUS=$?
  fi
else
  if [ "$vendor" = "claude" ]; then
    cat "$PROMPT_FILE" | bash "${ADAPTER_PATH[$vendor]}" > "$PEER_FILE" 2> "${PEER_FILE%.md}.err"
  else
    cat "$PROMPT_FILE" | bash "${ADAPTER_PATH[$vendor]}" --add-dir "$SESSION_DIR" > "$PEER_FILE" 2>/dev/null
  fi
  STATUS=$?
fi
rm -f "$PROMPT_FILE"
```

**3r.1a Reply validation (WP-509)**

Apply **before** recording in `round_skips` or consensus. A reply is considered `valid` if all 4 checks pass (with an exception for discovery rounds, see below):

1. **On-topic:** file is not empty, frontmatter is parsed, body contains a response to the round's task (not just formulaic phrases / restatement of the prompt).
2. **Role fulfilled:**
   - In **discovery rounds 0–2** (`PEER_COUNT >= 2`): `content_role` matches the Role proposed in `00-writer.md.proposed_roles` for this `agent_id`, or the peer explicitly proposes a different ad-hoc Role with reasoning.
   - In **substantive rounds** (`ROUND >= 1` after §2.5.3): `content_role` matches the Role agreed in `meta.yaml.roles` for this `agent_id`; if the reply proposes an ad-hoc Role — see §1.2 "In-session ad-hoc role signal".
3. **No side effects:** the stdout reply contains no markers of the form `FILE_WRITTEN`, `MEMORY_UPDATED`, `TOOL_CALLED`, etc.; additionally, **do not check the file system directly** — the adapter guarantees isolation, but a participant agent may declare actions in its text.
4. **Factual consistency:** if the reply references a specific fact (SHA, file name, WP status, commit), verify it against available sources; on mismatch — `failed` with reason `fact_mismatch`.

If the reply is `invalid`:
- Increment `meta.yaml.peer_attempts[vendor]`.
- If `peer_attempts[vendor] < max_peer_attempts` — retry that peer in the same round with a clarifying prompt (reason for invalid + round context).
- If `peer_attempts[vendor] >= max_peer_attempts` — record `meta.yaml.peer_failures += [{round: ROUND, vendor: vendor, reason: <check>}]`, set `meta.yaml.participant_status[vendor] = "failed"`, exclude vendor from the consensus Requirement in §3r.3 (like `round_skips` but with explicit `failed` status).

Empty file or `STATUS != 0` → this peer is skipped in this round (does not block the round, DP.SC.154 "Rounds instead of an infinite loop"): record `meta.yaml.round_skips.round_<NN>: [..., vendor]`, increment `peer_attempts[vendor]`; when retries are exhausted — `participant_status[vendor] = "failed"` and `peer_failures += [...]`.

### 3r.2 Show the pilot

Summary for EACH peer in the round (not just the last one) — who said what, briefly.

### 3r.3 Check markers in all round replies

Applies to the peer replies of this round (3r.1) **and**, on return from 3r.4, to the writer's reply of the same round — marker processing is identical for both roles; the only difference is that the writer writes last in the round.

- `ESCALATE_TO_USER` from any participant (including the writer) → same process as in §3.3 (write `escalation-NN.md`, pause for pilot response).
- `OFFER_HANDOFF`/`ACCEPT_HANDOFF`/`REQUEST_HANDOFF` from any participant → on a confirmed `ACCEPT_HANDOFF` (the addressed reply responds to an `OFFER_HANDOFF` from a previous reply) — append `{round, from, to, reason}` to `meta.yaml.handoff_history` AND update `meta.yaml.write_token_holder` to the new holder. `REQUEST_HANDOFF` without a corresponding `OFFER_HANDOFF` from the holder — changes nothing; the request is recorded in the reply and that is all.
- `CONSENSUS` — "round consensus": only participants with `active` status are counted (not in `round_skips` for this round and not with `participant_status == failed`). `DONE=true` if every active participant has either `CONSENSUS` or `PASS` without counter-arguments in the reply body. At least one substantive counter-argument without `CONSENSUS` from an active participant → round is not closed.
  - If all active participants posted `CONSENSUS`/`PASS` → `result_class` for report.md = `agreed`.
  - If consensus is reached among active participants but one or more have `participant_status == failed` (retries exhausted in this or earlier rounds) → `DONE=true`, but `result_class` = `partial`; failed participants and reasons are recorded in `report.md §5`.
  - If no participant has `CONSENSUS`/`PASS` but all technically replied — round is not closed; continue (or `ROUND >= rounds_limit` → §3r.5).

### 3r.4 Writer turn

If 3r.3 already set `DONE=true` based on peer replies in this round → the writer does not write a turn in this round; go directly to Step 3.5 (Decision Gate).

Otherwise — the writer responds (`$(printf '%02d' $ROUND)-writer.md`, same frontmatter format as in Step 2, plus the same markers `CONSENSUS`/`ESCALATE_TO_USER`/`OFFER_HANDOFF`/`ACCEPT_HANDOFF`/`REQUEST_HANDOFF` as for peers — the writer can also hold or pass the write token). Apply the marker checks from 3r.3 to this reply.

If after this `DONE=true` (the writer posted `CONSENSUS`, accepting the round's position) → Step 3.5.

Otherwise, if `ROUND >= rounds_limit` (default 6) → go to 3r.5 (disagreement without consensus).

Otherwise — `ROUND += 1` → 3r.1.

### 3r.5 Disagreement among 3+ positions (after rounds_limit exhausted without consensus)

> Account for `participant_status`: participants with `failed` status do not vote and do not block the remaining participants from reaching a decision.

Apply the reversibility criterion (DP.SC.154 "Resolving disagreement among 3+ positions") **before** escalation:
- Decision is reversible and within the authority of **active** participants → the writer records the majority position among `active` (2 of 3, or a majority when N>3), minority dissent in `report.md §3 "Rejected Alternatives"`, `DONE=true`, `result_class` = `partial` if there are `failed` participants, otherwise `agreed` → Step 3.5.
- Decision is irreversible, out of scope, OR the reversibility itself is disputed → `ESCALATE_TO_USER: rounds_limit exhausted, no consensus, irreversible or scope-disputed` → pause for the pilot.

---

## Step 3.5. Decision Gate (after consensus)

> **When it fires:** `DONE=true` via CONSENSUS marker in Step 3.3 (turn-loop) or 3r.3 (round-loop) — not via `TURN >= 10`/`ROUND >= rounds_limit` without consensus; those go directly to Step 3r.5 or Step 4.
> **Why:** consensus ≠ implementation. This is a **legitimate choice question** for the pilot (choosing work scope, not a yes/no on a ready decision). Exception to P5 — the pilot confirmed: "I need to sign off here" (trigger 2026-05-30, WP-367 Ph5).
> **Mandatory:** before the question — **a plain-language consensus summary** so the pilot can make an informed choice. A question without a summary is a mechanical "choose A/B" with no understanding.

Extract the consensus summary: `PEER_COUNT==1` → `grep "^CONSENSUS:" "$PEER_FILE" | sed 's/^CONSENSUS: //'`. `PEER_COUNT>=2` → scan all `${SESSION_DIR}/$(printf '%02d' $ROUND)-peer-*.md` from the last round, take the summary from the first file with a `CONSENSUS:` marker (if the wording differs — the writer synthesizes a single sentence, rather than arbitrarily picking one voice).

**Plain-language summary** — mandatory. Format (no technical terms, codes, or paths):

```
Consensus reached.

What was discussed: <one phrase>
What was agreed: <2-3 lines in plain language — the essence of the decision>
What is proposed for implementation: <list of changes, one line each; no files or paths>
Estimated implementation time: ~<N>h (including Review + smoke + deploy)
Impact on other users: <if any — what and how it is delivered; if none — "local only">
```

After the summary — choice question:

```
What next?
  A. Record only → Step 4 (report.md + commit + close).
     Implementation — a separate WP/phase in a later session.
  B. Implement now → Review → verify → deploy → Step 4.
```

Wait for the pilot's response. Record the choice in `meta.yaml` (Bash sed):
```yaml
implementation_pipeline: false | true
```

- **A** → `IMPLEMENTATION=false`, go to Step 4.
- **B** → `IMPLEMENTATION=true`, go to Step 3.6.

**Default when the pilot is silent:** B (implement now), per rule 11 "finish > defer". Apply only if the pilot clearly did not respond within a reasonable time (for example, skipped the Decision Gate in a script).

**Triggers automatic-defer** (without asking the pilot — go directly to A):
1. Implementation requires a new WP (new scope not covered by the current WP).
2. An ArchGate is required (new system-level architectural decision).
3. Context has fully switched (a different part of the system; a new framing is needed).

When a trigger fires — announce to the pilot with the summary (NOT a question), then Step 4.

---

## Step 3.6. Implementation Pipeline (optional)

> **Activated:** only when `IMPLEMENTATION=true` in Step 3.5.
> **Principle:** the writer applies the decision → a cold-context Agent does a code Review → the writer fixes → built-in `/verify` runs smoke → deploy → "Implementation and verification" section in report-draft.md.
> **Ending:** in any sub-step the writer can escalate to the pilot via an `ESCALATE_TO_USER:` marker (as in Step 3.3) — write `escalation-NN.md`, wait for a response.

### 3.6.1 Implementation

**Content Gate for reserved decisions (found at the Workshop 11–12.10.2026 — see "Scope boundary" above; strengthened 12.10 after the second and third recurrence in the same session, see below).** Before the announcement below, check every file in the future `CHANGED_FILES` against the list of "decisions reserved for the pilot" (Scope boundary: WeekPlan, Strategy.md, monthly-priorities.md, the WP pool/weekly list, hypothesis log verdicts — any document where the content is a decision, not the method of executing it):

- The peer(s)' agreement at the Decision Gate (Step 3.5) covers ONLY what was explicitly asked there — as a rule, the method and scope ("record or implement now", "do X now or later"). It does not extend to the content of such a file if the specific edit was never shown to the pilot.
- **Rule ≠ ready result (found at the Workshop 12.10, same day, third consecutive recurrence).** The pilot may respond not with a ready line-by-line list but with a rule or criterion ("keep only what relates to N monthly directions"). A rule is not a decision for each line: the writer must first APPLY the rule and COMPUTE the result, then show the pilot exactly that computed result (who is kept, who is removed) and wait for confirmation of THAT result specifically — before any file edit. The pilot's rule formulation alone does not close the gate.
- **Before EACH edit of a file from this list, not just before the first one in a session (found at the Workshop 12.10, same day, second recurrence).** The previous wording "before the first Edit/Write of this file" incorrectly permitted skipping the show-and-wait for the second and subsequent edits of the same file in one session — a live example: the first edit of the week plan passed through show-and-wait, the second (different content, different reason) was published without showing it again because the "first edit of this file" had already happened earlier. Each edit that changes the content of a set/decision (not just the very first) requires its own presentation and its own wait — the "gate already passed for this file in this session" credit is prohibited.
- If even one file falls into this list — the file and method announcement below is NOT sufficient on its own. Before EACH Edit/Write of such a file that changes content (not formatting without changing the decision), present the pilot with the full content of the proposed edit (a line-by-line diff for edits to existing lines; the full candidate table — if the set composition changes, e.g. the weekly WP pool) and wait for a decision on each line/change individually, not a general "yes, continue".
- Without this presentation, Edit/Write of such a file is prohibited — this is a stop of the step itself, not a reminder earlier in the Skill text.

Announce to the pilot:
```
Implementing consensus <SESSION_ID>
Files: <list of files with absolute paths>
Repo: <repo names, separated by " · ">
Method: Edit/Write tools directly
```

The writer applies changes via Edit/Write. Prohibited:
- Modifying files outside the announced list without a new announcement.
- Committing at this stage (commit — Step 3.6.5 only).
- Applying Edit/Write to a file from the "decisions reserved for the pilot" list without passing the Content Gate above — every time, including repeated edits of the same file in the same session.

Record the list of changed files in the variable `CHANGED_FILES` (one path per line).

### 3.6.2 Code Review (cold-context)

Iteration variables: `REVIEW_ITER=1` on first entry to 3.6.2, incremented in 3.6.3 on Critical.

Save the report to `${SESSION_DIR}/review-$(printf '%02d' $REVIEW_ITER).md` (Write).

Call `Agent` (subagent_type: general-purpose) with an explicit checklist:

```
Agent(
  description: "Code review post-consensus",
  subagent_type: "general-purpose",
  prompt: """
    Cold-context code review of peer session <SESSION_ID> results.

    Consensus context: <summary from 3.5>
    Changed files:
    <CHANGED_FILES>

    Read each file (only the indicated lines/functions, not the full file if it is large).
    Check against the checklist:
    1. asyncio runtime: look for `wait_for(coro)` without `shield` → coroutine reuse. Look for fire-and-forget tasks that read/write the same DB row from different places.
    2. Shell ordering: function call BEFORE function definition. Is `set -u` respected?
    3. SQL race: cross-file writers to the same row without atomicity (UPDATE ... RETURNING or SELECT FOR UPDATE).
    4. Lock enforcing: on collision — `exit N` or `log WARN && continue`? If advisory — is this intentional or a bug?
    5. Consensus-specific context: <add from summary if there are invariants>.

    Return the report in the format:
    ## Critical (must fix before deploy)
    - <file:line-range>: <issue> | fix: <concrete fix>
    ## High
    - ...
    ## Medium
    - ...
    ## OK (what was checked and is fine)
    - ...

    Do not suggest refactoring or style changes — only runtime bugs and checklist violations.
  """
)
```

Save the reviewer's report to `${SESSION_DIR}/review-NN.md` where `NN = printf '%02d' $REVIEW_ITER` (Write).

### 3.6.3 Review Outcome

Show the pilot a brief summary of the report (Critical + High count + one example).

**If there are Critical items:**
- Apply fixes (Edit) → increment `REVIEW_ITER += 1` → return to 3.6.2 (new review-NN.md).
- Iteration limit: 3. If Critical items remain after the 3rd iteration → ESCALATE_TO_USER with the latest review attached.

**If only High/Medium:**
- Ask the pilot: "There are N High and M Medium findings. Fix now or after deploy?"
- Record the decision in meta.yaml (`review_iterations: <N>`, `unresolved: <count>`).

**If only OK:**
- Continue to 3.6.4.

### 3.6.4 Smoke Verification

Call built-in `/verify` via Skill tool:

```
Skill(
  skill: "verify",
  args: "Smoke test changes from peer session <SESSION_ID>. Files: <CHANGED_FILES>. Consensus invariants to check: <list from 3.5 — what must work>. Run the application/tests, check behavior, return PASS/FAIL with traceback on FAIL."
)
```

`/verify` decides how to verify (running the application, pytest, manual instructions for UI).

**Result:**
- PASS → go to 3.6.5.
- FAIL → show the traceback to the pilot, ask "fix and retry or escalate?"
  - "fix" → Edit → return to 3.6.2 (Review after fixes) or directly to 3.6.4 if the fix is targeted (with pilot agreement).
  - "escalate" → ESCALATE_TO_USER + escalation-NN.md.

Save the `/verify` output to `${SESSION_DIR}/verify-01.md`.

### 3.6.5 Deploy

For each repo in the list of changed files:

```bash
(cd <repo path>
git status --short
# pathspec after `--`: commit ONLY own files. Bare `git commit` sweeps in
# others' pre-staged files from the shared index (mis-attribution, see 2026-06-20-39).
git add <specific files — NOT git add . and NOT git add -u>
git commit -m "<type>(<scope>): <short description>

Refs: peer-session <SESSION_ID>
Review iters: <REVIEW_ITER>
Verify: PASS" -- <same specific files>
git push
)
```

Record the commit SHA for each repo in the variable `DEPLOY_SHAS` (map: repo → sha).

**If push fails** (pre-commit Hook rejected, conflict with remote):
- Do NOT bypass Hooks (`--no-verify` is prohibited by rule 6).
- Record in logs, show to the pilot, ESCALATE_TO_USER.

### 3.6.6 Outcome addendum to report-draft.md

Before Step 4 (finalization) the writer appends to `${SESSION_DIR}/report-draft.md` (if the file already exists — append; if not yet — note that it will be created in 4.2 with this section included) a note for the synthesizer:

In `${SESSION_DIR}/_outcome.md` (Write) — service file for the synthesizer:
```markdown
## Implementation and verification

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

> **Why here:** a Peer Session is also a work session; the reflection question is mandatory just as it is in a regular Quick Close (Ph18), not only there (Ph28 — that gap was found 29.07). The threshold and wording are the same as already used everywhere — not a new mechanism, just an application of an existing one.

**Threshold:** the same threshold as in `quick-close.yaml`, and the same computation formula already verified and fixed in `gather-session-facts.sh` (WP-484 Ph26, 30.07 — naive ISO date parsing gave a bug "duration_min always 0" on BSD date/macOS; that same formula is reused here, not reinvented):
```bash
START_TIME=$(grep '^start_time:' "$SESSION_DIR/meta.yaml" | sed -E 's/^start_time: *"?([^"]*)"?$/\1/')
NOW_EPOCH=$(date -u +%s)
START_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$START_TIME" +%s 2>/dev/null \
    || date -u -d "$START_TIME" +%s 2>/dev/null \
    || echo "$NOW_EPOCH")
DURATION_MIN=$(( (NOW_EPOCH - START_EPOCH) / 60 ))
```
If `DURATION_MIN ≤ 15` — skip, proceed to Step 4 silently (short session, do not delay the pilot).

If `duration_min > 15`:

1. Show the pilot a brief summary (2–3 lines, what was done in this Peer Session — not a retelling of the turn files, the essence).
2. Ask: "What from this session is worth remembering for the future — not about the task itself, but about how the work went?" (verbatim question from Ph18, `CONCEPT-night-cycle.md §18`).
3. Write the response to the daily ledger (issue #409: the script is not present on every installation — do not block if absent):
   ```bash
   LEDGER_SCRIPT="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/ledger-append.sh"
   if [ -f "$LEDGER_SCRIPT" ]; then
     bash "$LEDGER_SCRIPT" day "$(date +%F)" session_reflection "{\"wp\": \"<WP-NNN>\", \"answer\": <escaped answer>}" peer-conversation
   else
     echo "ledger-append.sh is not available on this installation — reflection was not written to the daily ledger"
   fi
   ```
4. Tell the pilot: "You are free to go; I will close the session from here" — and continue with Step 4 (finalization: report.md, commit, session-guard close) without further pilot involvement.

If the pilot does not answer (left, no response) — do not block: record `"answer": "no response"`, continue with Step 4 as normal.

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

### 4.2 Synthesize report-draft.md (not report.md — see 4.2a)

> **Architectural Constraint:** the Claude writer uses the Agent tool for synthesis, because Claude can launch a Sonnet sub-agent inside the session. The Kimi writer (skill `/peer-writer`) is forced to use a bash pipe via `claude-peer-adapter.sh`, because Kimi does not have access to the Claude Agent tool. This is an intentional difference, not drift.

Launch a sub-agent via the Agent tool (Sonnet, context isolation).
**Fallback:** if `report-draft.md` is not created or is empty after the sub-agent finishes — write a stub (Write):

```markdown
---
session_id: <SESSION_ID>
generated_at: <now>
note: synthesis not performed (sub-agent unavailable or returned an empty result)
---

# Final Report

Transcript: see turn files in the session directory.
Retry synthesis: `/peer-conversation --finalize <SESSION_ID>`
```

### 4.2a Deferred finalization rule (post-2026-05-22)

> **Invariant:** `report.md` — final version only. Until an explicit Close signal from the pilot, the file is named `report-draft.md`.

**On consensus (turn ≤ 10):**
- Do not rename to `report.md`.
- Ask the pilot: "Consensus reached. Closing the session or do you need an extension?"
- If the pilot says "closing" → rename `report-draft.md → report.md` (step 4.3).
- If the pilot requests an extension → continue the turn-loop, and at final Close append `## Extension (turns N–M, <timestamp>)` to the same `report-draft.md`, then rename.

**On extension:**
```markdown
## Extension (turns N–M, <timestamp>)

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
- Creating `report-v1.md`, `report-v2.md` — one session = one report.
- Creating supplement directories — `sessions/YYYY-MM/DD/<id>/` = single unified space.
- Continuing to write `-writer.md`/`-peer.md` when `status: completed` — status changes only after the Close signal.

### 4.2b report.md style (DP.SC.050)

> **Channel determines style.** Turn files (00-writer.md, 01-peer.md, …) — technical, for agents. report.md — conversational, for the pilot.
>
> When synthesizing report.md from turn files: **rewrite**, do not copy. Replace technical terms with plain language (A1–A11), remove machine markers (PASS, SHA, exit), convert passive voice to active.

Sub-agent prompt:

```
You are a synthesizer of dialog results between multiple agents (DP.SC.154, writer + <PEER_COUNT> peer(s)).
Session task: <task>

Style: conversational for the pilot (A1-A11). Rewrite, do not copy turn files.

Read all turn files in <SESSION_DIR> (00-writer.md, then 01-peer.md.../01-peer-<vendor>.md... — in numbering order; when PEER_COUNT>=2 there are multiple files per round number, read all of them) in numbering order.
If `_outcome.md` is present in the directory — read it; it is mandatory for §6.
If review-NN.md / verify-NN.md files are present — include them as anchors in §5/§6.
Write <SESSION_DIR>/report.md strictly according to the schema below.
Do not wrap in ```markdown``` — write markdown directly.
Invariant: result_class=agreed → §4 is non-empty; not-agreed → §4 = "Consensus not reached".
Verify anchors are mandatory for code references (file:line-range). Tags [synthesized] in §4.

---
schema_version: 1
session_id: <SESSION_ID>
generated_at: <ISO-8601 UTC>
writer: <from meta.yaml: writer_agent>
peer: <from meta.yaml: peer_agent; when PEER_COUNT>=2 — all peer_agents separated by ", ">
duration_min: <(end_time − start_time) in minutes, integer>
escalations_count: <from meta.yaml>
result_class: agreed | partial | escalated | not-agreed
confidence: low | med | high
confidence_basis: <required if confidence <= med; otherwise omit>
ttl_event: <"until merge PR-NNN" | "until WP-NNN" | "until pilot cancels" | omit>
cost_usd: <if known; otherwise omit>
cost_source: api | estimated | missing
---

# Final Report

## Algorithm

## 1. Original problem statement
- **Task:** <verbatim quote from the pilot's assignment>
- **Writer's initial position:** <if recorded in 00-writer.md; omit if absent>

## 2. Positions by topic
Under each topic (raised by 2+ parties and influenced the outcome). When PEER_COUNT==1 — "Writer/Peer" section as before. When PEER_COUNT>=2 — a separate line for each participant who sent a position (do not merge all peers into a single "Peer"):

**Topic N: <statement>**
- Initiator: <agent_id, who raised the topic>
- **<agent_id 1>:** thesis → reasoning → anchor (file:line-range / Pack-ID)
- **<agent_id 2>:** thesis → reasoning → anchor
- **<agent_id N>:** ... (one line per participant who spoke on the topic)
- Evolution (opt.): if position changed — round/turn and reason
- Resolution: what was accepted + whose argument prevailed

## 3. Rejected alternatives
Omit if empty. Only alternatives argued by both sides OR rejected with a counter-argument.
- Alternative → reason for rejection → reference to turn

## 4. Recorded decision
- <Actionable statement> [synthesized]
- **Key argument:** <one line>
- **Confidence:** low | med | high (if ≤ med — justification is mandatory)
- **TTL event:** <link to event or omit>

Invariant: agreed → non-empty; not-agreed → "Consensus not reached".

## 5. Open questions and escalations
Omit if empty.
- <Question or escalation>
- Status: needs-decision | needs-verification | deferred
- Reference: escalation-NN.md or NN-peer.md (if available)

## 6. Implementation and verification
Omit if `implementation_pipeline: false` in meta.yaml.
If true — mandatory section, source = `${SESSION_DIR}/_outcome.md`.
- **Changed files:** list with one-line description of each
- **Code review iterations:** <N>
- **Unresolved:** <count High/Medium or "none">
- **Smoke verification:** PASS | FAIL
- **Deploy:** repo → commit SHA (for each affected repo)
- **Open tasks after deploy:** list or "none"
- **References:** review-NN.md, verify-NN.md

## 7. Metadata and navigation
- **Log:** links to all NN-writer.md / NN-peer.md (or NN-peer-<vendor>.md when PEER_COUNT>=2) in order
- **Related Artifacts:** Pack-IDs, files (PRs, specifications) — if mentioned
- **Round skips** (only when PEER_COUNT>=2 and `meta.yaml.round_skips` is non-empty): who and in which round did not respond — omit if empty
- **Write token handoff** (only when PEER_COUNT>=2 and `meta.yaml.handoff_history` is non-empty): round → from → to → reason, for each entry — omit if empty
- **Cost:** $X (source: api / estimated / missing) — omit if missing
```

### 4.3 Update sessions/00-index.md

File does not exist (session ran bypassing Step 1.3, or the index was deleted) → first create it using the same block as in Step 1.3 (idempotent, issue #568), then add the row as new. Otherwise — find the row with `<SESSION_ID>` and replace it entirely (the "Agents" column — the same `+`-join when PEER_COUNT>=2 as in Step 1.3):
```
| <TODAY> | <SESSION_ID> | <task ≤50> | claude-code / <PEER_VENDOR1>[+<PEER_VENDOR2>...] | <TURNS/ROUNDS> | <ESCALATIONS> | completed | [report.md](<MONTH>/<DAY>/<SESSION_ID>/report.md) |
```
(Bash awk — safe for strings containing `|`.)

### 4.4 Closing (ORZ — session file alongside the session directory)

> **Before 2026-08-03 this step and Step 4.5.0 wrote to the file independently, using different templates and different paths** (`SESSION_SLUG` here dropped the date AND the session number, while `CLEAN_SESSION_ID` in 4.5.0 dropped only the date) — two orphan files were left on disk instead of one (example: `sessions/2026-08/2026-08-03-codex-wp510-strategy-questions.md` alongside `sessions/2026-08/2026-08-03-04-codex-wp510-strategy-questions.md`). Found and fixed in peer session `2026-08-03-09-launchd-focustodo-weekly-export`. Now the file write is a single operation at Step 4.5.0; this step only defines the shared path variable.

Slug part (without date, with number — the same formula that `session-guard.sh` uses for its ORZ scaffold, `session-guard.sh:241-243`): `SESSION_SLUG="${SESSION_ID#"$TODAY"-}"`

Target path (used here and at Step 4.5.0): `${IWE_GOVERNANCE_REPO:-DS-strategy}/sessions/<MONTH>/<TODAY>-<SESSION_SLUG>.md` — a flat Quick Close file under the monthly directory, without DD/ (DD/ is only for peer-session directories). The same path that `session-guard.sh` has already created (or will create) as its ORZ scaffold at Step 1.0 — the content is written once, at Step 4.5.0.

### 4.5 Commit + push

**4.5.0 Write the closing ORZ session file** (single write point — path formula and rationale: see Step 4.4; also closes the session-guard semaphore if Step 1.0 created it):

```bash
# Path is built with THE SAME formula that session-guard.sh uses for its ORZ scaffold
# (session-guard.sh:241-243, WP-484 31.07 — protection against date duplication)
# — $SESSION_SLUG is already defined at Step 4.4. SESSION_ID here ALWAYS
# starts with "$TODAY-" (Step 1: "${TODAY}-${NUM}-${SLUG}"), so concatenating
# "${TODAY}-${SESSION_ID}" without the prior subtraction would double the date.
GUARD_ORZ="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/sessions/$MONTH/${TODAY}-${SESSION_SLUG}.md"
cat > "$GUARD_ORZ" <<EOF
---
date: $TODAY
type: peer-session
wp: <WP-NNN>
agent: claude-code
writer: claude-code
peer: [<PEER_AGENT_ID>, ...]      # list; single element when PEER_COUNT==1
duration_h: <(end_time - start_time) in hours, 1 decimal>
artifacts: [sessions/$MONTH/$DAY/$SESSION_ID/report.md]
session_id: $SESSION_ID
---

## Key insight

<1-2 lines from §4 of report.md — the recorded decision>

## Context

Peer Session $SESSION_ID — full transcript and synthesis in sessions/$MONTH/$DAY/$SESSION_ID/.

## Accomplished

| Artifact | Description |
|----------|----------|
| sessions/$MONTH/$DAY/$SESSION_ID/report.md | Peer session final report |

## Key decisions

See report.md §4.
EOF
```

If the write fails (directory unavailable, disk full) — do not block finalization: tell the pilot in one line and continue; Step 4.5.1 will include `$GUARD_ORZ` in PATHS regardless of the outcome.

**4.5.1 Commit + push:**

```bash
(cd "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}"
# pathspec after `--`: commit ONLY session files, do not sweep others'
# pre-staged files from the shared index (mis-attribution, see 2026-06-20-39).
# $GUARD_ORZ (Step 4.5.0) — the same path as "$TODAY-$SESSION_SLUG.md" (Step 4.4),
# a single entry instead of two hard-coded references to the same file.
PATHS=("sessions/$MONTH/$DAY/$SESSION_ID/" "sessions/00-index.md" "$GUARD_ORZ")
git add "${PATHS[@]}"
git commit -m "feat(peer): $SESSION_ID — <task briefly>" -- "${PATHS[@]}"
git push
)
```

**4.5.2 Session-guard close** (best-effort, AFTER a successful push — the semaphore must not be closed earlier, otherwise the Scope gate at 4.5.1 will not find an active semaphore):

```bash
IWE_AGENT=claude-code bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" close --agent claude-code 2>&1 || \
  echo "session-guard close failed — semaphore will remain active until auto-orphan (TTL 30 min on next open), does not block the pilot"
```

**Show the pilot an in-chat summary** (read `report.md`, extract and display):

```
Session complete.

Turns/rounds: <turns_count|rounds> | Roles: <writer_agent> (writer) · <peer_agent(s)> (peer(s)) | Escalations: <escalations_count>

Decision: <first item of §4 from report.md — one plain-language line, no technical codes>

Full report: sessions/<MONTH>/<DAY>/<SESSION_ID>/report.md
```

If report.md is empty or the synthesizer sub-agent did not create it — show only the link without §4.

---

## Step 5. Interrupt mode

When `--interrupt <session_id>`:

1. Extract the month and day from the id: `MONTH=$(echo "$session_id" | cut -c1-7)`, `DAY=$(echo "$session_id" | cut -c9-10)` → find `sessions/$MONTH/$DAY/$session_id/meta.yaml`.
2. Update (Bash sed): `status: interrupted`, `end_time: <now>`, `turns_count: <number of files>`.
3. Find the row with `<session_id>` in `sessions/00-index.md` and replace it: status → `interrupted`, report → `—`.
4. Commit + push.

---

## Step 6. Finalize mode

When `--finalize <session_id>`:

1. Extract month and day: `MONTH=$(echo "$session_id" | cut -c1-7)`, `DAY=$(echo "$session_id" | cut -c9-10)`. Verify that the directory `sessions/$MONTH/$DAY/$session_id` exists and contains at least `00-writer.md`.
2. Read `meta.yaml` — take `task_description`, `start_time`, `escalations_count`.
3. Execute **Step 4.2** (synthesize report.md via Agent tool) with the same invariants and fallback.
4. Update `meta.yaml` (Bash sed): `status: completed`, `end_time: <now>`, `turns_count: <number of files>`.
5. Update the row in `sessions/00-index.md`: status → `completed`, report → link.
6. Commit + push.

Used to recover interrupted sessions without restarting the turn-loop.

---

## Report verification

To verify any existing report.md, write in the chat:
"verify the report for session `<session_id>`"

Launch a sub-agent (Sonnet, context isolation): read all session files + report.md, check against schema_version=1 invariants (frontmatter, §4 non-empty when agreed, verify anchors).

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
