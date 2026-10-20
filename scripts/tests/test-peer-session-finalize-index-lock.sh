#!/usr/bin/env bash
# WP-529 ArchGate (вариант Б, 20.10.2026): peer-session-finalize.sh писало
# в 00-index.md через awk+mv без лока — два параллельных finalize/interrupt
# на один governance-репо могли молча затереть друг друга (подтверждено
# peer-сессией Kimi+Codex механически, через POSIX rename semantics, не
# предположением). Тестирует _acquire_index_lock()/_release_index_lock() в
# изоляции — тот же reclaim-по-живости-pid, что уже проверен для
# acquire_captures_write_lock() в test-captures-write-lock-840.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/peer-session-finalize.sh"
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

ACQUIRE_SRC=$(sed -n '/^_acquire_index_lock()/,/^}/p' "$SCRIPT")
RELEASE_SRC=$(sed -n '/^_release_index_lock()/,/^}/p' "$SCRIPT")
if [ -z "$ACQUIRE_SRC" ] || [ -z "$RELEASE_SRC" ]; then
    echo "FAIL: _acquire_index_lock()/_release_index_lock() not found in $SCRIPT"
    exit 1
fi

# --- Test 1: lock held by a LIVE process -> acquire times out (fast: 1s) ---
LOCK_DIR="$TMP_DIR/held.lock"
mkdir "$LOCK_DIR"
sleep 60 & HOLDER_PID=$!
printf '%s\n' "$HOLDER_PID" > "$LOCK_DIR/pid"

HELD_OUT=$(env -i PATH="$PATH" bash -c "
    INDEX_LOCK_DIR='$LOCK_DIR'
    INDEX_LOCK_TIMEOUT=1
    $ACQUIRE_SRC
    _acquire_index_lock
    echo \"RESULT=\$?\"
")
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true

assert "acquire fails fast when lock is held by a live process" \
    "$(printf '%s\n' "$HELD_OUT" | grep -o 'RESULT=[0-9]*')" "RESULT=1"
if [ -d "$LOCK_DIR" ]; then
    echo "PASS: held lock dir left untouched (not stolen from live holder)"
else
    echo "FAIL: held lock dir was removed while holder was still alive"
    FAIL=1
fi

# --- Test 2: no holder -> acquire succeeds, release removes the lock dir ---
FREE_LOCK_DIR="$TMP_DIR/free.lock"
FREE_OUT=$(env -i PATH="$PATH" bash -c "
    INDEX_LOCK_DIR='$FREE_LOCK_DIR'
    INDEX_LOCK_TIMEOUT=1
    $ACQUIRE_SRC
    $RELEASE_SRC
    _acquire_index_lock
    echo \"ACQUIRE_RESULT=\$?\"
    test -f '$FREE_LOCK_DIR/pid' && echo 'PID_FILE_PRESENT'
    _release_index_lock
    test -d '$FREE_LOCK_DIR' && echo 'LOCK_DIR_STILL_PRESENT' || echo 'LOCK_DIR_GONE'
")
assert "acquire succeeds when no holder" \
    "$(printf '%s\n' "$FREE_OUT" | grep -o 'ACQUIRE_RESULT=[0-9]*')" "ACQUIRE_RESULT=0"
assert "pid file written on acquire" \
    "$(printf '%s\n' "$FREE_OUT" | grep -c 'PID_FILE_PRESENT')" "1"
assert "release removes the lock dir" \
    "$(printf '%s\n' "$FREE_OUT" | tail -1)" "LOCK_DIR_GONE"

# --- Test 3: lock left by a DEAD pid -> reclaimed, acquire succeeds ---
STALE_LOCK_DIR="$TMP_DIR/stale.lock"
mkdir "$STALE_LOCK_DIR"
printf '9999999\n' > "$STALE_LOCK_DIR/pid"  # must not resolve to a live process
STALE_OUT=$(env -i PATH="$PATH" bash -c "
    INDEX_LOCK_DIR='$STALE_LOCK_DIR'
    INDEX_LOCK_TIMEOUT=1
    $ACQUIRE_SRC
    _acquire_index_lock
    echo \"RESULT=\$?\"
    cat '$STALE_LOCK_DIR/pid'
")
assert "acquire reclaims a lock left by a dead pid" \
    "$(printf '%s\n' "$STALE_OUT" | grep -o 'RESULT=[0-9]*')" "RESULT=0"
RECLAIMED_PID=$(printf '%s\n' "$STALE_OUT" | tail -1)
if [ "$RECLAIMED_PID" = "9999999" ]; then
    echo "FAIL: stale pid 9999999 was not replaced after reclaim"
    FAIL=1
else
    echo "PASS: reclaimed lock now records a different (live) pid"
fi

# --- Test 4: lock dir present but pid file missing/empty -> NOT reclaimed
# (TOCTOU gap between another writer's mkdir and its own pid write) ---
EMPTY_PID_LOCK_DIR="$TMP_DIR/empty-pid.lock"
mkdir "$EMPTY_PID_LOCK_DIR"
: > "$EMPTY_PID_LOCK_DIR/pid"
EMPTY_OUT=$(env -i PATH="$PATH" bash -c "
    INDEX_LOCK_DIR='$EMPTY_PID_LOCK_DIR'
    INDEX_LOCK_TIMEOUT=1
    $ACQUIRE_SRC
    _acquire_index_lock
    echo \"RESULT=\$?\"
")
assert "acquire does not reclaim an empty-pid lock" \
    "$(printf '%s\n' "$EMPTY_OUT" | grep -o 'RESULT=[0-9]*')" "RESULT=1"
if [ -d "$EMPTY_PID_LOCK_DIR" ]; then
    echo "PASS: empty-pid lock dir left untouched (not deleted from under its real owner)"
else
    echo "FAIL: empty-pid lock dir was removed -- reclaim-on-empty-pid regressed"
    FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "SOME FAILED"
    exit 1
fi
