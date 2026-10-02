#!/usr/bin/env bash
# WP-485 Ф14: minimal smoke for FMT --isolate happy path (T1-ish).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SG="$ROOT/scripts/session-guard.sh"
LIB="$ROOT/scripts/lib/session-guard-isolate-lib.sh"
PUSH="$ROOT/scripts/isolate-push.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -x "$SG" ] || fail "session-guard missing"
[ -f "$LIB" ] || fail "isolate lib missing"
[ -x "$PUSH" ] || fail "isolate-push missing"
bash -n "$SG" || fail "session-guard syntax"
bash -n "$LIB" || fail "lib syntax"
bash -n "$PUSH" || fail "isolate-push syntax"
grep -q -- '--isolate)' "$SG" || fail "open does not parse --isolate"
grep -q 'with_isolate_lock' "$SG" || fail "open does not call with_isolate_lock"
grep -q 'resolve_isolate_push_script' "$SG" || fail "close missing isolate-push resolve"
grep -q 'IWE_GOVERNANCE_REPO:?isolate-push' "$PUSH" || fail "isolate-push missing required-env guard"
FORBIDDEN="$(printf '%s%s' 'IWE_GOVERNANCE_REPO:-DS-my-' 'strategy')"
if grep -F "$FORBIDDEN" "$PUSH" >/dev/null 2>&1; then
  fail "isolate-push still contains personal-repo silent default"
fi
grep -q 'freeze-canonical' "$SG" || fail "missing freeze-canonical"
grep -q 'request-unfreeze-canonical' "$SG" || fail "missing request-unfreeze-canonical"
grep -q 'FROZEN_CANONICAL_PATHS' "$SG" || fail "missing FROZEN_CANONICAL_PATHS"
echo "PASS: FMT isolate minimal surface present (syntax + wiring)"
