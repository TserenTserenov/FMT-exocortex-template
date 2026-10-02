#!/usr/bin/env bash
# issue #840: git-diff-feed (extractor.sh) wrote to inbox/captures.md
# without taking any lock, racing note-review (strategist.sh) on the same
# file. Verifies both sides of the fix: extractor.sh's git-diff-feed skips
# when the shared lock is held by a live process, and strategist.sh's new
# acquire_captures_write_lock() reclaims a stale lock left by a dead PID.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAIL=0
assert() {  # <condition-description> <actual> <expected>
    if [ "$2" != "$3" ]; then
        echo "FAIL: $1 (got: $2, expected: $3)"
        FAIL=1
    else
        echo "PASS: $1"
    fi
}

# --- Test 1: extractor.sh git-diff-feed skips when the shared lock is held
# by a live process (exit 0, never reaches run_claude / "Running git-diff FEED").
# extractor.sh refuses to run from the raw FMT-exocortex-template checkout
# (guards against unsubstituted {{...}} placeholders) -- copy it into a
# runtime-shaped temp path, same as a real build-runtime.sh output would be.
RUNTIME_COPY="$TMP_DIR/.iwe-runtime/roles/extractor/scripts"
mkdir -p "$RUNTIME_COPY"
cp "$ROOT_DIR/roles/extractor/scripts/extractor.sh" "$RUNTIME_COPY/"

LOCK_DIR="$TMP_DIR/feed.lock"
mkdir "$LOCK_DIR"
sleep 60 & HOLDER_PID=$!
printf '%s\n' "$HOLDER_PID" > "$LOCK_DIR/pid"

export IWE_EXTRACTOR_FEED_LOCK_DIR="$LOCK_DIR"
export HOME="$TMP_DIR/home"
mkdir -p "$HOME"
# check_auth() short-circuits (ai_cli_is_claude() false) once AI_CLI differs
# from CLAUDE_PATH -- the seam the script itself documents for non-Claude
# CLIs (see strategist.sh). Avoids needing a real Claude Code login here;
# the stub is never actually invoked because the lock-held path exits first
# (extractor.sh separately requires AI_CLI to exist on disk, hence the file).
mkdir -p "$TMP_DIR/bin"
printf '#!/bin/sh\nexit 1\n' > "$TMP_DIR/bin/fake-ai-cli"
chmod +x "$TMP_DIR/bin/fake-ai-cli"
export AI_CLI="$TMP_DIR/bin/fake-ai-cli"
LOG_OUT="$TMP_DIR/git-diff-feed.out"
set +e
bash "$RUNTIME_COPY/extractor.sh" git-diff-feed "1 hour ago" > "$LOG_OUT" 2>&1
EXIT_CODE=$?
set -e
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true

assert "git-diff-feed exits 0 when lock is held" "$EXIT_CODE" "0"
if grep -q "Running git-diff FEED" "$LOG_OUT"; then
    echo "FAIL: git-diff-feed ran despite held lock (log: $LOG_OUT)"
    FAIL=1
else
    echo "PASS: git-diff-feed did not run while lock was held"
fi

# --- Test 1b: with no holder, git-diff-feed actually acquires the lock
# (mkdir "$LOCK_DIR" itself, distinct from Test 1's pre-created lock dir) and
# releases it via the EXIT trap, even though run_claude fails downstream
# (fake-ai-cli exits 1) -- proves the lock is taken around the write, not
# just that a pre-existing lock blocks a second runner.
FREE_LOCK_DIR="$TMP_DIR/feed-free.lock"
export IWE_EXTRACTOR_FEED_LOCK_DIR="$FREE_LOCK_DIR"
set +e
bash "$RUNTIME_COPY/extractor.sh" git-diff-feed "1 hour ago" > "$TMP_DIR/git-diff-feed-free.out" 2>&1
set -e
if [ -d "$FREE_LOCK_DIR" ]; then
    echo "FAIL: lock dir $FREE_LOCK_DIR left behind after run_claude failure (trap did not release it)"
    FAIL=1
else
    echo "PASS: lock acquired and released around the (failing) run_claude call"
