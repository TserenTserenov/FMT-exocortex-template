#!/usr/bin/env bash
# issue #1279: OPEN_LOG must redirect into the isolated worktree under
# --isolate, not append to the frozen canonical checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SG="$ROOT/scripts/session-guard.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

SANDBOX=$(mktemp -d)
trap 'cd /; rm -rf "$SANDBOX"' EXIT

ORIGIN_DIR="$SANDBOX/origin.git"
git init --bare --initial-branch=main "$ORIGIN_DIR" >/dev/null

REPO_DIR="$SANDBOX/DS-strategy"
git init --initial-branch=main "$REPO_DIR" >/dev/null
git -C "$REPO_DIR" config user.email test@example.com
git -C "$REPO_DIR" config user.name test
mkdir -p "$REPO_DIR/inbox/WP-485"
echo "card" > "$REPO_DIR/inbox/WP-485/WP-485.md"
git -C "$REPO_DIR" add .
git -C "$REPO_DIR" commit -m "seed" >/dev/null
git -C "$REPO_DIR" remote add origin "$ORIGIN_DIR"
git -C "$REPO_DIR" push -u origin main >/dev/null 2>&1

IWE_ROOT="$SANDBOX/iwe-root"
mkdir -p "$IWE_ROOT/scripts" "$IWE_ROOT/MC-sessions" "$IWE_ROOT/.iwe-runtime/sessions"
ln -s "$REPO_DIR" "$IWE_ROOT/DS-strategy"
git -C "$IWE_ROOT/MC-sessions" init >/dev/null
git -C "$IWE_ROOT/MC-sessions" config user.email test@example.com
git -C "$IWE_ROOT/MC-sessions" config user.name test
echo "# sessions" > "$IWE_ROOT/MC-sessions/README.md"
git -C "$IWE_ROOT/MC-sessions" add README.md
git -C "$IWE_ROOT/MC-sessions" commit -m "seed sessions" >/dev/null

export IWE_ROOT
export IWE_GOVERNANCE_REPO=DS-strategy
export IWE_FROZEN_CANONICAL_PATH=""
export IWE_SESSIONS_ROOT="$IWE_ROOT/MC-sessions"

AGENT=claude-code
SID="t1279-$(date +%s)-$$"
export IWE_SESSION_ID="$SID"
export IWE_AGENT="$AGENT"

cd "$REPO_DIR"
OUT=$(bash "$SG" open --wp WP-485 --agent "$AGENT" --task "test open-log isolate redirect" --slug "$SID" --isolate)
WT_PATH=$(printf '%s\n' "$OUT" | grep -o '{.*}' | tail -1 | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["worktree_path"])')
[ -n "$WT_PATH" ] || fail "could not parse worktree_path from open --isolate output"

if [ -f "$REPO_DIR/inbox/open-sessions.log" ]; then
  fail "canonical checkout got inbox/open-sessions.log written (expected: untouched)"
fi
pass "canonical checkout has no inbox/open-sessions.log"

[ -f "$WT_PATH/inbox/open-sessions.log" ] || fail "isolated worktree is missing inbox/open-sessions.log"
grep -q "WP-485" "$WT_PATH/inbox/open-sessions.log" || fail "isolated open-sessions.log missing expected WP-485 entry"
pass "isolated worktree has inbox/open-sessions.log with the session entry"

SEM_FILE=$(find "$IWE_ROOT/.iwe-runtime/sessions" -maxdepth 1 -name "${AGENT}-${SID}.open" | head -1)
[ -n "$SEM_FILE" ] || fail "semaphore file not found"
if grep -q "^file: inbox/open-sessions.log$" "$SEM_FILE"; then
  fail "semaphore still registers canonical inbox/open-sessions.log in allowlist (stale redirect)"
fi
pass "semaphore does not register a canonical open-sessions.log allowlist entry"

# Peer-review safety net (Codex, round 1): the semaphore itself must resolve
# under .iwe-runtime (gitignored, outside the governance repo's git tree),
# never under $GOV_REPO -- otherwise it could reintroduce the same
# untracked-file-blocks-merge symptom this issue is about, just one level up.
case "$SEM_FILE" in
  "$IWE_ROOT"/.iwe-runtime/*) ;;
  *) fail "semaphore file resolved outside .iwe-runtime: $SEM_FILE" ;;
esac
pass "semaphore resolves under .iwe-runtime, not under the governance repo"
