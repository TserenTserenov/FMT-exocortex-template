#!/usr/bin/env bash
# Regression coverage for the ds-publish.sh side finding of issue #884: since
# WP-7 Ф101 strategist.sh publishes only through $WORKSPACE/scripts/ds-publish.sh,
# a script the template never shipped. On a template install every scheduled
# run logged a bare "No such file or directory" and the commit never reached
# origin. The publish step now says the script is missing and keeps the commit
# local; with the script present it behaves exactly as before.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SCRIPT="$ROOT/roles/strategist/scripts/strategist.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

SHA="0123456789abcdef0123456789abcdef01234567"

# Run the real function (extracted verbatim, with the real log()) against a
# throw-away workspace. Prints the exit code; the log lands in $TMP/log.txt.
run_publish() {
    local workspace="$1"
    : > "$TMP/log.txt"
    bash -c '
        set -e
        WORKSPACE="$1"; LOG_FILE="$2"; SHA="$3"
        '"$(sed -n '/^log() {/,/^}/p' "$SCRIPT")"'
        '"$(sed -n '/^publish_commit_or_explain() {/,/^}/p' "$SCRIPT")"'
        rc=0
        publish_commit_or_explain "strategist: test" "$SHA" "OK-MSG" "FAIL-MSG" >/dev/null || rc=$?
        echo "$rc"
    ' _ "$workspace" "$TMP/log.txt" "$SHA"
}

# --- 1. Script missing: explicit message, non-zero result, no false success.
mkdir -p "$TMP/ws-missing"
rc=$(run_publish "$TMP/ws-missing")
log=$(cat "$TMP/log.txt")
if [ "$rc" = "1" ]; then pass "missing script: function reports failure (rc=1)"; else fail_test "missing script: expected rc=1, got '$rc'"; fi
if printf '%s' "$log" | grep -q 'scripts/ds-publish.sh не установлен'; then
    pass "missing script: log says the script is not installed"
else
    fail_test "missing script: log does not explain the missing script: $log"
fi
if printf '%s' "$log" | grep -q "${SHA:0:12}" && printf '%s' "$log" | grep -q 'остался локальным'; then
    pass "missing script: log names the commit and says it stayed local"
else
    fail_test "missing script: log lacks the short SHA or the 'stayed local' statement: $log"
fi
if printf '%s' "$log" | grep -qE 'OK-MSG|Pushed|No such file'; then
    fail_test "missing script: log claims success or shows a bare shell error: $log"
else
    pass "missing script: no false success and no bare 'No such file or directory'"
fi

# --- 2. Script present and succeeding: exact arguments, success message.
mkdir -p "$TMP/ws-ok/scripts"
cat > "$TMP/ws-ok/scripts/ds-publish.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP/args.txt"
exit 0
EOF
rc=$(run_publish "$TMP/ws-ok")
log=$(cat "$TMP/log.txt")
expected=$(printf '%s\n' "$TMP/ws-ok" normal --reason "strategist: test" --from-commit "$SHA")
if [ "$rc" = "0" ]; then pass "present+ok: function reports success (rc=0)"; else fail_test "present+ok: expected rc=0, got '$rc'"; fi
if [ "$(cat "$TMP/args.txt" 2>/dev/null)" = "$expected" ]; then
    pass "present+ok: publisher got workspace, 'normal', --reason and the exact --from-commit SHA"
else
    fail_test "present+ok: publisher arguments differ. expected:
$expected
got:
$(cat "$TMP/args.txt" 2>/dev/null)"
fi
if printf '%s' "$log" | grep -q 'OK-MSG'; then pass "present+ok: success message logged"; else fail_test "present+ok: success message missing: $log"; fi

# --- 3. Script present but failing: failure message, non-zero, no success claim.
mkdir -p "$TMP/ws-bad/scripts"
printf '#!/usr/bin/env bash\nexit 3\n' > "$TMP/ws-bad/scripts/ds-publish.sh"
rc=$(run_publish "$TMP/ws-bad")
log=$(cat "$TMP/log.txt")
if [ "$rc" = "1" ] && printf '%s' "$log" | grep -q 'FAIL-MSG' && ! printf '%s' "$log" | grep -q 'OK-MSG'; then
    pass "present+failing: failure reported and logged, no success claim"
else
    fail_test "present+failing: rc='$rc' log: $log"
fi

# --- 4. Both publish call sites go through the function, and a failed publish
# cannot end the run under `set -e`. No direct ds-publish.sh call is left.
calls=$(grep -c 'publish_commit_or_explain "' "$SCRIPT")
if [ "$calls" = "2" ]; then pass "both publish sites (main push, notes cleanup) use publish_commit_or_explain"; else fail_test "expected 2 call sites, found $calls"; fi
# Join backslash-continued lines first: the guard sits on the last physical line
# of a multi-line call, so a plain per-line grep breaks on any harmless re-wrap.
guarded=$(awk '{ if (sub(/\\$/, "")) printf "%s", $0; else print $0 }' "$SCRIPT" \
    | grep -cE 'publish_commit_or_explain ".*\|\| true[[:space:]]*(#.*)?$')
if [ "$guarded" = "2" ]; then pass "both call sites are guarded with '|| true' (set -e safe)"; else fail_test "expected 2 guarded call sites, found $guarded"; fi
if grep -q 'bash "\$WORKSPACE/scripts/ds-publish.sh"' "$SCRIPT"; then
    fail_test "a direct ds-publish.sh call bypasses the missing-script check"
else
    pass "no direct ds-publish.sh call bypasses the missing-script check"
fi

if [ "$fail" -eq 0 ]; then
    echo "✅ test_issue_884_ds_publish_missing: all checks passed"
fi
exit "$fail"
