#!/usr/bin/env bash
# Regression coverage for issue #895: .claude/hooks/rule-engine.sh's
# _classify_integration_phase() called integration-gate-classifier.py, a
# file that ships nowhere (not on installs, not in the template tree, not
# in the delivery manifest) -- the only reference to it in the whole
# upstream is this one call site. Degradation was already safe
# (phase:unknown) but silent, reading like almost-working machinery with an
# accidentally missing file rather than a documented stub (#310: the
# machine classifier for AR.013 is intentionally not built yet). Fix: state
# that once per call on stderr; stdout/JSON contract is unchanged.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
HOOK="$ROOT/.claude/hooks/rule-engine.sh"

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

# Extract just the function under test (sed range, same technique as
# test_issue_884_ds_publish_missing.sh) -- never sources/executes the
# whole dispatcher file.
FUNC=$(sed -n '/^_classify_integration_phase() {/,/^}/p' "$HOOK")
if [ -z "$FUNC" ]; then
    fail_test "could not extract _classify_integration_phase() — anchors changed"
    echo "Result: $fail FAIL"
    exit 1
fi

run_with_home() {
    local fake_home="$1"
    bash -c '
        set -e
        HOME="$1"
        '"$FUNC"'
        _classify_integration_phase "{}"
    ' _ "$fake_home"
}

# --- 1. Classifier absent (the real, shipped state): stdout JSON unchanged
# in shape, stderr now names the known-stub reason.
FAKE_HOME=$(mktemp -d)
STDOUT=$(run_with_home "$FAKE_HOME" 2>"$FAKE_HOME/stderr.txt")
STDERR=$(cat "$FAKE_HOME/stderr.txt")
if printf '%s' "$STDOUT" | grep -q '"phase":"unknown"' && printf '%s' "$STDOUT" | grep -q '"skip_detected":false'; then
    pass "classifier absent: stdout JSON contract unchanged (phase:unknown, skip_detected:false)"
else
    fail_test "classifier absent: stdout JSON changed shape: $STDOUT"
fi
if printf '%s' "$STDERR" | grep -q '#310/#895'; then
    pass "classifier absent: stderr names the known-stub reason (#310/#895)"
else
    fail_test "classifier absent: stderr does not explain the missing file: $STDERR"
fi
rm -rf "$FAKE_HOME"

# --- 2. Classifier present: no stub warning, real output passed through
# unchanged (the fix must not fire on a real install of the classifier).
FAKE_HOME2=$(mktemp -d)
mkdir -p "$FAKE_HOME2/IWE/.claude/scripts"
cat > "$FAKE_HOME2/IWE/.claude/scripts/integration-gate-classifier.py" <<'PY'
#!/usr/bin/env python3
print('{"phase":"promise","skip_detected":false,"reason":"real classifier ran","missing":[]}')
PY
chmod +x "$FAKE_HOME2/IWE/.claude/scripts/integration-gate-classifier.py"
STDOUT2=$(run_with_home "$FAKE_HOME2" 2>"$FAKE_HOME2/stderr.txt")
STDERR2=$(cat "$FAKE_HOME2/stderr.txt")
if printf '%s' "$STDOUT2" | grep -q '"phase":"promise"'; then
    pass "classifier present: real classifier output passed through"
else
    fail_test "classifier present: real classifier output not used: $STDOUT2"
fi
if printf '%s' "$STDERR2" | grep -q '#310/#895'; then
    fail_test "classifier present: stub warning fired even though the classifier exists"
else
    pass "classifier present: no stub warning (only fires when the file is actually missing)"
fi
rm -rf "$FAKE_HOME2"

if [ "$fail" -eq 0 ]; then
    echo "✅ All checks passed (issue #895)"
fi
exit "$fail"
