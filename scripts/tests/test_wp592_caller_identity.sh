#!/usr/bin/env bash
# WP-592 F7: a day-open mark is opened and closed under the caller's own
# conversation id, whichever agent runs it. Codex reads CODEX_THREAD_ID, Claude
# reads CLAUDE_CODE_SESSION_ID. A child agent inherits the parent's variables,
# IWE_AGENT included, so a caller that sees both ids owns no mark whatever
# IWE_AGENT says, and an id of the other family is never borrowed. A refused
# close changes nothing on disk.
# Runs both implementations of the guard: full and Git Bash (stub uname).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

CLAUDE_ID=claude-conv-1
CODEX_ID=codex-thread-1

# Run the guard as a caller with exactly the given identity variables ("-" = unset).
# <root> <PATH prefix or ""> <IWE_AGENT> <CLAUDE id> <CODEX id> <args...>
run_as() {
  local root="$1" prefix="$2" agent="$3" cid="$4" xid="$5"; shift 5
  local envs=(-u IWE_AGENT -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID)
  [ "$agent" = - ] || envs+=("IWE_AGENT=$agent")
  [ "$cid" = - ] || envs+=("CLAUDE_CODE_SESSION_ID=$cid")
  [ "$xid" = - ] || envs+=("CODEX_THREAD_ID=$xid")
  rc=0
  out=$(env "${envs[@]}" PATH="${prefix:+$prefix:}$PATH" IWE_ROOT="$root" \
    IWE_GOVERNANCE_REPO=DS-strategy IWE_SG_GITBASH_LOCK_TRIES=2 \
    bash "$GUARD" "$@" 2>&1) || rc=$?
}

# Names and contents of everything in the sessions folder.
snapshot() { # <sessions dir>
  local f
  for f in "$1"/* "$1"/.[!.]*; do
    [ -e "$f" ] || continue
    printf '== %s\n' "${f##*/}"
    cat "$f"
  done
}

check_whoami() {
  local root="$TMP_DIR/whoami"
  mkdir -p "$root/DS-strategy"
  expect() { # <label> <IWE_AGENT> <claude id> <codex id> <agent> <harness> <resolution>
    run_as "$root" "" "$2" "$3" "$4" whoami
    [ "$rc" -eq 0 ] || fail "whoami $1: rc=$rc: $out"
    local want
    want=$(printf 'agent: %s\nharness: %s\nresolution: %s' "$5" "$6" "$7")
    [ "$out" = "$want" ] || fail "whoami $1: got [$out], want [$want]"
  }
  expect claude-alone - "$CLAUDE_ID" - claude-code "$CLAUDE_ID" inferred
  expect codex-alone - - "$CODEX_ID" codex "$CODEX_ID" inferred
  expect both-no-agent - "$CLAUDE_ID" "$CODEX_ID" claude-code "" ambiguous
  expect codex-explicit codex - "$CODEX_ID" codex "$CODEX_ID" explicit
  expect claude-explicit claude-code "$CLAUDE_ID" - claude-code "$CLAUDE_ID" explicit
  expect codex-in-claude codex "$CLAUDE_ID" "$CODEX_ID" codex "" ambiguous
  expect claude-in-codex claude-code "$CLAUDE_ID" "$CODEX_ID" claude-code "" ambiguous
  expect codex-no-own-id codex "$CLAUDE_ID" - codex "" explicit
  expect kimi kimi "$CLAUDE_ID" - kimi "" explicit
  expect nothing - - - claude-code "" none
  run_as "$root" "" - "$CLAUDE_ID" - whoami --field harness
  [ "$out" = "$CLAUDE_ID" ] || fail "whoami --field harness: [$out]"
  run_as "$root" "" 'bad agent' - - whoami
  [ "$rc" -eq 1 ] || fail "whoami with unsafe IWE_AGENT: rc=$rc, want 1"
  run_as "$root" "" - - - whoami --field pid
  [ "$rc" -eq 1 ] || fail "whoami with an unknown field: rc=$rc, want 1"
  echo "ok: whoami"
}

# The owner opens the mark as <agent>; another caller tries --only-own-harness
# close and must be refused with the sessions folder unchanged; then the owner
# closes it, or is refused too when no id was recorded.
# <mode> <PATH prefix> <case> <agent> <owner IWE_AGENT> <owner CLAUDE> <owner CODEX>
#   <other IWE_AGENT> <other CLAUDE> <other CODEX> <expected harness line or ->
check_case() {
  local mode="$1" prefix="$2" label="$3" agent="$4"
  local oa="$5" oc="$6" ox="$7" xa="$8" xc="$9" xx="${10}" want="${11}"
  local root="$TMP_DIR/$mode-$label" sessions sem before after
  sessions="$root/.iwe-runtime/sessions"
  sem="$sessions/$agent-housekeeping-day-open.open"
  mkdir -p "$root/DS-strategy"

  run_as "$root" "$prefix" "$oa" "$oc" "$ox" open --housekeeping day-open --agent "$agent"
  [ "$rc" -eq 0 ] || fail "$mode/$label: open rc=$rc: $out"
  if [ "$want" = - ]; then
    ! grep -q '^harness_session_id: ' "$sem" || fail "$mode/$label: a conversation id was recorded: $(cat "$sem")"
  else
    grep -qx "harness_session_id: $want" "$sem" || fail "$mode/$label: want harness $want: $(cat "$sem")"
  fi

  # A previous run's receipt and an older archive: a close that archives
  # before it checks ownership would move them, and the snapshot would differ.
  printf 'previous run %s\n' "$label" > "$sem.closed"
  printf 'older archive %s\n' "$label" > "$sem.closed.20260101T000000Z.1.1"
  before=$(snapshot "$sessions")
  run_as "$root" "$prefix" "$xa" "$xc" "$xx" close --housekeeping day-open --agent "$agent" --only-own-harness
  [ "$rc" -eq 3 ] || fail "$mode/$label: foreign close rc=$rc, want 3: $out"
  after=$(snapshot "$sessions")
  [ "$before" = "$after" ] || fail "$mode/$label: refused close changed the sessions folder"

  run_as "$root" "$prefix" "$oa" "$oc" "$ox" close --housekeeping day-open --agent "$agent" --only-own-harness
  if [ "$want" = - ]; then
    [ "$rc" -eq 3 ] || fail "$mode/$label: owner without an id closed the mark (rc=$rc)"
    after=$(snapshot "$sessions")
    [ "$before" = "$after" ] || fail "$mode/$label: owner's refused close changed the sessions folder"
  else
    [ "$rc" -eq 0 ] || fail "$mode/$label: own close rc=$rc: $out"
    [ ! -e "$sem" ] && [ -f "$sem.closed" ] || fail "$mode/$label: own close left the mark open"
  fi
}

