#!/bin/bash
# test-attestation-build-statement.sh — regression test for
# scripts/attestation-build-statement.sh (WP-529 Ф21).
#
# Usage: bash setup/test-attestation-build-statement.sh [--verbose]
# Exit: 0 — all cases passed. N — N cases failed.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_SCRIPT="$TEMPLATE_DIR/scripts/attestation-build-statement.sh"
SCHEMA="$TEMPLATE_DIR/scripts/attestation-statement.schema.json"
VERBOSE=false
[ "${1:-}" = "--verbose" ] && VERBOSE=true

FAIL=0
PASS=0
log() { $VERBOSE && echo "  $*" >&2 || true; }

# epoch_of <ISO-8601 UTC timestamp> — portable across BSD date (macOS) and
# GNU date (Linux CI runners), same fallback pattern as
# scripts/attestation-canonical-digest.sh's callers use elsewhere.
epoch_of() {
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || date -u -d "$1" +%s
}

HEX64="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
HEX40="0123456789abcdef0123456789abcdef01234567"

good_call() {
  bash "$BUILD_SCRIPT" \
    --subject-digest "$HEX64" --repo-name "aisystant/FMT-exocortex-template" \
    --repo-id 123456789 --head-sha "$HEX40" --base-sha "$HEX40" \
    --policy-id "red-team-layer-5-2026-08-27" --policy-digest "$HEX64" \
    --verdict pass "$@"
}

# --- Case 1: valid inputs produce output that validates against the schema ---
if out="$(good_call 2>&1)"; then
  PASS=$((PASS + 1))
  log "PASS: valid inputs succeed"
else
  FAIL=$((FAIL + 1))
  echo "FAIL: valid inputs should succeed, got: $out" >&2
fi

if printf '%s' "$out" | python3 -c "
import json, sys
import jsonschema
statement = json.load(sys.stdin)
schema = json.load(open(sys.argv[1]))
jsonschema.validate(statement, schema)
" "$SCHEMA" 2>/tmp/schema-err.$$; then
  PASS=$((PASS + 1))
  log "PASS: output validates against attestation-statement.schema.json"
else
  FAIL=$((FAIL + 1))
  echo "FAIL: output does not validate against schema:" >&2
  cat /tmp/schema-err.$$ >&2
fi
rm -f /tmp/schema-err.$$

# --- Case 2: subject.digest.sha256 in the JSON equals what we passed in ---
got_digest="$(printf '%s' "$out" | jq -r '.subject[0].digest.sha256')"
if [ "$got_digest" = "$HEX64" ]; then
  PASS=$((PASS + 1))
  log "PASS: subject digest round-trips through the JSON"
else
  FAIL=$((FAIL + 1))
  echo "FAIL: expected digest '$HEX64', got '$got_digest'" >&2
fi

# --- Case 3: predicateType is the fixed WP-529 URI (verifiers pin on this) ---
got_ptype="$(printf '%s' "$out" | jq -r '.predicateType')"
if [ "$got_ptype" = "https://aisystant.io/WP-529/red-team-attestation/v1" ]; then
  PASS=$((PASS + 1))
  log "PASS: predicateType is the expected fixed URI"
else
  FAIL=$((FAIL + 1))
  echo "FAIL: unexpected predicateType '$got_ptype'" >&2
fi

# --- Case 4: expires_at is strictly after issued_at ---
issued="$(printf '%s' "$out" | jq -r '.predicate.issued_at')"
expires="$(printf '%s' "$out" | jq -r '.predicate.expires_at')"
issued_epoch="$(epoch_of "$issued")"
expires_epoch="$(epoch_of "$expires")"
if [ "$expires_epoch" -gt "$issued_epoch" ]; then
  PASS=$((PASS + 1))
  log "PASS: expires_at is after issued_at"
else
  FAIL=$((FAIL + 1))
  echo "FAIL: expires_at ($expires) not after issued_at ($issued)" >&2
fi

# --- Case 5: --ttl-hours changes the gap between issued_at and expires_at ---
out_short="$(good_call --ttl-hours 1)"
issued_s="$(printf '%s' "$out_short" | jq -r '.predicate.issued_at')"
expires_s="$(printf '%s' "$out_short" | jq -r '.predicate.expires_at')"
gap=$(( $(epoch_of "$expires_s") - $(epoch_of "$issued_s") ))
if [ "$gap" -eq 3600 ]; then
  PASS=$((PASS + 1))
  log "PASS: --ttl-hours 1 gives a 3600s gap"
else
  FAIL=$((FAIL + 1))
  echo "FAIL: expected 3600s gap for --ttl-hours 1, got ${gap}s" >&2
fi

# assert_rejected <case name> <override args...> — good_call with one field
# overridden (parser applies args left-to-right, later wins) or truncated;
# every case here must fail closed (nonzero exit), never print a statement.
assert_rejected() {
  local name="$1"; shift
  if good_call "$@" >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    echo "FAIL: $name should be rejected" >&2
  else
    PASS=$((PASS + 1))
    log "PASS: $name rejected"
  fi
}

assert_rejected "malformed subject-digest (not 64 hex chars)" --subject-digest "not-hex"
assert_rejected "invalid verdict value" --verdict maybe

# --- Case: missing required argument is rejected (bypasses good_call's defaults) ---
if bash "$BUILD_SCRIPT" --subject-digest "$HEX64" >/dev/null 2>&1; then
  FAIL=$((FAIL + 1))
  echo "FAIL: missing required arguments should be rejected" >&2
else
  PASS=$((PASS + 1))
  log "PASS: missing required arguments rejected"
fi

echo ""
echo "attestation-build-statement.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
