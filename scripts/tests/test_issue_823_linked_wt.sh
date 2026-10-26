#!/usr/bin/env bash
# test_issue_823_linked_wt.sh — open without --isolate from a manual
# `git worktree add` of the governance repo used to record the canonical path
# as governance_worktree, so close never warned about that worktree's
# unpushed commits (issue #823). Opened from a subdirectory of the linked
# worktree, with the canon reached through a symlink, the semaphore must name
# the worktree and close must warn about its unpushed commit.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SG="$ROOT/scripts/session-guard.sh"

FAIL=0
pass() { echo "  ✅ PASS: $*"; }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL + 1)); }

SANDBOX=$(mktemp -d)
trap 'cd /; rm -rf "$SANDBOX"' EXIT
git init -q --bare --initial-branch=main "$SANDBOX/origin.git"
REPO_DIR="$SANDBOX/DS-strategy"
git init -q --initial-branch=main "$REPO_DIR"
git -C "$REPO_DIR" config user.email test@example.com
git -C "$REPO_DIR" config user.name test
mkdir -p "$REPO_DIR/inbox/WP-485"
echo card > "$REPO_DIR/inbox/WP-485/WP-485.md"
git -C "$REPO_DIR" add . && git -C "$REPO_DIR" commit -qm seed
git -C "$REPO_DIR" remote add origin "$SANDBOX/origin.git"
git -C "$REPO_DIR" push -qu origin main 2>/dev/null
git -C "$REPO_DIR" fetch -q origin
git -C "$REPO_DIR" remote set-head origin main >/dev/null 2>&1
WT="$SANDBOX/manual-wt"
git -C "$REPO_DIR" worktree add -q -b feature "$WT" origin/main 2>/dev/null

IWE_ROOT="$SANDBOX/iwe-root"
mkdir -p "$IWE_ROOT/scripts" "$IWE_ROOT/.iwe-runtime/sessions"
ln -s "$REPO_DIR" "$IWE_ROOT/DS-strategy"
export IWE_ROOT IWE_GOVERNANCE_REPO=DS-strategy IWE_FROZEN_CANONICAL_PATH=""
unset IWE_SESSIONS_ROOT
AGENT=claude-code SID="t823-$$"
export IWE_AGENT="$AGENT" IWE_SESSION_ID="$SID"

(cd "$WT/inbox" && bash "$SG" open --wp WP-485 --agent "$AGENT" --task "linked worktree" --slug "$SID") >/dev/null 2>&1
SEM="$IWE_ROOT/.iwe-runtime/sessions/${AGENT}-${SID}.open"
WT_REAL=$(cd "$WT" && pwd -P)
if grep -qx "governance_worktree: $WT_REAL" "$SEM" 2>/dev/null; then
    pass "semaphore names the linked worktree the session was opened in"
else
    fail "governance_worktree is '$(grep '^governance_worktree:' "$SEM" 2>/dev/null)'"
fi

echo change > "$WT/inbox/WP-485/note.md"
git -C "$WT" add inbox/WP-485/note.md && git -C "$WT" commit -qm "unpushed work"
ORZ=$(find "$REPO_DIR/sessions" -name "*-$SID.md" -type f 2>/dev/null | head -1)
if [ -n "$ORZ" ]; then
    printf '\n## Итог\n\nСделано.\n' >> "$ORZ"
    git -C "$REPO_DIR" add -- "${ORZ#"$REPO_DIR"/}"
fi
CLOSE_ERR=$( (cd "$WT" && bash "$SG" close --agent "$AGENT" --slug "$SID") 2>&1 >/dev/null )
if printf '%s\n' "$CLOSE_ERR" | grep -q "незапушенных коммита в $(basename "$WT_REAL")"; then
    pass "close warns about the unpushed commit in the linked worktree"
    if [ "$(printf '%s\n' "$CLOSE_ERR" | grep -c 'незапушенных коммита')" -eq 1 ]; then
        pass "the unpushed warning is printed once, not per path of the same repo"
    else
        fail "duplicate unpushed warnings: $(printf '%s\n' "$CLOSE_ERR" | grep 'незапушенных' | tr '\n' ' ')"
    fi
else
    fail "close did not warn about the linked worktree: $(printf '%s\n' "$CLOSE_ERR" | tail -3 | tr '\n' ' ')"
fi

# Control: open from the canonical checkout keeps the canonical path.
SID2="t823c-$$"
(cd "$REPO_DIR" && IWE_SESSION_ID="$SID2" bash "$SG" open --wp WP-485 --agent "$AGENT" --task "canon" --slug "$SID2") >/dev/null 2>&1
if grep -qx "governance_worktree: $IWE_ROOT/DS-strategy" "$IWE_ROOT/.iwe-runtime/sessions/${AGENT}-${SID2}.open" 2>/dev/null; then
    pass "open from the canonical checkout still records the canonical path"
else
    fail "canonical open recorded '$(grep '^governance_worktree:' "$IWE_ROOT/.iwe-runtime/sessions/${AGENT}-${SID2}.open" 2>/dev/null)'"
fi

[ "$FAIL" -eq 0 ] && echo "PASS: issue #823 linked worktree" || { echo "FAIL: issue #823 has $FAIL violation(s)"; exit 1; }
