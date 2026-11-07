#!/bin/bash
# test_issue_1470_isolate_range_delivered.sh -- regression guard for #1470.
# A session published its isolate commits through ds-publish (cherry-pick with new
# SHAs, conflicts resolved), then close ran isolate-push on the same commits. A chain
# of commits editing the same files differs from origin per commit, so the replay
# stopped on a conflict although everything was already delivered.
# Checks: (1) a chain already on origin as one squashed commit -> nothing pushed,
# exit 0; (2) a chain NOT on origin -> pushed as before (no false "delivered");
# (3) a chain only partly on origin -> not reported as delivered; (4) the chain
# published commit by commit (patch-equivalent) -> nothing pushed; (5) a range
# that already stopped on a conflict and was delivered later -> exit 0 instead of
# resuming the saved conflict.
# scripts/tests/run-issue-tests.sh picks up test_issue_*.sh by existence.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUSH="${ISOLATE_PUSH_UNDER_TEST:-$SCRIPT_DIR/../isolate-push.sh}"
[ -f "$PUSH" ] || { echo "FAIL: $PUSH not found"; exit 1; }
FAILURES=0
check() { if [ "$2" = ok ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAILURES=$((FAILURES+1)); fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# IWE_ROOT too: the attempt registry lives under ${IWE_ROOT:-$HOME/IWE}, and a
# configured machine exports IWE_ROOT, which would send passports to the real one.
export HOME="$TMP/home" IWE_WORKSPACE="$TMP/ws" IWE_ROOT="$TMP/ws" IWE_GOVERNANCE_REPO=GOV
mkdir -p "$HOME" "$IWE_WORKSPACE"

# setup <name> -- origin with reg.md/card.md, a session worktree with a 3-commit chain
setup() {
  local d="$TMP/$1"
  git init -q -b main "$d/seed"
  printf 'v0\n' > "$d/seed/reg.md"; printf 'c0\n' > "$d/seed/card.md"
  git -C "$d/seed" add reg.md card.md && git -C "$d/seed" commit -q -m init
  git clone -q --bare "$d/seed" "$d/origin.git"
  git clone -q "$d/origin.git" "$d/canon"
  git -C "$d/canon" worktree add -q -b session-isolate/t "$d/wt" origin/main
  printf 'v1\n' > "$d/wt/reg.md"; printf 'c1\n' > "$d/wt/card.md"; git -C "$d/wt" commit -q -am one
  printf 'v2\n' > "$d/wt/reg.md"; git -C "$d/wt" commit -q -am two
  printf 'v3\n' > "$d/wt/reg.md"; printf 'c3\n' > "$d/wt/card.md"; git -C "$d/wt" commit -q -am three
  # someone else publishes an unrelated file meanwhile
  git clone -q "$d/origin.git" "$d/pub"
  printf 'x\n' > "$d/pub/other.md"; git -C "$d/pub" add other.md
  git -C "$d/pub" commit -q -m other && git -C "$d/pub" push -q origin main
}
origin_head() { git -C "$TMP/$1/origin.git" rev-parse main; }
origin_file() { git -C "$TMP/$1/origin.git" show "main:$2" 2>/dev/null; }

# (1) the chain is already on origin, squashed by the publisher
setup delivered
printf 'v3\n' > "$TMP/delivered/pub/reg.md"; printf 'c3\n' > "$TMP/delivered/pub/card.md"
git -C "$TMP/delivered/pub" commit -q -am "published chain" && git -C "$TMP/delivered/pub" push -q origin main
before=$(origin_head delivered)
out=$(bash "$PUSH" "$TMP/delivered/wt" main 2>&1); rc=$?
[ "$rc" -eq 0 ] && check "delivered chain: exit 0" ok || { check "delivered chain: exit 0 (rc=$rc)" bad; echo "$out"; }
echo "$out" | grep -q 'перенос не нужен' && check "delivered chain: reported as already on origin" ok || check "delivered chain: reported as already on origin" bad
[ "$(origin_head delivered)" = "$before" ] && check "delivered chain: origin untouched" ok || check "delivered chain: origin untouched" bad
# isolate-push keeps its temp worktrees next to the source worktree
[ -z "$(ls -A "$TMP/delivered/.isolate-push-tmp" 2>/dev/null)" ] \
  && check "delivered chain: no temp worktree left" ok || check "delivered chain: no temp worktree left" bad

# (2) nothing published: the chain must be pushed as before
setup fresh
out=$(bash "$PUSH" "$TMP/fresh/wt" main 2>&1); rc=$?
[ "$rc" -eq 0 ] && check "fresh chain: exit 0" ok || { check "fresh chain: exit 0 (rc=$rc)" bad; echo "$out"; }
echo "$out" | grep -q 'перенос не нужен' && check "fresh chain: not reported as delivered" bad || check "fresh chain: not reported as delivered" ok
[ "$(origin_file fresh reg.md)" = v3 ] && [ "$(origin_file fresh card.md)" = c3 ] && [ "$(origin_file fresh other.md)" = x ] \
  && check "fresh chain: pushed on top of origin" ok || check "fresh chain: pushed on top of origin" bad

# (3) only card.md is on origin: reg.md still differs -> not delivered
setup partial
printf 'c3\n' > "$TMP/partial/pub/card.md"
git -C "$TMP/partial/pub" commit -q -am "card only" && git -C "$TMP/partial/pub" push -q origin main
out=$(bash "$PUSH" "$TMP/partial/wt" main 2>&1); rc=$?
echo "$out" | grep -q 'перенос не нужен' && check "partial chain: not reported as delivered" bad || check "partial chain: not reported as delivered" ok

# (4) the publisher replayed each commit as is (ds-publish without conflicts)
setup percommit
git -C "$TMP/percommit/pub" fetch -q "$TMP/percommit/canon" session-isolate/t
git -C "$TMP/percommit/pub" cherry-pick main..FETCH_HEAD >/dev/null
[ "$(git -C "$TMP/percommit/pub" rev-list --count origin/main..main)" -eq 3 ] \
  && check "per-commit publish: fixture replayed 3 commits" ok || check "per-commit publish: fixture replayed 3 commits" bad
git -C "$TMP/percommit/pub" push -q origin main
before=$(origin_head percommit)
out=$(bash "$PUSH" "$TMP/percommit/wt" main 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q 'перенос не нужен' && [ "$(origin_head percommit)" = "$before" ] \
  && check "per-commit publish: nothing pushed, exit 0" ok || { check "per-commit publish: nothing pushed, exit 0 (rc=$rc)" bad; echo "$out"; }

# (5) first close stops on a real conflict, the content lands on origin later
setup stuck
printf 'zzz\n' > "$TMP/stuck/pub/reg.md"
git -C "$TMP/stuck/pub" commit -q -am "competing edit" && git -C "$TMP/stuck/pub" push -q origin main
bash "$PUSH" "$TMP/stuck/wt" main >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && check "stuck range: first run stops on the conflict" ok || check "stuck range: first run stops on the conflict (rc=$rc)" bad
printf 'v3\n' > "$TMP/stuck/pub/reg.md"; printf 'c3\n' > "$TMP/stuck/pub/card.md"
git -C "$TMP/stuck/pub" commit -q -am "published chain" && git -C "$TMP/stuck/pub" push -q origin main
out=$(bash "$PUSH" "$TMP/stuck/wt" main 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q 'перенос не нужен' \
  && check "stuck range: delivered later -> exit 0, saved conflict not resumed" ok || { check "stuck range: delivered later -> exit 0 (rc=$rc)" bad; echo "$out"; }

[ "$FAILURES" -eq 0 ] && { echo "OK: all checks passed"; exit 0; }
echo "FAILED: $FAILURES"; exit 1
