#!/usr/bin/env bash
# Regression for issue #1419: a housekeeping semaphore keeps the same name on
# every open, so the .closed (and .stale) left by an earlier run used to block
# the next run's close ("exact identity/terminal state") and its stale rename
# (".stale destination collision"). Checked on the real guard in a temporary
# IWE_ROOT, in the full implementation and in the degraded Git Bash mode.
set -euo pipefail
unset IWE_SESSIONS_ROOT

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Run the guard against <root>; stdout+stderr in $out, exit code in $rc.
guard() { # <root> <extra PATH prefix or ""> <args...>
  local root="$1" prefix="$2"; shift 2
  rc=0
  out=$(PATH="${prefix:+$prefix:}$PATH" IWE_ROOT="$root" IWE_GOVERNANCE_REPO=DS-strategy \
    IWE_SG_GITBASH_LOCK_TRIES=2 CLAUDE_CODE_SESSION_ID="" bash "$GUARD" "$@" 2>&1) || rc=$?
}

# Rewrite created_at so the open looks older than the 30-minute TTL.
age_semaphore() { # <file>
  local old
  old=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=2)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  sed -i.bak "s/^created_at: .*/created_at: $old/" "$1" && rm -f "$1.bak"
}

archives() { # <sessions dir> <suffix: closed|stale>
  find "$1" -maxdepth 1 -name "kimi-housekeeping-day-open.open.$2.*" | wc -l | tr -d ' '
}

check_mode() { # <label> <PATH prefix for the mode>
  local label="$1" prefix="$2" root sessions sem
  root="$TMP_DIR/$label"
  sessions="$root/.iwe-runtime/sessions"
  mkdir -p "$root/DS-strategy"
  sem="$sessions/kimi-housekeeping-day-open.open"

  # Day 1: open and close leave a .closed receipt.
  guard "$root" "$prefix" open --housekeeping day-open --agent kimi
  [ "$rc" -eq 0 ] || fail "$label: first open rc=$rc: $out"
  guard "$root" "$prefix" close --housekeeping day-open --agent kimi
  [ "$rc" -eq 0 ] || fail "$label: first close rc=$rc: $out"
  [ -f "$sem.closed" ] || fail "$label: no .closed after first close"

  # Day 2: the same reason opens and closes again despite yesterday's .closed.
  guard "$root" "$prefix" open --housekeeping day-open --agent kimi
  [ "$rc" -eq 0 ] || fail "$label: second open rc=$rc: $out"
  [ "$(archives "$sessions" closed)" = 1 ] || fail "$label: previous .closed not archived on open"
  guard "$root" "$prefix" close --housekeeping day-open --agent kimi
  [ "$rc" -eq 0 ] || fail "$label: second close rc=$rc (bug #1419): $out"
  grep -q '^closed_at: \|^close_protocol: ' "$sem.closed" || fail "$label: new .closed lacks a close record"

  # Stale open twice in a row: the second stale rename meets the first .stale.
  for round in 1 2; do
    guard "$root" "$prefix" open --housekeeping day-open --agent kimi
    [ "$rc" -eq 0 ] || fail "$label: stale round $round open rc=$rc: $out"
    age_semaphore "$sem"
  done
  guard "$root" "$prefix" open --housekeeping day-open --agent kimi
  [ "$rc" -eq 0 ] || fail "$label: open over two stale runs rc=$rc (.stale collision): $out"
  [ -f "$sem.stale" ] || fail "$label: latest stale open not kept as .stale"
  [ "$(archives "$sessions" stale)" = 1 ] || fail "$label: earlier .stale not archived"
  guard "$root" "$prefix" close --housekeeping day-open --agent kimi
  [ "$rc" -eq 0 ] || fail "$label: close after stale rounds rc=$rc: $out"
  echo "ok: $label"
}

# Installation that opened before the fix: today's .open already sits next to
# an earlier run's .closed. Close alone must recover it.
check_legacy_state() {
  local root="$TMP_DIR/legacy" sessions sem
  sessions="$root/.iwe-runtime/sessions"
  mkdir -p "$root/DS-strategy"
  sem="$sessions/kimi-housekeeping-day-open.open"
  guard "$root" "" open --housekeeping day-open --agent kimi
  [ "$rc" -eq 0 ] || fail "legacy: setup open rc=$rc: $out"
  guard "$root" "" close --housekeeping day-open --agent kimi
  [ "$rc" -eq 0 ] || fail "legacy: setup close rc=$rc: $out"
  cp -p "$sem.closed" "$TMP_DIR/old.closed"
  guard "$root" "" open --housekeeping day-open --agent kimi
  [ "$rc" -eq 0 ] || fail "legacy: open rc=$rc: $out"
  find "$sessions" -maxdepth 1 -name 'kimi-housekeeping-day-open.open.closed.*' -delete
  cp -p "$TMP_DIR/old.closed" "$sem.closed"
  guard "$root" "" close --housekeeping day-open --agent kimi
  [ "$rc" -eq 0 ] || fail "legacy: close next to an old .closed rc=$rc: $out"
  [ "$(archives "$sessions" closed)" = 1 ] || fail "legacy: old .closed not archived on close"
  echo "ok: legacy state"
}

# Crashes inside the fix itself must not wedge the reason forever (cold review):
# (1) archive stopped after link, before unlink — .closed has a second name;
# (2) close stopped with .closed linked to .open, then the open went stale and
#     was renamed — .closed and .stale share one inode.
check_crash_recovery() {
  local root="$TMP_DIR/crash" sessions sem
  sessions="$root/.iwe-runtime/sessions"
  mkdir -p "$root/DS-strategy"
  sem="$sessions/kimi-housekeeping-day-open.open"

  guard "$root" "" open --housekeeping day-open --agent kimi
  guard "$root" "" close --housekeeping day-open --agent kimi
  [ "$rc" -eq 0 ] || fail "crash: setup close rc=$rc: $out"
  ln "$sem.closed" "$sem.closed.20260101T000000Z.deadbeef0000"
  guard "$root" "" open --housekeeping day-open --agent kimi
  [ "$rc" -eq 0 ] || fail "crash: open after interrupted archive rc=$rc: $out"
  [ ! -e "$sem.closed" ] || fail "crash: interrupted archive not finished"
  [ "$(archives "$sessions" closed)" = 1 ] || fail "crash: interrupted archive duplicated"
  guard "$root" "" close --housekeeping day-open --agent kimi
  [ "$rc" -eq 0 ] || fail "crash: close after interrupted archive rc=$rc: $out"

  guard "$root" "" open --housekeeping day-open --agent kimi
  [ "$rc" -eq 0 ] || fail "crash: open before half close rc=$rc: $out"
  find "$sessions" -maxdepth 1 -name 'kimi-housekeeping-day-open.open.closed.*' -delete
  rm -f "$sem.closed"
  ln "$sem" "$sem.closed"
  age_semaphore "$sem"
  for round in 1 2; do
    guard "$root" "" open --housekeeping day-open --agent kimi
    [ "$rc" -eq 0 ] || fail "crash: open $round after half close went stale rc=$rc: $out"
    age_semaphore "$sem"
  done
  echo "ok: crash recovery"
}

check_mode full ""
check_crash_recovery

STUBS="$TMP_DIR/stubs"
mkdir -p "$STUBS"
printf '#!/bin/sh\necho MINGW64_NT-10.0-22631\n' > "$STUBS/uname"
chmod +x "$STUBS/uname"
check_mode gitbash "$STUBS"

check_legacy_state
echo "PASS: issue #1419 housekeeping reopen"
