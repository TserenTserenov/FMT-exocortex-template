#!/usr/bin/env bash
# test-yookassa-test-name-mentions.sh - regression: 0.41.0's own files vs the
# pre-commit secret scan.
#
# Merging the 0.41.0 release into a fork was blocked as "yookassa: 8 matches";
# all eight were test names shipped by the release, in three forms the
# analyzer did not recognise:
#   1. def <five-segment name>(self): - the shape asked for six segments while
#      its own comments (and test_issue_896) state the bar as ">= 5";
#   2. echo "<mark> <name>: all checks passed" - every test_issue_*.sh of the
#      release reports its own result this way;
#   3. ^scripts/tests/<name>\.sh$ - a basename inside a regex, dot escaped.
# Each form must pass; a bare name and a dense token in the same line shapes
# must still be flagged.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
ANALYZER="$ROOT/.claude/hooks/secret-bypass-analyzer.py"

PYTHON=$(command -v python3 || true)
if [ -z "$PYTHON" ]; then
    echo "SKIP: python3 not installed"
    exit 0
fi

"$PYTHON" - "$ANALYZER" <<'PY'
import json
import subprocess
import sys

ANALYZER = sys.argv[1]
failures = []

# Built at runtime, so this file itself never carries a literal candidate
# (same technique as test_issue_896_yookassa_digit_segment.sh).
five_segments = "test_" + "empty_answer_preserves_pending"
issue_name = "test_" + "issue_902_budget_spread_working_days"
script_name = "test_" + "issue_463_setup_reuses_resolved_python3"
dense = "test_" + "9" * 32


def detect(text):
    proc = subprocess.run(
        [sys.executable, ANALYZER, "detect-text"],
        input=text,
        capture_output=True,
        text=True,
    )
    result = json.loads(proc.stdout) if proc.stdout.strip() else {}
    return proc.returncode, result, proc.stderr.strip()


def check(name, text, flagged):
    rc, result, err = detect(text)
    ok = rc == 0 and not err and bool(result.get("pattern_ids")) == flagged
    if ok:
        print("PASS: " + name)
    else:
        print("FAIL: %s -> rc=%s ids=%s stderr=%r" % (name, rc, result.get("pattern_ids"), err))
        failures.append(name)


check("five-segment name in a def line passes", "def " + five_segments + "(self):", False)
check("a test's own result line passes", 'echo "✅ ' + issue_name + ': all checks passed"', False)
check("basename with an escaped dot in a regex passes",
      "^scripts/tests/" + script_name + "\\.sh$')", False)

check("five-segment name with no context is still flagged", five_segments, True)
check("a dense token in a result line is still flagged", 'echo "key ' + dense + ': ok"', True)
check("a name after echo but not followed by a colon is still flagged", "echo " + issue_name, True)
check("a dense token before an escaped .sh is still flagged", dense + "\\.sh", True)

proc = subprocess.run([sys.executable, ANALYZER, "self-test"], input="", capture_output=True, text=True)
if proc.returncode == 0:
    print("PASS: analyzer self-test passes with the new corpus cases")
else:
    print("FAIL: analyzer self-test -> rc=%s stdout=%r" % (proc.returncode, proc.stdout))
    failures.append("self-test")

print("Result: %d FAIL" % len(failures))
sys.exit(1 if failures else 0)
PY
