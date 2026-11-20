#!/usr/bin/env bash
# #1010: exercise hook decisions; fixture commands are data and never run.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
PYTHON=$("$ROOT/.claude/lib/find-python3.sh")
"$PYTHON" - "$ROOT" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
hook = root / ".claude/hooks/destructive-guard.sh"
blocked = [
    "git push origin +main",
    "git -C /work push origin '+refs/heads/main:refs/heads/main'",
    "git push --force-with-lease origin +HEAD:main",
    "printf 'rm -rf build' | bash",
    "echo rm -rf build | sh",
    "x=rm; $x -rf build",
    "x=/bin/rm; \"$x\" -rf build",
    "x='rm'; ${x} -r -f build",
    "x=echo; x=rm; $x -rf build",
    "printf '%s\\n' 'rm -rf build' | bash -s",
    "printf 'rm %s %s\\n' -rf build | /bin/sh",
    "printf '%s\\n' 'git push origin +main' | env bash",
    "bash -c \"echo rm -rf build | sh\"",
    "x=rm; false && x=echo; $x -rf build",
    "x=rm && $x -rf build",
    "echo -n rm -rf build | bash -s",
    "echo -e 'r\\x6d -rf build' | sh",
    "printf '%b' 'rm -rf build' | sh",
    "printf '%q' 'rm -rf build' | sh",
    "printf -- 'rm -rf build' | bash",
    "printf '%s%s %s\\n' '' 'rm' '-rf build' | bash",
    "printf 'rm -rf build' | bash -o pipefail",
    "echo rm -rf build | sh -o errexit",
    "printf 'rm -rf build' | bash --rcfile /dev/null",
    "printf 'rm -rf build' | bash -onoclobber",
    "x=rm; (x=echo); $x -rf build",
    "x=rm; x=echo | cat; $x -rf build",
    "x=rm; x=echo & $x -rf build",
    "x=rm; unset -f x; $x -rf build",
    "x=rm; f() { x=echo; }; $x -rf build",
    "x=rm; false && unset x; $x -rf build",
    "x=rm; (unset x); $x -rf build",
    "printf 'rm -rf build' | bash +e",
    "echo rm -rf build | sh +o errexit",
    "printf 'rm -rf build' | bash +o pipefail",
    "printf 'rm -rf build' | bash +s",
]
allowed = [
    "git push origin main",
    "git push --force-with-lease origin HEAD:main",
    "printf '%s\\n' 'git push origin +main'",
    "echo 'rm -rf build'",
    "printf 'rm -rf build' | cat",
    "printf 'rm -rf build' | bash -c cat",
    "printf 'rm -rf build' | bash -s -c cat",
    "printf 'rm -rf build' | bash -o pipefail script.sh",
    "printf 'rm -rf build' | bash +e script.sh",
    "printf 'rm -rf build' | bash script.sh",
    "printf 'rm -rf build' || bash",
    "echo 'rm -rf build' && bash",
    "echo safe | bash",
    "printf '%s\\n' 'echo safe' | sh",
    "x=rm; echo '$x -rf build'",
    "x=rm; x=echo; $x -rf build",
    "x=rm; '$x' -rf build",
    "x=rm; unset x; $x -rf build",
    "x=rm; \\$x -rf build",
    "runner=\"${RUNNER:-python3}\"; \"$runner\" -V",
]
failures = []
for expected, commands in ((2, blocked), (0, allowed)):
    for command in commands:
        result = subprocess.run(
            ["bash", str(hook)],
            input=json.dumps({"tool_input": {"command": command}, "cwd": str(root)}),
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode != expected:
            failures.append((command, expected, result.returncode, result.stderr))
for command, expected, actual, error in failures:
    print(f"FAIL: {command!r}: expected {expected}, got {actual}: {error.strip()}")
print(f"indirect hook inputs: {len(blocked) + len(allowed) - len(failures)} passed, {len(failures)} failed")
sys.exit(bool(failures))
PY
