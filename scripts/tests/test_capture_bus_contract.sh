#!/usr/bin/env bash
# Contract test for bug #339: capture-bus.sh must survive a crashing detector
# without blocking the remaining detectors — and record the crash, not hide it.
#
# The dispatcher's own contract (capture-bus.sh header, "НИКОГДА не блокирует")
# is exit 0 always, by design (harness must never see a hook failure). An
# earlier draft of this test expected a non-zero exit on detector crash — that
# would have locked in a contract that contradicts the script's own documented
# behavior. The real safety invariant lives in the JSONL log, not the exit
# code: a crashed detector must produce a status=detector_error entry with the
# failure reason, and dispatch must continue to the next detector.

set -euo pipefail

TEMPLATE_ROOT="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# shellcheck source=lib/capture_fixture.sh
source "$TEMPLATE_ROOT/scripts/tests/lib/capture_fixture.sh"
setup_capture_fixture "$TEMPLATE_ROOT" "$TMPDIR"

mkdir -p "$TMPDIR/detectors"

cat > "$TMPDIR/detectors/first.sh" <<EOF
#!/usr/bin/env bash
: > "$TMPDIR/first.ran"
EOF
cat > "$TMPDIR/detectors/crash.sh" <<'EOF'
#!/usr/bin/env bash
echo "injected detector crash" >&2
exit 42
EOF
cat > "$TMPDIR/detectors/last.sh" <<EOF
#!/usr/bin/env bash
: > "$TMPDIR/last.ran"
EOF
chmod +x "$TMPDIR"/detectors/*.sh

cat > "$TMPDIR/.claude/config/capture-detectors.sh" <<'EOF'
CAPTURE_COST_LEVEL=free
CAPTURE_DETECTOR_TIMEOUT_SECONDS=2
DETECTORS=(
  "first|detectors/first.sh|capture|free|true|PostToolUse"
  "crash|detectors/crash.sh|capture|free|true|PostToolUse"
  "last|detectors/last.sh|capture|free|true|PostToolUse"
)
EOF

INPUT='{"hook_event_name":"PostToolUse","session_id":"contract","tool_name":"Write","cwd":"/tmp","tool_input":{"file_path":"x"}}'

run_dispatcher() {
  START=$(date +%s)
  set +e
  printf '%s\n' "$INPUT" |
    bash "$TMPDIR/.claude/hooks/capture-bus.sh" >"$TMPDIR/stdout" 2>"$TMPDIR/stderr"
  RC=$?
  set -e
  ELAPSED=$(( $(date +%s) - START ))
}

run_dispatcher

[ "$RC" -eq 0 ] ||
  { echo "FAIL: dispatcher must remain non-blocking, rc=$RC" >&2; cat "$TMPDIR/stderr" >&2; exit 1; }
[ "$ELAPSED" -lt 10 ] ||
  { echo "FAIL: progress invariant violated (${ELAPSED}s)" >&2; exit 1; }
[ -f "$TMPDIR/first.ran" ] ||
  { echo "FAIL: first detector did not run" >&2; exit 1; }
[ -f "$TMPDIR/last.ran" ] ||
  { echo "FAIL: loop stopped after crash — detector after it never ran" >&2; exit 1; }
grep -q '"detector":"crash"' "$CAPTURE_LOG_FILE" ||
  { echo "FAIL: crashed detector absent from log" >&2; exit 1; }
grep -q '"status":"detector_error"' "$CAPTURE_LOG_FILE" ||
  { echo "FAIL: degraded state was not recorded" >&2; exit 1; }
grep -q 'injected detector crash' "$CAPTURE_LOG_FILE" ||
  { echo "FAIL: crash reason was lost" >&2; exit 1; }

echo "✓ Progress and safety invariants hold (non-blocking, crash recorded, dispatch continued)"

# Idempotency: two independent PostToolUse events are two independent facts —
# a second identical hook call must record its own crash, not silently dedupe.
rm -f "$TMPDIR/first.ran" "$TMPDIR/last.ran"
run_dispatcher
[ "$RC" -eq 0 ] || { echo "FAIL: second invocation must also remain non-blocking, rc=$RC" >&2; exit 1; }
CRASH_COUNT=$(grep -c '"detector":"crash"' "$CAPTURE_LOG_FILE")
[ "$CRASH_COUNT" -eq 2 ] ||
  { echo "FAIL: expected 2 recorded crashes after 2 invocations, got $CRASH_COUNT" >&2; exit 1; }

echo "✓ Repeat invocation records its own event, no silent dedup"
