#!/bin/bash
# protocol-stop-gate.sh
# see DP.SC.025 (capture-bus), WP-229 Phase 4
# Event: Stop
# Checks: if the session had a Skill call (day-open|day-close|run-protocol|wp-new),
# there must be a TodoWrite with >=3 items. Otherwise -- block.
# Warn-before-block principle (issue #1184): no more than one real block per
# session per 24h (marker in $IWE_ROOT/.claude/state/protocol-stop-gate/,
# gitignored -- issue #250). A session longer than 24h may get a repeated block --
# this is intentional. Degradations (no session_id / lock unavailable) → the former
# systemMessage warning to the user, not a block.
#
# Protection against an infinite loop: the stop_hook_active field in the input JSON (issue #819)
# suppresses repeats within one turn; the marker covers clients without this flag.
# Read-only except gate_log.jsonl and .claude/state/protocol-stop-gate/.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

INPUT=$(cat)
if [ -z "$INPUT" ]; then
  echo '{}'
  exit 0
fi

# --- Infinite loop guard (issue #819) ---
# Claude Code launches this hook as a new bash process on every Stop event,
# so an env variable does not survive between calls -- the old guard via
# STOP_HOOK_ACTIVE was dead code from birth. Claude Code itself passes
# the repeat flag in the JSON; we read it from there (boolean or the string "true").
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

# issue #549 stage 2: idempotent fallback -- if this session's rehearsal
# is still active (the session died before normal completion), Stop moves it to
# completed. The transition is performed BY THE HOOK itself (trusted runtime code), without a
# helper and the --trusted-stop flag. Strictness (Codex r3): the whole scan under one
# lock; we continue only with EXACTLY one valid v2 active-state of this
# session -- corruption/multiple actives are not turned into allow, nothing is
# touched. The sentinel is removed only after a SUCCESSFUL transition.
complete_dry_run_on_stop() {
  local sid="$1" dry_dir lock_dir sf gid recorded tmp nonce tries lock_pid lock_start cur_start
  local active_file="" active_gid="" corrupted=0 active_count=0
  [ -n "$sid" ] || return 0
  dry_dir="${IWE_DRY_RUN_DIR:-/tmp/iwe-dry-run-$(id -u)}"
  local sentinel="${IWE_DRY_RUN_SENTINEL:-/tmp/iwe-dry-run.flag}"
  # Single path resolver (Codex r3): ANY override without a marker resets
  # BOTH paths to production -- as in gate/begin/complete.
  if [ -n "${IWE_DRY_RUN_DIR:-}" ] || [ -n "${IWE_DRY_RUN_SENTINEL:-}" ]; then
    if [ ! -f "${IWE_DRY_RUN_DIR:-/nonexistent}/.iwe-dry-run-test-mode" ]; then
      dry_dir="/tmp/iwe-dry-run-$(id -u)"
      sentinel="/tmp/iwe-dry-run.flag"
    fi
  fi
  [ -d "$dry_dir" ] && [ ! -L "$dry_dir" ] || return 0
  lock_dir="$dry_dir/transaction.lock"

  # Lock for the whole scan+transition.
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

  # Strict scan: broken/foreign version/mismatch is corruption (touch nothing).
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
    # Exactly one valid active, and it is ours -- a safe transition.
    if [ "$(jq -r '.state // empty' "$active_file" 2>/dev/null)" = "active" ]; then
      tmp=$(mktemp "$dry_dir/.complete.XXXXXX" 2>/dev/null || true)
      if [ -n "$tmp" ] && \
         jq --arg completed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '.state="completed" | .completed_at=$completed | .completion_reason="stop-hook-fallback"' \
            "$active_file" > "$tmp" 2>/dev/null && mv -f "$tmp" "$active_file" 2>/dev/null; then
        # Sentinel -- only AFTER a successful transition and only for our own gate_id.
        if [ -f "$sentinel" ] && [ ! -L "$sentinel" ] && \
           [ "$(jq -r '.gate_id // empty' "$sentinel" 2>/dev/null)" = "$active_gid" ]; then
          rm -f "$sentinel"
        fi
      else
        rm -f "$tmp" 2>/dev/null || true
      fi
    fi
  fi
  # corruption / active_count>1 / foreign active -- touch nothing (fail-closed
  # on the gate's side: it will sort out the state itself at the next tool-call).
  if [ "$(sed -n '2p' "$lock_dir/pid" 2>/dev/null)" = "$nonce" ]; then
    rm -rf "$lock_dir" 2>/dev/null || true
  fi
  # issue #818: the RETURN trap (line ~98) outlives this function -- bash does not
  # scope `trap ... RETURN` to the function where it was set; it stays
  # armed for ANY following return of a function/sourced script in
  # the same process. Without an explicit cleanup here, a normal Stop without an active
  # rehearsal fails under `set -u` when the hook later sources the bootstrap: the trap
  # fires again on the already dead $lock_dir/$nonce.
  trap - RETURN 2>/dev/null || true
  return 0
}

