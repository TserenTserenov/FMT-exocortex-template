#!/usr/bin/env bash
# test_issue_657.sh — regression for the composing EXIT-trap in
# strategist.sh (issue #657): a second `trap ... EXIT` used to silently
# replace the first — the inhibitor-kill cleanup never ran once
# acquire_lock() registered its own trap, on every ordinary run, not only
# on kill -9/orphaning.
set -euo pipefail

case "${1:-}" in
    "") [ "$#" -eq 0 ] || { echo "usage: $0 [--barrier-only]" >&2; exit 2; }; barrier_only=0 ;;
    --barrier-only) [ "$#" -eq 1 ] || { echo "usage: $0 [--barrier-only]" >&2; exit 2; }; barrier_only=1 ;;
    *) echo "usage: $0 [--barrier-only]" >&2; exit 2 ;;
esac

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SCRIPT="$ROOT/roles/strategist/scripts/strategist.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0

# --- 1. Both markers must survive to script exit, in registration order,
# not just the last one registered (the exact bug: a lone `trap X EXIT`
# followed by `trap Y EXIT` only ever runs Y).
cat > "$TMP/run1.sh" <<EOF
#!/bin/bash
set -e
$(sed -n '/^_EXIT_CLEANUPS=()/,/^trap run_exit_cleanups EXIT$/p' "$SCRIPT")
MARKER="$TMP/markers1.txt"
add_exit_cleanup "echo first >> '\$MARKER'"
add_exit_cleanup "echo second >> '\$MARKER'"
EOF
bash "$TMP/run1.sh"
if [ ! -f "$TMP/markers1.txt" ]; then
    echo "❌ no cleanups ran at all"
    fail=1
elif [ "$(cat "$TMP/markers1.txt")" != $'first\nsecond' ]; then
    echo "❌ expected both cleanups to run in order, got:"
    cat "$TMP/markers1.txt"
    fail=1
fi

# --- 2. acquire_lock()'s own trap registration (extracted verbatim from the
# real function) must coexist with an inhibitor-style cleanup registered
# before it — this is the literal collision from the issue: inhibit trap
# registered first, acquire_lock() trap registered second.
cat > "$TMP/run2.sh" <<EOF
#!/bin/bash
set -e
$(sed -n '/^_EXIT_CLEANUPS=()/,/^trap run_exit_cleanups EXIT$/p' "$SCRIPT")
log() { :; }
LOG_DIR="$TMP"
DATE="20260904"
$(sed -n '/^LOCK_DIR=/,/^# issue #840/p' "$SCRIPT")

INHIBIT_MARKER="$TMP/inhibit-killed.txt"
add_exit_cleanup "echo killed >> '\$INHIBIT_MARKER'"
acquire_lock "test-scenario"
EOF
bash "$TMP/run2.sh"
if [ ! -f "$TMP/inhibit-killed.txt" ]; then
    echo "❌ inhibitor-kill cleanup did not run — acquire_lock()'s trap clobbered it (issue #657)"
    fail=1
fi
if [ ! -d "$TMP/locks" ] || find "$TMP/locks" -mindepth 1 -maxdepth 1 | grep -q .; then
    echo "❌ lock files were not cleaned up by acquire_lock()'s registered cleanup"
    fail=1
fi

