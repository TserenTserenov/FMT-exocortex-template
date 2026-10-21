#!/bin/bash
# peer-session-finalize.sh — finalize / interrupt for peer-sessions (DP.SC.154)
# Replacement for deprecated deprecated peer-conversation.sh --finalize / --interrupt
# Works with the skills directory structure: sessions/YYYY-MM/DD/<id>/
#
# Usage:
#   bash scripts/peer-session-finalize.sh --finalize <session_id>
#   bash scripts/peer-session-finalize.sh --interrupt <session_id>
#   bash scripts/peer-session-finalize.sh --dry-run --finalize <session_id>
#   bash scripts/peer-session-finalize.sh --dry-run --interrupt <session_id>
#   bash scripts/peer-session-finalize.sh --validate <session_id>

set -euo pipefail

IWE_DIR="${IWE_DIR:-$HOME/IWE}"
# Name governance-repo name from environment: a hardcoded value breaks the file for the user
# template with a different repository name (validator FMT caught during delivery 03.08).
REPO_DIR="${IWE_DIR}/${IWE_GOVERNANCE_REPO:-DS-strategy}"
SESSIONS_DIR="${REPO_DIR}/sessions"
INDEX_FILE="${SESSIONS_DIR}/00-index.md"
INDEX_LOCK_DIR="${INDEX_FILE}.lock"
INDEX_LOCK_TIMEOUT="${IWE_INDEX_LOCK_TIMEOUT:-10}"

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# WP-529 ArchGate (option B, 20.10.2026): awk reads $INDEX_FILE, builds
# $tmpf, then mv replaces the file -- rename atomic, but the entire sequence
# "read -> modify -> replace" is not atomic. Two concurrent calls
# finalize/interrupt to the same governance-repo (confirmed peer-session
# Kimi+Codex mechanically, not by assumption) can both read the same
# version of the index -- the second mv silently overwrites the first ones edit. The same
# pattern reclaim-by-liveness-pid, that acquire_captures_write_lock()
# (strategist.sh/extractor.sh, issue #840): without depending on flock(1),
# which on a fresh macOS without homebrew/util-linux may not be available.
_acquire_index_lock() {
  local waited=0
  while true; do
    if mkdir "$INDEX_LOCK_DIR" 2>/dev/null; then
      printf '%s\n' "$$" > "$INDEX_LOCK_DIR/pid"
      return 0
    fi
    local owner_pid=""
    [[ -f "$INDEX_LOCK_DIR/pid" ]] && owner_pid="$(tr -d '[:space:]' < "$INDEX_LOCK_DIR/pid")"
    # The same asymmetry, as in acquire_captures_write_lock(): we acquire the lock
    # only if pid-the pid file exists and is non-empty. An empty/or absent pid-pid file
    # means mkdir another writers mkdir has already succeeded, but its printf pid has not yet
    # completed -- acquiring the lock here would mean stealing it from a live holder
    # (TOCTOU), that is reintroducing the same race, that the lock is supposed to prevent.
    if [[ -n "$owner_pid" ]] && { ! [[ "$owner_pid" =~ ^[0-9]+$ ]] || ! kill -0 "$owner_pid" 2>/dev/null; }; then
      rm -f "$INDEX_LOCK_DIR/pid"
      rmdir "$INDEX_LOCK_DIR" 2>/dev/null
      continue
    fi
    if (( waited >= INDEX_LOCK_TIMEOUT )); then
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

_release_index_lock() {
  rm -f "$INDEX_LOCK_DIR/pid" 2>/dev/null
  rmdir "$INDEX_LOCK_DIR" 2>/dev/null || true
}

_usage() {
  echo "Usage: peer-session-finalize.sh --finalize <session_id>"
  echo "       peer-session-finalize.sh --interrupt <session_id>"
  echo "       peer-session-finalize.sh --dry-run --finalize <session_id>"
  echo "       peer-session-finalize.sh --dry-run --interrupt <session_id>"
  echo "       peer-session-finalize.sh --validate <session_id>"
  exit 1
}

DRY_RUN=false
VALIDATE=false
ACTION=""
SESSION_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=true; shift ;;
    --validate)  VALIDATE=true; shift ;;
    --finalize|--interrupt)
      if [[ -n "$ACTION" ]]; then
        echo "❌ Action already specified: $ACTION"
        _usage
      fi
      ACTION="$1"; shift
      ;;
    -h|--help) _usage ;;
    -*)
      echo "❌ Unknown flag: $1"
      _usage
      ;;
    *)
      if [[ -n "$SESSION_ID" ]]; then
        echo "❌ SESSION_ID already specified: $SESSION_ID"
        _usage
      fi
      SESSION_ID="$1"; shift
      ;;
  esac
