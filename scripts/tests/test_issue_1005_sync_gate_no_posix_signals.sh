#!/usr/bin/env bash
# Issue #1005 (Sync Gate part): the portable deadline wrapper in
# scripts/lib/git-sync-status.sh used signal.SIGHUP and os.killpg, which do not
# exist on Windows, so the wrapper crashed and Sync Gate was always
# "undetermined". The default mode simulates missing POSIX attributes with
# sitecustomize.py; --native-windows checks a real Git Bash process tree.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/scripts/lib/git-sync-status.sh"
PYTHON3=$("$ROOT/scripts/lib/find-python3.sh" --stdlib-only) || {
    echo "FAIL: Python 3 is unavailable" >&2
    exit 1
}
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

if [ "${1:-}" = "--native-windows" ]; then
    case "$(uname -s)" in MINGW*|MSYS*) ;; *) fail "native mode requires Git Bash on Windows" ;; esac
    NATIVE_PYTHON=$("$PYTHON3" -c 'import os, sys; assert os.name == "nt", os.name; print(sys.executable)') \
        || fail "native Windows Python required"
    TEST_GIT_BASH=$(cygpath -w "$(command -v bash)") || fail "Git Bash executable is unavailable"
    export NATIVE_PYTHON TEST_GIT_BASH
    export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
    : > "$GIT_CONFIG_GLOBAL"
    git init -q --bare "$TMP/origin.git" || fail "cannot create local origin"
    git clone -q "$TMP/origin.git" "$TMP/repo" || fail "cannot clone local origin"
    git -C "$TMP/repo" checkout -q -b main || fail "cannot create main"
    git -C "$TMP/repo" config user.name test
    git -C "$TMP/repo" config user.email test@example.invalid
    echo initial > "$TMP/repo/seed.md"
    git -C "$TMP/repo" add seed.md
    git -C "$TMP/repo" commit -q -m initial || fail "cannot commit fixture"
    git -C "$TMP/repo" push -q origin main || fail "cannot push fixture"

    # The real Sync Gate must also pass a quick local-origin query through
    # native Python, not only the timeout branch.
    . "$LIB"
    check_git_sync_status "$TMP/repo" main 5
    [ "$GIT_SYNC_STATUS" = OK ] && [ "$GIT_SYNC_BEHIND" = 0 ] \
        || fail "native Windows local origin classified as $GIT_SYNC_STATUS: $GIT_SYNC_DETAIL"

    # A missing system taskkill must fail before spawning git. A separate
    # classifier probe checks that exit 125 cannot be reported as a normal
    # handled timeout when the supervisor cannot prove cleanup.
    cat > "$TMP/preflight-child.py" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text("started", encoding="ascii")
PY
    missing_system_root="$(cygpath -w "$TMP/missing-system-root")"
    preflight_marker="$TMP/preflight-child-started"
    SystemRoot="$missing_system_root" _git_sync_run_with_timeout 3 \
        "$NATIVE_PYTHON" "$(cygpath -w "$TMP/preflight-child.py")" "$(cygpath -w "$preflight_marker")" \
        >/dev/null 2>&1
    preflight_status=$?
    [ "$preflight_status" -eq 125 ] || fail "missing taskkill preflight returned $preflight_status, expected 125"
    [ ! -e "$preflight_marker" ] || fail "missing taskkill preflight launched a child"
    (
        _git_sync_run_with_timeout() { return 125; }
        check_git_sync_status "$TMP/repo" main 5
        [ "$GIT_SYNC_STATUS" = fetch_failed ] && [ "$GIT_SYNC_DETAIL" = reason=timeout_supervision_failed ] \
            || fail "supervisor failure misclassified as $GIT_SYNC_STATUS: $GIT_SYNC_DETAIL"
    )

    cat > "$TMP/native-tree-root.py" <<'PY'
import json
import os
import subprocess
import sys
import time

record, _repo = sys.argv[1:]

children = []
try:
    # Native Python children keep the tree fixture free of Git's shell alias.
    # The real-Git path is checked above with the local origin query.
    child = subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(30)"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    children.append(child)
    leaf = subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(30)"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    children.append(leaf)
    # Publish one complete record. Replacing a record held open by the reader
    # fails on Windows and can leave the fixture's child processes behind.
    with open(record + ".tmp", "w", encoding="ascii") as stream:
        json.dump({"root": os.getpid(), "child": child.pid, "leaf": leaf.pid}, stream)
    os.replace(record + ".tmp", record)
