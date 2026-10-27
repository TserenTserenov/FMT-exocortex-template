#!/usr/bin/env bash
# Regression for issue #1359: on Git Bash (Windows) session-guard used to refuse
# every command, which stopped the nightly loop. Now open/close --housekeeping and
# note-file run in a degraded pure-bash mode; everything else is refused up front.
# The routing is checked here with a stubbed `uname`; this does NOT prove the mode
# works on a real Windows host (MSYS paths, NTFS) -- that needs a Windows run.
set -euo pipefail
unset IWE_SESSIONS_ROOT

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

STUBS="$TMP_DIR/stubs"
mkdir -p "$STUBS" "$TMP_DIR/DS-strategy"
printf '#!/bin/sh\necho MINGW64_NT-10.0-22631\n' > "$STUBS/uname"
# Python that fails loudly and leaves a marker: the degraded path must not call it.
printf '#!/bin/sh\ntouch "%s/python-was-called"\nexit 97\n' "$TMP_DIR" > "$STUBS/python3"
chmod +x "$STUBS/uname" "$STUBS/python3"

SESSIONS="$TMP_DIR/.iwe-runtime/sessions"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Windows-routed call; stdout and stderr merged in $out, exit code in $rc.
gb() {
  rc=0
  out=$(PATH="$STUBS:$PATH" IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO=DS-strategy IWE_SG_GITBASH_LOCK_TRIES=2 \
    bash "$GUARD" "$@" 2>&1) || rc=$?
}

# 1. open --housekeeping works without Python and tells about the degraded mode.
gb open --housekeeping nightly --agent kimi
[ "$rc" -eq 0 ] || fail "open --housekeeping rc=$rc: $out"
grep -q "упрощённый режим Git Bash" <<<"$out" || fail "no degraded-mode notice: $out"
SEM="$SESSIONS/kimi-housekeeping-nightly.open"
[ -f "$SEM" ] || fail "semaphore not created"
grep -qx 'agent: kimi' "$SEM" && grep -qx 'session_id: housekeeping-nightly' "$SEM" \
  && grep -qx 'slug: nightly' "$SEM" || fail "semaphore lacks identity lines: $(cat "$SEM")"
[ ! -e "$TMP_DIR/python-was-called" ] || fail "degraded open called python3"
[ ! -d "$SESSIONS/.gb-lock-kimi-housekeeping-nightly" ] || fail "lock left behind after open"

# 2. a second open of the same fresh session is refused and keeps the file.
before=$(cat "$SEM")
gb open --housekeeping nightly --agent kimi
[ "$rc" -eq 1 ] || fail "second open should fail, rc=$rc"
grep -q "уже есть активная housekeeping-сессия" <<<"$out" || fail "wrong refusal text: $out"
[ "$(cat "$SEM")" = "$before" ] || fail "second open changed the semaphore"

# 3. note-file records the repo-relative path (file and directory).
REPO="$TMP_DIR/repo"
mkdir -p "$REPO/current/sub"
git -C "$REPO" init -q
printf x > "$REPO/current/sub/plan.md"
gb note-file "$REPO/current/sub/plan.md" --agent kimi --slug nightly
[ "$rc" -eq 0 ] || fail "note-file rc=$rc: $out"
grep -qx 'file: current/sub/plan.md' "$SEM" || fail "file line missing: $(cat "$SEM")"
gb note-file "$REPO/current/sub" --agent kimi --slug nightly
[ "$rc" -eq 0 ] || fail "note-file dir rc=$rc: $out"
grep -qx 'file: current/sub/' "$SEM" || fail "dir line missing (trailing slash): $(cat "$SEM")"

# 4. close --housekeeping moves the semaphore to .closed; later note-file has no session.
gb close --housekeeping nightly --agent kimi
[ "$rc" -eq 0 ] || fail "close rc=$rc: $out"
[ ! -e "$SEM" ] && [ -f "$SEM.closed" ] || fail "close did not produce .closed"
grep -qx 'close_protocol: degraded-gitbash-v1' "$SEM.closed" || fail "close receipt missing"
gb note-file "$REPO/current/sub/plan.md" --agent kimi --slug nightly
[ "$rc" -eq 1 ] || fail "note-file after close should fail, rc=$rc"
gb close --housekeeping nightly --agent kimi
[ "$rc" -eq 3 ] || fail "second close should return 3, rc=$rc"

# 4a. values that go into the semaphore verbatim cannot forge extra lines.
rm -rf "$SESSIONS"
gb open --housekeeping inj --agent kimi --personality $'x\nfile: secrets/'
[ "$rc" -eq 1 ] || fail "newline in --personality must be refused, rc=$rc"
gb open --housekeeping inj --agent kimi --owner-pid $'1\nsession_id: z'
[ "$rc" -eq 1 ] || fail "newline in --owner-pid must be refused, rc=$rc"
[ ! -e "$SESSIONS/kimi-housekeeping-inj.open" ] || fail "forged semaphore was created"

