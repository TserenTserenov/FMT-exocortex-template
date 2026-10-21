#!/bin/bash
# protocol-stop-gate.sh
# see DP.SC.025 (capture-bus), WP-229 Phase4
# Event: Stop
# Checks: if a Skill invocation occurred in the session Skill (day-open|day-close|run-protocol|wp-new),
# then there must be TodoWrite with ≥3 items. Otherwise — block.
# Principle warn-before-block (issue #1184): no more than one real block per
# session per 24h (marker in 24h (marker in $IWE_ROOT/.claude/state/protocol-stop-gate/,
# gitignored — issue #250). A session longer than 24h may receive a repeated block —
# this is intentional. Degraded cases (no session_id or lock unavailable) (no session_id / lock unavailable) → previous
# systemMessage-warning to user, not block.
#
# Guard against infinite loop: field stop_hook_active in the input JSON (issue #819)
# suppresses repeats within a single turn; marker — clients without this flag.
# Read-only except gate_log.jsonl and .claude/state/protocol-stop-gate/.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

INPUT=$(cat)
if [ -z "$INPUT" ]; then
  echo '{}'
  exit 0
fi

# --- Infinite loop guard (issue #819) ---
# Claude Code launches this hook in a new bash-process for each Stop-event,
# therefore env-variable does not survive between calls — old guard via
# STOP_HOOK_ACTIVE was dead code from birth. Claude Code passes itself
# repeat indicator in JSON; we read it from there (boolean or string "true").
STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r 'if (.stop_hook_active == true or .stop_hook_active == "true") then "1" else "0" end' 2>/dev/null || echo 0)
if [ "$STOP_ACTIVE" = "1" ]; then
  echo '{}'
  exit 0
fi

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

# #369 protected the shared sentinel from a NEIGHBOUR session's Stop (matched
# by session_id + owner-token, confirmed still correct by issue #460 path 7).
# It did not protect against the SAME session's own Stop: audit-installation
# creates the sentinel, launches a subagent rehearsal, and the parent turn's
# Stop can fire (session_id matches trivially) while that subagent is still
# writing under it — issue #460 path 6. Fix: this hook no longer deletes the
# shared sentinel at all, matched session or not. Removal is now only the
# explicit `rm -f` at the end of the owning procedure, backed by the
# fail-closed TTL in dry-run-gate.sh (path 3) as the crash fallback. The
# owner-file is still cleared here, but only once it's confirmed residue
# (sentinel already gone) — never while the sentinel it points at is live.
cleanup_owned_dry_run_sentinel() {
  local sid="$1" safe_sid owner_file
  [ -n "$sid" ] || return 0
  safe_sid=$(printf '%s' "$sid" | tr -cd 'A-Za-z0-9._-')
  [ -n "$safe_sid" ] || return 0
  owner_file="/tmp/iwe-dry-run-owner-${safe_sid}.token"
  [ -f "$owner_file" ] || return 0
  [ -f /tmp/iwe-dry-run.flag ] && return 0
  rm -f "$owner_file" 2>/dev/null || true
}

cleanup_owned_dry_run_sentinel "$SESSION_ID"

