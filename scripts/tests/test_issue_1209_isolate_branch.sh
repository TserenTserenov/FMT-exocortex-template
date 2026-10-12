#!/usr/bin/env bash
# issue #1209: session-guard.sh `open --isolate` used to fetch/worktree-add against
# the literal "origin/main", so an install whose governance repo defaults to e.g.
# "master" could never open an isolated copy (same class as #1097/#1195, fixed in
# strategist.sh via resolve_default_branch()). This checks the same resolution,
# extracted from the real script, against a throwaway bare origin on "master".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SG="$ROOT/scripts/session-guard.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/iwe-session-guard-1209.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@test GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@test
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

fail() { echo "FAIL: $*" >&2; exit 1; }

grep -q 'ISOLATE_DEFAULT_BRANCH="\$(git -C "\$ISOLATE_BASE_DIR" symbolic-ref refs/remotes/origin/HEAD' "$SG" \
  || fail "session-guard.sh no longer resolves the default branch before --isolate fetch/worktree add"
grep -q 'fetch origin "\$ISOLATE_DEFAULT_BRANCH"' "$SG" \
  || fail "--isolate fetch still hardcodes origin main"
grep -q '"\$ISOLATED_WORKTREE_PATH" "origin/\$ISOLATE_DEFAULT_BRANCH"' "$SG" \
  || fail "--isolate worktree add still hardcodes origin/main"

# Resolution itself, against a real repo whose default branch is "master".
ORIGIN="$TEST_ROOT/origin.git"
git init -q --bare --initial-branch=master "$ORIGIN"
WORK="$TEST_ROOT/seed"
git clone -q "$ORIGIN" "$WORK"
git -C "$WORK" commit -q --allow-empty -m "seed"
git -C "$WORK" push -q origin master

CLONE="$TEST_ROOT/clone"
git clone -q "$ORIGIN" "$CLONE"
resolved="$(git -C "$CLONE" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/origin/##' || true)"
[ "$resolved" = "master" ] || fail "resolution against a real master-default clone gave '$resolved', expected 'master'"

# Fallback: a repo with no remote HEAD symref set (e.g. partial/manual setup) defaults to "main".
NOSYMREF="$TEST_ROOT/nosymref"
git init -q "$NOSYMREF"
fallback="$(git -C "$NOSYMREF" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/origin/##' || true)"
fallback="${fallback:-main}"
[ "$fallback" = "main" ] || fail "fallback without a remote HEAD symref gave '$fallback', expected 'main'"

echo "PASS: session-guard.sh --isolate resolves the default branch (#1209)"
