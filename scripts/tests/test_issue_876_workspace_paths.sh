#!/usr/bin/env bash
# Regression coverage for issue #876: agent-instruction markdown must not
# hardcode the workspace path. check-hardcoded-workspace-md.py is the gate;
# this test pins its behaviour and runs it on the real tree.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
CHECK="$ROOT/scripts/check-hardcoded-workspace-md.py"
PY=$(command -v python3 || command -v python)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

run() { "$PY" -I "$CHECK" --root "$1" 2>&1; }

mkdir -p "$TMP/clean/.claude/skills/x" "$TMP/dirty/.claude/skills/x" "$TMP/docs-only/docs"

# parameterized form, and the lines that talk ABOUT hardcoding, are accepted
cat > "$TMP/clean/.claude/skills/x/SKILL.md" <<'EOF'
```bash
bash "${IWE_WORKSPACE:-$HOME/IWE}/scripts/x.sh"
```
Не хардкодить `~/IWE/scripts/x.sh`.
EOF
out=$(run "$TMP/clean"); rc=$?
[ "$rc" = 0 ] && pass "parameterized form and explanatory lines are accepted" || fail_test "clean tree rejected: $out"

# a literal path in a skill is a violation, named by file and line
cat > "$TMP/dirty/.claude/skills/x/SKILL.md" <<'EOF'
Шаг 1
```bash
cd ~/IWE/DS-strategy && git status
```
EOF
out=$(run "$TMP/dirty"); rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'SKILL.md:3:'; then
    pass "literal ~/IWE in a skill is reported with file and line"
else
    fail_test "violation not reported (rc=$rc): $out"
fi

# user guides are out of scope: there ~/IWE is the instruction "create it here"
echo 'mkdir -p ~/IWE' > "$TMP/docs-only/docs/SETUP.md"
out=$(run "$TMP/docs-only"); rc=$?
[ "$rc" = 0 ] && pass "docs/ is out of scope" || fail_test "docs/ flagged: $out"

# the real tree is clean
out=$(run "$ROOT"); rc=$?
[ "$rc" = 0 ] && pass "real tree has no hardcoded workspace path in instructions" || fail_test "real tree: $out"

exit $fail