# 4b. stale semaphore (older than the TTL) is moved to .stale and replaced;
#     an unreadable created_at is never treated as stale.
gb open --housekeeping aged --agent kimi
SEM_AGED="$SESSIONS/kimi-housekeeping-aged.open"
sed -i.bak 's/^created_at: .*/created_at: 2020-01-01T00:00:00Z/' "$SEM_AGED" && rm -f "$SEM_AGED.bak"
gb open --housekeeping aged --agent kimi
[ "$rc" -eq 0 ] || fail "stale semaphore should be replaced, rc=$rc: $out"
[ -f "$SEM_AGED.stale" ] && grep -qx 'created_at: 2020-01-01T00:00:00Z' "$SEM_AGED.stale" || fail "old semaphore not kept as .stale"
sed -i.bak '/^created_at: /d' "$SEM_AGED" && rm -f "$SEM_AGED.bak"
before=$(cat "$SEM_AGED")
gb open --housekeeping aged --agent kimi
[ "$rc" -eq 1 ] || fail "semaphore without created_at must not be replaced, rc=$rc"
[ "$(cat "$SEM_AGED")" = "$before" ] || fail "semaphore without created_at was modified"

# 4c. note-file: a future file in a directory that does not exist yet, and the repo root.
gb open --housekeeping fut --agent kimi
gb note-file "$REPO/archive/2026/new.md" --agent kimi --slug fut
[ "$rc" -eq 0 ] || fail "note-file future path rc=$rc: $out"
grep -qx 'file: archive/2026/new.md' "$SESSIONS/kimi-housekeeping-fut.open" || fail "future path line missing"
gb note-file "$REPO" --agent kimi --slug fut
[ "$rc" -eq 0 ] || fail "note-file repo root rc=$rc: $out"
grep -qx 'file: ./' "$SESSIONS/kimi-housekeeping-fut.open" || fail "repo root line missing"

# 4d. a close already started by the full implementation is not completed here.
printf 'close_protocol: durable-v2\n' >> "$SESSIONS/kimi-housekeeping-fut.open"
gb close --housekeeping fut --agent kimi
[ "$rc" -eq 1 ] || fail "close over a foreign close receipt must be refused, rc=$rc"
[ ! -e "$SESSIONS/kimi-housekeeping-fut.open.closed" ] || fail "foreign receipt was closed over"

# 4e. interchangeable with the full implementation, both directions.
rm -rf "$SESSIONS"
gb open --housekeeping xa --agent kimi
rc=0; out=$(IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO=DS-strategy bash "$GUARD" close --housekeeping xa --agent kimi 2>&1) || rc=$?
[ "$rc" -eq 0 ] && [ -f "$SESSIONS/kimi-housekeeping-xa.open.closed" ] || fail "full close of a degraded semaphore failed rc=$rc: $out"
rc=0; out=$(IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO=DS-strategy bash "$GUARD" open --housekeeping xb --agent kimi 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "full open failed rc=$rc: $out"
gb close --housekeeping xb --agent kimi
[ "$rc" -eq 0 ] && [ -f "$SESSIONS/kimi-housekeeping-xb.open.closed" ] || fail "degraded close of a full semaphore failed rc=$rc: $out"
[ ! -d "$SESSIONS/.gb-lock-kimi-housekeeping-xb" ] || fail "lock left after a successful close"

# 5. everything outside the three commands is refused before any state change.
rm -rf "$SESSIONS"
refused() {
  gb "$@"
  [ "$rc" -eq 1 ] || fail "'$*' should be refused, rc=$rc: $out"
  grep -q "только упрощённый режим" <<<"$out" || fail "'$*': no refusal text: $out"
  [ ! -d "$SESSIONS" ] || [ -z "$(ls -A "$SESSIONS")" ] || fail "'$*' changed state: $(ls -A "$SESSIONS")"
}
refused open --wp WP-001 --agent kimi --slug s
refused open --housekeeping x --agent kimi --isolate
refused open --housekeeping x --agent kimi --wp WP-001
refused close --agent kimi --slug s
refused note-file "$REPO/a" --agent kimi
refused heartbeat --agent kimi
refused quarantine
[ ! -e "$TMP_DIR/python-was-called" ] || fail "refusal path called python3"

# 6. a held lock is not taken over; the message names the directory to remove.
mkdir -p "$SESSIONS/.gb-lock-kimi-housekeeping-held"
gb open --housekeeping held --agent kimi
[ "$rc" -eq 1 ] || fail "held lock should block, rc=$rc"
grep -q "rm -rf" <<<"$out" || fail "no manual-removal hint: $out"
[ ! -e "$SESSIONS/kimi-housekeeping-held.open" ] || fail "semaphore created under a held lock"

# 7. outside Windows the old path runs: no degraded-mode notice.
rm -rf "$TMP_DIR/.iwe-runtime"
rc=0
out=$(IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO=DS-strategy bash "$GUARD" open --housekeeping plain --agent kimi 2>&1) || rc=$?
! grep -q "упрощённый режим Git Bash" <<<"$out" || fail "degraded notice leaked into the normal path: $out"
[ "$rc" -eq 0 ] || fail "normal-path open failed rc=$rc: $out"

echo "PASS: session guard on Git Bash: three nightly commands run degraded, the rest refused, normal path untouched"
