#!/usr/bin/env bash
# test_issue_874_here_string.sh - regression for issue #874.
#
# secret-bypass-analyzer.py: parse_heredoc_header() refused to treat "<<<" as a
# here-document start but left the cursor on the 2nd "<", where "<<" followed by
# a non-"<" looked like a here-document. The next word became its delimiter and
# extract_heredocs() failed with "unterminated heredoc: expected delimiter ...".
# Depending on the version that either blocked every Bash call using a
# here-string ("Secret PreToolUse guard failed") or - since #760 degrades to a
# literal scan - printed the error and downgraded the shell model to
# "unsupported", switching off the path/upload heuristics for that command.
# The analyzer is run for real (analyze-bash + self-test); the assertions look at
# stderr, the reported shell model and heredoc-body scanning.
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
HS = "<" * 3  # written out of pieces so this file stays free of the literal operator
failures = []


def analyze(command):
    envelope = json.dumps(
        {
            "session_id": "t",
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": command},
        }
    )
    proc = subprocess.run(
        [sys.executable, ANALYZER, "analyze-bash"],
        input=envelope,
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


# Fixture built at runtime so the repository file carries no secret-shaped literal.
fake_secret = "sk-proj-" + "A" * 28

clean_cases = {
    "double-quoted here-string": "cat " + HS + ' "hello"',
    "here-string with a variable": "jq . " + HS + ' "$json"',
    "here-string with '<<' inside single quotes": "cat " + HS + " 'x << y'",
    "unquoted here-string word": "cat " + HS + "word",
    "ordinary here-document": "cat <<EOF\nhello\nEOF\n",
}
for name, command in clean_cases.items():
    rc, result, err = analyze(command)
    check(
        name + ": exit 0, no parser error on stderr",
        rc == 0 and not err,
        "rc=%s stderr=%r" % (rc, err),
    )

# A here-string next to a real here-document with a free-form body: the body
# must be recognised as a heredoc body (placeholder + literal scan), which keeps
# the shell model complete.
mixed = "cat " + HS + " x <<'EOF'\n" + 'if x: print("a {b} \' ")\n' + "EOF\n"
rc, result, err = analyze(mixed)
check(
    "here-string + here-document: shell model stays complete",
    rc == 0 and result.get("shell_model") == "complete" and not err,
    "rc=%s model=%s stderr=%r" % (rc, result.get("shell_model"), err),
)

# Adjacent syntax: a here-document operator glued to the here-string word.
adjacent = "cat " + HS + "word<<EOF\n" + fake_secret + "\nEOF\n"
rc, result, err = analyze(adjacent)
check(
    "here-string word glued to a real here-document: parsed, body scanned, no error",
    rc == 0 and result.get("shell_model") == "complete" and not err and bool(result.get("pattern_ids")),
    "rc=%s model=%s ids=%s stderr=%r" % (rc, result.get("shell_model"), result.get("pattern_ids"), err),
)

# Secret detection must keep covering a heredoc body that follows a here-string.
secret_command = "cat " + HS + " x <<EOF\n" + fake_secret + "\nEOF\n"
rc, result, err = analyze(secret_command)
check(
    "secret in a heredoc body after a here-string is still detected",
    rc == 0 and bool(result.get("pattern_ids")),
    "rc=%s ids=%s" % (rc, result.get("pattern_ids")),
)

# The analyzer's own corpus must carry the new case.
proc = subprocess.run(
    [sys.executable, ANALYZER, "self-test"], input="", capture_output=True, text=True
)
check(
    "analyzer self-test passes and includes here_string_operator",
    proc.returncode == 0 and "PASS here_string_operator" in proc.stdout,
    "rc=%s" % proc.returncode,
)

print("Result: %d FAIL" % len(failures))
sys.exit(1 if failures else 0)
PY
