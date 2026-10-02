#!/usr/bin/env bash
# Issue #1005 (Sync Gate part): the portable deadline wrapper in
# scripts/lib/git-sync-status.sh used signal.SIGHUP and os.killpg, which do not
# exist on Windows, so the wrapper crashed and Sync Gate was always
# "undetermined". Real Windows is not available here: it is simulated by a
# sitecustomize.py (put on PYTHONPATH) that removes signal.SIGHUP, os.killpg
# and signal.SIGKILL before the wrapper runs -- exactly the attributes missing
# from the Windows builds of those modules.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/scripts/lib/git-sync-status.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/winsim"
cat > "$TMP/winsim/sitecustomize.py" <<'PY'
import os
import signal

for _mod, _name in ((signal, "SIGHUP"), (signal, "SIGKILL"), (os, "killpg")):
    if hasattr(_mod, _name):
        delattr(_mod, _name)
PY

# Self-check of the simulation: the attributes really are gone.
PYTHONPATH="$TMP/winsim" python3 -c 'import os, signal, sys; sys.exit(0 if not (hasattr(os, "killpg") or hasattr(signal, "SIGHUP")) else 1)' \
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
