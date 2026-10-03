#!/bin/bash
# release-receipt.sh — WP-529 Ф3 fail-closed release receipt.
#
# Aggregates the mandatory CI jobs of validate-template.yml into a single
# receipt tied to one commit: which checks ran, what they returned, and
# whether the tree is publishable. Fed by `needs.<job>.result` from the same
# workflow run — same trigger, same SHA — not by querying job status from
# elsewhere, which is exactly the trust gap Ф3 exists to close (a red main
# for two days, one accidental green run, proved that "we run this check
# somewhere" says nothing about whether THIS commit passed it).
#
# publishable=true requires all three Windows jobs to report success. Other
# mandatory checks may be intentionally skipped for this trigger (e.g. macOS
# integration on push). Failure/cancelled/unknown, or a skipped Windows job,
# produces false. The script exits 1 so branch protection can require this
# receipt instead of enumerating every individual job (Ф2).
#
# Usage (CI): RESULT_<JOB>=<needs.<job>.result> bash scripts/release-receipt.sh
# Usage (local dry-run): bash scripts/release-receipt.sh — reads "unknown" for
# unset RESULT_* vars, which counts as a failure (fail-closed, not fail-open).
#
# Exit 0 = publishable. Exit 1 = not publishable (receipt still written).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$SCRIPT_DIR/update-manifest.json"
RECEIPT="${RELEASE_RECEIPT_OUT:-$SCRIPT_DIR/release-receipt.json}"

[ -f "$MANIFEST" ] || { echo "ERROR: $MANIFEST не найден"; exit 2; }

SHA="${RELEASE_RECEIPT_SHA:-$(git -C "$SCRIPT_DIR" rev-parse HEAD)}"
# Same "second version bump in update-manifest.json history" logic
# validate-template.yml's upgrade-test job already uses to find the previous
# published version — reused here, not reimplemented, so the receipt's
# base_sha always agrees with what upgrade-test actually exercised.
BASE_SHA="$(git -C "$SCRIPT_DIR" log --format=%H -- "$MANIFEST" | sed -n '2p')"
MANIFEST_HASH="$(sha256sum "$MANIFEST" | awk '{print $1}')"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Ordered, not an associative array — JSON key order in the receipt should
# be stable across runs, and bash associative-array iteration order isn't.
CHECK_NAMES=(
  release-sync
  integration-contract-ubuntu
  integration-contract-macos
  issue-1030-windows
  shellcheck
  platform-compat
  validate
  guarded-rm-windows
  upgrade-test
  guide-kit-drift
  windows-session-guard
)
CHECK_ENV_VARS=(
  RESULT_RELEASE_SYNC
  RESULT_INTEGRATION_CONTRACT_UBUNTU
  RESULT_INTEGRATION_CONTRACT_MACOS
  RESULT_ISSUE_1030_WINDOWS
  RESULT_SHELLCHECK
  RESULT_PLATFORM_COMPAT
  RESULT_VALIDATE
  RESULT_GUARDED_RM_WINDOWS
  RESULT_UPGRADE_TEST
  RESULT_GUIDE_KIT_DRIFT
  RESULT_WINDOWS_SESSION_GUARD
)

PUBLISHABLE=true
CHECKS_JSON="[]"
FAILED_NAMES=()

for i in "${!CHECK_NAMES[@]}"; do
  name="${CHECK_NAMES[$i]}"
  var="${CHECK_ENV_VARS[$i]}"
  result="${!var:-unknown}"
  case "$result" in
    success) ;;
    skipped)
      # These Windows jobs run on every trigger; skipped bypasses their proof.
      if [ "$name" = issue-1030-windows ] || [ "$name" = guarded-rm-windows ] ||
         [ "$name" = windows-session-guard ]; then
        PUBLISHABLE=false
        FAILED_NAMES+=("$name:$result")
      fi
      ;;
    *)
      PUBLISHABLE=false
      FAILED_NAMES+=("$name:$result")
      ;;
  esac
  CHECKS_JSON=$(echo "$CHECKS_JSON" | jq --arg name "$name" --arg result "$result" \
    '. + [{name: $name, result: $result}]')
done

jq -n \
  --arg sha "$SHA" \
  --arg base_sha "${BASE_SHA:-}" \
  --arg manifest_hash "$MANIFEST_HASH" \
  --arg generated_at "$GENERATED_AT" \
  --argjson publishable "$PUBLISHABLE" \
  --argjson checks "$CHECKS_JSON" \
  '{sha: $sha, base_sha: $base_sha, manifest_hash: $manifest_hash,
    generated_at: $generated_at, checks: $checks, publishable: $publishable}' \
  > "$RECEIPT"

if [ "$PUBLISHABLE" = "true" ]; then
  echo "PASS: publishable=true — $SHA"
else
  echo "FAIL: publishable=false — $SHA"
  echo "  Обязательные проверки с недопустимым результатом: ${FAILED_NAMES[*]}"
  exit 1
fi
