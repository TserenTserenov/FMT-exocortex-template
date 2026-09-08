#!/usr/bin/env bash
# Regression test for bug #339: capture-bus.sh must have a timeout for detectors.
# Verify a hung detector is cut off by timeout/gtimeout and does not block the
# rest of the dispatch.
#
# Earlier version copied capture-bus.sh alone into a bare tmpdir. HOOK_DIR/
# CLAUDE_DIR are resolved from the script's own location (dirname of
# BASH_SOURCE), so a lone copy resolves CLAUDE_DIR to the tmpdir's PARENT
# (the system temp root) and the bootstrap `source` fails immediately — the
# test then "passed" only because the resulting fast exit-1 happened to be
# under the elapsed-time threshold, not because timeout logic ever ran (found
# 03.08: this stderr line was visible in the old run: ".../T/lib/iwe-env-
# bootstrap.sh: No such file or directory"). Now uses the same real .claude/
# tree fixture as test_capture_bus_contract.sh, so the timeout path is what's
# actually exercised.

set -euo pipefail

TEMPLATE_ROOT="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}"

if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
  echo "SKIP: neither timeout nor gtimeout available — this machine cannot enforce the timeout capture-bus.sh relies on"
  exit 0
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# shellcheck source=lib/capture_fixture.sh
source "$TEMPLATE_ROOT/scripts/tests/lib/capture_fixture.sh"
setup_capture_fixture "$TEMPLATE_ROOT" "$TMPDIR"

mkdir -p "$TMPDIR/detectors"

cat > "$TMPDIR/detectors/sleepy.sh" <<EOF
#!/usr/bin/env bash
sleep 60
: > "$TMPDIR/sleep-completed"
EOF
cat > "$TMPDIR/detectors/after.sh" <<EOF
#!/usr/bin/env bash
: > "$TMPDIR/after.ran"
EOF
chmod +x "$TMPDIR"/detectors/*.sh

cat > "$TMPDIR/.claude/config/capture-detectors.sh" <<'EOF'
CAPTURE_COST_LEVEL=free
CAPTURE_DETECTOR_TIMEOUT_SECONDS=2
DETECTORS=(
  "sleepy|detectors/sleepy.sh|capture|free|true|PostToolUse"
  "after|detectors/after.sh|capture|free|true|PostToolUse"
)
EOF

INPUT='{"hook_event_name":"PostToolUse","session_id":"timeout","tool_name":"Write","cwd":"/tmp","tool_input":{"file_path":"x"}}'

START=$(date +%s)
printf '%s\n' "$INPUT" | bash "$TMPDIR/.claude/hooks/capture-bus.sh"
ELAPSED=$(( $(date +%s) - START ))

echo "Elapsed: ${ELAPSED}s"

[ "$ELAPSED" -lt 10 ] ||
  { echo "FAIL: dispatcher did not time out (elapsed ${ELAPSED}s)" >&2; exit 1; }
[ ! -e "$TMPDIR/sleep-completed" ] ||
  { echo "FAIL: sleepy detector was allowed to run to completion" >&2; exit 1; }
[ -e "$TMPDIR/after.ran" ] ||
  { echo "FAIL: dispatcher did not continue past the timed-out detector" >&2; exit 1; }
grep -q 'timeout (2s)' "$CAPTURE_LOG_FILE" ||
  { echo "FAIL: timeout was not recorded in the log" >&2; exit 1; }

echo "✓ Detector timed out correctly (${ELAPSED}s < 10s), dispatch continued, timeout logged"
