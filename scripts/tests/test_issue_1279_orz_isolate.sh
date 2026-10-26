#!/usr/bin/env bash
# test_issue_1279_orz_isolate.sh — on an install without MC-sessions the ORZ
# scaffold falls back to $GOV_REPO/sessions. Under --isolate it used to be
# written into the frozen canonical checkout anyway (resolved and created
# before the worktree existed). Now: no write into the canon, the scaffold
# lands in the isolated worktree, close finds it there, and a failed isolate
# leaves the canon untouched (issue #1279).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SG="$ROOT/scripts/session-guard.sh"

FAIL=0
pass() { echo "  ✅ PASS: $*"; }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL + 1)); }

SANDBOX=$(mktemp -d)
trap 'cd /; rm -rf "$SANDBOX"' EXIT

ORIGIN_DIR="$SANDBOX/origin.git"
git init -q --bare --initial-branch=main "$ORIGIN_DIR"
REPO_DIR="$SANDBOX/DS-strategy"
git init -q --initial-branch=main "$REPO_DIR"
git -C "$REPO_DIR" config user.email test@example.com
git -C "$REPO_DIR" config user.name test
mkdir -p "$REPO_DIR/inbox/WP-485"
echo "card" > "$REPO_DIR/inbox/WP-485/WP-485.md"
git -C "$REPO_DIR" add .
git -C "$REPO_DIR" commit -qm "seed"
git -C "$REPO_DIR" remote add origin "$ORIGIN_DIR"
git -C "$REPO_DIR" push -qu origin main 2>/dev/null

IWE_ROOT="$SANDBOX/iwe-root"
mkdir -p "$IWE_ROOT/scripts" "$IWE_ROOT/.iwe-runtime/sessions"
ln -s "$REPO_DIR" "$IWE_ROOT/DS-strategy"
export IWE_ROOT IWE_GOVERNANCE_REPO=DS-strategy IWE_FROZEN_CANONICAL_PATH=""
unset IWE_SESSIONS_ROOT
AGENT=claude-code
export IWE_AGENT="$AGENT"

# 1. A failed isolate (bad --base-sha) must not create anything in the canon.
SID_BAD="t1279bad-$$"
(cd "$REPO_DIR" && IWE_SESSION_ID="$SID_BAD" bash "$SG" open --wp WP-485 --agent "$AGENT" \
    --task "bad isolate" --slug "$SID_BAD" --isolate --base-sha deadbeefdeadbeefdeadbeefdeadbeefdeadbeef) >/dev/null 2>&1
if [ ! -e "$REPO_DIR/sessions" ]; then
    pass "failed --isolate writes nothing into the canonical sessions/"
else
    fail "failed --isolate created $REPO_DIR/sessions"
fi

# 2. Successful isolate: scaffold in the worktree, canon untouched.
SID="t1279orz-$$"
OUT=$(cd "$REPO_DIR" && IWE_SESSION_ID="$SID" bash "$SG" open --wp WP-485 --agent "$AGENT" \
    --task "orz isolate redirect" --slug "$SID" --isolate 2>&1)
WT_PATH=$(printf '%s\n' "$OUT" | grep -o '{.*}' | tail -1 | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["worktree_path"])' 2>/dev/null)
if [ -z "$WT_PATH" ]; then
    fail "open --isolate did not return a worktree: $(printf '%s\n' "$OUT" | tail -3 | tr '\n' ' ')"
else
    if [ ! -e "$REPO_DIR/sessions" ]; then
        pass "canonical checkout has no sessions/ after open --isolate"
    else
        fail "ORZ scaffold written into the frozen canon: $(find "$REPO_DIR/sessions" -type f | head -2 | tr '\n' ' ')"
    fi
    ORZ=$(find "$WT_PATH/sessions" -name "*-$SID.md" -type f 2>/dev/null | head -1)
    if [ -n "$ORZ" ]; then
        pass "ORZ scaffold is in the isolated worktree"
    else
        fail "ORZ scaffold missing from the isolated worktree"
    fi
    SEM="$IWE_ROOT/.iwe-runtime/sessions/${AGENT}-${SID}.open"
    if grep -qx "orz_sessions_dir: $WT_PATH/sessions" "$SEM" 2>/dev/null; then
        pass "semaphore records the worktree sessions dir"
    else
        fail "semaphore orz_sessions_dir is $(grep '^orz_sessions_dir:' "$SEM" 2>/dev/null)"
    fi
    # 3. close reads the dir back from the semaphore and succeeds.
    if [ -n "$ORZ" ]; then
        printf '\n## Итог\n\nСделано.\n' >> "$ORZ"
        git -C "$WT_PATH" add -- "${ORZ#"$WT_PATH"/}"
    fi
    CLOSE_RC=0
    CLOSE_OUT=$(cd "$WT_PATH" && IWE_SESSION_ID="$SID" bash "$SG" close --agent "$AGENT" --slug "$SID" 2>&1) || CLOSE_RC=$?
    if printf '%s\n' "$CLOSE_OUT" | grep -qF "проверяю ORZ $WT_PATH/sessions/"; then
        pass "close validates the ORZ file in the isolated worktree"
    else
        fail "close looked elsewhere: $(printf '%s\n' "$CLOSE_OUT" | grep 'проверяю ORZ' | head -1)"
    fi
    if [ "$CLOSE_RC" -eq 0 ] && [ -f "$SEM.closed" ]; then
        pass "close succeeds and leaves the .closed receipt"
    else
        fail "close rc=$CLOSE_RC, receipt present=$([ -f "$SEM.closed" ] && echo y || echo n): $(printf '%s\n' "$CLOSE_OUT" | tail -2 | tr '\n' ' ')"
    fi
    [ ! -e "$REPO_DIR/sessions" ] || fail "close created $REPO_DIR/sessions"
fi

# 4. Isolate from a manual linked worktree of the governance repo: same repo,
# so the scaffold still must not land in the canon.
git -C "$REPO_DIR" worktree add -q -b manual "$SANDBOX/manual-wt" origin/main 2>/dev/null
SID3="t1279wt-$$"
OUT3=$(cd "$SANDBOX/manual-wt" && IWE_SESSION_ID="$SID3" bash "$SG" open --wp WP-485 --agent "$AGENT" \
    --task "isolate from linked worktree" --slug "$SID3" --isolate 2>&1)
WT3=$(printf '%s\n' "$OUT3" | grep -o '{.*}' | tail -1 | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["worktree_path"])' 2>/dev/null)
if [ -n "$WT3" ] && [ ! -e "$REPO_DIR/sessions" ] && [ -n "$(find "$WT3/sessions" -name "*-$SID3.md" 2>/dev/null)" ]; then
    pass "isolate from a linked governance worktree keeps the scaffold out of the canon"
else
    fail "isolate from a linked worktree: wt='$WT3', canon sessions present=$([ -e "$REPO_DIR/sessions" ] && echo y || echo n)"
fi

[ "$FAIL" -eq 0 ] && echo "PASS: issue #1279 ORZ scaffold under --isolate" || { echo "FAIL: issue #1279 ORZ has $FAIL violation(s)"; exit 1; }
