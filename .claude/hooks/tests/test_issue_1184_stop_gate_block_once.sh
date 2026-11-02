#!/bin/bash
# test_issue_1184_stop_gate_block_once.sh — issue #1184:
# protocol-stop-gate.sh on a protocol violation blocks Stop once per
# session per 24h (marker under lock in .claude/state/protocol-stop-gate/);
# degradations (no session_id, lock busy) → the former systemMessage, not a block.
#
# Run: bash .claude/hooks/tests/test_issue_1184_stop_gate_block_once.sh

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0

IWE_ROOT="$TMP_DIR/iwe-root"
mkdir -p "$IWE_ROOT/.claude/logs"
STATE_DIR="$IWE_ROOT/.claude/state/protocol-stop-gate"
GATE_LOG="$IWE_ROOT/.claude/logs/gate_log.jsonl"

check() {
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc (ожидалось '$want', получено '$got')"
  fi
}

# transcript fragments (JSONL, one JSON object per line)
msg_skill='{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"day-open"}}]}}'
msg_text_plain='{"message":{"role":"assistant","content":[{"type":"text","text":"просто текст"}]}}'
msg_todo_3='{"message":{"role":"assistant","content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"title":"a"},{"title":"b"},{"title":"c"}]}}]}}'

TR_VIOLATION="$TMP_DIR/violation.jsonl"
printf '%s\n%s\n' "$msg_skill" "$msg_text_plain" > "$TR_VIOLATION"
TR_OK="$TMP_DIR/ok.jsonl"
printf '%s\n%s\n' "$msg_skill" "$msg_todo_3" > "$TR_OK"

# run_hook <stdin-json> — a fresh hook process, stdout to stdout
run_hook() {
  printf '%s\n' "$1" | IWE_ROOT="$IWE_ROOT" bash "$HOOK_DIR/protocol-stop-gate.sh"
}

mk_input() { # <session_id> <transcript> [stop_hook_active]
  local sid="$1" tr="$2" active="${3:-}"
  if [ -n "$active" ]; then
    printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":%s}' "$sid" "$tr" "$active"
  else
    printf '{"session_id":"%s","transcript_path":"%s"}' "$sid" "$tr"
  fi
}

last_log_action() {
  tail -1 "$GATE_LOG" | jq -r '.action'
}

make_marker() { # <session_id> <age-seconds-ago>
  local m="$STATE_DIR/marker-$(sid_key "$1")"
  mkdir -p "$m"
  echo $(( $(date +%s) - "$2" )) > "$m/ts"
}

# sid_key — the same name the hook builds (sanitized + crc of the full session_id).
sid_key() {
  local safe crc
  safe=$(printf '%s' "$1" | tr -cd 'A-Za-z0-9._-')
  crc=$(printf '%s' "$1" | cksum | awk '{print $1}')
  printf '%s-%s' "$safe" "$crc"
}

# === a. violation, no flag, no marker → block, marker created, action=block-once ===
SID="sess-a"
OUT=$(run_hook "$(mk_input "$SID" "$TR_VIOLATION")")
check "a: decision=block" "block" "$(printf '%s' "$OUT" | jq -r '.decision // empty')"
check "a: есть reason" "yes" "$(printf '%s' "$OUT" | jq -r 'if (.reason // "") != "" then "yes" else "no" end')"
check "a: marker создан" "yes" "$([ -f "$STATE_DIR/marker-$(sid_key "$SID")/ts" ] && echo yes || echo no)"
check "a: log action" "block-once" "$(last_log_action)"

# === b. stop_hook_active=true → {} (existing behavior, issue #819) ===
SID="sess-b"
OUT=$(run_hook "$(mk_input "$SID" "$TR_VIOLATION" true)")
check "b: stop_hook_active → {}" "{}" "$(printf '%s' "$OUT" | tr -d '[:space:]')"
check "b: marker НЕ создан" "no" "$([ -e "$STATE_DIR/marker-$(sid_key "$SID")" ] && echo yes || echo no)"

# === c. violation, fresh marker, no flag → {} (suppressed) ===
SID="sess-c"
make_marker "$SID" 60
OUT=$(run_hook "$(mk_input "$SID" "$TR_VIOLATION")")
check "c: свежий marker → {}" "{}" "$(printf '%s' "$OUT" | tr -d '[:space:]')"
check "c: log action" "suppressed-fresh-marker" "$(last_log_action)"

