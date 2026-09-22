#!/usr/bin/env bash
# Regression coverage for issue #893: continuation of #877. After #885 fixed
# the HTTP 401 message to "LLM gateway is not configured", the morning
# strategist scenario still never used the --scaffold-only escape hatch
# (issue #434) that day-open-pipeline.sh's own error text points at -- any
# pipeline failure, gateway-related or not, fell straight through to the
# free-form day-plan prompt, which ignores priorities.yaml and the
# deterministic scaffold. Fix: day-open-pipeline.sh's "no gateway configured"
# abort now exits 9 (a distinct code, not text-parsing); strategist.sh
# retries with --scaffold-only on exactly that code before giving up to the
# free-form prompt.
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

run_block() {
    local pipeline_script="$1" workspace="$2"
    : > "$TMP/log.txt" "$TMP/calls.txt"
    bash -c '
        set -e
        IWE_SCRIPTS="$1"; WORKSPACE="$2"; LOG_FILE="$3"
        log() { printf "%s\n" "$*" >> "'"$TMP"'/log.txt"; }
        run_claude() { printf "run_claude %s\n" "$*" >> "'"$TMP"'/calls.txt"; }
        notify_telegram() { printf "notify_telegram %s\n" "$*" >> "'"$TMP"'/calls.txt"; }
        '"$(cat "$BLOCK_FILE")"'
    ' _ "$(dirname "$pipeline_script")" "$workspace" "$TMP/log.txt"
}

# --- 1. Pipeline exits 9 (no gateway), --scaffold-only retry succeeds:
# scaffold runs, free-form day-plan is never invoked.
cat > "$TMP/pipeline1.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--scaffold-only" ]; then exit 0; fi
exit 9
SH
chmod +x "$TMP/pipeline1.sh"
mv "$TMP/pipeline1.sh" "$TMP/day-open-pipeline.sh"
run_block "$TMP/day-open-pipeline.sh" "$TMP/ws1"
if grep -q 'scaffold only, no gateway' "$TMP/log.txt" 2>/dev/null; then
    pass "exit 9 + scaffold-only succeeds: logs the no-gateway scaffold success"
else
    fail_test "exit 9 + scaffold-only succeeds: missing success log: $(cat "$TMP/log.txt" 2>/dev/null)"
fi
if [ -s "$TMP/calls.txt" ]; then
    fail_test "exit 9 + scaffold-only succeeds: free-form day-plan was still called: $(cat "$TMP/calls.txt")"
else
    pass "exit 9 + scaffold-only succeeds: free-form day-plan prompt was NOT called"
fi
rm -f "$TMP/day-open-pipeline.sh"

# --- 2. Pipeline exits 9, --scaffold-only retry ALSO fails: falls back to
# the free-form prompt (does not just silently give up).
cat > "$TMP/day-open-pipeline.sh" <<'SH'
#!/usr/bin/env bash
exit 9
SH
chmod +x "$TMP/day-open-pipeline.sh"
run_block "$TMP/day-open-pipeline.sh" "$TMP/ws2"
if grep -q 'run_claude day-plan' "$TMP/calls.txt" 2>/dev/null && grep -q 'notify_telegram day-plan' "$TMP/calls.txt" 2>/dev/null; then
    pass "exit 9 + scaffold-only also fails: falls back to free-form day-plan prompt"
else
    fail_test "exit 9 + scaffold-only also fails: no fallback recorded: $(cat "$TMP/calls.txt" 2>/dev/null)"
fi
rm -f "$TMP/day-open-pipeline.sh"

# --- 3. Pipeline fails for an UNRELATED reason (exit 1, not 9): falls
# straight to the free-form prompt without a --scaffold-only retry.
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
if grep -q 'SHOULD NOT BE CALLED' "$TMP/log.txt" 2>/dev/null; then
    fail_test "exit 1 (non-gateway): wrongly retried with --scaffold-only"
else
    pass "exit 1 (non-gateway): no --scaffold-only retry attempted"
fi
if grep -q 'run_claude day-plan' "$TMP/calls.txt" 2>/dev/null; then
    pass "exit 1 (non-gateway): falls back to free-form day-plan prompt directly"
else
    fail_test "exit 1 (non-gateway): no fallback recorded: $(cat "$TMP/calls.txt" 2>/dev/null)"
fi

if [ "$fail" -eq 0 ]; then
    echo "✅ All checks passed (issue #893)"
fi
exit "$fail"