fi
if grep -q "Running git-diff FEED" "$TMP_DIR/git-diff-feed-free.out"; then
    echo "PASS: git-diff-feed reached run_claude once the lock was free"
else
    echo "FAIL: git-diff-feed never reached run_claude with no lock held (log: $TMP_DIR/git-diff-feed-free.out)"
    FAIL=1
fi

# --- Test 2: strategist.sh's acquire_captures_write_lock reclaims a lock
# left behind by a dead PID (extractor.sh's own reclaim semantics, reused).
STRATEGIST="$ROOT_DIR/roles/strategist/scripts/strategist.sh"
FUNC_SRC=$(sed -n '/^acquire_captures_write_lock()/,/^}/p' "$STRATEGIST")
if [ -z "$FUNC_SRC" ]; then
    echo "FAIL: acquire_captures_write_lock() not found in strategist.sh"
    FAIL=1
else
    STALE_LOCK_DIR="$TMP_DIR/stale.lock"
    mkdir "$STALE_LOCK_DIR"
    # PID 9999999 must not resolve to a live process on any test host.
    printf '9999999\n' > "$STALE_LOCK_DIR/pid"
    RECLAIM_OUT=$(env -i PATH="$PATH" TMPDIR="$TMP_DIR" IWE_EXTRACTOR_FEED_LOCK_DIR="$STALE_LOCK_DIR" bash -c "
        log() { :; }
        add_exit_cleanup() { :; }
        $FUNC_SRC
        acquire_captures_write_lock
        echo \"RESULT=\$?\"
        test -f '$STALE_LOCK_DIR/pid' && cat '$STALE_LOCK_DIR/pid'
    ")
    ACQUIRED_PID=$(printf '%s\n' "$RECLAIM_OUT" | tail -1)
    assert "acquire_captures_write_lock reclaims stale lock (result)" \
        "$(printf '%s\n' "$RECLAIM_OUT" | grep -o 'RESULT=[0-9]*')" "RESULT=0"
    if [ "$ACQUIRED_PID" = "9999999" ]; then
        echo "FAIL: stale pid 9999999 was not replaced after reclaim"
        FAIL=1
    else
        echo "PASS: reclaimed lock now recorded a different (live) pid"
    fi
fi

# --- Test 2b: acquire_captures_write_lock must NOT reclaim a lock dir with
# a missing/empty pid file -- that state means another writer's mkdir landed
# but its pid write has not yet happened (a real gap in acquire_inbox_lock's
# own mkdir-then-printf sequence, extractor.sh:583-585), not a stale lock.
# Cold-context review of this same fix caught an earlier version that
# reclaimed on empty pid too, which re-opened the exact TOCTOU race #840
# reports. Bounded to 2s here (not the real 30s) so the test stays fast.
if [ -n "$FUNC_SRC" ]; then
    EMPTY_PID_LOCK_DIR="$TMP_DIR/empty-pid.lock"
    mkdir "$EMPTY_PID_LOCK_DIR"
    : > "$EMPTY_PID_LOCK_DIR/pid"  # present but empty, as in the acquisition gap
    FAST_FUNC_SRC=$(printf '%s\n' "$FUNC_SRC" | sed 's/-ge 30/-ge 1/')
    NOWAIT_OUT=$(env -i PATH="$PATH" TMPDIR="$TMP_DIR" IWE_EXTRACTOR_FEED_LOCK_DIR="$EMPTY_PID_LOCK_DIR" bash -c "
        log() { :; }
        add_exit_cleanup() { :; }
        $FAST_FUNC_SRC
        acquire_captures_write_lock
        echo \"RESULT=\$?\"
    ")
    assert "acquire_captures_write_lock does not reclaim an empty-pid lock" \
        "$(printf '%s\n' "$NOWAIT_OUT" | grep -o 'RESULT=[0-9]*')" "RESULT=1"
    if [ -d "$EMPTY_PID_LOCK_DIR" ]; then
        echo "PASS: empty-pid lock dir left untouched (not deleted from under its real owner)"
    else
        echo "FAIL: empty-pid lock dir was removed -- reclaim-on-empty-pid regressed"
        FAIL=1
    fi
fi

if [ "$FAIL" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "SOME FAILED"
    exit 1
fi