# --- 3. Issue #1030: stop the first owner at the publication boundary.
# The old mkdir/pid protocol exposes an empty pid file here. Two contenders
# can remove that live lock and enter the critical section. A completed owner
# record published with an atomic link must let only A enter.
RACE="$TMP/race"
mkdir -p "$RACE"
sed -n '/^_EXIT_CLEANUPS=()/,/^trap run_exit_cleanups EXIT$/p' "$SCRIPT" > "$RACE/cleanups.sh"
sed -n '/^LOCK_DIR=/,/^# issue #840/p' "$SCRIPT" > "$RACE/lock.sh"
cat > "$RACE/worker.sh" <<'WORKER'
#!/usr/bin/env bash
set -e
LOG_DIR="$RACE"
DATE=20261003
source "$RACE/cleanups.sh"
log() { printf '%s\n' "$*" >> "$RACE/log_$WORKER"; }
echo() {
    if [ "$WORKER" = A ] && [ "$1" = "$$" ]; then
        : > "$RACE/published_A"
        while [ ! -f "$RACE/release_A" ]; do sleep 0.01; done
    fi
    builtin echo "$@"
}
ln() {
    local rc=0
    command ln "$@" || rc=$?
    if [ "$WORKER" = A ] && [ "$rc" -eq 0 ]; then
        : > "$RACE/published_A"
        while [ ! -f "$RACE/release_A" ]; do sleep 0.01; done
    fi
    return "$rc"
}
python3() {
    local rc=0
    command python3 "$@" || rc=$?
    if [ "$WORKER" = A ] && [ "$rc" -eq 0 ] && [ "${3:-}" = "$RACE/locks/race-scenario.lock" ]; then
        : > "$RACE/published_A"
        while [ ! -f "$RACE/release_A" ]; do sleep 0.01; done
    fi
    return "$rc"
}
source "$RACE/lock.sh"
trap 'rc=$?; run_exit_cleanups; printf "%s\n" "$rc" > "$RACE/rc_$WORKER"' EXIT
acquire_lock race-scenario
: > "$RACE/entered_$WORKER"
while [ ! -f "$RACE/finish" ]; do sleep 0.01; done
WORKER
chmod +x "$RACE/worker.sh"

wait_for_race_file() {
    local path="$1" i
    for ((i = 0; i < 500; i++)); do
        [ -e "$path" ] && return 0
        sleep 0.01
    done
    echo "❌ timed out waiting for $path"
    fail=1
    return 1
}

export RACE
WORKER=A bash "$RACE/worker.sh" & race_a=$!
if wait_for_race_file "$RACE/published_A"; then
    WORKER=B bash "$RACE/worker.sh" & race_b=$!
    WORKER=C bash "$RACE/worker.sh" & race_c=$!
    sleep 0.1
    if [ -e "$RACE/entered_B" ] || [ -e "$RACE/entered_C" ]; then
        echo "❌ issue #1030: a contender entered while A was paused at publication"
        fail=1
    fi
fi
: > "$RACE/release_A"
wait_for_race_file "$RACE/entered_A" || true
for worker in B C; do
    for ((i = 0; i < 500; i++)); do
        [ -e "$RACE/entered_$worker" ] || [ -e "$RACE/rc_$worker" ] && break
        sleep 0.01
    done
done
: > "$RACE/finish"
wait "$race_a" || true
[ -z "${race_b:-}" ] || wait "$race_b" || true
[ -z "${race_c:-}" ] || wait "$race_c" || true
owners=0
for worker in A B C; do
    [ ! -e "$RACE/entered_$worker" ] || owners=$((owners + 1))
done
if [ "$owners" -ne 1 ] || [ ! -e "$RACE/entered_A" ]; then
    echo "❌ issue #1030: $owners workers entered the critical section (expected only A)"
    fail=1
fi
for worker in A B C; do
    expected_rc=2
    [ "$worker" = A ] && expected_rc=0
    actual_rc=$(cat "$RACE/rc_$worker" 2>/dev/null || true)
    if [ "$actual_rc" != "$expected_rc" ]; then
        echo "❌ issue #1030: worker $worker exited $actual_rc (expected $expected_rc)"
        fail=1
    fi
done

# Windows Git Bash runs this exact three-process barrier with native Python.
# The signal matrix below uses POSIX preexec_fn/SIGKILL semantics and is run
# by the default mode on Linux/macOS.
if [ "$barrier_only" -eq 1 ]; then
    if [ "$fail" -eq 0 ]; then
        echo "✅ issue #1030 three-process publication barrier: OK"
    fi
    exit "$fail"
fi

# --- 4. Normal and signal exits release only the owner's links. SIGKILL
# leaves a stale owner, which the next guarded acquisition must recover.
SIGNALS="$TMP/signals"
mkdir -p "$SIGNALS"
cp "$RACE/cleanups.sh" "$SIGNALS/cleanups.sh"
cp "$RACE/lock.sh" "$SIGNALS/lock.sh"
cat > "$SIGNALS/worker.sh" <<'WORKER'
#!/usr/bin/env bash
set -e
LOG_DIR="$SIGNALS"
DATE=20261003
source "$SIGNALS/cleanups.sh"
log() { printf '%s\n' "$*" >> "$SIGNALS/log"; }
source "$SIGNALS/lock.sh"
acquire_lock signal-scenario
: > "$SIGNALS/entered_$RUN_LABEL"
while [ ! -e "$SIGNALS/finish_$RUN_LABEL" ]; do sleep 0.01; done
WORKER
chmod +x "$SIGNALS/worker.sh"
SIGNALS="$SIGNALS" python3 - <<'PY' || fail=1
import os
import pathlib
import signal
import subprocess
import sys
import time

