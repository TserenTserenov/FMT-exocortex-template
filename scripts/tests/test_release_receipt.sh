#!/usr/bin/env bash
# WP-529 Ф3: release-receipt.sh must be fail-closed — publishable=true only
# when every mandatory check reports success or an allowed skip (the macOS
# integration job on a push event). All three Windows jobs must report success.
# Any failure, cancelled run, or an unset RESULT_* var (the receipt job
# never even wired that job's result in) must produce publishable=false and
# a non-zero exit, not silently pass.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SCRIPT="$ROOT/scripts/release-receipt.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# GITHUB_* pinned to a non-release trigger: in CI the runner exports the
# real push/main values, which would turn these scenarios into release runs.
ALL_SUCCESS_ENV=(
  GITHUB_EVENT_NAME=pull_request
  GITHUB_REF_NAME=main
  GITHUB_REPOSITORY=TserenTserenov/FMT-exocortex-template
  RESULT_RELEASE_SYNC=success
  RESULT_INTEGRATION_CONTRACT_UBUNTU=success
  RESULT_INTEGRATION_CONTRACT_MACOS=skipped
  RESULT_ISSUE_1030_WINDOWS=success
  RESULT_SHELLCHECK=success
  RESULT_PLATFORM_COMPAT=success
  RESULT_VALIDATE=success
  RESULT_GUARDED_RM_WINDOWS=success
  RESULT_UPGRADE_TEST=success
  RESULT_GUIDE_KIT_DRIFT=success
  RESULT_WINDOWS_SESSION_GUARD=success
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
[ "$(jq '.checks | length' "$OUT1")" = "11" ] || {
  echo "FAIL: all-success receipt does not list all 11 mandatory checks"
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

# Each Windows job is mandatory even when the other passes. A skipped job has
# not checked its invariant and must block publication too.
check_windows_gate() {
  local name=$1 result_var=$2 output result
  for result in failure skipped; do
    output="$TMP/receipt-$name-$result.json"
    if RELEASE_RECEIPT_OUT="$output" env "${ALL_SUCCESS_ENV[@]}" "$result_var=$result" bash "$SCRIPT"; then
      echo "FAIL: $name:$result did not block the receipt"
      exit 1
    fi
    [ "$(jq -r '.publishable' "$output")" = "false" ] || {
      echo "FAIL: $name:$result did not produce publishable=false"
      exit 1
    }
    [ "$(jq -r --arg name "$name" '.checks[] | select(.name==$name) | .result' "$output")" = "$result" ] || {
      echo "FAIL: receipt does not record $name:$result"
      exit 1
    }
  done
}
check_windows_gate issue-1030-windows RESULT_ISSUE_1030_WINDOWS
check_windows_gate guarded-rm-windows RESULT_GUARDED_RM_WINDOWS
check_windows_gate windows-session-guard RESULT_WINDOWS_SESSION_GUARD

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

# Issue #1032: this job runs on every trigger. A skipped or failed native
# Windows test cannot count as publishable, nor may the receipt omit the job.
for result in failure skipped unknown; do
  out="$TMP/receipt-windows-$result.json"
  if RELEASE_RECEIPT_OUT="$out" env "${ALL_SUCCESS_ENV[@]}" \
    RESULT_WINDOWS_SESSION_GUARD="$result" bash "$SCRIPT"; then
    echo "FAIL: windows-session-guard:$result was publishable" >&2
    exit 1
  fi
  [ "$(jq -r '.publishable' "$out")" = false ] && \
  [ "$(jq -r '.checks[] | select(.name=="windows-session-guard") | .result' "$out")" = "$result" ] || {
    echo "FAIL: windows-session-guard:$result was not recorded as blocking" >&2
    exit 1
  }
done

# Issue #1010a: a skipped macOS job is reported as skipped, not as success,
# and is mandatory on a release run. The release-run rule is the one
# release.yml applies (push|workflow_dispatch on main of the upstream
# repository, manifest version not tagged yet), so it is exercised on a
# disposable repository whose tags the test controls.
FX="$TMP/fixture"
mkdir -p "$FX/scripts/lib"
cp "$SCRIPT" "$FX/scripts/release-receipt.sh"
cp "$ROOT/scripts/lib/common.sh" "$FX/scripts/lib/common.sh"
printf '{\n  "version": "9.9.1"\n}\n' > "$FX/update-manifest.json"
git -C "$FX" init -q
git -C "$FX" add update-manifest.json scripts/release-receipt.sh scripts/lib/common.sh
git -C "$FX" -c user.email=t@example.invalid -c user.name=test commit -qm fixture
FX_SCRIPT="$FX/scripts/release-receipt.sh"
RELEASE_ENV=(GITHUB_EVENT_NAME=push GITHUB_REF_NAME=main GITHUB_REPOSITORY=TserenTserenov/FMT-exocortex-template)

release_run_is() {
  local expected=$1 label=$2 got
  shift 2
  got=$(env "$@" bash "$FX_SCRIPT" --release-run)
  [ "$got" = "$expected" ] || { echo "FAIL: --release-run for $label: expected $expected, got $got" >&2; exit 1; }
}
release_run_is true "push to main, version not tagged" "${RELEASE_ENV[@]}"
release_run_is true "workflow_dispatch on main, version not tagged" "${RELEASE_ENV[@]}" GITHUB_EVENT_NAME=workflow_dispatch
release_run_is false "pull_request" "${RELEASE_ENV[@]}" GITHUB_EVENT_NAME=pull_request
release_run_is false "schedule" "${RELEASE_ENV[@]}" GITHUB_EVENT_NAME=schedule
release_run_is false "push to another branch" "${RELEASE_ENV[@]}" GITHUB_REF_NAME=feature
release_run_is false "push in a fork" "${RELEASE_ENV[@]}" GITHUB_REPOSITORY=someone/FMT-exocortex-template

macos_receipt() {
  local out=$1 macos=$2
  shift 2
  RELEASE_RECEIPT_OUT="$out" env "${ALL_SUCCESS_ENV[@]}" "$@" \
    RESULT_INTEGRATION_CONTRACT_MACOS="$macos" bash "$FX_SCRIPT"
}

# Case 1: release run (untagged version), macOS skipped -> receipt fails.
OUT_R1="$TMP/receipt-release-macos-skipped.json"
if macos_receipt "$OUT_R1" skipped "${RELEASE_ENV[@]}" > "$TMP/r1.log"; then
  echo "FAIL: release run with skipped macOS job was publishable" >&2
  exit 1
fi
[ "$(jq -r '.publishable' "$OUT_R1")" = false ] && [ "$(jq -r '.release_run' "$OUT_R1")" = true ] || {
  echo "FAIL: release run with skipped macOS job not recorded as release_run=true, publishable=false" >&2
  exit 1
}
grep -q 'integration-contract-macos:skipped' "$TMP/r1.log" || {
  echo "FAIL: release-run failure does not name integration-contract-macos:skipped" >&2
  exit 1
}

# Case 2: release run, macOS ran green -> publishable, nothing skipped.
OUT_R2="$TMP/receipt-release-macos-success.json"
if ! macos_receipt "$OUT_R2" success "${RELEASE_ENV[@]}" > "$TMP/r2.log"; then
  echo "FAIL: release run with green macOS job was not publishable" >&2
  exit 1
fi
[ "$(jq -r '.publishable' "$OUT_R2")" = true ] && [ "$(jq -c '.skipped' "$OUT_R2")" = '[]' ] &&
  [ "$(jq -r '.checks[] | select(.name=="integration-contract-macos") | .result' "$OUT_R2")" = success ] || {
  echo "FAIL: green macOS on a release run not recorded as success with empty skipped list" >&2
  exit 1
}
if grep -q 'пропущено' "$TMP/r2.log"; then
  echo "FAIL: green macOS run printed a «пропущено» line" >&2
  exit 1
fi

# Case 3: not a release run (the version is already tagged), macOS skipped ->
# publishable, but listed as skipped and printed as «пропущено», not success.
git -C "$FX" tag v9.9.1
release_run_is false "push to main, version already tagged" "${RELEASE_ENV[@]}"
OUT_R3="$TMP/receipt-nonrelease-macos-skipped.json"
if ! macos_receipt "$OUT_R3" skipped "${RELEASE_ENV[@]}" > "$TMP/r3.log"; then
  echo "FAIL: non-release push with skipped macOS job was blocked" >&2
  exit 1
fi
[ "$(jq -r '.publishable' "$OUT_R3")" = true ] && [ "$(jq -r '.release_run' "$OUT_R3")" = false ] &&
  [ "$(jq -c '.skipped' "$OUT_R3")" = '["integration-contract-macos"]' ] &&
  [ "$(jq -r '.checks[] | select(.name=="integration-contract-macos") | .result' "$OUT_R3")" = skipped ] || {
  echo "FAIL: skipped macOS on a non-release run not listed separately as skipped" >&2
  exit 1
}
grep -q 'пропущено.*integration-contract-macos' "$TMP/r3.log" || {
  echo "FAIL: skipped macOS on a non-release run is not printed as «пропущено»" >&2
  exit 1
}

echo "PASS: release receipt fails closed for Windows failure, skipped and unknown results"
echo "PASS: macOS skip is reported as «пропущено» and blocks a release run"