except BaseException:
    # The fault case overrides SystemRoot to break the production taskkill;
    # test cleanup uses the system directory captured before that override.
    system_root = os.environ.get("TEST_REAL_SYSTEM_ROOT")
    taskkill = os.path.join(system_root, "System32", "taskkill.exe") if system_root else None
    for child in reversed(children):
        if child.poll() is None:
            try:
                if taskkill:
                    subprocess.run([taskkill, "/F", "/T", "/PID", str(child.pid)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   timeout=5, check=False)
            except (OSError, subprocess.TimeoutExpired):
                pass
            if child.poll() is None:
                child.kill()
            child.wait(timeout=3)
    raise
time.sleep(30)
PY
    cat > "$TMP/native-tree-check.py" <<'PY'
import ctypes
import json
import os
import shutil
import subprocess
import sys
import time
from ctypes import wintypes

kernel = ctypes.WinDLL("kernel32", use_last_error=True)
kernel.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
kernel.OpenProcess.restype = wintypes.HANDLE
kernel.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
kernel.WaitForSingleObject.restype = wintypes.DWORD
kernel.TerminateProcess.argtypes = (wintypes.HANDLE, wintypes.UINT)
kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
kernel.GetProcessId.argtypes = (wintypes.HANDLE,)
kernel.GetProcessId.restype = wintypes.DWORD
WAIT_OBJECT_0 = 0
ACCESS = 0x00100000 | 0x0001  # SYNCHRONIZE | PROCESS_TERMINATE
system_root = os.environ.get("SystemRoot") or os.environ.get("WINDIR")
if not system_root:
    raise RuntimeError("Windows system directory unavailable")
os.environ["TEST_REAL_SYSTEM_ROOT"] = system_root
TASKKILL = os.path.join(system_root, "System32", "taskkill.exe")

def capture_tree(record, handles, owner):
    deadline = time.monotonic() + 5
    while True:
        if os.path.exists(record):
            with open(record, encoding="ascii") as stream:
                pids = json.load(stream)
            for name, pid in pids.items():
                if name not in handles:
                    handle = kernel.OpenProcess(ACCESS, False, pid)
                    if not handle:
                        raise OSError(ctypes.get_last_error(), f"OpenProcess({name}={pid})")
                    handles[name] = handle
            if set(handles) == {"root", "child", "leaf"}:
                return
        if owner.poll() is not None:
            raise AssertionError(f"tree fixture exited with {owner.returncode} before publishing all PIDs in {record}")
        if time.monotonic() > deadline:
            raise AssertionError(f"tree fixture did not publish all PIDs in {record}")
        time.sleep(0.05)

def stopped(handle, timeout_ms=0):
    return kernel.WaitForSingleObject(handle, timeout_ms) == WAIT_OBJECT_0

def kill_tree(pid):
    try:
        subprocess.run(
            [TASKKILL, "/F", "/T", "/PID", str(pid)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=5, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        pass

def cleanup(handles):
    for handle in handles.values():
        try:
            if not stopped(handle):
                kill_tree(kernel.GetProcessId(handle))
                if not stopped(handle, 3000):
                    kernel.TerminateProcess(handle, 1)
                if not stopped(handle, 3000):
                    raise AssertionError(f"test process {kernel.GetProcessId(handle)} survived cleanup")
        finally:
            kernel.CloseHandle(handle)

root_script, repo, record, sync_lib = sys.argv[1:]

# Red control: direct termination of the root (the prior Windows behavior)
# leaves at least one native child running. Handles are kept open to avoid
# PID reuse and are always cleaned up, including when an assertion fails.
control = subprocess.Popen([sys.executable, root_script, record + ".control", repo])
control_handles = {}
try:
    capture_tree(record + ".control", control_handles, control)
    control.terminate()
    control.wait(timeout=3)
    assert not stopped(control_handles["child"]) and not stopped(control_handles["leaf"]), \
        "red control did not expose both orphaned native descendants"
finally:
    if control.poll() is None:
        kill_tree(control.pid)
    cleanup(control_handles)
    if control.poll() is None:
        control.kill()
        control.wait(timeout=3)

def launch_wrapper(pid_record, overrides=None):
    environment = os.environ.copy()
    environment.update({"SYNC_LIB": sync_lib, "ROOT_SCRIPT": root_script,
                        "PID_RECORD": pid_record, "FIXTURE_REPO": repo})
    if overrides:
        environment.update(overrides)
    return subprocess.Popen(
        [os.environ["TEST_GIT_BASH"], "-c", '. "$(cygpath -u "$SYNC_LIB")"; _git_sync_run_with_timeout 7 "$NATIVE_PYTHON" "$ROOT_SCRIPT" "$PID_RECORD" "$FIXTURE_REPO"'],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

def capture_wrapper_tree(pid_record, handles, wrapper):
    try:
        capture_tree(pid_record, handles, wrapper)
    except Exception as error:
        if wrapper.poll() is None:
            kill_tree(wrapper.pid)
        try:
            stdout, stderr = wrapper.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            stdout, stderr = "", "wrapper pipe remained open after taskkill"
        raise AssertionError(
            f"{error}; wrapper rc={wrapper.returncode}; out={stdout}; err={stderr}"
        ) from error

wrapper = launch_wrapper(record + ".green")
green_handles = {}
try:
    capture_wrapper_tree(record + ".green", green_handles, wrapper)
    stdout, stderr = wrapper.communicate(timeout=16)
    assert wrapper.returncode == 124, f"timeout rc={wrapper.returncode}; out={stdout}; err={stderr}"
    for name, handle in green_handles.items():
        assert stopped(handle, 3000), f"timed-out {name} process survived"
finally:
    if wrapper.poll() is None:
        kill_tree(wrapper.pid)
    cleanup(green_handles)
    if wrapper.poll() is None:
        wrapper.kill()
        wrapper.communicate(timeout=3)

# A taskkill binary that exists but fails after the child starts must not be
# reported as a handled timeout. Copying a real system executable makes the
# failure deterministic without replacing the production taskkill or PATH.
fake_root = os.path.join(os.path.dirname(record), "failed-taskkill-root")
os.makedirs(os.path.join(fake_root, "System32"), exist_ok=True)
fake_taskkill = os.path.join(fake_root, "System32", "taskkill.exe")
shutil.copyfile(os.path.join(system_root, "System32", "where.exe"), fake_taskkill)
probe = subprocess.run([fake_taskkill, "/F", "/T", "/PID", "0"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=5, check=False)
assert probe.returncode != 0, "fault taskkill executable unexpectedly succeeded"
fault = launch_wrapper(record + ".fault", {"SystemRoot": fake_root})
fault_handles = {}
try:
    capture_wrapper_tree(record + ".fault", fault_handles, fault)
    stdout, stderr = fault.communicate(timeout=19)
    assert fault.returncode == 125, \
        f"failed taskkill returned {fault.returncode}, expected 125; out={stdout}; err={stderr}"
    assert stopped(fault_handles["root"], 3000), "fallback did not stop direct root"
    assert not stopped(fault_handles["child"]) or not stopped(fault_handles["leaf"]), \
        "fault injection did not expose a surviving descendant"
finally:
    if fault.poll() is None:
        kill_tree(fault.pid)
    cleanup(fault_handles)
    if fault.poll() is None:
        fault.kill()
        fault.communicate(timeout=3)
print("PASS: native Windows Sync Gate red/green tree and both taskkill failure paths")
PY
    "$PYTHON3" "$(cygpath -w "$TMP/native-tree-check.py")" \
        "$(cygpath -w "$TMP/native-tree-root.py")" \
        "$(cygpath -w "$TMP/repo")" \
        "$(cygpath -w "$TMP/tree-record")" \
        "$LIB" || fail "native Windows process-tree timeout test failed"
    exit 0
fi

mkdir -p "$TMP/winsim"
cat > "$TMP/winsim/sitecustomize.py" <<'PY'
import os
import signal

for _mod, _name in ((signal, "SIGHUP"), (signal, "SIGKILL"), (os, "killpg")):
    if hasattr(_mod, _name):
        delattr(_mod, _name)
PY

# Self-check of the simulation: the attributes really are gone.
PYTHONPATH="$TMP/winsim" "$PYTHON3" -c 'import os, signal, sys; sys.exit(0 if not (hasattr(os, "killpg") or hasattr(signal, "SIGHUP")) else 1)' \
    || fail "Windows simulation is not effective"

# shellcheck source=../lib/git-sync-status.sh
. "$LIB"
export PYTHONPATH="$TMP/winsim${PYTHONPATH:+:$PYTHONPATH}"

# 1. Exit status of a quick command is passed through.
_git_sync_run_with_timeout 5 true; rc=$?
[ "$rc" -eq 0 ] || fail "true under simulated Windows: rc=$rc (want 0)"
_git_sync_run_with_timeout 5 sh -c 'exit 3'; rc=$?
[ "$rc" -eq 3 ] || fail "exit 3 under simulated Windows: rc=$rc (want 3)"

# 2. A hung command is stopped at the deadline (rc 124), not left running.
started=$(date +%s)
_git_sync_run_with_timeout 1 sleep 30; rc=$?
elapsed=$(( $(date +%s) - started ))
[ "$rc" -eq 124 ] || fail "hung command under simulated Windows: rc=$rc (want 124)"
[ "$elapsed" -lt 10 ] || fail "deadline did not fire promptly: ${elapsed}s"

echo "PASS: issue 1005 sync gate wrapper (3 checks)"
