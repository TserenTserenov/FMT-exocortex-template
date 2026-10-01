#!/usr/bin/env bash
# Artifactor Gate contract for create-wp.sh (WP-7 Ф142, 2026-09-11; issue #956).
#
# The gate runs BEFORE every other check and before anything is written: a new WP
# must carry the Artifactor result (--artifactor-result), its title comes from the
# result's "artifact" field, and the only ways around it are an explicit
# --pilot-revision (the title differs on purpose) or the emergency
# --no-artifactor-check. The other create_wp tests pass --no-artifactor-check so
# that they exercise the gate they are about; this test owns the gate itself.
#
# Fixtures are inline (no shared helper): every case gets a fresh copy of
# seed/strategy and its own IWE_ROOT, so WP numbers and state markers never leak
# between cases. A refusal must be specific (exit 1 plus the gate's own message)
# and leave no trace: no inbox folder, no number reservation, REGISTRY untouched.
#
# Bash 3.2 compatible. Usage: bash scripts/tests/test_create_wp_artifactor_gate.sh

set -uo pipefail

# Template root comes from this file's own location, never from $HOME (CI checks
# the repository out elsewhere); HOME and TMPDIR stay inside the test's temp dir.
TEMPLATE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CREATE_WP="$TEMPLATE_ROOT/scripts/create-wp.sh"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
export TMPDIR
export HOME="$TMPDIR/home"
mkdir -p "$HOME"
export IWE_GOVERNANCE_REPO="strategy"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

sha256_of() {
  { shasum -a 256 "$1" 2>/dev/null || sha256sum "$1" 2>/dev/null; } | cut -d' ' -f1
}

# new_case: fresh IWE_ROOT with its own copy of seed/strategy.
CASE=0
CASE_ROOT=""
new_case() {
  CASE=$((CASE + 1))
  CASE_ROOT="$TMPDIR/case-$CASE"
  mkdir -p "$CASE_ROOT"
  cp -R "$TEMPLATE_ROOT/seed/strategy" "$CASE_ROOT/strategy"
  cp "$CASE_ROOT/strategy/docs/WP-REGISTRY.md" "$CASE_ROOT/registry.before"
  export IWE_ROOT="$CASE_ROOT"
}

# run_create <extra create-wp args...>: sets OUT (stdout+stderr) and RC.
OUT=""
RC=0
run_create() {
  OUT=$(bash "$CREATE_WP" --budget 1h --priority P4 --verification-class closed-loop \
    --no-consent-check "$@" 2>&1)
  RC=$?
}

# expect_refused <label> <fragment of the gate's message>
expect_refused() {
  local label="$1" fragment="$2" wp_dirs
  if [ "$RC" -eq 1 ]; then
    pass "$label: exit 1"
  else
    fail "$label: expected exit 1, got $RC; output: $OUT"
  fi
  if grep -qF -- "$fragment" <<<"$OUT"; then
    pass "$label: names the reason ($fragment)"
  else
    fail "$label: message fragment '$fragment' missing; output: $OUT"
  fi
  wp_dirs=$(find "$CASE_ROOT/strategy/inbox" -mindepth 1 -maxdepth 1 -type d -name 'WP-*' | wc -l | tr -d ' ')
  if [ "$wp_dirs" -eq 0 ] && [ ! -e "$CASE_ROOT/.claude/state/wp-numbers" ] \
    && cmp -s "$CASE_ROOT/registry.before" "$CASE_ROOT/strategy/docs/WP-REGISTRY.md"; then
    pass "$label: refused before any write (no WP folder, no number reserved, REGISTRY untouched)"
  else
    fail "$label: the gate must refuse before writing anything (WP folders: $wp_dirs)"
  fi
}

# expect_created <label> <expected title>: sets WP_FILE to the new context file.
WP_FILE=""
expect_created() {
  local label="$1" title="$2"
  if [ "$RC" -eq 0 ]; then
    pass "$label: exit 0"
  else
    fail "$label: expected exit 0, got $RC; output: $OUT"
  fi
  WP_FILE=$(find "$CASE_ROOT/strategy/inbox" -type f -name 'WP-*.md' | sed -n 1p)
  if [ -n "$WP_FILE" ] && grep -qxF "title: \"$title\"" "$WP_FILE"; then
    pass "$label: context file carries title \"$title\""
  else
    fail "$label: no context file with title \"$title\" (file: ${WP_FILE:-none})"
  fi
  if grep -qF "**$title**" "$CASE_ROOT/strategy/docs/WP-REGISTRY.md"; then
    pass "$label: REGISTRY row written"
  else
    fail "$label: REGISTRY has no row for \"$title\""
  fi
}

# expect_frontmatter <label> <exact frontmatter line>
expect_frontmatter() {
  if [ -n "$WP_FILE" ] && grep -qxF -- "$2" "$WP_FILE"; then
    pass "$1: frontmatter has $2"
  else
    fail "$1: frontmatter line missing: $2"
  fi
}

