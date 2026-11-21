#!/usr/bin/env bash
# peer-fanout.sh — fan-out of independent subtasks to several AI agents at once.
# The writer hands N INDEPENDENT subtasks to N peers in parallel and collects the
# results without the peers waiting for each other, then prints a joint summary.
#
# Usage:
#   peer-fanout.sh --tasks <file> [--peer codex,claude[,kimi,hermes]] [--out-dir <path>]
#
# Tasks file — strict one-line TSV: id<TAB>vendor<TAB>prompt
#   id     — [A-Za-z0-9][A-Za-z0-9._-]*  (no "..", no "/", non-empty, unique)
#   vendor — kimi|codex|hermes|claude (adapter scripts/<vendor>-peer-adapter.sh)
#   prompt — one line, no TAB or newline; self-contained (--add-dir is not supported)
#
# --peer is an allowlist / composition check, NOT the assignment (the vendor column is).
#
# Environment:
#   IWE_FANOUT_TIMEOUT_SEC   — watchdog per call, default 600, range 1..3600
#   IWE_FANOUT_ADAPTERS_DIR  — override the adapters directory (tests/stubs)
#   IWE_FANOUT_SKIP_CLI_CHECK=1 — skip the vendor CLI check in PATH (tests)
#
# Exit codes: 0 — every task ok; 2 — partial result (at least one task not ok,
# including timeout and interruption); 1 — preflight/manifest failure (no call
# was started). The summary is ALWAYS printed to stdout, including failures and interrupts.
#
# Results: <out-dir>/<id>.md (answer), <id>.err (adapter stderr), <id>.status.
# Compatibility: macOS bash 3.2 (no declare -A, readarray, wait -n); needs perl for the watchdog.

set -uo pipefail

TASKS_FILE=""
PEER_ALLOWLIST=""
OUT_DIR_ARG=""
TIMEOUT_SEC="${IWE_FANOUT_TIMEOUT_SEC:-600}"
ADAPTERS_DIR="${IWE_FANOUT_ADAPTERS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

KNOWN_VENDORS="kimi codex hermes claude"

fail_preflight() {
  echo "PREFLIGHT FAIL: $1" >&2
  exit 1
}

# --- argument parsing (an unknown flag is an explicit error, not silently ignored) ---
while [ $# -gt 0 ]; do
  case "$1" in
    --tasks)   [ $# -ge 2 ] || fail_preflight "--tasks requires a value"; TASKS_FILE="$2"; shift 2 ;;
    --peer)    [ $# -ge 2 ] || fail_preflight "--peer requires a value"; PEER_ALLOWLIST="$2"; shift 2 ;;
    --out-dir) [ $# -ge 2 ] || fail_preflight "--out-dir requires a value"; OUT_DIR_ARG="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | head -26; exit 0 ;;
    *) fail_preflight "unknown flag '$1'. Known: --tasks, --peer, --out-dir" ;;
  esac
done

[ -n "$TASKS_FILE" ] || fail_preflight "--tasks is required"
[ -f "$TASKS_FILE" ] || fail_preflight "tasks file not found: $TASKS_FILE"
[ -d "$ADAPTERS_DIR" ] || fail_preflight "adapters dir not found: $ADAPTERS_DIR"
command -v perl >/dev/null 2>&1 || fail_preflight "perl not found in PATH (needed for the per-task watchdog)"
case "$TIMEOUT_SEC" in
  ''|*[!0-9]*) fail_preflight "IWE_FANOUT_TIMEOUT_SEC must be integer, got '$TIMEOUT_SEC'" ;;
esac
[ "$TIMEOUT_SEC" -ge 1 ] && [ "$TIMEOUT_SEC" -le 3600 ] || fail_preflight "IWE_FANOUT_TIMEOUT_SEC out of range 1..3600: $TIMEOUT_SEC"