done

[[ -n "$SESSION_ID" ]] || _usage

_require_peer_session() {
  local meta_file="$1"
  local peer_agent
  local test_subject

  peer_agent="$(grep -E '^peer_agent:' "$meta_file" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | sed 's/"//g' | sed "s/'//g" | tr -d ' ')"
  test_subject="$(grep -E '^test_subject:' "$meta_file" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | sed 's/"//g' | sed "s/'//g" | tr -d ' ')"

  if [[ -n "$test_subject" && "$test_subject" != "~" && "$test_subject" != "null" && ( -z "$peer_agent" || "$peer_agent" == "~" || "$peer_agent" == "null" ) ]]; then
    echo "❌ This is a control session with test_subject test_subject, not a peer-peer session: peer-session-finalize.sh does not apply to it."
    return 1
  fi

  if [[ -z "$peer_agent" || "$peer_agent" == "~" || "$peer_agent" == "null" ]]; then
    echo "❌ For peer-session a non-empty peer_agent is missing peer_agent: $meta_file"
    return 1
  fi
}

# --validate: only check meta.yaml, no side effects
if [[ "$VALIDATE" == true ]]; then
  MONTH="$(echo "$SESSION_ID" | cut -c1-7)"
  DAY="$(echo "$SESSION_ID" | cut -c9-10)"
  SESSION_DIR="${SESSIONS_DIR}/${MONTH}/${DAY}/${SESSION_ID}"
  META="${SESSION_DIR}/meta.yaml"

  [[ -d "$SESSION_DIR" ]] || { echo "❌ Session not found: $SESSION_DIR"; exit 1; }
  [[ -f "$META" ]] || { echo "❌ meta.yaml not found: $META"; exit 1; }

  ERRORS=0
  _require_field() {
    local field="$1"
    local file="$2"
    if ! grep -qE "^${field}:" "$file"; then
      echo "  ✗ Field '${field}' is missing"
      ERRORS=$((ERRORS + 1))
    else
      local val
      val="$(grep -E "^${field}:" "$file" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | sed 's/"//g' | sed "s/'//g" | tr -d ' ')"
      if [[ -z "$val" || "$val" == "~" || "$val" == "null" ]]; then
        echo "  ✗ Field '${field}' is empty"
        ERRORS=$((ERRORS + 1))
      else
        echo "  ✓ ${field}: ${val}"
      fi
    fi
  }

  echo "📋 Validating meta.yaml: $META"
  _require_peer_session "$META" || exit 2
  _require_field "session_id" "$META"
  _require_field "start_time" "$META"
  _require_field "status" "$META"
  _require_field "writer_agent" "$META"

  # bug-2026-07-10 (Day Close, PRODSYNC2-round5-session): the agent literally
  # wrote into meta.yaml an unfilled shell-placeholder instead of the real
  # time ("2026-07-10T$(date +%H:%M:%SZ)") — YAML does not execute commands,
  # the value ended up in the file as-is and silently broke any recalculation
  # of session duration. Catch any `$(` in start_time/end_time before writing.
  for field in start_time end_time; do
    val="$(grep -E "^${field}:" "$META" | head -1)"
    if [[ "$val" == *'$('* ]]; then
      echo "  ✗ Field '${field}' contains an unexpanded shell-placeholder: ${val}"
      ERRORS=$((ERRORS + 1))
    fi
  done

  # bug-2026-07-10: two meta.yaml in the same folder for 10.07 contained
  # start_time later than end_time (manual time entry, not programmatic) —
  # portcorrupts the day multiplier calculation (Day Close §6). String comparison of ISO ISO
  # 8601 8601 strings with identical format is safe and requires no external dependencies.
  start_val="$(grep -E '^start_time:' "$META" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"'"'"' ')"
  end_val="$(grep -E '^end_time:' "$META" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"'"'"' ')"
  if [[ -n "$start_val" && -n "$end_val" && "$start_val" != *'$('* && "$end_val" != *'$('* ]]; then
    if [[ "$end_val" < "$start_val" ]]; then
      echo "  ✗ end_time ($end_val) is earlier than start_time ($start_val)"
      ERRORS=$((ERRORS + 1))
    fi
  fi

  if (( ERRORS > 0 )); then
    echo "❌ Validation failed: $ERRORS errors"
    exit 1
  fi
  echo "✅ Validation passed"
  exit 0
