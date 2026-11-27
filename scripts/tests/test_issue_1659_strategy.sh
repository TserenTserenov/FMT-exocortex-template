#!/usr/bin/env bash
# test_issue_1659_strategy_session_isolate.sh — issue #1659: the weekly/monthly
# strategy session saves without a WP number.
#
# Checks, in a throwaway sandbox with a bare origin:
#  1. `open --housekeeping strategy-session --isolate` from the governance repo
#     creates an isolated copy inside .iwe-runtime/isolated-worktrees and a
#     semaphore with housekeeping + isolated_worktree + harness_session_id;
#  2. session-open-gate.sh lets a commit through under that semaphore;
#  3. the same conversation re-enters the same copy; another conversation is
#     refused and the copy survives;
#  4. --isolate is refused for other housekeeping reasons and outside the
#     governance repository;
#  5. `close --housekeeping strategy-session` publishes the copy's commit to
#     origin, removes the copy and leaves a .closed receipt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SG="$ROOT/scripts/session-guard.sh"
PUSH="$ROOT/scripts/isolate-push.sh"
GATE="$ROOT/.claude/hooks/session-open-gate.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

SANDBOX=$(mktemp -d)
trap 'cd /; rm -rf "$SANDBOX"' EXIT

ORIGIN_DIR="$SANDBOX/origin.git"
git init -q --bare --initial-branch=main "$ORIGIN_DIR"
REPO_DIR="$SANDBOX/DS-strategy"
git init -q --initial-branch=main "$REPO_DIR"
git -C "$REPO_DIR" config user.email test@example.com
git -C "$REPO_DIR" config user.name test
mkdir -p "$REPO_DIR/current"
echo "plan" > "$REPO_DIR/current/WeekPlan W48.md"
git -C "$REPO_DIR" add current
git -C "$REPO_DIR" commit -q -m seed
git -C "$REPO_DIR" remote add origin "$ORIGIN_DIR"
git -C "$REPO_DIR" push -q -u origin main 2>/dev/null
git -C "$REPO_DIR" remote set-head origin main >/dev/null

OTHER_REPO="$SANDBOX/other-repo"
git init -q --initial-branch=main "$OTHER_REPO"
git -C "$OTHER_REPO" -c user.email=t@e -c user.name=t commit -q --allow-empty -m seed

IWE_ROOT="$SANDBOX/iwe-root"
mkdir -p "$IWE_ROOT/scripts" "$IWE_ROOT/.iwe-runtime/sessions"
ln -s "$REPO_DIR" "$IWE_ROOT/DS-strategy"
cp "$PUSH" "$IWE_ROOT/scripts/isolate-push.sh"
chmod +x "$IWE_ROOT/scripts/isolate-push.sh"
export IWE_ROOT IWE_GOVERNANCE_REPO=DS-strategy IWE_FROZEN_CANONICAL_PATH="" IWE_AGENT=claude-code
export CLAUDE_CODE_SESSION_ID="test-1659-$$"
SEM="$IWE_ROOT/.iwe-runtime/sessions/claude-code-housekeeping-strategy-session.open"
STORE_REAL=$(mkdir -p "$IWE_ROOT/.iwe-runtime/isolated-worktrees" && realpath "$IWE_ROOT/.iwe-runtime/isolated-worktrees")

json_field() { python3 -c 'import json,sys; print(json.loads(sys.stdin.read())[sys.argv[1]])' "$1"; }

# --- 1. open with an isolated copy, no WP ---
OUT=$(cd "$REPO_DIR" && bash "$SG" open --housekeeping strategy-session --isolate --agent claude-code 2>"$SANDBOX/open.err") \
  || { cat "$SANDBOX/open.err" >&2; fail "open --housekeeping strategy-session --isolate failed"; }
