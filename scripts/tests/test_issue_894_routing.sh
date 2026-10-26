#!/usr/bin/env bash
# issue #894: the routing block was validated in three places with three rule
# sets (generator validate_entry, an embedded copy in route-task.sh --validate,
# nothing in verify-skill.sh). All three now run validate_entry. This test
# feeds the same fixtures through --validate-catalog, --validate-skill,
# route-task.sh --validate and verify-skill.sh and requires equal verdicts.
#
# Usage: test_issue_894_routing.sh [ROUTE_TASK_SH]
# Passing another route-task.sh (e.g. the pre-fix one from origin/main) is the
# negative control: its "missing file" assertion must fail.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ROUTE_TASK="${1:-$ROOT/scripts/route-task.sh}"
GENERATOR="$ROOT/scripts/generate-executor-catalog.py"
VERIFY_SKILL="$ROOT/.claude/skills/skill-creator/scripts/verify-skill.sh"
fail=0
check() { if [ "$2" = ok ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

if ! PYTHON=$("$ROOT/scripts/lib/find-python3.sh" 2>/dev/null); then
    echo "SKIP: no python3 with PyYAML"
    exit 0
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# Disposable template root: template-relative script_path resolves here.
mkdir -p "$T/template/scripts" "$T/iwe/DS-test/scripts" "$T/skills"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/template/scripts/present.sh"

# name|routing YAML lines (two-space indented under routing:)|expected verdict
CASES=(
    "valid-script|  executor: script\n  script_path: scripts/present.sh\n  deterministic: true|pass"
    "no-script-path|  executor: script\n  deterministic: true|fail"
    "missing-file|  executor: script\n  script_path: scripts/absent.sh\n  deterministic: true|fail"
    "det-model|  executor: sonnet\n  deterministic: true|fail"
    "valid-model|  executor: sonnet\n  deterministic: false|pass"
)

verdict() { [ "$1" -eq 0 ] && echo pass || echo fail; }

for case in "${CASES[@]}"; do
    name="${case%%|*}"; rest="${case#*|}"
    routing="${rest%|*}"; expected="${rest##*|}"
    skill="$T/skills/$name"
    mkdir -p "$skill"
    printf -- '---\nname: %s\ndescription: fixture for issue 894\nrouting:\n%b\n---\n\n# %s\n' \
        "$name" "$routing" "$name" > "$skill/SKILL.md"
    catalog="$T/$name.yaml"
    printf 'schema_version: "1.0"\ntotal_entries: 1\nentries:\n  - name: %s\n    routing:\n%b\nreflexes: []\n' \
        "$name" "$(printf '%b' "$routing" | sed 's/^/    /')" > "$catalog"

    "$PYTHON" "$GENERATOR" --validate-catalog "$catalog" --template-root "$T/template" >/dev/null 2>&1
    by_catalog=$(verdict $?)
    "$PYTHON" "$GENERATOR" --validate-skill "$skill" --template-root "$T/template" >/dev/null 2>&1
    by_skill=$(verdict $?)
    [ "$by_catalog" = "$expected" ] && r=ok || r=bad
    check "$name: --validate-catalog → $expected (got $by_catalog)" "$r"
    [ "$by_skill" = "$by_catalog" ] && r=ok || r=bad
    check "$name: --validate-skill agrees with --validate-catalog ($by_skill)" "$r"

    IWE_DIR="$T/iwe" IWE_TEMPLATE="$T/template" IWE_GOVERNANCE_REPO=DS-test \
        IWE_EXECUTOR_CATALOG="$catalog" \
        IWE_ROUTER_AUDIT="$T/audit.tsv" IWE_ROUTER_ERRORS="$T/errors.log" \
        bash "$ROUTE_TASK" --validate >/dev/null 2>&1
    by_router=$(verdict $?)
    [ "$by_router" = "$expected" ] && r=ok || r=bad
    check "$name: route-task.sh --validate → $expected (got $by_router)" "$r"
done

# verify-skill.sh runs the same check for the skill it verifies. Its generic
# checks need markdown-it-py; only the routing line is asserted here, so the
# test does not depend on that optional package.
verify_line() {
    IWE_TEMPLATE='' bash "$VERIFY_SKILL" "$1" "$T/skills" 2>&1 | grep -E '^(PASS|FAIL|SKIP): '"$1"': ' || true
}
out=$(verify_line missing-file)
printf '%s\n' "$out" | grep -q '^FAIL: missing-file: ' && r=ok || r=bad
check "verify-skill.sh reports the routing error of missing-file" "$r"
out=$(verify_line det-model)
printf '%s\n' "$out" | grep -q '^FAIL: det-model: ' && r=ok || r=bad
check "verify-skill.sh reports the routing error of det-model" "$r"

# A skill without a routing block keeps passing (routing is not mandatory yet).
mkdir -p "$T/skills/no-routing"
printf -- '---\nname: no-routing\ndescription: fixture for issue 894\n---\n\n# no-routing\n' \
    > "$T/skills/no-routing/SKILL.md"
"$PYTHON" "$GENERATOR" --validate-skill "$T/skills/no-routing" >/dev/null 2>&1 && r=ok || r=bad
check "skill without routing block passes --validate-skill" "$r"
out=$(verify_line no-routing)
printf '%s\n' "$out" | grep -q '^SKIP: no-routing: ' && r=ok || r=bad
check "verify-skill.sh does not fail a skill without routing block" "$r"

# route-task.sh must fail loudly when no generator can be found, not pass.
mkdir -p "$T/lonely/scripts/lib"
cp "$ROUTE_TASK" "$T/lonely/scripts/route-task.sh"
cp "$ROOT/scripts/lib/common.sh" "$ROOT/scripts/lib/find-python3.sh" "$T/lonely/scripts/lib/"
out=$(IWE_DIR="$T/iwe" IWE_TEMPLATE="$T/template" IWE_GOVERNANCE_REPO=DS-test \
    IWE_EXECUTOR_CATALOG="$T/valid-script.yaml" \
    bash "$T/lonely/scripts/route-task.sh" --validate 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'generate-executor-catalog.py not found'; } && r=ok || r=bad
check "route-task.sh --validate without a generator fails with a clear message" "$r"

exit $fail
