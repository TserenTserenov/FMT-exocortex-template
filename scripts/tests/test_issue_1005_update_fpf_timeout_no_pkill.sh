#!/usr/bin/env bash
# Issue #1005 (update.sh part): refresh_fpf_base_clone killed the timed-out git
# fetch with `pkill -P`, which Git Bash on Windows does not have -- the git
# child could outlive the timeout. Fixed: without pkill the process tree is
# killed with taskkill (Windows pid from /proc/<pid>/winpid).
# The local control simulates MSYS with both pkill and taskkill present. The
# Windows branch must choose taskkill because pkill -P cannot be trusted to
# terminate native descendants. A separate mode runs the real tree on Windows.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
cleanup() {
    if [ -n "${REAL_TASKKILL:-}" ] && [ -n "${PYTHON3:-}" ] \
       && [ -f "$TMP/check-native-child.py" ]; then
        for pidfile in "$TMP"/native-*.pid; do
            [ -f "$pidfile" ] || continue
            "$PYTHON3" "$(cygpath -w "$TMP/check-native-child.py")" \
                "$(cygpath -w "$pidfile")" cleanup >/dev/null 2>&1 || true
        done
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

eval "$(awk '
  /^refresh_fpf_base_clone\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$ROOT/update.sh")"
declare -F refresh_fpf_base_clone >/dev/null || fail "refresh_fpf_base_clone not found in update.sh"

export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
: > "$GIT_CONFIG_GLOBAL"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# Prefer a real git binary over a wrapper script (a wrapper that calls `git`
# through PATH would recurse into the shim below).
REAL_GIT=""
while IFS= read -r cand; do
    if [ "$(head -c 4 "$cand" 2>/dev/null | od -An -c | tr -d ' ')" = '177ELF' ]; then
        REAL_GIT="$cand"; break
    fi
done < <(type -ap git)
[ -n "$REAL_GIT" ] || REAL_GIT="$(command -v git)"

WORKSPACE_DIR="$TMP/workspace"
mkdir -p "$WORKSPACE_DIR/FPF"
"$REAL_GIT" -C "$WORKSPACE_DIR/FPF" -c init.defaultBranch=main init -q
echo one > "$WORKSPACE_DIR/FPF/Readme.md"
"$REAL_GIT" -C "$WORKSPACE_DIR/FPF" add Readme.md
"$REAL_GIT" -C "$WORKSPACE_DIR/FPF" commit -q -m first

if [ "${1:-}" = "--native-windows" ]; then
    case "$(uname -s)" in MINGW*|MSYS*) ;; *) fail "native mode requires Git Bash on Windows" ;; esac
    PYTHON3=$("$ROOT/scripts/lib/find-python3.sh" --stdlib-only) || fail "Python 3 is unavailable"
    "$PYTHON3" -c 'import os; assert os.name == "nt", os.name' || fail "native Windows Python required"
    REAL_TASKKILL=$(command -v taskkill) || fail "taskkill is unavailable"
    export REAL_GIT REAL_TASKKILL PYTHON3

    cat > "$TMP/native-child.py" <<'PY'
import os
import sys
import time
import ctypes
from ctypes import wintypes

class FILETIME(ctypes.Structure):
    _fields_ = [("low", wintypes.DWORD), ("high", wintypes.DWORD)]

kernel = ctypes.WinDLL("kernel32", use_last_error=True)
kernel.GetCurrentProcess.restype = wintypes.HANDLE
kernel.GetProcessTimes.argtypes = (
    wintypes.HANDLE,
    ctypes.POINTER(FILETIME), ctypes.POINTER(FILETIME),
    ctypes.POINTER(FILETIME), ctypes.POINTER(FILETIME),
)
created, exited, user, system = FILETIME(), FILETIME(), FILETIME(), FILETIME()
if not kernel.GetProcessTimes(kernel.GetCurrentProcess(),
                              ctypes.byref(created), ctypes.byref(exited),
                              ctypes.byref(user), ctypes.byref(system)):
    raise OSError(ctypes.get_last_error(), "GetProcessTimes failed")
birth = (created.high << 32) | created.low

with open(sys.argv[1], "w", encoding="ascii") as record:
    record.write(f"{os.getpid()} {birth} {os.getppid()}")
time.sleep(30)
PY
    cat > "$TMP/check-native-child.py" <<'PY'
import ctypes
import os
import subprocess
import sys
import time
from ctypes import wintypes

