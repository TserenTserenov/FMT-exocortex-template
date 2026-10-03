#!/usr/bin/env bash
# Issue #1005 (update.sh part): Git Bash $! can identify a Bash shim whose
# native Git helper is no longer its Windows child. A taskkill /T of that PID
# reports success while the helper survives. The FPF fetch must use the same
# bounded native process-tree supervisor as the read-only Sync Gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$ROOT"
TMP="$(mktemp -d)"
cleanup() {
    if [ -n "${PYTHON3:-}" ] && [ -f "$TMP/check-native-child.py" ]; then
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
# Prefer a real git binary over a wrapper script in the local fixture.
REAL_GIT=""
while IFS= read -r cand; do
    if [ "$(head -c 4 "$cand" 2>/dev/null | od -An -c | tr -d ' ')" = '177ELF' ]; then
        REAL_GIT="$cand"; break
    fi
done < <(type -ap git)
[ -n "$REAL_GIT" ] || REAL_GIT="$(command -v git)"

WORKSPACE_DIR="$TMP/work space"
mkdir -p "$WORKSPACE_DIR/FPF"
"$REAL_GIT" -C "$WORKSPACE_DIR/FPF" -c init.defaultBranch=main init -q
echo one > "$WORKSPACE_DIR/FPF/Readme.md"
"$REAL_GIT" -C "$WORKSPACE_DIR/FPF" add Readme.md
"$REAL_GIT" -C "$WORKSPACE_DIR/FPF" commit -q -m first

if [ "${1:-}" = "--native-windows" ]; then
    case "$(uname -s)" in MINGW*|MSYS*) ;; *) fail "native mode requires Git Bash on Windows" ;; esac
    PYTHON3=$("$ROOT/scripts/lib/find-python3.sh" --stdlib-only) || fail "Python 3 is unavailable"
    "$PYTHON3" -c 'import os; assert os.name == "nt", os.name' || fail "native Windows Python required"
    NATIVE_PYTHON=$("$PYTHON3" -c 'import sys; print(sys.executable)') || fail "native Python path unavailable"
    export GIT_ALLOW_PROTOCOL=ext

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

    cat > "$TMP/native-red-control.py" <<'PY'
import os
import subprocess
import sys
import time

git_exe, repo, record = sys.argv[1:]
error_file = record + ".git-error"
error_stream = open(error_file, "w+", encoding="utf-8")
process = subprocess.Popen(
    [git_exe, "-C", repo, "fetch", "--quiet"],
    stdout=subprocess.DEVNULL, stderr=error_stream,
)
try:
    deadline = time.monotonic() + 5
    while not os.path.exists(record):
        if process.poll() is not None:
            error_stream.seek(0)
            raise AssertionError(
                f"git fetch exited before remote helper started: {process.returncode}; "
                f"stderr={error_stream.read()}"
            )
        if time.monotonic() >= deadline:
            raise AssertionError("remote helper did not publish its PID")
        time.sleep(0.05)
    process.terminate()  # Prior Windows behavior: only the direct git root.
    process.wait(timeout=3)
finally:
    if process.poll() is None:
        process.kill()
        process.wait(timeout=3)
    error_stream.close()
PY

    remote_ext_arg() {
        local value="$1"
        value="${value//%/%%}"
        value="${value// /% }"
        printf '%s' "$value"
    }

    run_native_case() {
        local mode="$1" pidfile="$TMP/native-$1.pid" url output start elapsed
        local python_arg script_arg record_arg
        python_arg=$(remote_ext_arg "$(cygpath -m "$NATIVE_PYTHON")")
        script_arg=$(remote_ext_arg "$(cygpath -m "$TMP/native-child.py")")
        record_arg=$(remote_ext_arg "$(cygpath -m "$pidfile")")
        url="ext::$python_arg $script_arg $record_arg"
        "$REAL_GIT" -C "$WORKSPACE_DIR/FPF" remote remove origin >/dev/null 2>&1 || true
        "$REAL_GIT" -C "$WORKSPACE_DIR/FPF" remote add origin "$url" || fail "$mode: cannot configure local ext remote"
        if [ "$mode" = red ]; then
            "$PYTHON3" "$(cygpath -w "$TMP/native-red-control.py")" \
                "$(cygpath -w "$REAL_GIT")" "$(cygpath -w "$WORKSPACE_DIR/FPF")" "$(cygpath -w "$pidfile")" \
                || fail "red control: direct git termination did not start the remote helper"
            "$PYTHON3" "$(cygpath -w "$TMP/check-native-child.py")" "$(cygpath -w "$pidfile")" alive-clean \
                || fail "red control: direct git termination did not leave the native helper alive"
        else
            start=$(date +%s)
            output=$(IWE_FPF_FETCH_TIMEOUT=2 refresh_fpf_base_clone 2>&1)
            elapsed=$(( $(date +%s) - start ))
            [ "$elapsed" -lt 15 ] || fail "green: fetch timeout took ${elapsed}s: $output"
            grep -q 'не ответил' <<<"$output" || fail "green: no timeout message: $output"
            [ -f "$pidfile" ] || fail "green: remote helper did not start: $output"
            "$PYTHON3" "$(cygpath -w "$TMP/check-native-child.py")" "$(cygpath -w "$pidfile")" dead \
                || fail "green: native Git helper survived; output=$output; helper=$(cat "$pidfile")"
        fi
        rm -f "$pidfile"
    }

    run_native_case red
    run_native_case green
    echo "PASS: issue 1005 FPF native Windows red/green real-Git remote-helper timeout"
    exit 0
fi

# Local POSIX smoke: a fetch that never returns must be bounded by the shared
# supervisor. The native Windows mode above checks the real descendant tree.
TOOLS="$TMP/tools"
mkdir -p "$TOOLS"
cat > "$TOOLS/git" <<SHIM
#!/bin/bash
for a in "\$@"; do
    [ "\$a" = fetch ] && exec sleep 30
done
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$TOOLS/git"

started=$(date +%s)
out=$(PATH="$TOOLS:$PATH" IWE_FPF_FETCH_TIMEOUT=2 refresh_fpf_base_clone 2>&1)
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 12 ] || fail "POSIX timeout took ${elapsed}s: $out"
grep -q 'не ответил' <<<"$out" || fail "no timeout message: $out"

# A supervisor that cannot prove cleanup must get a distinct warning. The
# temporary library replaces only the timeout helper for this classification
# probe; the native Windows branch above exercises the real process tree.
mkdir -p "$TMP/failing-controller/scripts/lib"
printf '%s\n' '_git_sync_run_with_timeout() { return 125; }' \
    > "$TMP/failing-controller/scripts/lib/git-sync-status.sh"
out=$(SCRIPT_DIR="$TMP/failing-controller" IWE_FPF_FETCH_TIMEOUT=2 refresh_fpf_base_clone 2>&1)
grep -q 'остановка дерева git не подтверждена' <<<"$out" \
    || fail "supervision failure lost its distinct warning: $out"
out=$(IWE_FPF_FETCH_TIMEOUT=0 refresh_fpf_base_clone 2>&1)
grep -q 'некорректный лимит' <<<"$out" || fail "zero timeout was not rejected: $out"

echo "PASS: issue 1005 FPF local bounded timeout, supervision failure, zero limit"
