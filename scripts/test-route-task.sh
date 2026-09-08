#!/usr/bin/env bash
# test-route-task.sh — изолированные regression-кейсы для route-task.sh (WP-350 Ф14)
# routing: executor=script deterministic=true
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${1:-$SCRIPT_DIR/route-task.sh}"

# The harness must never dispatch into the installed workspace: a historical
# T13 invocation wrote an agent_fault row to the live governance database.
# Every catalog, script and router log below belongs to this disposable root.
HARNESS_TMP=$(mktemp -d)
trap 'rm -rf "$HARNESS_TMP"' EXIT
FIXTURE_IWE="$HARNESS_TMP/iwe"
FIXTURE_GOV="DS-test"
mkdir -p "$FIXTURE_IWE/scripts" "$FIXTURE_IWE/$FIXTURE_GOV/scripts" "$FIXTURE_IWE/$FIXTURE_GOV/logs"

cat > "$FIXTURE_IWE/scripts/consent-fixture.sh" <<'SH'
#!/usr/bin/env bash
exit 2
SH
cat > "$FIXTURE_IWE/scripts/agent-fault-fixture.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "record" ]] || exit 64
args=" $* "
[[ "$args" == *" --subject-kind runtime "* ]] || exit 64
[[ "$args" == *" --subject-id route-task-test "* ]] || exit 64
[[ "$args" == *" --fault=test "* ]] || exit 64
exit 0
SH
chmod +x "$FIXTURE_IWE/scripts/consent-fixture.sh" "$FIXTURE_IWE/scripts/agent-fault-fixture.sh"

cat > "$FIXTURE_IWE/$FIXTURE_GOV/scripts/executor-catalog.yaml" <<'YAML'
schema_version: '1.0'
generated_at: '2026-08-24T00:00:00Z'
total_entries: 3
entries:
  - name: consent
    routing:
      executor: script
      script_path: scripts/consent-fixture.sh
      deterministic: true
  - name: connect-guide
    routing:
      executor: script
      script_path: scripts/intentionally-missing.sh
      deterministic: true
  - name: agent-fault
    routing:
      executor: script
      script_path: scripts/agent-fault-fixture.sh
      deterministic: true
YAML

export IWE_DIR="$FIXTURE_IWE"
export IWE_GOVERNANCE_REPO="$FIXTURE_GOV"
export IWE_EXECUTOR_CATALOG="$FIXTURE_IWE/$FIXTURE_GOV/scripts/executor-catalog.yaml"
export IWE_ROUTER_AUDIT="$FIXTURE_IWE/$FIXTURE_GOV/logs/routing-path-distribution.tsv"
export IWE_ROUTER_ERRORS="$FIXTURE_IWE/$FIXTURE_GOV/logs/routing-errors.log"

PASS=0
FAIL=0

run_test() {
    local name="$1" expected="$2"
    shift 2
    echo "=== $name ==="
    set +e
    bash "$SCRIPT" "$@" >/dev/null 2>&1
    local actual=$?
    set -e
    if [[ "$actual" -eq "$expected" ]]; then
        echo "PASS (exit $actual)"
        ((PASS++)) || true
    else
        echo "FAIL: expected exit $expected, got $actual"
        ((FAIL++)) || true
    fi
    echo ""
}

# 1. Known script skill (consent) — script exists, fails on env var (exit from script, not router)
run_test "T1: --skill consent (script exists, router dispatches correctly)" 2 --skill consent

# 2. Unknown skill — strict (--skill)
run_test "T2: --skill unknown_skill (strict → exit 3)" 3 --skill unknown_skill

# 3. Unknown skill — flex (--tag)
run_test "T3: --tag unknown_skill (flex → fallback Sonnet, exit 0)" 0 --tag unknown_skill

# 4. Missing script — strict (--skill)
run_test "T4: --skill connect-guide (missing script → exit 2)" 2 --skill connect-guide

# 5. Missing script — flex (--tag)
run_test "T5: --tag connect-guide (missing script → fallback Haiku, exit 0)" 0 --tag connect-guide

# 6. Empty tag
run_test "T6: --tag '' (empty → unknown → fallback Sonnet, exit 0)" 0 --tag ""

# 7. --list
run_test "T7: --list (exit 0)" 0 --list

# 8. --validate
run_test "T8: --validate (exit 0)" 0 --validate

# 9. Broken YAML catalog → exit 1 (error)
echo "=== T9: broken YAML catalog → exit 1 ==="
TMP_CATALOG=$(mktemp)
echo "broken: [" > "$TMP_CATALOG"
set +e
IWE_EXECUTOR_CATALOG="$TMP_CATALOG" bash "$SCRIPT" --skill consent >/dev/null 2>&1
actual=$?
set -e
rm -f "$TMP_CATALOG"
if [[ "$actual" -eq 1 ]]; then
    echo "PASS (exit $actual)"
    ((PASS++)) || true
else
    echo "FAIL: expected exit 1, got $actual"
    ((FAIL++)) || true
fi
echo ""

# 10. A yaml-less first PATH candidate must fall through to the shared resolver.
echo "=== T10: first python3 lacks PyYAML → resolver falls through ==="
TMP_DIR=$(mktemp -d)
cat > "$TMP_DIR/python3" << 'FAKEPY'
#!/usr/bin/env bash
if [[ "$1" == "-c" && "$2" == "import yaml" ]]; then
    exit 1
