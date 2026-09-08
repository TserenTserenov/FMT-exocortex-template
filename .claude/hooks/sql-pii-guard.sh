#!/bin/bash
# sql-pii-guard.sh — fail-visible PostToolUse gate for AR.112/AR.113.
# It evaluates the complete on-disk SQL file after Write/Edit/MultiEdit and
# refuses to report success when the detector, registry or result is incomplete.

set -uo pipefail
umask 077
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

HOOK_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENGINE="${SQL_PII_RULE_ENGINE:-$HOOK_DIR/rule-engine.sh}"

guard_failure() {
    printf 'SQL Security gate unavailable: %s\n' "$1" >&2
    exit 2
}

make_payload() {
    python3 - "$1" <<'PYEOF'
import json
import sys

print(json.dumps({
    "hook_event_name": "PostToolUse",
    "tool_name": "Edit",
    "tool_input": {
        "file_path": sys.argv[1],
        "new_string": "SELECT 1 WHERE account_id = 1;",
    },
}))
PYEOF
}

self_test() {
    local temp_dir registry unsafe uppercase scoped non_pii pii sentinel payload rc failures=0
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/sql-pii-guard.XXXXXX") || return 1
    SQL_PII_TEST_TMP="$temp_dir"
    trap 'rm -rf "$SQL_PII_TEST_TMP"' EXIT
    registry="${SQL_PII_TEST_REGISTRY:-$HOOK_DIR/../rules-registry.yaml}"
    unsafe="$temp_dir/unsafe.sql"
    uppercase="$temp_dir/unsafe.SQL"
    scoped="$temp_dir/scoped.sql"
    non_pii="$temp_dir/non-pii.sql"
    pii="$temp_dir/pii.sql"
    sentinel="$temp_dir/sentinel.sql"

    printf '%s\n' 'SET ROLE privileged;' 'SELECT * FROM user_events LIMIT 1;' > "$unsafe"
    printf '%s\n' 'DELETE FROM user_events;' > "$uppercase"
    printf '%s\n' 'SET ROLE privileged;' "SELECT * FROM user_events WHERE account_id = current_setting('app.current_user_id');" > "$scoped"
    printf '%s\n' 'SELECT 1;' > "$non_pii"
    printf '%s\n' 'CREATE TABLE people (date_of_birth date, address text);' > "$pii"
    printf '%s\n' '-- SQL_PRIVATE_SENTINEL' 'SELECT 1;' > "$sentinel"

    run_case() {
        local name expected file engine registry_path
        name="$1"
        expected="$2"
        file="$3"
        engine="$4"
        registry_path="$5"
        payload=$(make_payload "$file") || return 1
        printf '%s' "$payload" | HOME="$temp_dir" RULE_REGISTRY="$registry_path" SQL_PII_RULE_ENGINE="$engine" "$0" >/dev/null 2>&1
        rc=$?
        if [ "$rc" -eq "$expected" ]; then
            printf 'PASS %s\n' "$name"
        else
            printf 'FAIL %s: rc=%s expected=%s\n' "$name" "$rc" "$expected" >&2
            failures=$((failures + 1))
        fi
    }

    printf '%s\n' 'schema_version: "1.0"' 'rules: []' > "$temp_dir/no-rules.yaml"
    run_case missing_engine 2 "$non_pii" "$temp_dir/missing-engine" "$registry"
    run_case no_rules 2 "$non_pii" "$ENGINE" "$temp_dir/no-rules.yaml"
    run_case final_file_unsafe 2 "$unsafe" "$ENGINE" "$registry"
    run_case uppercase_extension 2 "$uppercase" "$ENGINE" "$registry"
    run_case scoped_pii_manual_review 2 "$scoped" "$ENGINE" "$registry"
    run_case non_pii_sql 0 "$non_pii" "$ENGINE" "$registry"
    run_case pii_schema_manual_review 2 "$pii" "$ENGINE" "$registry"
    run_case journal_redaction 0 "$sentinel" "$ENGINE" "$registry"
    if grep -R -q 'SQL_PRIVATE_SENTINEL' "$temp_dir/logs/rule-engine" 2>/dev/null; then
        printf 'FAIL journal_contains_raw_sql\n' >&2
        failures=$((failures + 1))
    else
        printf 'PASS journal_omits_raw_sql\n'
    fi

    [ "$failures" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit $?
fi

INPUT=$(cat)
[ -z "$INPUT" ] && guard_failure "empty hook payload"

if ! printf '%s' "$INPUT" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
    guard_failure "malformed hook JSON"
fi

HOOK_EVENT=$(printf '%s' "$INPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("hook_event_name", ""))') ||
    guard_failure "cannot read hook event"
[ "$HOOK_EVENT" != "PostToolUse" ] && exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_name", ""))') ||
    guard_failure "cannot read tool name"
case "$TOOL_NAME" in
    Write|Edit|MultiEdit) ;;
    *) exit 0 ;;
esac

FILE_PATH=$(printf '%s' "$INPUT" | python3 -c '
import json
import sys

tool_input = json.load(sys.stdin).get("tool_input", {})
print(tool_input.get("file_path", "") or tool_input.get("path", ""))
') || guard_failure "cannot read SQL file path"
[ -z "$FILE_PATH" ] && guard_failure "write event has no file path"

FILE_PATH_LOWER=$(printf '%s' "$FILE_PATH" | tr '[:upper:]' '[:lower:]')
case "$FILE_PATH_LOWER" in
    *.sql|*/migrations/*|*/migrate/*) ;;
    *) exit 0 ;;
esac

[ -f "$FILE_PATH" ] && [ -r "$FILE_PATH" ] || guard_failure "final SQL file is not readable"

[ -x "$ENGINE" ] || guard_failure "rule engine is missing or not executable"

CTX=$(python3 - "$FILE_PATH" <<'PYEOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as sql_file:
    file_content = sql_file.read()
print(json.dumps({
    "file_path": sys.argv[1],
    "file_content": file_content,
}))
PYEOF
) || guard_failure "cannot build SQL analysis context"

RESULT=$(RULE_EVENT="sql_file_write" RULE_CONTEXT="$CTX" "$ENGINE" dispatch 2>/dev/null) ||
    guard_failure "rule engine execution failed"
[ -n "$RESULT" ] || guard_failure "rule engine returned no result"

if ! printf '%s' "$RESULT" | python3 -c '
import json
import sys

result = json.load(sys.stdin)
if result.get("verdict") not in {"ok", "warn", "block"}:
    raise SystemExit(2)
applied = result.get("applied_rules")
if not isinstance(applied, list):
    raise SystemExit(2)
ids = {str(item).split(":", 1)[0] for item in applied}
if not {"AR.112", "AR.113"}.issubset(ids):
    raise SystemExit(2)
' >/dev/null 2>&1; then
    guard_failure "AR.112/AR.113 were not both applied"
fi

VERDICT=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["verdict"])') ||
    guard_failure "cannot read detector verdict"
RULE_ID=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("rule_id", "unknown"))') ||
    guard_failure "cannot read detector rule"
REASON=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason", "manual review required"))') ||
    guard_failure "cannot read detector reason"

case "$VERDICT" in
    ok)
        exit 0
        ;;
    warn)
        printf 'SQL Security review required (%s): %s\n' "$RULE_ID" "$REASON" >&2
        exit 2
        ;;
    block)
        printf 'SQL Security block (%s): %s\n' "$RULE_ID" "$REASON" >&2
        exit 2
        ;;
    *)
        guard_failure "unknown detector verdict"
        ;;
esac
