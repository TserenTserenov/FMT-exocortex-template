#!/usr/bin/env bash
# git-sync-status-smoke.sh — regression coverage for scripts/lib/git-sync-status.sh
# (WP-561 Ф20). Real bare-origin sandboxes, real git commands — no mocking of
# the classifier itself, only of the network for fetch_failed.
set -uo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/git-sync-status.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB not found"; exit 1; }
# shellcheck source=../lib/git-sync-status.sh
. "$LIB"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAILURES=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 -- ожидалось '$2', получено '$3'"
    FAILURES=$((FAILURES + 1))
  fi
}

setup_sandbox() {  # setup_sandbox <dir> -- clone + real bare "origin"
  local dir="$1"
  local bare="$dir/origin.git"
  git init -q --bare "$bare"
  git clone -q "$bare" "$dir/repo"
  git -C "$dir/repo" checkout -q -b main
  git -C "$dir/repo" config user.email test@test.local
  git -C "$dir/repo" config user.name test
  echo init > "$dir/repo/seed.md"
  git -C "$dir/repo" add seed.md
  git -C "$dir/repo" commit -q -m init
  git -C "$dir/repo" push -q origin main
  git -C "$bare" symbolic-ref HEAD refs/heads/main
}

commit_and_push() {  # commit_and_push <repo> <message>
  local repo="$1" msg="$2"
  echo "$msg" >> "$repo/seed.md"
  git -C "$repo" add seed.md
  git -C "$repo" commit -q -m "$msg"
  git -C "$repo" push -q origin main
}

echo "=== OK: HEAD equals origin ==="
DIR="$TMP/ok-equal"; mkdir -p "$DIR"; setup_sandbox "$DIR"
check_git_sync_status "$DIR/repo" main 5
check "status" "OK" "$GIT_SYNC_STATUS"
check "behind" "0" "$GIT_SYNC_BEHIND"
check "ahead" "0" "$GIT_SYNC_AHEAD"

echo "=== OK: ahead-only (local commit not yet pushed) ==="
DIR="$TMP/ok-ahead"; mkdir -p "$DIR"; setup_sandbox "$DIR"
echo local >> "$DIR/repo/seed.md"
git -C "$DIR/repo" add seed.md
git -C "$DIR/repo" commit -q -m local-only
check_git_sync_status "$DIR/repo" main 5
check "status" "OK" "$GIT_SYNC_STATUS"
check "ahead" "1" "$GIT_SYNC_AHEAD"

echo "=== STALE: behind, remote object present locally (exact count) ==="
DIR="$TMP/stale-known"; mkdir -p "$DIR"; setup_sandbox "$DIR"
DIR2="$TMP/stale-known-pusher"; git clone -q "$DIR/origin.git" "$DIR2" 2>/dev/null
git -C "$DIR2" checkout -q main
commit_and_push "$DIR2" second-commit
git -C "$DIR/repo" fetch -q origin main
check_git_sync_status "$DIR/repo" main 5
check "status" "STALE" "$GIT_SYNC_STATUS"
check "behind" "1" "$GIT_SYNC_BEHIND"

echo "=== STALE: behind, remote object absent locally (unknown count, no fetch was run) ==="
DIR="$TMP/stale-unknown"; mkdir -p "$DIR"; setup_sandbox "$DIR"
DIR2="$TMP/stale-unknown-pusher"; git clone -q "$DIR/origin.git" "$DIR2" 2>/dev/null
git -C "$DIR2" checkout -q main
commit_and_push "$DIR2" second-commit
# deliberately no `git fetch` here — this is the exact scenario the checker
# exists for: origin moved, local has never seen the new object.
check_git_sync_status "$DIR/repo" main 5
check "status" "STALE" "$GIT_SYNC_STATUS"
check "behind" "unknown" "$GIT_SYNC_BEHIND"

echo "=== DIVERGED: both sides have commits the other lacks ==="
DIR="$TMP/diverged"; mkdir -p "$DIR"; setup_sandbox "$DIR"
DIR2="$TMP/diverged-pusher"; git clone -q "$DIR/origin.git" "$DIR2" 2>/dev/null
git -C "$DIR2" checkout -q main
commit_and_push "$DIR2" remote-side-commit
echo local >> "$DIR/repo/seed.md"
git -C "$DIR/repo" add seed.md
git -C "$DIR/repo" commit -q -m local-side-commit
git -C "$DIR/repo" fetch -q origin main
check_git_sync_status "$DIR/repo" main 5
check "status" "DIVERGED" "$GIT_SYNC_STATUS"
check "behind" "1" "$GIT_SYNC_BEHIND"
check "ahead" "1" "$GIT_SYNC_AHEAD"

