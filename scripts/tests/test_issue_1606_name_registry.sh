#!/usr/bin/env bash
# Registry Gate of create-wp.sh (issue #1606).
#
# The Artifactor skill (step 2.2) names create-wp.sh as the lock that checks a new WP name
# against the concept-kinds registry of PACK-digital-platform, and artifactor.py
# --check-registry loads scripts/concept-kind.py. 0.42.0 shipped the skill and artifactor.py
# but neither concept-kind.py nor the gate in create-wp.sh: with the Pack installed the check
# answered REGISTRY_BLOCK, and the flags the skill names (--name-kind*, --registry-waiver)
# were unknown to create-wp.sh.
#
# Each case gets a fresh copy of seed/strategy and its own IWE_ROOT. A refusal must leave
# no trace: no inbox folder, no number reservation, REGISTRY untouched. The Pack is a small
# fixture registry, not the author's real one.
#
# Bash 3.2 compatible. Usage: bash scripts/tests/test_issue_1606_name_registry.sh

set -uo pipefail

TEMPLATE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CREATE_WP="$TEMPLATE_ROOT/scripts/create-wp.sh"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
export TMPDIR
export HOME="$TMPDIR/home"
mkdir -p "$HOME"
export IWE_GOVERNANCE_REPO="strategy"
unset CONCEPT_KINDS_REGISTRY IWE_AGENT STYLE_AGENT

# The same Python finder as create-wp.sh uses: the registry needs PyYAML.
if ! bash "$TEMPLATE_ROOT/scripts/lib/find-python3.sh" >/dev/null 2>&1; then
  echo "SKIP: no Python with PyYAML is available, the registry cannot be read"
  exit 0
fi

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

# new_case [with-pack]: fresh IWE_ROOT with its own copy of seed/strategy (+ a fixture Pack).
CASE=0
CASE_ROOT=""
new_case() {
  CASE=$((CASE + 1))
  CASE_ROOT="$TMPDIR/case-$CASE"
  mkdir -p "$CASE_ROOT"
  cp -R "$TEMPLATE_ROOT/seed/strategy" "$CASE_ROOT/strategy"
  cp "$CASE_ROOT/strategy/docs/WP-REGISTRY.md" "$CASE_ROOT/registry.before"
  export IWE_ROOT="$CASE_ROOT"
  if [ "${1:-}" = "with-pack" ]; then
    mkdir -p "$CASE_ROOT/PACK-digital-platform/pack/digital-platform"
    cat > "$CASE_ROOT/PACK-digital-platform/pack/digital-platform/concept-kinds-registry.yaml" <<'YAML'
schema_version: 1
kinds:
  - {id: system, name: система, test: "Это работающая система?"}
  - {id: description, name: описание, test: "Это утверждения о предмете?"}
  - {id: document, name: документ, test: "Это носитель описания?"}
  - {id: work_plan, name: "план работ", test: "Это план работ?"}
  - {id: collection, name: набор, test: "Это набор?"}
  - {id: method, name: метод, test: "Это способ действия?"}
  - {id: ambiguous, name: неоднозначное, test: "Слово неоднозначно?"}
terms:
  - {term: сервер, kind: system, stems: [сервер], status: pilot, basis: fixture}
  - {term: протокол, kind: description, stems: [протокол], status: pilot, basis: fixture}
  - {term: библиотека, kind: ambiguous, stems: [библиотек], status: pilot, basis: fixture}
YAML
  fi
}

# result_json <artifact> <system|episteme>: writes the Artifactor result, prints its path
result_json() {
  local path="$CASE_ROOT/result.json"
  printf '{"schema_version":3,"artifact":"%s","resolution_path":"keyword","result_type":"%s"}' "$1" "$2" > "$path"
  printf '%s' "$path"
}

OUT=""
RC=0
run_create() {
  OUT=$(bash "$CREATE_WP" --budget 1h --priority P4 --verification-class closed-loop \
    --no-consent-check "$@" 2>&1)
  RC=$?
}

expect_refused() {
  local label="$1" fragment="$2" wp_dirs
  if [ "$RC" -eq 1 ]; then pass "$label: exit 1"; else fail "$label: expected exit 1, got $RC; output: $OUT"; fi
  if grep -qF -- "$fragment" <<<"$OUT"; then
    pass "$label: names the reason ($fragment)"
  else
    fail "$label: message fragment '$fragment' missing; output: $OUT"
  fi
  wp_dirs=$(find "$CASE_ROOT/strategy/inbox" -mindepth 1 -maxdepth 1 -type d -name 'WP-*' | wc -l | tr -d ' ')
  if [ "$wp_dirs" -eq 0 ] && [ ! -e "$CASE_ROOT/.claude/state/wp-numbers" ] \
    && cmp -s "$CASE_ROOT/registry.before" "$CASE_ROOT/strategy/docs/WP-REGISTRY.md"; then
    pass "$label: refused before any write"
  else
    fail "$label: the gate must refuse before writing anything (WP folders: $wp_dirs)"
  fi
}

