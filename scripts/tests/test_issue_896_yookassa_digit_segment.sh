#!/usr/bin/env bash
# test_issue_896_yookassa_digit_segment.sh - regression for issue #896.
#
# secret-bypass-analyzer.py: YOOKASSA_PYTEST_SHAPE_RE required every
# underscore-separated segment to start with a letter ([a-z][a-z0-9]*), so a
# pytest identifier carrying an issue-number segment (test_issue_463_...)
# never matched the shape at all -- no def-line/pytest-nodeid/comment/CLI/
# filename context exemption below it can rescue a candidate that already
# failed the shape check. Reported symptom: 0.40.1's own delivered test
# files (test_issue_463_..., etc.) tripped the pre-commit secret scan as
# possible YooKassa keys. Fix: the segment pattern now allows a digit-led
# segment too ([a-z0-9]+); the structural bar (>=5 underscore-separated
# segments) is what actually distinguishes an identifier from a real key,
# not which character a segment happens to start with.
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

# Built at runtime, split at the digit boundary, so this file itself never
# carries the literal candidate substring (same technique as the analyzer's
# own self-test corpus and test_issue_874_here_string.sh).
digit_led_name = "test_" + "issue_463_foo_bar_baz_qux_quux"


def detect(text):
    proc = subprocess.run(
        [sys.executable, ANALYZER, "detect-text"],
        input=text,
        capture_output=True,
        text=True,
    )
    result = json.loads(proc.stdout) if proc.stdout.strip() else {}
    return proc.returncode, result, proc.stderr.strip()


def check(name, ok, detail=""):
    if ok:
        print("PASS: " + name)
    else:
        print("FAIL: " + name + (" -> " + detail if detail else ""))
        failures.append(name)


# A digit-led pytest identifier in a def-line context must be rescued, the
# same way a letter-only one already is.
rc, result, err = detect("def " + digit_led_name + "(self):")
check(
    "def-line context rescues a digit-led segment",
    rc == 0 and not err and not result.get("pattern_ids"),
    "rc=%s ids=%s stderr=%r" % (rc, result.get("pattern_ids"), err),
)

# Same for a pytest node id.
rc, result, err = detect("scripts/tests/foo.py::" + digit_led_name + " PASSED")
check(
    "pytest node-id context rescues a digit-led segment",
    rc == 0 and not err and not result.get("pattern_ids"),
    "rc=%s ids=%s stderr=%r" % (rc, result.get("pattern_ids"), err),
)

# A bare occurrence with no protecting context must still redact -- the fix
# widens which segments count as identifier-shaped, it must not disable the
# context requirement itself.
rc, result, err = detect(digit_led_name)
check(
    "bare occurrence (no context) still redacts",
    rc == 0 and not err and bool(result.get("pattern_ids")),
    "rc=%s ids=%s stderr=%r" % (rc, result.get("pattern_ids"), err),
)

# A genuine unbroken YooKassa-shaped token (no underscore word-segments)
# must still be caught regardless of this fix -- it never had the pytest
# shape to begin with.
real_looking = "test_" + "9" * 32
rc, result, err = detect(real_looking)
check(
    "an unbroken 30+ char token is still flagged as a real candidate",
    rc == 0 and not err and bool(result.get("pattern_ids")),
    "rc=%s ids=%s stderr=%r" % (rc, result.get("pattern_ids"), err),
)

# The analyzer's own corpus must carry the new case.
proc = subprocess.run(
    [sys.executable, ANALYZER, "self-test"], input="", capture_output=True, text=True
)
check(
    "analyzer self-test passes with the widened corpus",
    proc.returncode == 0,
    "rc=%s stdout=%r" % (proc.returncode, proc.stdout),
)

print("Result: %d FAIL" % len(failures))
sys.exit(1 if failures else 0)
PY
