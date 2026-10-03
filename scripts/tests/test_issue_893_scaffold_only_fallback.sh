#!/usr/bin/env bash
# Regression coverage for issue #893: continuation of #877. After #885 fixed
# the HTTP 401 message to "LLM gateway is not configured", the morning
# strategist scenario still never used the --scaffold-only escape hatch
# (issue #434) that day-open-pipeline.sh's own error text points at -- any
# pipeline failure, gateway-related or not, fell straight through to the
# free-form day-plan prompt, which ignores priorities.yaml and the
# deterministic scaffold. Fix: day-open-pipeline.sh's "no gateway configured"
# abort now exits 9 (a distinct code, not text-parsing); strategist.sh
# retries with --scaffold-only on exactly that code.
# Since D16 (#983) no failure reaches the free-form prompt any more: a failed
# retry gives up for the day with an alarm, any other code is passed out with an
# alarm (the full contract is in test_issue_983_morning_alarm.sh).
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
STRATEGIST="$ROOT/roles/strategist/scripts/strategist.sh"
PIPELINE="$ROOT/scripts/day-open-pipeline.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

# --- 0. day-open-pipeline.sh itself: "no gateway" aborts with exit 9, not 1.
# Driving the real pipeline end to end needs a WeekPlan, day-rhythm-config
# and a real repo it can chdir into -- a static check on the actual abort
# call is more reliable here than an e2e run that may abort even earlier
# for unrelated reasons and never reach the assertion at all.
if grep -qE 'abort "LLM gateway is not configured.*" 9$' "$PIPELINE"; then
    pass "day-open-pipeline.sh: no-gateway abort passes exit code 9"
else
    fail_test "day-open-pipeline.sh: no-gateway abort does not pass exit code 9"
fi

# --- Extract the real DAY_OPEN_PIPELINE resolution+dispatch block from
# strategist.sh by bracket-depth, not a hardcoded line range -- survives
# unrelated edits elsewhere in the file; fails loudly (not silently on stale
# code) if the anchors themselves ever stop existing.
BLOCK_FILE="$TMP/block.sh"
RESOLVED_PYTHON3=$(bash "$ROOT/scripts/lib/find-python3.sh" --stdlib-only)
"$RESOLVED_PYTHON3" - "$STRATEGIST" "$BLOCK_FILE" <<'PYEOF'
import sys

src_path, out_path = sys.argv[1], sys.argv[2]
lines = open(src_path, encoding="utf-8").readlines()

start_idx = next(
    i for i, l in enumerate(lines)
    if 'DAY_OPEN_PIPELINE="${IWE_SCRIPTS:-}/day-open-pipeline.sh"' in l
)
# Two sibling if-statements follow start_idx (a short path-fallback one,
# then the real dispatch one with the elif/else this test targets) -- walk
# each to its own matching fi and keep the first whose body actually has
# the exit-9 retry branch, instead of stopping at the first if/fi pair.
i = start_idx
end_idx = None
while i < len(lines):
    stripped = lines[i].strip()
    if stripped.startswith("if "):
        depth = 1
        block_start = i
        i += 1
        while i < len(lines) and depth > 0:
            s = lines[i].strip()
            if s.startswith("if "):
                depth += 1
            if s == "fi":
                depth -= 1
            i += 1
        block_end = i - 1
        if "pipeline_rc" in "".join(lines[block_start:block_end + 1]):
            end_idx = block_end
            break
        continue
    i += 1
assert end_idx is not None, "exit-9 retry branch not found -- anchors changed, update this test"
open(out_path, "w", encoding="utf-8").writelines(lines[start_idx:end_idx + 1])
PYEOF
if [ ! -s "$BLOCK_FILE" ]; then
    fail_test "could not extract the DAY_OPEN_PIPELINE block from strategist.sh — anchors likely changed"
    echo "Result: $fail FAIL"
    exit 1
fi
if ! grep -q 'pipeline_rc" -eq 9' "$BLOCK_FILE"; then
    fail_test "extracted block does not contain the exit-9 retry branch — extraction anchors are wrong"
    echo "Result: $fail FAIL"
    exit 1
fi

# The block calls the D16 helpers (alarm, give-up, attempt counter): cut them and their
# constants out of strategist.sh by name, like the block itself.
extract_function() {  # <name> -> the function, from its header line to the first closing brace
    awk -v head="$1() {" 'index($0, head) == 1 { on = 1 } on { print } on && /^}/ { exit }' "$STRATEGIST"
}
HELPERS="$(grep -E '^DAY_OPEN_[A-Z_]+=' "$STRATEGIST")
$(for fn in count_in_log day_open_alarm day_open_give_up day_open_start_attempt day_open_deferred day_open_transient_failure; do extract_function "$fn"; done)"
if ! printf '%s\n' "$HELPERS" | grep -q '^day_open_transient_failure() {'; then
    fail_test "could not cut the D16 helpers out of strategist.sh — names changed, update this test"
    echo "Result: $fail FAIL"
    exit 1