complete_dry_run_on_stop "$SESSION_ID"

TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')

# No transcript -- skip
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

# --- Step 1: was there a protocol skill call? ---
# issue #758: in the Claude Code transcript tool_use is nested, in
# .message.content[], not at the top level of the line (there type=assistant/
# user/attachment) -- select(.type=="tool_use") at the top level
# never matched. `[]?` suppresses the error if .message/.content is absent
# or not an array -- this is enough, a broad `try` is not needed.
# issue #862 follow-up (Codex r3): the transcript is JSONL (one JSON object
# per line/message), so all jq queries use -s and unwrap the
# message array via .[].
# issue #1311 (round-loop Kimi+Codex, 22.10): skill and args are read by ONE
# jq selection from ONE tool_use object, not by two independent pipes --
# otherwise there is a risk of taking args from another Skill call in the same transcript.
# `.[-1]` (the last found call), not `.[0]`: before this change "the first
# found" was safe, because the choice affected only the log/message text --
# the Step 2 threshold scanned the whole transcript the same way regardless
# of which call was chosen. Now the same object decides the Quick Close
# exemption, and "first" breaks the invariant -- an early `run-protocol close` at the
# start of the session would silently exempt a LATE `run-protocol
# week-close` without its own checklist (cold-review, Critical, 22.10,
# reproduced with a synthetic transcript with two calls).
# issue #1411 item 7: a Skill call rejected before it ran (PreToolUse hook
# deny, permission denial, unknown skill) is answered by a tool_result with
# is_error=true for the same tool_use_id; such a call is not counted.
# A tool_use with no tool_result (truncated transcript, crash mid-call) still
# counts: Stop fires after the turn's tools have returned, so a missing
# result is not evidence of rejection — stay fail-closed.
PROTOCOL_CALL_JSON=$(jq -s -c '
  ([.[] | .message.content? | if type == "array" then .[] else empty end
     | select(type == "object" and .type == "tool_result" and .is_error == true)
     | .tool_use_id | select(type == "string")]) as $rejected
  | [.[] | select((.message.role // "assistant") == "assistant") | .message.content[]?]
  | map(select(.type == "tool_use" and .name == "Skill"))
  | map(select(.id as $id | ($id == null) or (any($rejected[]; . == $id) | not)))
  | map(select((.input.skill // "") | test("^(day-open|day-close|run-protocol|wp-new)$")))
  | .[-1] // empty
' "$TRANSCRIPT_PATH" 2>/dev/null)

if [ -z "$PROTOCOL_CALL_JSON" ] || [ "$PROTOCOL_CALL_JSON" = "null" ]; then
  # The protocol skill was not launched -- the gate is not needed
  echo '{}'
  exit 0
fi

PROTOCOL_SKILL=$(printf '%s' "$PROTOCOL_CALL_JSON" | jq -r '.input.skill // empty')

# --- Step 1b: Quick Close exempt (issue #1311) ---
# memory/protocol-close.md promises Quick Close "inline, without TodoWrite, ~3 min"
# (triggers «закрываю сессию»/«всё»/«закрывай» → run-protocol close/close
# session). Before this change ANY run-protocol (including week-close/month-close/
# day-close, where the step list is really needed -- via SKILL.md + TodoWrite)
# required the same THRESHOLD -- Quick Close was indistinguishable from the heavy
# protocols. A non-string or missing args → NOT Quick Close (fail-closed,
# round-loop consensus Kimi+Codex 22.10: unrecognized input does not weaken the gate).
IS_QUICK_CLOSE=0
if [ "$PROTOCOL_SKILL" = "run-protocol" ]; then
  # `.input.args | type` DIRECTLY, without `// ""` -- jq's `//` treats JSON
  # `false` as falsy the same as `null`, and the substitution would happen BEFORE `type`,
  # turning boolean `false` into type "string" with the value "" (cold-review,
  # High, 22.10: `{"args": false}` without a checklist passed as Quick Close --
  # a violation of its own declared fail-closed). A missing key
  # `.input.args` gives `null` in jq, so "null" is treated as an empty
  # string (= Quick Close), any other type (boolean/number/object/array)
  # is NOT Quick Close.
  ARGS_KIND=$(printf '%s' "$PROTOCOL_CALL_JSON" | jq -r '.input.args | type')
  ARGS_NORM=""
  if [ "$ARGS_KIND" = "string" ]; then
    ARGS_NORM=$(printf '%s' "$PROTOCOL_CALL_JSON" | jq -r '.input.args' \
      | tr '[:upper:]' '[:lower:]' \
      | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g')
  fi
  if [ "$ARGS_KIND" = "null" ] || [ "$ARGS_KIND" = "string" ]; then
    case "$ARGS_NORM" in
      ""|"close"|"close session") IS_QUICK_CLOSE=1 ;;
    esac
  fi
fi

if [ "$IS_QUICK_CLOSE" = "1" ]; then
  # Quick Close is by design without a TodoWrite/Task checklist, Step 2 is not needed.
  echo '{}'
  exit 0
fi

# --- Step 2: was there a task list with >=3 items? --- (same nesting as in Step 1)
# issue #862: TodoWrite is obsolete and replaced by TaskCreate/TaskUpdate; besides,
# SKILL.md explicitly allows numbering steps in replies when the Task tools are
# unavailable. We count all three signals.
# issue #862 follow-up (Codex r3): the transcript is JSONL, we count only assistant
# messages, separate TaskCreate and TaskUpdate (updates of one task
# must not multiply), and take TodoWrite by the maximum list.
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

# Explicit step numbering in assistant replies: "Шаг N из M" / "Step N of M".
# We take the maximum common denominator M, because a reply may contain
# intermediate steps without the full formula.
# issue #1340: case classes are listed explicitly, without -i: in Git Bash on Windows
# (LC_CTYPE=C.UTF-8) grep -i does not fold Cyrillic to a single case, and the form at the
# start of a sentence («Шаг 2 из 15») was not found -- the gate blocked an honest turn.
# Peer round WP-7 Phase 259: the classes cover every letter («[Шш][Аа]г»), not only
# the first -- otherwise caps lock was lost («ШАГ 2 ИЗ 15», «STEP 2 OF 15»), which -i
# used to find.
STEP_MAX=$(jq -s -r '
  [.[] | select((.message.role // "assistant") == "assistant") | .message]
  | .[] | .content[]?
  | select(.type == "text" and (.text // "") != "")
  | .text
' "$TRANSCRIPT_PATH" 2>/dev/null \
  | grep -oE '([Шш][Аа][Гг]|[Ss][Tt][Ee][Pp])[[:space:]]+[0-9]+[[:space:]]+([Ии][Зз]|[Oo][Ff])[[:space:]]+[0-9]+' \
  | grep -oE '[0-9]+$' \
  | sort -n | tail -1)
STEP_MAX="${STEP_MAX:-0}"

# TodoWrite and TaskCreate are planning signals (a task list); we sum them,
# because separate TaskCreate = separate steps, and TodoWrite may be
# supplemented by TaskCreate. TaskUpdate are updates, we take max so that updates
# of one task do not multiply. Explicit numbering in the text is an independent
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
# For a Stop event {"decision":"block","reason":...} is the channel that delivers
# text to the AGENT; systemMessage is seen only by the user. So on a violation
# we block, but no more than once per session per 24h (marker under lock).
# The lock is PER-SESSION (lock-<sid>-<crc>): different sessions do not compete at all,
# and the client does not produce concurrent Stops of one session.
# A stale lock is NEVER deleted and NEVER moved (cold-review #1184,
# rounds 1-2: any "check staleness, then mv/rm" scheme leaves a window
# in which someone else's fresh lock is carried off). Cost: a hook that died between mkdir and rm of its own
# lock leaves it forever -- Stop of this session degrades to systemMessage
# (exactly the behavior before #1184). New sessions get fresh sids and are unaffected.
# A held lock is removed only by the process that created it (proof
# of ownership = a successful mkdir). The marker/lock directories accumulate by the number of sessions
# with a violation -- the same scale as the marker; no separate cleanup is introduced.
ACTION="none"

PSG_STATE_DIR="$IWE_ROOT/.claude/state/protocol-stop-gate"

# crc of the full session_id: tr-sanitization collapses different sids into one marker
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

psg_lock_release() {  # $1 = lock directory created by THIS process
  rm -rf "$1" 2>/dev/null || true
}

if [ "$FIRED" = "1" ]; then
  SID_KEY=$(psg_sid_key "$SESSION_ID")
  if [ -z "$SESSION_ID" ]; then
    # Without session_id the repeat rate cannot be limited -- do not block at all.
    ACTION="warn-no-session"
  else
    PSG_LOCK_DIR="$PSG_STATE_DIR/lock-$SID_KEY"
    mkdir -p "$PSG_STATE_DIR" 2>/dev/null || true
    if ! psg_lock_acquire "$PSG_LOCK_DIR"; then
      ACTION="warn-lock-unavailable"
    else
      # The whole sequence check→delete→create→write ts -- strictly
      # under one lock: otherwise two concurrent processes both block, and
      # deleting a stale marker may remove someone else's fresh one (peer-review #1184).
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
        # State storage is unusable -- the repeat rate cannot be limited, do not block.
        ACTION="warn-lock-unavailable"
      fi
      psg_lock_release "$PSG_LOCK_DIR"
    fi
  fi
fi

# --- Step 5: log the event (action -- honestly: what actually happened) ---
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
    # reason goes to the AGENT (Stop decision control); the text is the same requirement
    # as in the warning: a task list or explicit numbering, and the protocol again.
    jq -nc --arg reason "⚠️ PROTOCOL-STOP-GATE [block-once]: Скилл '$PROTOCOL_SKILL' был вызван, но признак исполнения по шагам (TodoWrite/Task-инструменты/явная нумерация) с ≥$THRESHOLD задачами не найден (найдено: $LIST_MAX). Протокол требует пошаговый план ДО начала исполнения. Прежде чем завершить ход: создай TodoWrite/Task-лист с шагами скилла либо явно пронумеруй шаги в ответах, как разрешено SKILL.md, и пройди протокол заново. Это единственный block сессии за 24ч. (gate_log: $GATE_LOG)" \
      '{"decision": "block", "reason": $reason}'
    ;;
  warn-no-session|warn-lock-unavailable)
    # Degradation: the former unobtrusive notification to the user (the same pattern
    # as in secret-leak-block.sh / secret-file-read-block.sh / secret-mcp-dump-guard.sh).
    cat <<EOF
{"systemMessage": "⚠️ PROTOCOL-STOP-GATE [warn]: Скилл '$PROTOCOL_SKILL' был вызван, но признак исполнения по шагам (TodoWrite/Task-инструменты/явная нумерация) с ≥$THRESHOLD задачами не найден (найдено: $LIST_MAX). Протокол требует пошаговый план ДО начала исполнения. Действие: создай TodoWrite/Task-лист с шагами скилла либо явно пронумеруй шаги в ответах, как разрешено SKILL.md, и пройди протокол заново. (gate_log: $GATE_LOG)"}
EOF
    ;;
  *)
    echo '{}'
    ;;
esac

exit 0
