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
    # Executor classes (steps 4-5): model names stay as values, the rules
    # apply per class — script / model / script+model.
    "class-model-opus|  executor: opus\n  deterministic: false|pass"
    "class-model-haiku-det|  executor: haiku\n  deterministic: true|fail"
    "class-agent-model|  executor: agent\n  model: sonnet\n  deterministic: false|pass"
    "class-agent-no-model|  executor: agent\n  deterministic: false|fail"
    "class-agent-det|  executor: agent\n  model: haiku\n  deterministic: true|fail"
    "class-mcp-direct-det|  executor: mcp-direct\n  deterministic: true|pass"
    "class-unknown-model-word|  executor: model\n  deterministic: false|fail"
    "mixed-with-step|  executor: script+judgment\n  deterministic: false\n  model_step: step 2 judges the findings|pass"
    "mixed-no-step|  executor: script+judgment\n  deterministic: false|fail"
    "mixed-empty-step|  executor: script+judgment\n  deterministic: false\n  model_step: '  '|fail"
    "mixed-list-step|  executor: script+judgment\n  deterministic: false\n  model_step: [a, b]|fail"
    "mixed-det|  executor: script+judgment\n  deterministic: true\n  model_step: step 2|fail"
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

# The routing block is mandatory (steps 4-5): a skill without one fails with
# the path of its SKILL.md in the message, in --validate-skill and verify-skill.sh.
mkdir -p "$T/skills/no-routing"
printf -- '---\nname: no-routing\ndescription: fixture for issue 894\n---\n\n# no-routing\n' \
    > "$T/skills/no-routing/SKILL.md"
out=$("$PYTHON" "$GENERATOR" --validate-skill "$T/skills/no-routing" 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "$T/skills/no-routing/SKILL.md" \
    && printf '%s\n' "$out" | grep -q 'mandatory'; } && r=ok || r=bad
check "skill without routing block fails --validate-skill, message names its SKILL.md" "$r"
out=$(verify_line no-routing)
printf '%s\n' "$out" | grep -q '^FAIL: no-routing: ' && r=ok || r=bad
check "verify-skill.sh fails a skill without routing block" "$r"

# A routing block that is not a YAML mapping is reported as such, not as absent.
mkdir -p "$T/skills/bad-yaml"
printf -- '---\nname: bad-yaml\ndescription: fixture for issue 894\nrouting:\n  executor: [sonnet\n---\n\n# bad-yaml\n' \
    > "$T/skills/bad-yaml/SKILL.md"
out=$("$PYTHON" "$GENERATOR" --validate-skill "$T/skills/bad-yaml" 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'not a valid YAML mapping'; } && r=ok || r=bad
check "unparseable routing block fails --validate-skill as invalid YAML" "$r"

# A trailing comment after "routing:" is still the routing block.
mkdir -p "$T/skills/commented"
printf -- '---\nname: commented\ndescription: fixture for issue 894\nrouting:  # who runs it\n  executor: sonnet\n  deterministic: false\n---\n\n# commented\n' \
    > "$T/skills/commented/SKILL.md"
"$PYTHON" "$GENERATOR" --validate-skill "$T/skills/commented" 2>/dev/null | grep -q "^PASS: commented:" && r=ok || r=bad
check "routing: with a trailing comment is parsed" "$r"

# Every shipped skill passes --validate-skill (the same check CI runs on a
# changed SKILL.md), so making the block mandatory broke nothing in delivery.
shipped_fail=""
for skill_md in "$ROOT"/.claude/skills/*/SKILL.md; do
    dir="$(dirname "$skill_md")"
    "$PYTHON" "$GENERATOR" --validate-skill "$dir" --template-root "$ROOT" >/dev/null 2>&1 \
        || shipped_fail="$shipped_fail $(basename "$dir")"
done
[ -z "$shipped_fail" ] && r=ok || r=bad
check "every shipped skill passes --validate-skill${shipped_fail:+ (failed:$shipped_fail)}" "$r"

# Both skill-creator scaffolds carry a routing block the creator must fill:
# rendered without a choice (executor TODO) they fail, with one they pass.
SCAFFOLD_INIT="$ROOT/.claude/skills/skill-creator/scripts/scaffold-init.sh"
for kind in minimal full; do
    full_flag=""; [ "$kind" = full ] && full_flag="--full"
    grep -q '^routing:$' "$ROOT/.claude/skills/skill-creator/assets/skill-scaffold-$kind.md" && r=ok || r=bad
    check "skill-scaffold-$kind.md has a routing block" "$r"
    bash "$SCAFFOLD_INIT" --name "todo-$kind" $full_flag --gates-rationale fixture \
        --target "$T/scaffold/todo-$kind/SKILL.md" >/dev/null 2>&1
    "$PYTHON" "$GENERATOR" --validate-skill "$T/scaffold/todo-$kind" >/dev/null 2>&1 && r=bad || r=ok
    check "$kind scaffold without --executor fails --validate-skill (placeholder TODO)" "$r"
    bash "$SCAFFOLD_INIT" --name "mixed-$kind" $full_flag --gates-rationale fixture \
        --executor script+judgment --model-step 'step 2: "judge" findings' \
        --target "$T/scaffold/mixed-$kind/SKILL.md" >/dev/null 2>&1
    "$PYTHON" "$GENERATOR" --validate-skill "$T/scaffold/mixed-$kind" >/dev/null 2>&1 && r=ok || r=bad
    check "$kind scaffold with --executor script+judgment --model-step passes" "$r"
done

# The authoring template (_template) carries an example routing block but is
# not a routable skill: the catalog build skips it instead of listing skill-id.
catalog_out="$T/shipped-catalog.yaml"
"$PYTHON" "$GENERATOR" --skills-dir "$ROOT/.claude/skills" --output "$catalog_out" \
    --template-root "$ROOT" >/dev/null 2>&1
"$PYTHON" - "$catalog_out" <<'PY' && r=ok || r=bad
import sys, yaml
catalog = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
names = {entry["name"] for entry in catalog["entries"]}
skipped = {item["name"]: item["skip_reason"] for item in catalog["skipped"]}
sys.exit(0 if "skill-id" not in names and skipped.get("_template") == "template" else 1)
PY
check "catalog build skips _template as a template, not as a skill" "$r"

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