# --- manifest validation ---
LINE_NO=0
SEEN_IDS_FILE=$(mktemp "${TMPDIR:-/tmp}/fanout-ids.XXXXXX")
trap 'rm -f "$SEEN_IDS_FILE"' EXIT
while IFS= read -r line || [ -n "$line" ]; do
  LINE_NO=$((LINE_NO + 1))
  [ -z "$line" ] && continue
  case "$line" in \#*) continue ;; esac
  id="${line%%	*}"
  rest="${line#*	}"
  [ "$rest" != "$line" ] || fail_preflight "line $LINE_NO: expected id<TAB>vendor<TAB>prompt"
  vendor="${rest%%	*}"
  prompt="${rest#*	}"
  [ "$prompt" != "$rest" ] || fail_preflight "line $LINE_NO: missing third column (prompt)"
  case "$prompt" in *"	"*) fail_preflight "line $LINE_NO: TAB inside prompt is forbidden" ;; esac
  [ -n "$id" ] && [ -n "$vendor" ] && [ -n "$prompt" ] || fail_preflight "line $LINE_NO: empty field"
  case "$id" in
    *[!A-Za-z0-9._-]*|.*|*/*) fail_preflight "line $LINE_NO: bad id '$id' (allowed: [A-Za-z0-9][A-Za-z0-9._-]*)" ;;
  esac
  case "$id" in [A-Za-z0-9]*) ;; *) fail_preflight "line $LINE_NO: id must start with alphanumeric: '$id'" ;; esac
  if grep -qx "$id" "$SEEN_IDS_FILE" 2>/dev/null; then
    fail_preflight "line $LINE_NO: duplicate id '$id'"
  fi
  echo "$id" >> "$SEEN_IDS_FILE"
  found=0
  for kv in $KNOWN_VENDORS; do [ "$kv" = "$vendor" ] && found=1; done
  [ "$found" = "1" ] || fail_preflight "line $LINE_NO: unknown vendor '$vendor' (known: $KNOWN_VENDORS)"
  if [ -n "$PEER_ALLOWLIST" ]; then
    allowed=0
    OLDIFS="$IFS"; IFS=','
    for pv in $PEER_ALLOWLIST; do [ "$pv" = "$vendor" ] && allowed=1; done
    IFS="$OLDIFS"
    [ "$allowed" = "1" ] || fail_preflight "line $LINE_NO: vendor '$vendor' not in --peer allowlist ($PEER_ALLOWLIST)"
  fi
done < "$TASKS_FILE"
TASK_COUNT=$(wc -l < "$SEEN_IDS_FILE" | tr -d ' ')
[ "$TASK_COUNT" -ge 1 ] || fail_preflight "tasks file has no tasks: $TASKS_FILE"

# --- preflight: adapters and CLIs are checked BEFORE the first task starts ---
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  case "$line" in \#*) continue ;; esac
  rest="${line#*	}"
  vendor="${rest%%	*}"
  adapter="$ADAPTERS_DIR/${vendor}-peer-adapter.sh"
  [ -f "$adapter" ] && [ -x "$adapter" ] || fail_preflight "adapter missing or not executable: $adapter"
  if [ "${IWE_FANOUT_SKIP_CLI_CHECK:-}" != "1" ] && [ "$vendor" != "hermes" ]; then
    command -v "$vendor" >/dev/null 2>&1 || fail_preflight "CLI '$vendor' not found in PATH (needed by $adapter)"
  fi
done < "$TASKS_FILE"

# --- OUT_DIR ---
if [ -n "$OUT_DIR_ARG" ]; then
  [ -L "$OUT_DIR_ARG" ] && fail_preflight "out-dir is a symlink, refusing to follow: $OUT_DIR_ARG"
  if [ -d "$OUT_DIR_ARG" ]; then
    while IFS= read -r id; do
      [ -e "$OUT_DIR_ARG/$id.md" ] && fail_preflight "out-dir already contains result '$id.md', refusing to overwrite: $OUT_DIR_ARG"
    done < "$SEEN_IDS_FILE"
  else
    mkdir -p "$OUT_DIR_ARG" || fail_preflight "cannot create out-dir: $OUT_DIR_ARG"
  fi
  OUT_DIR="$OUT_DIR_ARG"
else
  OUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/peer-fanout.XXXXXX")
fi

# --- launch ---
START_EPOCH=$(date +%s)
LIVE_PIDS_FILE=$(mktemp "${TMPDIR:-/tmp}/fanout-pids.XXXXXX")
: > "$LIVE_PIDS_FILE"

kill_tree() {
  # kill descendants recursively (adapter -> CLI -> its children), then the process itself
  local pid="$1" child
  [ -n "$pid" ] || return 0
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_tree "$child"
  done
  kill "$pid" 2>/dev/null
}

on_interrupt() {
  trap - TERM INT
  echo "" >&2
  echo "INTERRUPTED: killing task group..." >&2
  while IFS= read -r pid; do
    [ -n "$pid" ] && kill_tree "$pid"
  done < "$LIVE_PIDS_FILE"
  sleep 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
  done < "$LIVE_PIDS_FILE"
  summarize "interrupted"
  exit 2
}

summarize() {
  local final_state="$1"
  echo ""
  echo "=== fan-out summary ($final_state) ==="
  printf '%-20s | %-8s | %-12s | %-8s | %s\n' "id" "vendor" "status" "bytes" "elapsed_s"
  local total=0 ok=0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    local id="${line%%	*}"
    local rest="${line#*	}"
    local vendor="${rest%%	*}"
    local status_file="$OUT_DIR/$id.status"
    local status="not_started"
    [ -f "$status_file" ] && status=$(cat "$status_file")
    local bytes=0
    [ -f "$OUT_DIR/$id.md" ] && bytes=$(wc -c < "$OUT_DIR/$id.md" | tr -d ' ')
    local started=0 ended=0
    [ -f "$OUT_DIR/$id.t0" ] && started=$(cat "$OUT_DIR/$id.t0")
    [ -f "$OUT_DIR/$id.t1" ] && ended=$(cat "$OUT_DIR/$id.t1")
    local elapsed="-"
    [ "$started" != "0" ] && [ "$ended" != "0" ] && elapsed=$((ended - started))
    printf '%-20s | %-8s | %-12s | %-8s | %s\n' "$id" "$vendor" "$status" "$bytes" "$elapsed"
    total=$((total + 1))
    [ "$status" = "ok" ] && ok=$((ok + 1))
  done < "$TASKS_FILE"
  echo "---"
  echo "ok=$ok total=$total out_dir=$OUT_DIR wall_s=$(( $(date +%s) - START_EPOCH ))"
}

# Per-task watchdog. The adapter runs in its own process group; after N seconds
# the whole group (adapter and the vendor CLI it started) gets TERM, then KILL,
# and the watchdog exits 142. An exec'ed alarm would kill only the adapter and
# leave the CLI running (and spending tokens) after the task is reported as timed out.
# shellcheck disable=SC2016  # perl code, not shell: $t/$pid must stay literal
WATCHDOG_PL='
my $t = shift;
my $pid = fork();
die "fork failed: $!\n" unless defined $pid;
if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127; }
$SIG{ALRM} = sub { kill "TERM", -$pid; sleep 1; kill "KILL", -$pid; waitpid($pid, 0); exit 142; };
alarm $t;
waitpid($pid, 0);
my $st = $?;
alarm 0;
exit(($st & 127) ? 128 + ($st & 127) : $st >> 8);
'

trap on_interrupt TERM INT

while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  case "$line" in \#*) continue ;; esac
  id="${line%%	*}"
  rest="${line#*	}"
  vendor="${rest%%	*}"
  prompt="${rest#*	}"
  adapter="$ADAPTERS_DIR/${vendor}-peer-adapter.sh"
  (
    date +%s > "$OUT_DIR/$id.t0"
    printf '%s' "$prompt" | IWE_PEER_PLAIN=1 perl -e "$WATCHDOG_PL" "$TIMEOUT_SEC" bash "$adapter" > "$OUT_DIR/$id.md" 2> "$OUT_DIR/$id.err"
    rc=$?
    date +%s > "$OUT_DIR/$id.t1"
    if [ "$rc" -eq 0 ]; then
      if [ -s "$OUT_DIR/$id.md" ]; then echo "ok" > "$OUT_DIR/$id.status"; else echo "error:empty" > "$OUT_DIR/$id.status"; fi
    elif [ "$rc" -eq 142 ]; then
      echo "timeout" > "$OUT_DIR/$id.status"
    else
      echo "error:$rc" > "$OUT_DIR/$id.status"
    fi
  ) &
  tpid=$!
  echo "$tpid" >> "$LIVE_PIDS_FILE"
done < "$TASKS_FILE"

# --- collect without mutual waiting: wait on each PID, one failure does not stop the loop ---
FINAL_RC=0
while IFS= read -r tpid; do
  [ -n "$tpid" ] || continue
  # the task status comes from its .status file, not from wait's code (wait is over a subshell)
  wait "$tpid" 2>/dev/null
done < "$LIVE_PIDS_FILE"

while IFS= read -r id; do
  status=$(cat "$OUT_DIR/$id.status" 2>/dev/null || echo "unknown")
  [ "$status" = "ok" ] || FINAL_RC=2
done < "$SEEN_IDS_FILE"

rm -f "$LIVE_PIDS_FILE" "$SEEN_IDS_FILE"
trap - EXIT
summarize "done"
exit "$FINAL_RC"