root = pathlib.Path(os.environ["SIGNALS"])
main = root / "locks/signal-scenario.lock"
legacy = root / "locks/signal-scenario.20261003.lck"
workers = []

def start(label):
    env = os.environ.copy()
    env["RUN_LABEL"] = label
    process = subprocess.Popen(
        ["/bin/bash", str(root / "worker.sh")], env=env, start_new_session=True,
        preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL),
    )
    workers.append(process)
    marker = root / ("entered_" + label)
    for _ in range(500):
        if marker.exists():
            return process
        if process.poll() is not None:
            raise AssertionError(f"{label} exited before acquiring: {process.returncode}")
        time.sleep(0.01)
    raise AssertionError(f"{label} did not acquire in 5 seconds")

try:
    for label, sig in (("term", signal.SIGTERM), ("int", signal.SIGINT)):
        process = start(label)
        os.kill(process.pid, sig)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired as exc:
            raise AssertionError(f"{label} did not exit on {sig.name}") from exc
        assert not main.exists() and not legacy.exists(), f"{label} left owned links"

    process = start("killed")
    os.kill(process.pid, signal.SIGKILL)
    process.wait(timeout=5)
    assert main.exists() and legacy.exists(), "SIGKILL did not leave a recoverable stale lock"
    retry = start("retry")
    (root / "finish_retry").touch()
    assert retry.wait(timeout=5) == 0, "retry after SIGKILL failed"
    assert not main.exists() and not legacy.exists(), "retry left lock links"
    assert "recovered stale lock" in (root / "log").read_text(), "stale recovery was not reported"

    legacy.mkdir()
    for label, owner in (("legacy-empty", None), ("legacy-dead", "999999999\n")):
        if owner is not None:
            (legacy / "pid").write_text(owner)
        env = os.environ.copy()
        env["RUN_LABEL"] = label
        blocked = subprocess.run(["/bin/bash", str(root / "worker.sh")], env=env, timeout=5)
        assert blocked.returncode == 1, f"{label} did not fail closed"
        assert legacy.is_dir() and not main.exists(), f"{label} changed a legacy lock"
    assert "legacy lock has no published owner" in (root / "log").read_text(), "empty legacy lock was not diagnosed"
    assert "stale legacy lock" in (root / "log").read_text(), "dead legacy lock was not diagnosed"
    (legacy / "pid").unlink()
    legacy.rmdir()

    # Inject a directory or a symlink to one after inspect_lock but before
    # publication. Neither fixed path may become a directory operand.
    foreign_dir = root / "foreign-dir"
    foreign_dir.mkdir()
    symlink_script = r'''
set -e
LOG_DIR="$SIGNALS"
DATE=20261003
source "$SIGNALS/cleanups.sh"
log() { printf '%s\n' "$*" >> "$SIGNALS/log"; }
source "$SIGNALS/lock.sh"
inject_target() {
    if [ "$INJECT_KIND" = symlink ]; then
        command ln -s "$FOREIGN_DIR" "$INJECT_TARGET"
    else
        command mkdir "$INJECT_TARGET"
    fi
}
ln() {
    if [ "${2:-}" = "$INJECT_TARGET" ]; then inject_target; fi
    command ln "$@"
}
python3() {
    if [ "${3:-}" = "$INJECT_TARGET" ]; then inject_target; fi
    command python3 "$@"
}
acquire_lock signal-scenario
'''
    for kind in ("symlink", "directory"):
        for target in (main, legacy):
            env = os.environ.copy()
            env.update(INJECT_TARGET=str(target), FOREIGN_DIR=str(foreign_dir), INJECT_KIND=kind)
            blocked = subprocess.run(["/bin/bash", "-c", symlink_script], env=env, timeout=5)
            assert blocked.returncode == 1, f"{kind} injection at {target.name} did not fail closed"
            if kind == "symlink":
                assert target.is_symlink(), f"symlink injection changed {target.name}"
            else:
                assert target.is_dir() and not any(target.iterdir()), f"directory injection gained a file at {target.name}"
            assert not any(foreign_dir.iterdir()), f"{kind} injection at {target.name} wrote into foreign directory"
            assert not (legacy if target == main else main).exists(), "failed publish left its other lock link"
            target.unlink() if kind == "symlink" else target.rmdir()
    assert "lock path is a symlink" in (root / "log").read_text(), "symlink refusal was not diagnosed"

    # TERM at the mkdir/assignment boundary must release our new gate; on a
    # failed mkdir it must leave another process's gate untouched.
    gate_signal_script = r'''
set -e
LOG_DIR="$SIGNALS"
DATE=20261003
source "$SIGNALS/cleanups.sh"
log() { printf '%s\n' "$*" >> "$SIGNALS/log"; }
source "$SIGNALS/lock.sh"
mkdir() {
    local rc=0
    command mkdir "$@" || rc=$?
    if [ "$1" = "$SIGNALS/locks/.signal-scenario.acquire" ]; then
        kill -TERM "$$"
    fi
    return "$rc"
}
acquire_lock signal-scenario
'''
    signal_gate = root / "locks/.signal-scenario.acquire"
    created = subprocess.run(["/bin/bash", "-c", gate_signal_script], env=os.environ.copy(), timeout=5)
    assert created.returncode == 143 and not signal_gate.exists(), "TERM after mkdir orphaned our gate"
    signal_gate.mkdir()
    collided = subprocess.run(["/bin/bash", "-c", gate_signal_script], env=os.environ.copy(), timeout=5)
    assert collided.returncode == 143 and signal_gate.is_dir(), "TERM after collision deleted another gate"
    signal_gate.rmdir()

    # A different contender can recreate the shared gate immediately after
    # rmdir. Terminating the old owner at that boundary must preserve it.
    gate = root / "locks/.gate-replacement.acquire"
    gate_exit = subprocess.run(["/bin/bash", "-c", r'''
set -e
LOG_DIR="$SIGNALS"
DATE=20261003
source "$SIGNALS/cleanups.sh"
log() { printf '%s\n' "$*" >> "$SIGNALS/log"; }
source "$SIGNALS/lock.sh"
rmdir() {
    if [ "$1" = "$SIGNALS/locks/.gate-replacement.acquire" ] && [ ! -e "$SIGNALS/gate-replaced" ]; then
        command rmdir "$1" || return
        command mkdir "$1"
        : > "$SIGNALS/gate-replaced"
        kill -TERM "$$"
    else
        command rmdir "$@"
    fi
}
acquire_lock gate-replacement
'''], env=os.environ.copy(), timeout=5)
    assert gate_exit.returncode == 143, "gate replacement did not terminate at release"
    assert gate.is_dir(), "EXIT cleanup removed a contender's acquisition gate"
    gate.rmdir()

    process = start("foreign-symlink")
    saved_link = root / "saved-owner-link"
    main.rename(saved_link)
    main.symlink_to(saved_link)
    (root / "finish_foreign-symlink").touch()
    assert process.wait(timeout=5) == 0, "foreign symlink scenario failed"
    assert main.is_symlink(), "cleanup removed a foreign symlink to its owner record"
    assert not legacy.exists(), "cleanup did not remove its own legacy link"
    main.unlink()
    saved_link.unlink()

    process = start("foreign")
    saved = root / "old-owner-link"
    main.rename(saved)
    main.write_text("foreign owner\n")
    (root / "finish_foreign").touch()
    assert process.wait(timeout=5) == 0, "foreign replacement scenario failed"
    assert main.read_text() == "foreign owner\n", "cleanup removed another owner's link"
    assert not legacy.exists(), "cleanup did not remove its own legacy link"
    print("✅ issue #1030 signal, stale-retry, and owner-only cleanup: OK")
except (AssertionError, subprocess.TimeoutExpired) as exc:
    print(f"❌ issue #1030 signal/cleanup: {exc}", file=sys.stderr)
    sys.exit(1)
finally:
    for process in workers:
        if process.poll() is None:
            process.kill()
            process.wait()
PY

if [ "$fail" -eq 0 ]; then
    echo "✅ test_issue_657: OK"
fi
exit "$fail"