fi

# Validate action for non-validate modes
[[ -n "$ACTION" ]] || _usage

MONTH="$(echo "$SESSION_ID" | cut -c1-7)"
DAY="$(echo "$SESSION_ID" | cut -c9-10)"
SESSION_DIR="${SESSIONS_DIR}/${MONTH}/${DAY}/${SESSION_ID}"
META="${SESSION_DIR}/meta.yaml"

[[ -d "$SESSION_DIR" ]] || { echo "❌ Session not found: $SESSION_DIR"; exit 1; }
[[ -f "$META" ]] || { echo "❌ meta.yaml not found: $META"; exit 1; }
_require_peer_session "$META" || exit 2

end_time="$(_now_iso)"
turns_count=$(find "$SESSION_DIR" -maxdepth 1 -name "[0-9][0-9]-*.md" | wc -l | tr -d ' ')

# --- INTERRUPT ---
if [[ "$ACTION" == "--interrupt" ]]; then
  tmpf="$(mktemp)"
  sed "s/^status:.*/status: interrupted/" "$META" |
    sed "s/^end_time:.*/end_time: \"${end_time}\"/" |
    sed "s/^turns_count:.*/turns_count: ${turns_count}/" > "$tmpf"
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Will update $META: status=interrupted, end_time=${end_time}, turns_count=${turns_count}"
    rm "$tmpf"
  else
    mv "$tmpf" "$META"
  fi

  # Update index: status → interrupted, report → —
  if [[ -f "$INDEX_FILE" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      echo "[DRY-RUN] Will update $INDEX_FILE: status interrupted, report removed"
    elif _acquire_index_lock; then
      tmpf="$(mktemp)"
      awk -v id="$SESSION_ID" '
        $0 ~ id {
          gsub(/\| (started|completed|interrupted) \|/, "| interrupted |")
          gsub(/\| \[?report\.md[^|]*\|/, "| — |")
          # If no report link column, ensure last column is —
          if ($0 !~ /\| — \| *$/) { sub(/\| *$/, "| — |") }
          print
          next
        }
        { print }
      ' "$INDEX_FILE" > "$tmpf"
      mv "$tmpf" "$INDEX_FILE"
      _release_index_lock
    else
      echo "⚠️  Could not acquire index lock within ${INDEX_LOCK_TIMEOUT}s — $INDEX_FILE not updated (status session status in meta.yaml is already correct)" >&2
    fi
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Session $SESSION_ID would have been interrupted."
  else
    echo "✅ Session $SESSION_ID interrupted."
  fi
  exit 0
fi

# --- FINALIZE ---
if [[ "$ACTION" == "--finalize" ]]; then
  [[ -f "${SESSION_DIR}/00-writer.md" ]] || { echo "❌ No turns in session"; exit 1; }

  writer_agent="$(grep "^writer_agent:" "$META" | sed 's/^writer_agent: *//; s/"//g' | tr -d "'")"

  # Choose adapter based on writer_agent
  if [[ "$writer_agent" == "kimi-headless" ]]; then
    ADAPTER="${REPO_DIR}/scripts/kimi-peer-adapter.sh"
  else
    ADAPTER="${REPO_DIR}/scripts/claude-peer-adapter.sh"
  fi

  report_file="${SESSION_DIR}/report.md"

  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Synthesizing report.md via $ADAPTER (skipped in dry-run)"
  else
    # Synthesize report via Python (safe prompt handling)
    python3 - "$SESSION_DIR" "$META" "$report_file" "$ADAPTER" <<'PYEOF'
import sys, os, glob, subprocess, datetime

session_dir, meta_path, report_file, adapter = sys.argv[1:5]

# Read meta
meta = {}
with open(meta_path, encoding='utf-8') as f:
    for line in f:
        if ':' in line and not line.strip().startswith('#'):
            k, v = line.split(':', 1)
            meta[k.strip()] = v.strip().strip('"').strip("'")

task_desc = meta.get('task_description', '')
writer_agent = meta.get('writer_agent', '')
start_time = meta.get('start_time', '')
escalations_count = meta.get('escalations_count', '0')
session_id = meta.get('session_id', '')

# Gather turns
turn_files = sorted(glob.glob(os.path.join(session_dir, '[0-9][0-9]-*.md')))
turns_text = ''
for tf in turn_files:
    fname = os.path.basename(tf)
    with open(tf, encoding='utf-8') as f:
        body = f.read()
    turns_text += f'\n\n=== {fname} ===\n{body}'

synth_prompt = f"""You are — a synthesizer of dialogue summaries for two agents (DP.SC.154).

Session task: {task_desc}

Below is the full dialogue transcript (turns in order) — complete transcript of the dialogue (utterances in turn order):
{turns_text}

Write the final report.md strictly in the format below. Maintain the invariant: when result_class: agreed section §4 is non-empty; when not-agreed — literal «Consensus not reached». Do not wrap the output in ```markdown ... ``` — write markdown directly.

---
schema_version: 1
session_id: {session_id}
generated_at: {datetime.datetime.utcnow().isoformat()}Z
writer: {writer_agent}
peer: <from meta.yaml: peer_agent>
duration_min: <compute: (end_time − start_time) in minutes, integer>
escalations_count: {escalations_count}
result_class: agreed | partial | escalated | not-agreed
confidence: low | med | high
confidence_basis: <required, if confidence <= med; otherwise omit>
ttl_event: <«until merge merge PR-NNN» | «until WP-NNN WP-NNN» | «until cancelled by pilot» | omit>
cost_usd: <if known; otherwise omit>
cost_source: api | estimated | missing
---

# Final Report

## 1. Original Problem Statement
- **Task:** <verbatim quote from the pilot assignment, verbatim>
- **Initial position of the writer:** <if recorded in 00-writer.md; omit, if not>

## 2. Positions by Topic
Under each topic (materiality criterion: raised by both sides and influenced the outcome):

**Topic N: <short label>**
- Initiator: writer | peer
- **Writer:** thesis → rationale → anchor (file:line-range / Pack-ID, required for code-references and external facts)
- **Peer:** thesis → justification → anchor
- Evolution (opt.): if any-one changed their position — indicate the move and the reason
- Resolution: what was accepted + whose argument prevailed

## 3. Rejected alternatives
Omit, if empty. Filter: only alternatives, argued by both sides OR rejected with an explicit counter-argument.
- Alternative → reason for rejection → reference to the move

## 4. Recorded decision
- <Actionable statement> [synthesized]
- **Key argument:** <in one line — why exactly this>
- **Confidence:** low | med | high (if ≤ med — justification is required)
- **TTL-event:** <binding to an event or omit>

Invariant: when result_class: agreed section is non-empty; when not-agreed — «Consensus not reached».

## 5. Open questions and escalations
Omit, if empty. Single list:
- <Question or escalation>
- Status: needs-decision | needs-verification | deferred
- Reference: escalation-NN.md or NN-peer.md (if present)

## 6. Metadata and navigation
- **Log:** links to all NN-writer.md / NN-peer.md in order
- **Related artifacts:** Pack-IDs, files (PR, specifications) — if mentioned
- **Cost:** $X (source: api / estimated / missing) — omit, if cost_source: missing
"""

# Write prompt to temp file and feed to adapter
import tempfile
with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False, encoding='utf-8') as tmp:
    tmp.write(synth_prompt)
    tmp_path = tmp.name

# synth_prompt above already inlines the full transcript into stdin — neither
# adapter needs --add-dir to synthesize, and claude-peer-adapter.sh
# unconditionally rejects it (exit 64, WP-458 contract: text-only reviewer,
# no file access), which made every synthesis call through this path fail
# whenever ADAPTER resolved to claude-peer-adapter.sh (writer_agent !=
# "kimi-headless"). Same bug as kimi-peer-writer/SKILL.md's synthesis step,
# found independently by Codex re-auditing that fix — this script is a
# separate finalize path, not covered by that first pass. stderr is now
# captured (not discarded) so a future regression leaves a real diagnostic
# in the fallback stub instead of the same generic guess every time.
stderr_path = tmp_path + '.err'
try:
    with open(tmp_path, 'r', encoding='utf-8') as stdin_f, \
         open(report_file, 'w', encoding='utf-8') as stdout_f, \
         open(stderr_path, 'w', encoding='utf-8') as stderr_f:
        result = subprocess.run(
            ['bash', adapter],
            stdin=stdin_f,
            stdout=stdout_f,
            stderr=stderr_f
        )
finally:
    os.unlink(tmp_path)

if result.returncode != 0 or os.path.getsize(report_file) == 0:
    stderr_tail = ''
    if os.path.exists(stderr_path):
        with open(stderr_path, encoding='utf-8') as f:
            stderr_tail = f.read()[-2000:]
        os.unlink(stderr_path)
    now = datetime.datetime.utcnow().isoformat() + 'Z'
    with open(report_file, 'w', encoding='utf-8') as f:
        f.write(f"""---
session_id: {session_id}
generated_at: {now}
note: synthesis not performed (subagent unavailable)
---

# Final Report

Dialog transcript: see. replica files in the session folder.
Retry synthesis: `bash scripts/peer-session-finalize.sh --finalize {session_id}`

## Diagnostics (stderr adapter, for debugging — not for the pilot)

```
returncode: {result.returncode}
{stderr_tail if stderr_tail else '(stderr empty)'}
```
""")
    sys.exit(1)
elif os.path.exists(stderr_path):
    os.unlink(stderr_path)
PYEOF
  fi

  # Update meta.yaml
  tmpf="$(mktemp)"
  sed "s/^status:.*/status: \"completed\"/" "$META" |
    sed "s/^end_time:.*/end_time: \"${end_time}\"/" |
    sed "s/^turns_count:.*/turns_count: ${turns_count}/" > "$tmpf"
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Will update $META: status=completed, end_time=${end_time}, turns_count=${turns_count}"
    rm "$tmpf"
  else
    mv "$tmpf" "$META"
  fi

  # Update index
  if [[ -f "$INDEX_FILE" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      echo "[DRY-RUN] Will update $INDEX_FILE: status completed, report.md added"
    elif _acquire_index_lock; then
      tmpf="$(mktemp)"
      awk -v id="$SESSION_ID" -v link="[report.md](${MONTH}/${DAY}/${SESSION_ID}/report.md)" '
        $0 ~ id {
          gsub(/\| (started|interrupted) \|/, "| completed |")
          gsub(/\| — \|/, "| " link " |")
          print
          next
        }
        { print }
      ' "$INDEX_FILE" > "$tmpf"
      mv "$tmpf" "$INDEX_FILE"
      _release_index_lock
    else
      echo "⚠️  Could not acquire index lock within ${INDEX_LOCK_TIMEOUT}s — $INDEX_FILE not updated (status session in meta.yaml already correct)" >&2
    fi
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Session $SESSION_ID would have been finalized. Report: $report_file"
  else
    echo "✅ Session $SESSION_ID finalized. Report: $report_file"
  fi
  exit 0
fi

echo "❌ Unknown action: $ACTION"
_usage