RESULT_NAME="Имя из Артефактора"
VALID_RESULT="{\"schema_version\":3,\"artifact\":\"$RESULT_NAME\",\"resolution_path\":\"keyword\"}"

echo "=== 1. no Artifactor result and no bypass → refused by the gate ==="
new_case
run_create --title "Имя без Артефактора"
expect_refused "no result" "нет результата Артефактора"

echo "=== 2. result file does not exist → refused ==="
new_case
run_create --artifactor-result "$CASE_ROOT/missing.json"
expect_refused "missing file" "файл не найден"

echo "=== 3. malformed or unusable result → refused ==="
new_case
printf '%s' 'not json at all' > "$CASE_ROOT/result.json"
run_create --artifactor-result "$CASE_ROOT/result.json"
expect_refused "malformed JSON" "не читается или не JSON"

new_case
printf '%s' '["artifact"]' > "$CASE_ROOT/result.json"
run_create --artifactor-result "$CASE_ROOT/result.json"
expect_refused "JSON array" "верхний уровень JSON не объект"

new_case
printf '%s' '{"schema_version":3,"artifact":"","resolution_path":"keyword"}' > "$CASE_ROOT/result.json"
run_create --artifactor-result "$CASE_ROOT/result.json"
expect_refused "empty artifact" "поле 'artifact' пустое или не строка"

new_case
printf '%s' '{"schema_version":3,"resolution_path":"keyword"}' > "$CASE_ROOT/result.json"
run_create --artifactor-result "$CASE_ROOT/result.json"
expect_refused "missing artifact" "поле 'artifact' пустое или не строка"

new_case
printf '%s' '{"schema_version":3,"artifact":42,"resolution_path":"keyword"}' > "$CASE_ROOT/result.json"
run_create --artifactor-result "$CASE_ROOT/result.json"
expect_refused "non-string artifact" "поле 'artifact' пустое или не строка"

new_case
printf '%s' '{"schema_version":3,"artifact":"Первая строка\nВторая строка","resolution_path":"keyword"}' > "$CASE_ROOT/result.json"
run_create --artifactor-result "$CASE_ROOT/result.json"
expect_refused "multi-line artifact" "содержит перевод строки"

echo "=== 4. --title differs from the result's artifact → refused without --pilot-revision ==="
new_case
printf '%s' "$VALID_RESULT" > "$CASE_ROOT/result.json"
run_create --artifactor-result "$CASE_ROOT/result.json" --title "Другое имя"
expect_refused "title mismatch" "расходится с результатом Артефактора"

echo "=== 5. --pilot-revision lets a deliberately different title through ==="
new_case
printf '%s' "$VALID_RESULT" > "$CASE_ROOT/result.json"
run_create --artifactor-result "$CASE_ROOT/result.json" --title "Другое имя" \
  --pilot-revision "пилот уточнил формулировку"
expect_created "pilot revision" "Другое имя"
expect_frontmatter "pilot revision" 'pilot_revision: "пилот уточнил формулировку"'
expect_frontmatter "pilot revision" 'artifactor_resolution_path: "keyword"'
expect_frontmatter "pilot revision" "artifactor_result_sha256: \"$(sha256_of "$CASE_ROOT/result.json")\""

echo "=== 6. --no-artifactor-check is the explicit emergency bypass ==="
new_case
run_create --title "Имя в обход" --no-artifactor-check
expect_created "bypass" "Имя в обход"
expect_frontmatter "bypass" 'artifactor_resolution_path: "bypassed"'
if [ -n "$WP_FILE" ] && grep -q '^artifactor_result_sha256:' "$WP_FILE"; then
  fail "bypass: a bypassed WP must not claim an Artifactor result checksum"
else
  pass "bypass: no Artifactor checksum recorded"
fi

echo "=== 7. valid result without --title → the title comes from the result ==="
new_case
printf '%s' "$VALID_RESULT" > "$CASE_ROOT/result.json"
run_create --artifactor-result "$CASE_ROOT/result.json"
expect_created "valid result" "$RESULT_NAME"
expect_frontmatter "valid result" 'artifactor_resolution_path: "keyword"'
expect_frontmatter "valid result" "artifactor_result_sha256: \"$(sha256_of "$CASE_ROOT/result.json")\""
if [ -n "$WP_FILE" ] && grep -q '^pilot_revision:' "$WP_FILE"; then
  fail "valid result: pilot_revision must be absent when no revision was given"
else
  pass "valid result: no pilot_revision recorded"
fi

echo "=== 8. valid result with a matching --title → accepted ==="
new_case
printf '%s' "$VALID_RESULT" > "$CASE_ROOT/result.json"
run_create --artifactor-result "$CASE_ROOT/result.json" --title "$RESULT_NAME"
expect_created "matching title" "$RESULT_NAME"

echo ""
echo "Result: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
[ "$FAIL_COUNT" -eq 0 ]