# issue #549 stage 2: idempotent fallback — if the rehearsal for this session
# still active (session died before normal completion), Stop transitions it to
# completed. The transition is performed BY THE HOOK ITSELF (trusted runtime code), without
# helper'a helper and the flag --trusted-stop. Strictness (Codex r3): entire scan under a single
# lock; we proceed only with EXACTLY one valid v2 active-state this
# session — corruption/multiple active we do not convert to allow, we do not
# touch. Sentinel is released only after a SUCCESSFUL transition.
complete_dry_run_on_stop() {
  local sid="$1" dry_dir lock_dir sf gid recorded tmp nonce tries lock_pid lock_start cur_start
  local active_file="" active_gid="" corrupted=0 active_count=0
  [ -n "$sid" ] || return 0
  dry_dir="${IWE_DRY_RUN_DIR:-/tmp/iwe-dry-run-$(id -u)}"
  local sentinel="${IWE_DRY_RUN_SENTINEL:-/tmp/iwe-dry-run.flag}"
  # Unified path resolver (Codex r3): ANY override without marker resets
  # BOTH paths to production production — same as in gate/begin/complete.
  if [ -n "${IWE_DRY_RUN_DIR:-}" ] || [ -n "${IWE_DRY_RUN_SENTINEL:-}" ]; then
    if [ ! -f "${IWE_DRY_RUN_DIR:-/nonexistent}/.iwe-dry-run-test-mode" ]; then
      dry_dir="/tmp/iwe-dry-run-$(id -u)"
      sentinel="/tmp/iwe-dry-run.flag"
    fi
  fi
  [ -d "$dry_dir" ] && [ ! -L "$dry_dir" ] || return 0
  lock_dir="$dry_dir/transaction.lock"

  # Lock for the entire scan and transition+transition.
  tries=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -gt 20 ] && return 0
    lock_pid=$(sed -n '1p' "$lock_dir/pid" 2>/dev/null || true)
    lock_start=$(sed -n '3p' "$lock_dir/pid" 2>/dev/null || true)
    cur_start=$(ps -o lstart= -p "$lock_pid" 2>/dev/null || true)
    if [ -n "$lock_pid" ] && { ! kill -0 "$lock_pid" 2>/dev/null || { [ -n "$lock_start" ] && [ -n "$cur_start" ] && [ "$lock_start" != "$cur_start" ]; }; }; then
      mv "$lock_dir" "$dry_dir/.stale-lock-$$-$(date +%s)" 2>/dev/null || true
      rm -rf "$dry_dir"/.stale-lock-* 2>/dev/null || true
      mkdir "$lock_dir" 2>/dev/null && break
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
  nonce=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  if ! { echo "$$"; echo "$nonce"; ps -o lstart= -p $$ 2>/dev/null || echo "unknown"; } > "$lock_dir/pid" 2>/dev/null; then
    rm -rf "$lock_dir" 2>/dev/null || true
    return 0
  fi
  trap 'if [ "$(sed -n "2p" "$lock_dir/pid" 2>/dev/null)" = "$nonce" ]; then rm -rf "$lock_dir" 2>/dev/null; fi' RETURN 2>/dev/null || true

  # Strict scan: corrupted/foreign version/mismatch — corruption (we do not touch anything).
  shopt -s nullglob
  for sf in "$dry_dir"/gate-*.state; do
    jq -e . "$sf" >/dev/null 2>&1 || { corrupted=1; break; }
    [ "$(jq -r '.version // empty' "$sf" 2>/dev/null)" = "2" ] || { corrupted=1; break; }
    gid=$(jq -r '.gate_id // empty' "$sf" 2>/dev/null || true)
    [ -n "$gid" ] && [ "gate-$gid.state" = "$(basename "$sf")" ] || { corrupted=1; break; }
    case "$(jq -r '.state // empty' "$sf" 2>/dev/null)" in
      active)
        active_count=$((active_count + 1))
        if [ "$(jq -r '.owner_session_id // empty' "$sf" 2>/dev/null)" = "$sid" ]; then
          active_file="$sf"; active_gid="$gid"
        fi
        ;;
      completed) ;;
      *) corrupted=1; break ;;
    esac
  done
  shopt -u nullglob

  if [ "$corrupted" = "0" ] && [ "$active_count" -le 1 ] && [ -n "$active_file" ]; then
    # Exactly one valid active, and it is ours — safe transition.
    if [ "$(jq -r '.state // empty' "$active_file" 2>/dev/null)" = "active" ]; then
      tmp=$(mktemp "$dry_dir/.complete.XXXXXX" 2>/dev/null || true)
      if [ -n "$tmp" ] && \
         jq --arg completed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '.state="completed" | .completed_at=$completed | .completion_reason="stop-hook-fallback"' \
            "$active_file" > "$tmp" 2>/dev/null && mv -f "$tmp" "$active_file" 2>/dev/null; then
        # Sentinel — only AFTER a successful transition and only for our own gate_id.
        if [ -f "$sentinel" ] && [ ! -L "$sentinel" ] && \
           [ "$(jq -r '.gate_id // empty' "$sentinel" 2>/dev/null)" = "$active_gid" ]; then
          rm -f "$sentinel"
        fi
      else
        rm -f "$tmp" 2>/dev/null || true
      fi
    fi
  fi
  # corruption / active_count>1 / foreign active — we do not touch anything (fail-closed
  # from the gate side: it itself he will resolve the state on the next tool-call).
  if [ "$(sed -n '2p' "$lock_dir/pid" 2>/dev/null)" = "$nonce" ]; then
    rm -rf "$lock_dir" 2>/dev/null || true
  fi
  # issue #818: RETURN trap (line ~98) outlives this function — bash does not
  # scope `trap ... RETURN` to the function, where it was set, it remains
  # armed for ANY subsequent function return/sourced-script in
  # the same process. Without explicit cleanup here — a regular Stop without an active
  # rehearsal fails under `set -u`, when the hook later sources bootstrap: trap
  # fires again on already dead $lock_dir/$nonce.
  trap - RETURN 2>/dev/null || true
  return 0
}

