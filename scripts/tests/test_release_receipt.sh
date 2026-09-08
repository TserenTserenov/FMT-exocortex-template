#!/usr/bin/env bash
# WP-529 Ф3: release-receipt.sh must be fail-closed — publishable=true only
# when every mandatory check reports success or skipped (a job intentionally
# not run for this trigger, e.g. the macOS integration job on a push event).
# Any failure, cancelled run, or an unset RESULT_* var (the receipt job
# never even wired that job's result in) must produce publishable=false and
# a non-zero exit, not silently pass.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SCRIPT="$ROOT/scripts/release-receipt.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ALL_SUCCESS_ENV=(
  RESULT_RELEASE_SYNC=success
  RESULT_INTEGRATION_CONTRACT_UBUNTU=success
  RESULT_INTEGRATION_CONTRACT_MACOS=skipped
  RESULT_SHELLCHECK=success
  RESULT_PLATFORM_COMPAT=success
  RESULT_VALIDATE=success
  RESULT_UPGRADE_TEST=success
  RESULT_GUIDE_KIT_DRIFT=success
)

# Scenario 1: every mandatory check success/skipped -> publishable, exit 0.
OUT1="$TMP/receipt-allpass.json"
if ! RELEASE_RECEIPT_OUT="$OUT1" env "${ALL_SUCCESS_ENV[@]}" bash "$SCRIPT"; then
  echo "FAIL: all-success scenario exited non-zero"
  exit 1
fi
[ "$(jq -r '.publishable' "$OUT1")" = "true" ] || {
  echo "FAIL: all-success scenario did not produce publishable=true"
  exit 1
}
[ "$(jq '.checks | length' "$OUT1")" = "8" ] || {
  echo "FAIL: all-success receipt does not list all 8 mandatory checks"
  exit 1
}
[ "$(jq -r '.sha' "$OUT1")" = "$(git -C "$ROOT" rev-parse HEAD)" ] || {
  echo "FAIL: receipt sha does not match HEAD"
  exit 1
}

# Scenario 2: one mandatory check failed -> not publishable, exit 1, and the
# failing check is identifiable in the receipt (not just a bare false).
OUT2="$TMP/receipt-onefail.json"
if RELEASE_RECEIPT_OUT="$OUT2" env "${ALL_SUCCESS_ENV[@]}" RESULT_VALIDATE=failure bash "$SCRIPT"; then
  echo "FAIL: one-failure scenario exited 0, expected non-zero"
  exit 1
fi
[ "$(jq -r '.publishable' "$OUT2")" = "false" ] || {
  echo "FAIL: one-failure scenario did not produce publishable=false"
  exit 1
}
[ "$(jq -r '.checks[] | select(.name=="validate") | .result' "$OUT2")" = "failure" ] || {
  echo "FAIL: receipt does not record validate:failure"
  exit 1
}

# Scenario 3: a cancelled run must fail closed too, not just a literal "failure".
OUT3="$TMP/receipt-cancelled.json"
if RELEASE_RECEIPT_OUT="$OUT3" env "${ALL_SUCCESS_ENV[@]}" RESULT_UPGRADE_TEST=cancelled bash "$SCRIPT"; then
  echo "FAIL: cancelled scenario exited 0, expected non-zero"
  exit 1
fi
[ "$(jq -r '.publishable' "$OUT3")" = "false" ] || {
  echo "FAIL: cancelled scenario did not produce publishable=false"
  exit 1
}

# Scenario 4: no RESULT_* vars set at all (e.g. a `needs:` entry added to the
# receipt job's list but never wired as env) must fail closed, not read as
# vacuously publishable.
OUT4="$TMP/receipt-noenv.json"
if RELEASE_RECEIPT_OUT="$OUT4" bash "$SCRIPT"; then
  echo "FAIL: no-env scenario exited 0, expected non-zero"
  exit 1
fi
[ "$(jq -r '.publishable' "$OUT4")" = "false" ] || {
  echo "FAIL: no-env scenario did not produce publishable=false"
  exit 1
}
[ "$(jq -r '.checks[] | select(.name=="release-sync") | .result' "$OUT4")" = "unknown" ] || {
  echo "FAIL: no-env scenario did not record unknown result for unset checks"
  exit 1
}

# Scenario 5: a RESULT_* var set to an empty string (not merely unset) must
# still fail closed — `${!var:-unknown}` treats bash's null and unset the
# same way, but that equivalence is exactly the kind of thing a future edit
# could accidentally break, so assert it directly instead of trusting it.
OUT5="$TMP/receipt-emptystring.json"
if RELEASE_RECEIPT_OUT="$OUT5" env "${ALL_SUCCESS_ENV[@]}" RESULT_VALIDATE="" bash "$SCRIPT"; then
  echo "FAIL: empty-string scenario exited 0, expected non-zero"
  exit 1
fi
[ "$(jq -r '.publishable' "$OUT5")" = "false" ] || {
  echo "FAIL: empty-string scenario did not produce publishable=false"
  exit 1
}
[ "$(jq -r '.checks[] | select(.name=="validate") | .result' "$OUT5")" = "unknown" ] || {
  echo "FAIL: empty-string RESULT_VALIDATE was not recorded as unknown"
  exit 1
}

echo "PASS: release-receipt.sh is fail-closed across all-pass/failure/cancelled/unset/empty-string scenarios"
