#!/bin/bash
# capture_selftest.sh
# see DP.SC.025 (capture-bus service clause), DP.SC.026 (behaviour monitoring), WP-217 Phase8.6
# Self-test capture-bus infrastructure.
# Three levels:
#   L1 — syntax and executability (bash -n + chmod)
#   L2 — smoke-test each detector: null-event → exit 0, empty output
#   L3 — latency measurement: each detector on PostToolUse-event, threshold 150ms
#
# Usage:
#   bash .claude/lib/capture_selftest.sh          — all levels
#   bash .claude/lib/capture_selftest.sh --l1     — syntax only
#   bash .claude/lib/capture_selftest.sh --l2     — L1 + smoke
#   bash .claude/lib/capture_selftest.sh --quiet  — summary only (CI-mode)
#
# Exit code: 0 = all OK, 1 = there are FAIL.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./iwe-env-bootstrap.sh
source "$LIB_DIR/iwe-env-bootstrap.sh" || exit 1
CLAUDE_DIR="$IWE_ROOT/.claude"
CONFIG_FILE="$CLAUDE_DIR/config/capture-detectors.sh"
LATENCY_THRESHOLD=150  # ms

LEVEL="all"
QUIET=false
for arg in "$@"; do
  case "$arg" in
    --l1) LEVEL="l1" ;;
    --l2) LEVEL="l2" ;;
    --quiet) QUIET=true ;;
  esac
done

PASS=0
FAIL=0
WARN=0

log()  { $QUIET || echo "$*"; }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
warn() { $QUIET || echo "WARN: $*"; WARN=$((WARN + 1)); }
pass() { log "  ✓ $*"; PASS=$((PASS + 1)); }

# ── L1: syntax and executability ───────────────────────────────────────────
log "=== L1: syntax and executability ==="

CHECK_FILES=(
  "$CLAUDE_DIR/hooks/capture-bus.sh"
  "$CLAUDE_DIR/lib/capture_writer.sh"
  "$CLAUDE_DIR/lib/capture_selftest.sh"
  "$CLAUDE_DIR/config/capture-detectors.sh"
)

for f in "${CHECK_FILES[@]}"; do
  if [ ! -f "$f" ]; then
    fail "file not found: $f"; continue
  fi
  if bash -n "$f" 2>/tmp/selftest_syntax_err_$$; then
    pass "syntax OK: $(basename "$f")"
  else
    fail "syntax ERROR: $(basename "$f"): $(cat /tmp/selftest_syntax_err_$$)"
  fi
  # capture-detectors.sh — sourced sourced config, not executed directly, chmod not needed
  base=$(basename "$f")
  if [ "$base" != "capture-detectors.sh" ]; then
    if [ -x "$f" ]; then
      pass "executable: $base"
    else
      warn "not executable (chmod +x needed): $base"
    fi
  fi
done

if [ ! -f "$CONFIG_FILE" ]; then
  fail "capture-detectors.sh not found"
  log "Summary: PASS=$PASS FAIL=$FAIL WARN=$WARN"
  exit 1
fi
source "$CONFIG_FILE"

log ""
log "=== Detectors in registry: ${#DETECTORS[@]} ==="
for entry in "${DETECTORS[@]}"; do
  IFS='|' read -r name path event_type cost_class enabled triggers <<< "$entry"
  detector_path="$IWE_ROOT/$path"
  log "  detector: $name  enabled=$enabled  triggers=$triggers"

  [ ! -f "$detector_path" ] && { fail "[$name] file not found: $detector_path"; continue; }

  if bash -n "$detector_path" 2>/tmp/selftest_syntax_err_$$; then
    pass "[$name] syntax OK"
  else
    fail "[$name] syntax ERROR: $(cat /tmp/selftest_syntax_err_$$)"
  fi

  if [ -x "$detector_path" ]; then
    pass "[$name] executable"
  else
    fail "[$name] not executable — required chmod +x"
  fi
done

[ "$LEVEL" = "l1" ] && {
  log ""; log "Summary L1: PASS=$PASS FAIL=$FAIL WARN=$WARN"
  rm -f /tmp/selftest_syntax_err_$$
  [ "$FAIL" -gt 0 ] && exit 1 || exit 0
}

# ── L2: smoke-test (null-event → exit 0, empty output) ─────────────────────
log ""; log "=== L2: smoke-test (null-event) ==="

NULL_EVENT='{}'

for entry in "${DETECTORS[@]}"; do
  IFS='|' read -r name path event_type cost_class enabled triggers <<< "$entry"
  detector_path="$IWE_ROOT/$path"
  [ ! -x "$detector_path" ] && continue

  if out=$(echo "$NULL_EVENT" | "$detector_path" 2>/tmp/selftest_smoke_err_$$); then
    if [ -z "$out" ]; then
      pass "[$name] null-event → skip (empty) ✓"
    else
      warn "[$name] null-event → unexpected output: ${out:0:100}"
    fi
  else
    fail "[$name] null-event → non-zero exit: $(cat /tmp/selftest_smoke_err_$$ 2>/dev/null | head -c 200)"
  fi
done

[ "$LEVEL" = "l2" ] && {
  log ""; log "Summary L2: PASS=$PASS FAIL=$FAIL WARN=$WARN"
  rm -f /tmp/selftest_syntax_err_$$ /tmp/selftest_smoke_err_$$
  [ "$FAIL" -gt 0 ] && exit 1 || exit 0
}

# ── L3: latency-test (PostToolUse-event, threshold 150ms) ───────────────────────
log ""; log "=== L3: latency-test (threshold=${LATENCY_THRESHOLD}ms) ==="

TEST_EVENT=$(jq -n \
  '{hook_event_name:"PostToolUse",session_id:"selftest",tool_name:"Write",
    tool_input:{file_path:"/tmp/selftest_dummy.md"},cwd:"/tmp"}')

for entry in "${DETECTORS[@]}"; do
  IFS='|' read -r name path event_type cost_class enabled triggers <<< "$entry"
  detector_path="$IWE_ROOT/$path"
  [ ! -x "$detector_path" ] && continue

  if [[ ",$triggers," != *",PostToolUse,"* ]]; then
    log "  [$name] skip (no PostToolUse trigger)"; continue
  fi

  start_ns=$(perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000000000' 2>/dev/null || echo 0)
  echo "$TEST_EVENT" | "$detector_path" > /dev/null 2>&1 || true
  end_ns=$(perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000000000' 2>/dev/null || echo 0)
  ms=$(( (end_ns - start_ns) / 1000000 ))

  if [ "$ms" -le "$LATENCY_THRESHOLD" ]; then
    pass "[$name] latency=${ms}ms ≤ ${LATENCY_THRESHOLD}ms"
  else
    fail "[$name] latency=${ms}ms > ${LATENCY_THRESHOLD}ms (budget exceeded)"
  fi
done

# ── Summary ────────────────────────────────────────────────────────────────────
rm -f /tmp/selftest_syntax_err_$$ /tmp/selftest_smoke_err_$$
log ""
log "══════════════════════════════════════"
log "Summary: PASS=$PASS  FAIL=$FAIL  WARN=$WARN"
if [ "$FAIL" -gt 0 ]; then
  log "Status: FAIL"
  exit 1
elif [ "$WARN" -gt 0 ]; then
  log "Status: PASS with warnings"
  exit 0
else
  log "Status: ALL PASS"
  exit 0
fi