complete_dry_run_on_stop "$SESSION_ID"

TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')

# No transcript — skip
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  echo '{}'
  exit 0
fi

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$HOOK_DIR/.." && pwd)"
# shellcheck source=../lib/iwe-env-bootstrap.sh
source "$CLAUDE_DIR/lib/iwe-env-bootstrap.sh" || exit 1
GATE_LOG="$IWE_ROOT/.claude/logs/gate_log.jsonl"
mkdir -p "$(dirname "$GATE_LOG")" 2>/dev/null || true

# --- Step 1: was a protocol skill invoked? ---
# issue #758: in the transcript Claude Code tool_use is nested, in
# .message.content[], and not at the top level of the line (there type=assistant/
# user/attachment) — select(.type=="tool_use") at the top level does not
# never matched. `[]?` suppresses the error, if .message/.content is absent
# or is not an array, — that is sufficient, a broad `try` is not needed.
# issue #862 follow-up (Codex r3): transcript — JSONL (one per JSON-object
# per line/message), therefore all jq-queries use -s and unwrap
# the message array via .[].
PROTOCOL_SKILL=$(jq -s -r '
  [.[] | select((.message.role // "assistant") == "assistant") | .message.content[]?]
  | .[]
  | select(.type == "tool_use" and .name == "Skill")
  | .input.skill // empty
' "$TRANSCRIPT_PATH" 2>/dev/null \
  | grep -E '^(day-open|day-close|run-protocol|wp-new)$' \
  | head -1)

if [ -z "$PROTOCOL_SKILL" ]; then
  # Protocol skill was not invoked — gate gate is not needed
  echo '{}'
  exit 0
fi

# --- Step 2: was there a task-list with ≥3 items? --- (same nesting level, as in Step 1)
# issue #862: TodoWrite is deprecated and replaced by TaskCreate/TaskUpdate; furthermore,
# SKILL.md explicitly permits step numbering in responses, when Task-tools
# are unavailable. We account for all three indicators.
# issue #862 follow-up (Codex r3): transcript JSONL, count only messages
# from the assistant, TaskCreate and TaskUpdate we treat separately (updates to the same task do not
# should be multiplied), TodoWrite we take the maximum list for TodoWrite.
TODO_MAX=$(jq -s -r '
  [.[] | select((.message.role // "assistant") == "assistant") | .message]
  | .[] | .content[]?
  | select(.type == "tool_use" and .name == "TodoWrite")
  | .input.todos
  | if type == "array" then length else 0 end
' "$TRANSCRIPT_PATH" 2>/dev/null \
  | sort -n | tail -1)
TODO_MAX="${TODO_MAX:-0}"

TASK_CREATE_MAX=$(jq -s -r '
  [.[] | select((.message.role // "assistant") == "assistant") | .message]
  | .[] | .content[]?
  | select(.type == "tool_use" and .name == "TaskCreate")
  | .input
  | if (.tasks // .task_list // .items) | type == "array" then
      (.tasks // .task_list // .items) | length
    elif (.tasks // .task_list // .items) != null then
      1
    elif (.name // .title // .description // .status) then
      1
    else
      0
    end
' "$TRANSCRIPT_PATH" 2>/dev/null \
  | awk '{s+=$1} END {print s+0}')
TASK_CREATE_MAX="${TASK_CREATE_MAX:-0}"

TASK_UPDATE_MAX=$(jq -s -r '
  [.[] | select((.message.role // "assistant") == "assistant") | .message]
  | .[] | .content[]?
  | select(.type == "tool_use" and .name == "TaskUpdate")
  | .input
  | if (.tasks // .task_list // .items) | type == "array" then
      (.tasks // .task_list // .items) | length
    elif (.tasks // .task_list // .items) != null then
      1
    elif (.name // .title // .description // .status) then
      1
    else
      0
    end
' "$TRANSCRIPT_PATH" 2>/dev/null \
  | sort -n | tail -1)
TASK_UPDATE_MAX="${TASK_UPDATE_MAX:-0}"

# Explicit step numbering in assistant responses: "Step N of M" / "Step N of M".
# We take the maximum common denominator M M, because the response may contain
# intermediate steps without the full formula.
STEP_MAX=$(jq -s -r '
  [.[] | select((.message.role // "assistant") == "assistant") | .message]
  | .[] | .content[]?
  | select(.type == "text" and (.text // "") != "")
  | .text
' "$TRANSCRIPT_PATH" 2>/dev/null \
  | grep -oiE '(step|step)[[:space:]]+[0-9]+[[:space:]]+(of|of)[[:space:]]+[0-9]+' \
  | grep -oiE '[0-9]+$' \
  | sort -n | tail -1)
STEP_MAX="${STEP_MAX:-0}"

# TodoWrite and TaskCreate — planning signals (task list); we sum,
# because individual TaskCreate = individual steps, while TodoWrite can be
# supplemented by TaskCreate. TaskUpdate — updates, we take max so that updates max, so that updates
# to the same task do not multiply. Explicit numbering in text is an independent. Explicit numbering in the text — independent
# source; we take max.
LIST_MAX=$(( TODO_MAX + TASK_CREATE_MAX ))
if [ "$TASK_UPDATE_MAX" -gt "$LIST_MAX" ]; then LIST_MAX="$TASK_UPDATE_MAX"; fi
if [ "$STEP_MAX" -gt "$LIST_MAX" ]; then LIST_MAX="$STEP_MAX"; fi

THRESHOLD=3

# --- Step 3: event ---
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
FIRED=0
if [ "$LIST_MAX" -lt "$THRESHOLD" ]; then
  FIRED=1
fi

TASK_MAX_SIGNAL="$TASK_CREATE_MAX"
if [ "$TASK_UPDATE_MAX" -gt "$TASK_MAX_SIGNAL" ]; then TASK_MAX_SIGNAL="$TASK_UPDATE_MAX"; fi

# --- Step 4: block-once (issue #1184) ---
# For Stop-event {"decision":"block","reason":...} — channel, delivering
# text TO THE AGENT; systemMessage is visible only to the user. Therefore on violation
# we block, but no more than once per session per 24h (marker under lock).
# The lock is PER-SESSION (lock-<sid>-<crc>): different sessions do not compete at all,
# and concurrent Stop of one session the client does not produce.
# A stale lock is NEVER deleted and NEVER moved (cold-review #1184,
# rounds 1-2: any scheme «check staleness, then mv/rm» leaves a window,
# where a foreign fresh lock gets taken away). Cost: a hook, that crashed between mkdir and rm its own
# lock, leaves it permanently — Stop of this session degrades to systemMessage
# (exactly the behavior before #1184). New sessions receive fresh sid and are not affected.
# An acquired lock is deleted only by the process that created it (proof
# of ownership = successful mkdir). Directories marker/lock accumulate proportionally to the number of sessions
# with a violation — the same scale, as for marker; no separate cleanup is introduced.
ACTION="none"

PSG_STATE_DIR="$IWE_ROOT/.claude/state/protocol-stop-gate"

# crc full session_id: tr-sanitization collapses different sid into one marker
# (a/b and ab → ab), the second session would lose its block (cold-review #1184).
psg_sid_key() {
  local safe crc
  safe=$(printf '%s' "$1" | tr -cd 'A-Za-z0-9._-')
  crc=$(printf '%s' "$1" | cksum | awk '{print $1}')
  printf '%s-%s' "$safe" "$crc"
}

psg_lock_acquire() {  # $1 = lock directory
  local lock_dir="$1" tries=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -gt 3 ] && return 1
    sleep 0.1 2>/dev/null || sleep 1
  done
  return 0
}

psg_lock_release() {  # $1 = lock directory, created by THIS process
  rm -rf "$1" 2>/dev/null || true
}

if [ "$FIRED" = "1" ]; then
  SID_KEY=$(psg_sid_key "$SESSION_ID")
  if [ -z "$SESSION_ID" ]; then
    # Without session_id the repeat frequency cannot be limited — we do not block at all.
    ACTION="warn-no-session"
  else
    PSG_LOCK_DIR="$PSG_STATE_DIR/lock-$SID_KEY"
    mkdir -p "$PSG_STATE_DIR" 2>/dev/null || true
    if ! psg_lock_acquire "$PSG_LOCK_DIR"; then
      ACTION="warn-lock-unavailable"
    else
      # The entire sequence check→delete→create→write ts — strictly
      # under one lock: otherwise two concurrent processes both acquire locks, and
      # delete stale marker'and may delete a fresh marker belonging to another process (peer-review #1184).
      MARKER_DIR="$PSG_STATE_DIR/marker-$SID_KEY"
      NOW_EPOCH=$(date +%s)
      MARKER_FRESH=0
      if [ -d "$MARKER_DIR" ]; then
        MARKER_TS=$(cat "$MARKER_DIR/ts" 2>/dev/null || true)
        if [ -n "$MARKER_TS" ] && [ "$MARKER_TS" -eq "$MARKER_TS" ] 2>/dev/null \
           && [ $((NOW_EPOCH - MARKER_TS)) -lt 86400 ]; then
          MARKER_FRESH=1
        else
          rm -rf "$MARKER_DIR" 2>/dev/null || true
        fi
      fi
      if [ "$MARKER_FRESH" = "1" ]; then
        ACTION="suppressed-fresh-marker"
      elif mkdir "$MARKER_DIR" 2>/dev/null && echo "$NOW_EPOCH" > "$MARKER_DIR/ts" 2>/dev/null; then
        ACTION="block-once"
      else
        # State storage is unusable — repeat rate cannot be limited, we do not block.
        ACTION="warn-lock-unavailable"
      fi
      psg_lock_release "$PSG_LOCK_DIR"
    fi
  fi
fi

# --- Step 5: log the event (action — accurately: what actually happened) ---
LOG_ENTRY=$(jq -nc \
  --arg ts "$TIMESTAMP" \
  --arg sid "$SESSION_ID" \
  --arg skill "$PROTOCOL_SKILL" \
  --arg todo_max "$TODO_MAX" \
  --arg task_max "$TASK_MAX_SIGNAL" \
  --arg task_create_max "$TASK_CREATE_MAX" \
  --arg task_update_max "$TASK_UPDATE_MAX" \
  --arg step_max "$STEP_MAX" \
  --arg list_max "$LIST_MAX" \
  --arg threshold "$THRESHOLD" \
  --arg fired "$FIRED" \
  --arg action "$ACTION" \
  '{ts: $ts, gate: "protocol-stop-gate", session_id: $sid, skill: $skill,
    todo_max: ($todo_max|tonumber), task_max: ($task_max|tonumber),
    task_create_max: ($task_create_max|tonumber),
    task_update_max: ($task_update_max|tonumber),
    step_max: ($step_max|tonumber), list_max: ($list_max|tonumber),
    threshold: ($threshold|tonumber), fired: ($fired == "1"), action: $action}' 2>/dev/null || true)

if [ -n "$LOG_ENTRY" ]; then
  echo "$LOG_ENTRY" >> "$GATE_LOG" 2>/dev/null || true
fi

# --- Step 6: output ---
case "$ACTION" in
  block-once)
    # reason goes to the AGENT (Stop decision control); text — the same requirement,
    # as in the warning: task list or explicit numbering and protocol from the start.
    jq -nc --arg reason "⚠️ PROTOCOL-STOP-GATE [block-once]: Skill '$PROTOCOL_SKILL' was invoked, but the step-by-step execution indicator (TodoWrite/Task-tools/explicit numbering) with ≥$THRESHOLD tasks was not found (found: $LIST_MAX). The protocol requires a step-by-step plan BEFORE execution begins. Before finishing the turn: create TodoWrite/Task-a list with the skill steps or explicitly number the steps in your responses, as permitted SKILL.md, and run through the protocol again from the start. This is the only block sessions for 24h. (gate_log: $GATE_LOG)" \
      '{"decision": "block", "reason": $reason}'
    ;;
  warn-no-session|warn-lock-unavailable)
    # Degradation: previous unobtrusive notification to the user (same pattern,
    # as in secret-leak-block.sh / secret-file-read-block.sh / secret-mcp-dump-guard.sh).
    cat <<EOF
{"systemMessage": "⚠️ PROTOCOL-STOP-GATE [warn]: Skill '$PROTOCOL_SKILL' was invoked, but the step-by-step execution marker (TodoWrite/Task-tools/explicit numbering) with ≥$THRESHOLD tasks was not found (found: $LIST_MAX). The protocol requires a step-by-step plan BEFORE execution begins. Action: create TodoWrite/Task-a task list with the skill steps or explicitly number the steps in responses, as permitted SKILL.md, and run through the protocol again. (gate_log: $GATE_LOG)"}
EOF
    ;;
  *)
    echo '{}'
    ;;
esac

exit 0