class FILETIME(ctypes.Structure):
    _fields_ = [("low", wintypes.DWORD), ("high", wintypes.DWORD)]

kernel = ctypes.WinDLL("kernel32", use_last_error=True)
kernel.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
kernel.OpenProcess.restype = wintypes.HANDLE
kernel.GetProcessTimes.argtypes = (
    wintypes.HANDLE,
    ctypes.POINTER(FILETIME), ctypes.POINTER(FILETIME),
    ctypes.POINTER(FILETIME), ctypes.POINTER(FILETIME),
)
kernel.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
kernel.WaitForSingleObject.restype = wintypes.DWORD
kernel.CloseHandle.argtypes = (wintypes.HANDLE,)

with open(sys.argv[1], encoding="ascii") as record:
    pid_text, birth_text, _parent_text = record.read().split()
pid, birth = int(pid_text), int(birth_text)
mode = sys.argv[2]
handle = kernel.OpenProcess(0x00100000 | 0x1000, False, pid)  # SYNCHRONIZE | QUERY_LIMITED_INFORMATION
if not handle:
    error = ctypes.get_last_error()
    if error == 87 and mode in {"dead", "cleanup"}:
        raise SystemExit(0)
    raise OSError(error, "OpenProcess failed")
try:
    created, exited, user, system = FILETIME(), FILETIME(), FILETIME(), FILETIME()
    if not kernel.GetProcessTimes(handle, ctypes.byref(created), ctypes.byref(exited),
                                  ctypes.byref(user), ctypes.byref(system)):
        raise OSError(ctypes.get_last_error(), "GetProcessTimes failed")
    if ((created.high << 32) | created.low) != birth:
        if mode == "alive-clean":
            raise AssertionError("red control child PID was reused")
        raise SystemExit(0)  # Original child exited; never kill a reused PID.

    def alive():
        return kernel.WaitForSingleObject(handle, 0) == 258  # WAIT_TIMEOUT

    if mode == "alive-clean":
        assert alive(), "red control child exited before tree-kill probe"
    if mode in {"alive-clean", "cleanup"} and alive():
        system_root = os.environ.get("SystemRoot") or os.environ.get("WINDIR")
        if not system_root:
            raise RuntimeError("Windows system directory unavailable")
        taskkill = os.path.join(system_root, "System32", "taskkill.exe")
        result = subprocess.run([taskkill, "/F", "/T", "/PID", str(pid)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                timeout=5, check=False)
        if result.returncode or kernel.WaitForSingleObject(handle, 3000) != 0:
            raise AssertionError(f"native child {pid} cleanup failed")
    if mode == "dead":
        deadline = time.monotonic() + 4
        while alive() and time.monotonic() < deadline:
            time.sleep(0.1)
        assert not alive(), f"native child {pid} survived taskkill"
finally:
    kernel.CloseHandle(handle)
PY

    NATIVE_TOOLS="$TMP/native-tools"
    mkdir -p "$NATIVE_TOOLS"
    cat > "$NATIVE_TOOLS/git" <<'SHIM'
#!/usr/bin/env bash
for arg in "$@"; do
    if [ "$arg" = fetch ]; then
        printf 'shell_pid=%s shell_winpid=%s\n' "$$" "$(cat "/proc/$$/winpid" 2>/dev/null)" > "$TEST_SHIM_PIDFILE"
        "$PYTHON3" "$TEST_CHILD_SCRIPT" "$TEST_CHILD_PIDFILE" >/dev/null 2>&1 &
        wait "$!"
        exit $?
    fi
done
exec "$REAL_GIT" "$@"
SHIM
    cat > "$NATIVE_TOOLS/taskkill" <<'SHIM'
#!/usr/bin/env bash
if [ "$TEST_TASKKILL_MODE" = noop ]; then
    exit 0
fi
printf 'args=%s\n' "$*" > "$TEST_TASKKILL_LOG"
"$REAL_TASKKILL" "$@" > "$TEST_TASKKILL_OUT" 2>&1
rc=$?
printf 'rc=%s\n' "$rc" >> "$TEST_TASKKILL_LOG"
exit "$rc"
SHIM
    chmod +x "$NATIVE_TOOLS/git" "$NATIVE_TOOLS/taskkill"
    export TEST_CHILD_SCRIPT="$(cygpath -w "$TMP/native-child.py")"

    run_native_case() {
        local mode="$1" pidfile="$TMP/native-$1.pid" output start elapsed
        export TEST_TASKKILL_MODE="$mode"
        export TEST_CHILD_PIDFILE="$(cygpath -w "$pidfile")"
        export TEST_SHIM_PIDFILE="$TMP/shim-$mode.pid"
        export TEST_TASKKILL_LOG="$TMP/taskkill-$mode.log"
        export TEST_TASKKILL_OUT="$TMP/taskkill-$mode.out"
        start=$(date +%s)
        output=$(PATH="$NATIVE_TOOLS:$PATH" IWE_FPF_FETCH_TIMEOUT=2 refresh_fpf_base_clone 2>&1)
        elapsed=$(( $(date +%s) - start ))
        [ "$elapsed" -lt 12 ] || fail "$mode: watchdog took ${elapsed}s: $output"
        grep -q 'не ответил' <<<"$output" || fail "$mode: no timeout message: $output"
        [ -f "$pidfile" ] || fail "$mode: native child did not start: $output"
        if [ "$mode" = noop ]; then
            sleep 1
            "$PYTHON3" "$(cygpath -w "$TMP/check-native-child.py")" "$(cygpath -w "$pidfile")" alive-clean \
                || fail "red control: missing tree kill did not leave a live native child"
        else
            "$PYTHON3" "$(cygpath -w "$TMP/check-native-child.py")" "$(cygpath -w "$pidfile")" dead \
                || fail "green control: native child survived; output=$output; child=$(cat "$pidfile"); shim=$(cat "$TEST_SHIM_PIDFILE" 2>/dev/null); taskkill=$(cat "$TEST_TASKKILL_LOG" 2>/dev/null); taskkill_out=$(cat "$TEST_TASKKILL_OUT" 2>/dev/null)"
        fi
        rm -f "$pidfile"
    }

    run_native_case noop
    run_native_case real
    echo "PASS: issue 1005 update.sh timeout kills a real Windows child; no-op control detects leak"
    exit 0
fi

# Minimal PATH with explicit pkill and taskkill probes.
TOOLS="$TMP/tools"
PROC="$TMP/proc"
mkdir -p "$TOOLS" "$PROC"
# Mirror the tools of the current PATH (the real git may be a wrapper script
# that needs arbitrary helpers).
IFS=: read -r -a path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
        n="$(basename "$f")"
        [ -x "$f" ] && [ ! -e "$TOOLS/$n" ] && ln -s "$f" "$TOOLS/$n"
    done
done
# Replace (never write through) the mirrored symlinks.
rm -f "$TOOLS/git" "$TOOLS/taskkill" "$TOOLS/pkill"

# git shim: a fetch that never returns; publishes a fake Windows pid first.
cat > "$TOOLS/git" <<SHIM
#!/bin/bash
for a in "\$@"; do
    if [ "\$a" = fetch ]; then
        mkdir -p "$PROC/\$\$"
        echo 4242 > "$PROC/\$\$/winpid"
        exec sleep 30
    fi
done
exec "$REAL_GIT" "\$@"
SHIM
cat > "$TOOLS/taskkill" <<STUB
#!/bin/bash
echo "\$*" >> "$TMP/taskkill.args"
STUB
cat > "$TOOLS/pkill" <<STUB
#!/bin/bash
echo "\$*" >> "$TMP/pkill.args"
STUB
chmod +x "$TOOLS/git" "$TOOLS/taskkill" "$TOOLS/pkill"

started=$(date +%s)
out=$(OSTYPE=msys PATH="$TOOLS" IWE_PROC_DIR="$PROC" IWE_FPF_FETCH_TIMEOUT=2 refresh_fpf_base_clone 2>&1)
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 12 ] || fail "watchdog did not fire (${elapsed}s): $out"
grep -q 'не ответил' <<<"$out" || fail "no timeout message: $out"
[ -f "$TMP/taskkill.args" ] || fail "taskkill was not used for MSYS (native child tree left running)"
[ ! -f "$TMP/pkill.args" ] || fail "MSYS incorrectly used pkill -P despite taskkill being available"
grep -q '4242' "$TMP/taskkill.args" || fail "taskkill got no Windows pid: $(cat "$TMP/taskkill.args")"
grep -q '//T' "$TMP/taskkill.args" || fail "taskkill not asked for the process tree: $(cat "$TMP/taskkill.args")"

echo "PASS: issue 1005 update.sh fetch timeout prefers taskkill on MSYS (5 checks)"