# expect_created <label> <registry_check value>: checks exit code, the card and its source line
WP_FILE=""
expect_created() {
  local label="$1" source="$2" cards
  if [ "$RC" -eq 0 ]; then pass "$label: exit 0"; else fail "$label: expected exit 0, got $RC; output: $OUT"; fi
  WP_FILE=$(find "$CASE_ROOT/strategy/inbox" -type f -name 'WP-*.md' | sed -n 1p)
  cards=$(find "$CASE_ROOT/strategy/inbox" -type f -name 'WP-*.md' | wc -l | tr -d ' ')
  if [ "$cards" -eq 1 ]; then pass "$label: exactly one card created"; else fail "$label: expected one card, found $cards"; fi
  if [ -n "$WP_FILE" ] && grep -qxF "registry_check: \"$source\"" "$WP_FILE"; then
    pass "$label: card records registry_check: \"$source\""
  else
    fail "$label: card lacks registry_check: \"$source\" (file: ${WP_FILE:-none})"
  fi
}

echo "=== 1. no Pack installed: the check is skipped and the card says so ==="
new_case
run_create --artifactor-result "$(result_json "Сервер заказов" system)"
expect_created "no pack" "no-pack"

echo "=== 1b. no Pack, result without result_type: still created (artifactor.py alone would refuse it) ==="
new_case
printf '{"schema_version":3,"artifact":"Имя без типа результата","resolution_path":"keyword"}' > "$CASE_ROOT/result.json"
run_create --artifactor-result "$CASE_ROOT/result.json"
expect_created "no pack, no result_type" "no-pack"

echo "=== 1c. Pack installed, result without result_type: refused, the Pack user must see why ==="
new_case with-pack
printf '{"schema_version":3,"artifact":"Имя без типа результата","resolution_path":"keyword"}' > "$CASE_ROOT/result.json"
run_create --artifactor-result "$CASE_ROOT/result.json"
expect_refused "pack, no result_type" "тип результата"

echo "=== 1d. no Pack, --producer is still recorded in the card ==="
new_case
run_create --artifactor-result "$(result_json "Сервер заказов" system)" --producer "ops team"
expect_created "no pack, producer" "no-pack"
if grep -qxF 'producer: "ops team"' "$WP_FILE"; then pass "producer: written into the card"; else fail "producer: missing in the card"; fi

echo "=== 2. Pack installed, the registry knows the word and the kind fits ==="
new_case with-pack
run_create --artifactor-result "$(result_json "Сервер заказов" system)"
expect_created "registry hit" "registry"

echo "=== 3. Pack installed, the kind of the word contradicts the result type ==="
new_case with-pack
run_create --artifactor-result "$(result_json "Сервер заказов" episteme)"
expect_refused "kind conflict" "Registry Gate"

echo "=== 4. the same conflict with --registry-waiver: created, waiver recorded ==="
new_case with-pack
run_create --artifactor-result "$(result_json "Сервер заказов" episteme)" --registry-waiver "pilot allowed it"
expect_created "waiver" "waived"
if grep -qxF 'registry_waiver_reason: "pilot allowed it"' "$WP_FILE"; then
  pass "waiver: the reason is written into the card"
else
  fail "waiver: reason missing in the card"
fi

echo "=== 4b. a waiver made only of whitespace is not a reason ==="
new_case with-pack
run_create --artifactor-result "$(result_json "Сервер заказов" episteme)" --registry-waiver "$(printf ' \t ')"
expect_refused "blank waiver" "Registry Gate"

echo "=== 5. a word the registry does not know: refused, then accepted with the AI answer ==="
new_case with-pack
run_create --artifactor-result "$(result_json "Фреза станка" system)"
expect_refused "unknown word" "Registry Gate"
new_case with-pack
run_create --artifactor-result "$(result_json "Фреза станка" system)" \
  --name-kind system --name-kind-answer "it is a working machine part"
expect_created "ai answer" "ai"

echo "=== 5b. the AI is unsure: the pilot must decide ==="
new_case with-pack
run_create --artifactor-result "$(result_json "Фреза станка" system)" \
  --name-kind system --name-kind-answer "probably a machine part" --name-kind-unsure
expect_refused "unsure" "решение пилота"

echo "=== 6. a kind the registry does not have: refused even with an answer ==="
new_case with-pack
run_create --artifactor-result "$(result_json "Фреза станка" system)" \
  --name-kind spaceship --name-kind-answer "whatever"
expect_refused "unknown kind" "Registry Gate"

echo "=== 7. an ambiguous word needs the pilot: asks, then accepts the pilot's decision ==="
new_case with-pack
run_create --artifactor-result "$(result_json "Библиотека методов" episteme)" \
  --name-kind collection --name-kind-answer "a set of documents"
expect_refused "ambiguous word" "решение пилота"
new_case with-pack
run_create --artifactor-result "$(result_json "Библиотека методов" episteme)" \
  --name-kind collection --name-kind-answer "a set of documents" --name-kind-pilot "collection, confirmed"
expect_created "pilot decision" "pilot"

echo "=== 8. emergency bypass of the Artifactor leaves a mark in the card ==="
new_case
run_create --title "Аварийное имя" --no-artifactor-check
expect_created "skipped" "skipped"

echo
echo "Passed: $PASS_COUNT, failed: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