echo "=== NO_UPSTREAM: origin remote missing ==="
DIR="$TMP/no-origin"; mkdir -p "$DIR/repo"
git -C "$DIR/repo" init -q -b main
git -C "$DIR/repo" config user.email test@test.local
git -C "$DIR/repo" config user.name test
echo x > "$DIR/repo/seed.md"
git -C "$DIR/repo" add seed.md
git -C "$DIR/repo" commit -q -m init
check_git_sync_status "$DIR/repo" main 5
check "status" "NO_UPSTREAM" "$GIT_SYNC_STATUS"

echo "=== NO_UPSTREAM: branch exists locally but was never pushed ==="
DIR="$TMP/branch-not-pushed"; mkdir -p "$DIR"; setup_sandbox "$DIR"
git -C "$DIR/repo" checkout -q -b feature/never-pushed
check_git_sync_status "$DIR/repo" feature/never-pushed 5
check "status" "NO_UPSTREAM" "$GIT_SYNC_STATUS"

echo "=== fetch_failed: origin URL unreachable ==="
DIR="$TMP/bad-remote"; mkdir -p "$DIR/repo"
git -C "$DIR/repo" init -q -b main
git -C "$DIR/repo" config user.email test@test.local
git -C "$DIR/repo" config user.name test
echo x > "$DIR/repo/seed.md"
git -C "$DIR/repo" add seed.md
git -C "$DIR/repo" commit -q -m init
git -C "$DIR/repo" remote add origin "file:///nonexistent/$$/origin.git"
check_git_sync_status "$DIR/repo" main 5
check "status" "fetch_failed" "$GIT_SYNC_STATUS"

echo "=== NOT_A_REPO: plain directory, no .git ==="
DIR="$TMP/plain-dir"; mkdir -p "$DIR"
check_git_sync_status "$DIR" main 5
check "status" "NOT_A_REPO" "$GIT_SYNC_STATUS"

echo "=== NOT_A_REPO: fixture directory that resolves inside a real outer repo ==="
DIR="$TMP/fixture-outer"; mkdir -p "$DIR"; setup_sandbox "$DIR"
FIXTURE_SUBDIR="$DIR/repo/scripts/tests/fixtures/not-a-real-repo"
mkdir -p "$FIXTURE_SUBDIR"
check_git_sync_status "$FIXTURE_SUBDIR" main 5
check "status" "NOT_A_REPO" "$GIT_SYNC_STATUS"

echo "=== precomputed: valid value short-circuits without touching git ==="
DIR="$TMP/precomputed-valid"; mkdir -p "$DIR"; setup_sandbox "$DIR"
GIT_SYNC_PRECOMPUTED_STATUS="STALE" check_git_sync_status "$DIR/repo" main 5
check "status" "STALE" "$GIT_SYNC_STATUS"
check "detail method" "method=precomputed" "$GIT_SYNC_DETAIL"

echo "=== precomputed: invalid value fails closed, not a silent re-check ==="
DIR="$TMP/precomputed-invalid"; mkdir -p "$DIR"; setup_sandbox "$DIR"
GIT_SYNC_PRECOMPUTED_STATUS="not-a-real-status" check_git_sync_status "$DIR/repo" main 5
check "status" "checker_unavailable" "$GIT_SYNC_STATUS"

echo "=== timeout: hung remote query is bounded, not indefinite ==="
DIR="$TMP/timeout"; mkdir -p "$DIR/repo"
git -C "$DIR/repo" init -q -b main
git -C "$DIR/repo" config user.email test@test.local
git -C "$DIR/repo" config user.name test
echo x > "$DIR/repo/seed.md"
git -C "$DIR/repo" add seed.md
git -C "$DIR/repo" commit -q -m init
# a TCP address that silently drops packets (no RST/ICMP) hangs ls-remote
# until the deadline fires, unlike a refused connection (instant fetch_failed
# above) -- this exercises the actual watchdog, not just the error path.
git -C "$DIR/repo" remote add origin "http://10.255.255.1/origin.git"
START=$(date +%s)
check_git_sync_status "$DIR/repo" main 2
END=$(date +%s)
check "status" "fetch_failed" "$GIT_SYNC_STATUS"
ELAPSED=$((END - START))
check "bounded by timeout (<=5s for a 2s deadline)" "1" "$([ "$ELAPSED" -le 5 ] && echo 1 || echo 0)"

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: все проверки git-sync-status.sh прошли"
  exit 0
else
  echo "FAIL: $FAILURES проверок не прошли"
  exit 1
fi