check_mode() { # <mode> <PATH prefix>
  local m="$1" p="$2"
  #                    case            agent       owner: IWE_AGENT CLAUDE CODEX           other: IWE_AGENT CLAUDE CODEX     harness
  check_case "$m" "$p" claude-alone    claude-code -           "$CLAUDE_ID" -            -           other-claude -            "$CLAUDE_ID"
  check_case "$m" "$p" codex-alone     codex       -           -            "$CODEX_ID"  -           -            other-codex  "$CODEX_ID"
  check_case "$m" "$p" codex-explicit  codex       codex       -            "$CODEX_ID"  codex       -            other-codex  "$CODEX_ID"
  # A child agent sees both ids: it records none and owns nothing, whatever IWE_AGENT says.
  check_case "$m" "$p" codex-in-claude codex       codex       "$CLAUDE_ID" "$CODEX_ID"  claude-code "$CLAUDE_ID" -            -
  check_case "$m" "$p" claude-in-codex claude-code claude-code "$CLAUDE_ID" "$CODEX_ID"  codex       -            "$CODEX_ID"  -
  check_case "$m" "$p" ambiguous       claude-code -           "$CLAUDE_ID" "$CODEX_ID"  -           "$CLAUDE_ID" -            -
  # The parent's own mark is safe from a child that inherited IWE_AGENT and the
  # parent's id (Codex started from Claude without its project settings, and
  # Claude started from Codex).
  check_case "$m" "$p" claude-parent   claude-code -           "$CLAUDE_ID" -            claude-code "$CLAUDE_ID" "$CODEX_ID"  "$CLAUDE_ID"
  check_case "$m" "$p" codex-parent    codex       -           -            "$CODEX_ID"  codex       "$CLAUDE_ID" "$CODEX_ID"  "$CODEX_ID"
  # IWE_AGENT names another family than --agent, one id only: nothing recorded.
  check_case "$m" "$p" family-mismatch claude-code codex       "$CLAUDE_ID" -            -           other-claude -            -
  check_case "$m" "$p" family-mismatch-codex codex claude-code -           "$CODEX_ID"  -           -            other-codex  -
  # The owner's own id under another family's IWE_AGENT does not close the mark.
  check_case "$m" "$p" family-close    claude-code -           "$CLAUDE_ID" -            codex       "$CLAUDE_ID" -            "$CLAUDE_ID"
  check_case "$m" "$p" family-close-codex codex    -           -            "$CODEX_ID"  claude-code -            "$CODEX_ID"  "$CODEX_ID"
  # Kimi has no native conversation id: an inherited Claude id is not borrowed.
  check_case "$m" "$p" kimi-in-claude  kimi        kimi        "$CLAUDE_ID" -            -           "$CLAUDE_ID" -            -
  echo "ok: $m"
}

# The ambiguous mark says so, instead of passing for an established author.
check_ambiguous_marked() {
  local root="$TMP_DIR/ambiguous-marked"
  mkdir -p "$root/DS-strategy"
  run_as "$root" "" - "$CLAUDE_ID" "$CODEX_ID" open --housekeeping day-open --agent claude-code
  [ "$rc" -eq 0 ] || fail "ambiguous-marked: open rc=$rc: $out"
  grep -qx 'agent_resolution: ambiguous' "$root/.iwe-runtime/sessions/claude-code-housekeeping-day-open.open" \
    || fail "ambiguous-marked: no agent_resolution line"
  run_as "$root" "" - "$CLAUDE_ID" "$CODEX_ID" close --housekeeping day-open --agent claude-code --only-own-harness
  [ "$rc" -eq 3 ] || fail "ambiguous-marked: close rc=$rc, want 3"
  printf '%s\n' "$out" | grep -q 'запущен из другого агента' \
    || fail "ambiguous-marked: the refusal does not name the reason: $out"
  run_as "$root" "" - - "$CODEX_ID" close --housekeeping day-open --agent claude-code --only-own-harness
  printf '%s\n' "$out" | grep -q 'нет своего номера разговора' \
    || fail "ambiguous-marked: a caller without an own id is told something else: $out"
  echo "ok: ambiguous mark labelled, refusals name the reason"
}

check_whoami
check_mode full ""
check_ambiguous_marked
STUBS="$TMP_DIR/stubs"
mkdir -p "$STUBS"
printf '#!/bin/sh\necho MINGW64_NT-10.0-22631\n' > "$STUBS/uname"
chmod +x "$STUBS/uname"
check_mode gitbash "$STUBS"
echo "PASS: WP-592 caller identity"