# === d. violation, stale marker (25h) → block again, marker updated ===
SID="sess-d"
make_marker "$SID" 90000
OLD_TS=$(cat "$STATE_DIR/marker-$(sid_key "$SID")/ts")
OUT=$(run_hook "$(mk_input "$SID" "$TR_VIOLATION")")
check "d: протухший marker → block" "block" "$(printf '%s' "$OUT" | jq -r '.decision // empty')"
check "d: marker обновлён" "yes" "$([ "$(cat "$STATE_DIR/marker-$(sid_key "$SID")/ts")" -gt "$OLD_TS" ] && echo yes || echo no)"
check "d: log action" "block-once" "$(last_log_action)"

# === e. two concurrent processes with a stale marker → exactly one block ===
SID="sess-e"
make_marker "$SID" 90000
run_hook "$(mk_input "$SID" "$TR_VIOLATION")" > "$TMP_DIR/e1.out" &
P1=$!
run_hook "$(mk_input "$SID" "$TR_VIOLATION")" > "$TMP_DIR/e2.out" &
P2=$!
wait "$P1" "$P2"
BLOCKS=$(cat "$TMP_DIR/e1.out" "$TMP_DIR/e2.out" | jq -r '.decision // empty' | grep -c '^block$' || true)
check "e: ровно один block из двух" "1" "$BLOCKS"

# === f. the lock is held by a sleeping process → systemMessage, the hook does not hang ===
SID="sess-f"
sleep 30 &
DUMMY_PID=$!
LOCK_DIR="$STATE_DIR/lock-$(sid_key "$SID")"
mkdir -p "$LOCK_DIR"
START=$(date +%s)
OUT=$(run_hook "$(mk_input "$SID" "$TR_VIOLATION")")
ELAPSED=$(( $(date +%s) - START ))
kill "$DUMMY_PID" 2>/dev/null || true
wait "$DUMMY_PID" 2>/dev/null || true
rm -rf "$LOCK_DIR"
check "f: есть systemMessage" "yes" "$(printf '%s' "$OUT" | jq -r 'if (.systemMessage // "") != "" then "yes" else "no" end')"
check "f: нет decision" "no" "$(printf '%s' "$OUT" | jq -r 'if has("decision") then "yes" else "no" end')"
check "f: не завис (<15с)" "yes" "$([ "$ELAPSED" -lt 15 ] && echo yes || echo no)"
check "f: log action" "warn-lock-unavailable" "$(last_log_action)"

# === f2. the lock is left over from a crashed process → we do NOT recover (no mv/rm
# of someone else's lock — cold-review rounds 1-2), degradation to systemMessage ===
SID="sess-f2"
LOCK_DIR="$STATE_DIR/lock-$(sid_key "$SID")"
mkdir -p "$LOCK_DIR"  # lock without an owner: the creating process "crashed"
OUT=$(run_hook "$(mk_input "$SID" "$TR_VIOLATION")")
check "f2: забытый замок → systemMessage, не block" "yes" "$(printf '%s' "$OUT" | jq -r 'if (.systemMessage // "") != "" then "yes" else "no" end')"
check "f2: log action" "warn-lock-unavailable" "$(last_log_action)"

# === i. sids that collapse under sanitization (a/b vs ab) → different markers, both are blocked ===
OUT1=$(run_hook "$(mk_input "sess-i/x" "$TR_VIOLATION")")
OUT2=$(run_hook "$(mk_input "sess-ix" "$TR_VIOLATION")")
check "i: первая сессия block" "block" "$(printf '%s' "$OUT1" | jq -r '.decision // empty')"
check "i: вторая сессия тоже block (marker не схлопнулся)" "block" "$(printf '%s' "$OUT2" | jq -r '.decision // empty')"

# === g. empty session_id → systemMessage, not a block ===
OUT=$(run_hook "$(printf '{"session_id":"","transcript_path":"%s"}' "$TR_VIOLATION")")
check "g: есть systemMessage" "yes" "$(printf '%s' "$OUT" | jq -r 'if (.systemMessage // "") != "" then "yes" else "no" end')"
check "g: нет decision" "no" "$(printf '%s' "$OUT" | jq -r 'if has("decision") then "yes" else "no" end')"
check "g: log action" "warn-no-session" "$(last_log_action)"

# === h. no violation (TodoWrite >=3) → {} ===
SID="sess-h"
OUT=$(run_hook "$(mk_input "$SID" "$TR_OK")")
check "h: без нарушения → {}" "{}" "$(printf '%s' "$OUT" | tr -d '[:space:]')"
check "h: marker НЕ создан" "no" "$([ -e "$STATE_DIR/marker-$(sid_key "$SID")" ] && echo yes || echo no)"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