fi
exit 0
FAKEPY
chmod +x "$TMP_DIR/python3"
set +e
PATH="$TMP_DIR:$PATH" bash "$SCRIPT" --skill consent >/dev/null 2>&1
actual=$?
set -e
rm -rf "$TMP_DIR"
if [[ "$actual" -eq 2 ]]; then
    echo "PASS (exit $actual)"
    ((PASS++)) || true
else
    echo "FAIL: expected dispatched fixture exit 2 after resolver fallback, got $actual"
    ((FAIL++)) || true
fi
echo ""

# 11. JSON mode — NO_MATCH
run_test "T11: --json --skill unknown (strict → NO_MATCH, exit 3)" 3 --json --skill unknown_skill

# 12. JSON mode — OK fallback
run_test "T12: --json --tag unknown (flex → OK, exit 0)" 0 --json --tag unknown_skill

# 13. AGENT_FAULT routing stays inside the fixture; subject identity is
# mandatory and the fake executor rejects an incomplete invocation.
run_test "T13: --skill agent-fault (isolated script, no live DB)" 0 \
    --skill agent-fault \
    --args "record --severity major --fault=test --subject-kind runtime --subject-id route-task-test"

# 14. Path-resolution via IWE_DIR
echo "=== T14: IWE_DIR path-resolution ==="
TMP_IWE=$(mktemp -d)
mkdir -p "$TMP_IWE/scripts" "$TMP_IWE/DS-alt/scripts" "$TMP_IWE/logs"
cp "$FIXTURE_IWE/scripts/consent-fixture.sh" "$TMP_IWE/scripts/"
cat > "$TMP_IWE/DS-alt/scripts/executor-catalog.yaml" <<'YAML'
schema_version: '1.0'
generated_at: '2026-08-24T00:00:00Z'
total_entries: 1
entries:
  - name: consent
    routing:
      executor: script
      script_path: scripts/consent-fixture.sh
      deterministic: true
YAML
set +e
IWE_DIR="$TMP_IWE" \
IWE_GOVERNANCE_REPO="DS-alt" \
IWE_EXECUTOR_CATALOG="$TMP_IWE/DS-alt/scripts/executor-catalog.yaml" \
IWE_ROUTER_AUDIT="$TMP_IWE/logs/audit.tsv" \
IWE_ROUTER_ERRORS="$TMP_IWE/logs/errors.log" \
    bash "$SCRIPT" --skill consent --args "status" >/dev/null 2>&1
actual=$?
set -e
rm -rf "$TMP_IWE"
if [[ "$actual" -eq 2 ]]; then
    echo "PASS (exit $actual — script found via IWE_DIR, failed on env as expected)"
    ((PASS++)) || true
else
    echo "FAIL: expected exit 2 (script found, env missing), got $actual"
    ((FAIL++)) || true
fi
echo ""

# 15-17. The generator's compound executor taxonomy must be executable by the
# consumer, not merely accepted into a catalog that route-task cannot use.
echo "=== T15-T17: agent and script+judgment executor modes ==="
TMP_MODE_CATALOG=$(mktemp)
cat > "$TMP_MODE_CATALOG" <<'YAML'
schema_version: '1.0'
generated_at: '2026-08-24T00:00:00Z'
total_entries: 2
entries:
  - name: agent-mode
    routing:
      executor: agent
      model: sonnet
      deterministic: false
  - name: hybrid-mode
    routing:
      executor: script+judgment
      deterministic: false
YAML
if IWE_EXECUTOR_CATALOG="$TMP_MODE_CATALOG" bash "$SCRIPT" --validate >/dev/null 2>&1; then
    echo "PASS: generated taxonomy validates"
    ((PASS++)) || true
else
    echo "FAIL: generated taxonomy rejected"
    ((FAIL++)) || true
fi
AGENT_MODE_OUT=$(IWE_EXECUTOR_CATALOG="$TMP_MODE_CATALOG" \
    bash "$SCRIPT" --skill agent-mode 2>&1 || true)
if echo "$AGENT_MODE_OUT" | grep -q 'ROUTE_TO_AGENT skill=agent-mode model=sonnet'; then
    echo "PASS: agent executor preserves its declared model"
    ((PASS++)) || true
else
    echo "FAIL: agent executor output: $AGENT_MODE_OUT"
    ((FAIL++)) || true
fi
HYBRID_MODE_OUT=$(IWE_EXECUTOR_CATALOG="$TMP_MODE_CATALOG" \
    bash "$SCRIPT" --skill hybrid-mode 2>&1 || true)
if echo "$HYBRID_MODE_OUT" | grep -q 'ROUTE_TO_JUDGMENT skill=hybrid-mode mode=script+judgment'; then
    echo "PASS: script+judgment executor routes to the judgment layer"
    ((PASS++)) || true
else
    echo "FAIL: script+judgment executor output: $HYBRID_MODE_OUT"
    ((FAIL++)) || true
fi
rm -f "$TMP_MODE_CATALOG"
echo ""

echo "========================"
echo "PASS: $PASS  FAIL: $FAIL"
exit $FAIL