fi

run_block() {  # -> exit code of the block
    local pipeline_script="$1" workspace="$2"
    : > "$TMP/log.txt" "$TMP/calls.txt"
    bash -c '
        set -e
        IWE_SCRIPTS="$1"; WORKSPACE="$2"; LOG_FILE="$3"
        log() { printf "%s\n" "$*" >> "'"$TMP"'/log.txt"; }
        run_claude() { printf "run_claude %s\n" "$*" >> "'"$TMP"'/calls.txt"; }
        notify_telegram() { printf "notify_telegram %s\n" "$*" >> "'"$TMP"'/calls.txt"; }
        '"$HELPERS"'
        day_open_alarm_owed() { return 1; }
        '"$(cat "$BLOCK_FILE")"'
    ' _ "$(dirname "$pipeline_script")" "$workspace" "$TMP/log.txt"
}

# --- 1. Pipeline exits 9 (no gateway), --scaffold-only saves an incomplete
# draft: the strategist alarms and never reports a completed day.
cat > "$TMP/pipeline1.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--scaffold-only" ]; then exit 10; fi
exit 9
SH
chmod +x "$TMP/pipeline1.sh"
mv "$TMP/pipeline1.sh" "$TMP/day-open-pipeline.sh"
run_block "$TMP/day-open-pipeline.sh" "$TMP/ws1"
if grep -q 'GAVE UP scenario: day-plan (.*неполный каркас' "$TMP/log.txt" 2>/dev/null \
   && ! grep -q 'Day Open pipeline OK' "$TMP/log.txt" 2>/dev/null; then
    pass "exit 9 + scaffold-only returns 10: incomplete draft is alarmed, not marked ready"
else
    fail_test "exit 9 + scaffold-only returns 10: wrong status: $(cat "$TMP/log.txt" 2>/dev/null)"
fi
if grep -q 'run_claude' "$TMP/calls.txt" 2>/dev/null \
   || ! grep -q 'notify_telegram day-open-failed' "$TMP/calls.txt" 2>/dev/null; then
    fail_test "exit 9 + scaffold-only returns 10: missing alarm or free-form day-plan ran: $(cat "$TMP/calls.txt")"
else
    pass "exit 9 + scaffold-only returns 10: alarm sent, free-form day-plan prompt NOT called"
fi
rm -f "$TMP/day-open-pipeline.sh"

# --- 2. Pipeline exits 9, --scaffold-only retry ALSO fails: no free-form
# prompt (D16, #983); the day gives up with an alarm instead of silently.
cat > "$TMP/day-open-pipeline.sh" <<'SH'
#!/usr/bin/env bash
exit 9
SH
chmod +x "$TMP/day-open-pipeline.sh"
run_block "$TMP/day-open-pipeline.sh" "$TMP/ws2"
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'GAVE UP scenario: day-plan (' "$TMP/log.txt" 2>/dev/null \
    && grep -q 'notify_telegram day-open-failed' "$TMP/calls.txt" 2>/dev/null \
    && ! grep -q 'run_claude' "$TMP/calls.txt" 2>/dev/null; then
    pass "exit 9 + scaffold-only also fails: gives up for the day with an alarm, free-form prompt NOT called"
else
    fail_test "exit 9 + scaffold-only also fails: rc=$rc calls=$(cat "$TMP/calls.txt" 2>/dev/null) log=$(tail -3 "$TMP/log.txt" 2>/dev/null)"
fi
rm -f "$TMP/day-open-pipeline.sh"

# --- 3. Pipeline fails for an UNRELATED reason (exit 1, not 9): no
# --scaffold-only retry and no free-form prompt; the code goes out with an alarm.
cat > "$TMP/day-open-pipeline.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--scaffold-only" ]; then
    echo "SHOULD NOT BE CALLED FOR A NON-GATEWAY FAILURE" >&2
    exit 1
fi
exit 1
SH
chmod +x "$TMP/day-open-pipeline.sh"
run_block "$TMP/day-open-pipeline.sh" "$TMP/ws3"
rc=$?
if grep -q 'SHOULD NOT BE CALLED' "$TMP/log.txt" 2>/dev/null; then
    fail_test "exit 1 (non-gateway): wrongly retried with --scaffold-only"
else
    pass "exit 1 (non-gateway): no --scaffold-only retry attempted"
fi
if [ "$rc" -eq 1 ] && grep -q 'notify_telegram day-open-failed' "$TMP/calls.txt" 2>/dev/null \
    && ! grep -q 'run_claude' "$TMP/calls.txt" 2>/dev/null; then
    pass "exit 1 (non-gateway): the code goes out with an alarm, free-form prompt NOT called"
else
    fail_test "exit 1 (non-gateway): rc=$rc calls=$(cat "$TMP/calls.txt" 2>/dev/null)"
fi

if [ "$fail" -eq 0 ]; then
    echo "✅ All checks passed (issue #893)"
fi
exit "$fail"