WT=$(grep worktree_path <<<"$OUT" | tail -1 | json_field worktree_path)
[ -d "$WT" ] || fail "isolated copy missing: $WT"
case "$(realpath "$WT")" in "$STORE_REAL"/*) ;; *) fail "copy outside the store: $WT" ;; esac
[ "$(git -C "$WT" rev-parse HEAD)" = "$(git -C "$ORIGIN_DIR" rev-parse main)" ] || fail "copy not based on origin/main"
grep -qx "housekeeping: strategy-session" "$SEM" || fail "semaphore lacks housekeeping reason"
grep -qx "isolated_worktree: $WT" "$SEM" || fail "semaphore lacks isolated_worktree"
grep -qx "harness_session_id: $CLAUDE_CODE_SESSION_ID" "$SEM" || fail "semaphore lacks harness_session_id"
grep -q '^wp: ' "$SEM" && fail "housekeeping semaphore must not carry a wp"
pass "open --housekeeping strategy-session --isolate creates the copy"

# --- 2. the commit gate accepts the binding ---
gate_rc() {
  printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m week"},"session_id":"%s"}' "$WT" "$1" \
    | bash "$GATE" >/dev/null 2>&1 && echo 0 || echo $?
}
[ "$(gate_rc "$CLAUDE_CODE_SESSION_ID")" = 0 ] || fail "gate blocked a commit under strategy-session"
[ "$(gate_rc "another-conversation")" = 2 ] || fail "gate let a foreign conversation commit"
pass "session-open-gate accepts the strategy-session binding of this conversation only"

# --- 3. re-entry and a foreign conversation ---
OUT2=$(cd "$REPO_DIR" && bash "$SG" open --housekeeping strategy-session --isolate --agent claude-code 2>/dev/null) \
  || fail "re-entry of the same conversation failed"
grep -q 're-entry' <<<"$OUT2" || fail "re-entry not reported"
[ "$(grep worktree_path <<<"$OUT2" | tail -1 | json_field worktree_path)" = "$WT" ] || fail "re-entry returned another copy"
if (cd "$REPO_DIR" && CLAUDE_CODE_SESSION_ID="another-conversation" bash "$SG" open --housekeeping strategy-session --isolate --agent claude-code >/dev/null 2>"$SANDBOX/foreign.err"); then
  fail "a foreign conversation took over the copy"
fi
grep -q 'close --housekeeping strategy-session' "$SANDBOX/foreign.err" || fail "foreign open does not point at close"
[ -d "$WT" ] && grep -qx "isolated_worktree: $WT" "$SEM" || fail "foreign open damaged the open session"
pass "same conversation re-enters, another one is refused and the copy survives"

# --- 4. --isolate only for strategy-session and only from the governance repo ---
if (cd "$REPO_DIR" && bash "$SG" open --housekeeping day-close --isolate --agent claude-code >/dev/null 2>"$SANDBOX/dc.err"); then
  fail "--isolate accepted for day-close"
fi
grep -q 'strategy-session' "$SANDBOX/dc.err" || fail "day-close refusal does not explain the limit"
[ ! -e "$IWE_ROOT/.iwe-runtime/sessions/claude-code-housekeeping-day-close.open" ] || fail "refused open left a semaphore"
pass "--isolate refused for another housekeeping reason"

# --- 5. close publishes the copy ---
echo "decisions" >> "$WT/current/WeekPlan W48.md"
git -C "$WT" -c user.email=test@example.com -c user.name=test commit -q -am "week plan"
WORK_SHA=$(git -C "$WT" rev-parse HEAD)
(cd "$REPO_DIR" && bash "$SG" close --housekeeping strategy-session --agent claude-code --only-own-harness >/dev/null 2>"$SANDBOX/close.err") \
  || { cat "$SANDBOX/close.err" >&2; fail "close --housekeeping strategy-session failed"; }
git -C "$ORIGIN_DIR" log --format=%s main | grep -qx "week plan" || fail "commit $WORK_SHA not published to origin"
[ ! -d "$WT" ] || fail "copy not removed after publishing"
[ ! -e "$SEM" ] && [ -f "$SEM.closed" ] || fail "semaphore not closed"
pass "close publishes the commit, removes the copy and closes the session"

# --- 4b. outside the governance repository (after close, the slot is free) ---
if (cd "$OTHER_REPO" && bash "$SG" open --housekeeping strategy-session --isolate --agent claude-code >/dev/null 2>"$SANDBOX/other.err"); then
  fail "--isolate accepted outside the governance repo"
fi
grep -q 'репозитория управления' "$SANDBOX/other.err" || fail "outside-repo refusal unclear"
[ ! -e "$SEM" ] || fail "refused open outside the governance repo left a semaphore"
pass "--isolate refused outside the governance repository"

echo "ALL PASS: issue #1659"
