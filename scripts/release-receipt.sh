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
# integration on an ordinary push); a skip is listed in the receipt's
# "skipped" array and printed as «пропущено», never counted as success.
# On a release run (#1010a) the macOS integration job is mandatory too: its
# skip blocks the receipt. Failure/cancelled/unknown, or a skipped Windows
# job, produces false. The script exits 1 so branch protection can require
# this receipt instead of enumerating every individual job (Ф2).
#
# Release run = the run whose green result makes release.yml publish a new
# release: same repository, a push or workflow_dispatch run on main, and no
# tag v<manifest version> yet (release.yml's job `if:` plus its tag check).
# `--release-run` prints that decision (true/false) so the macOS job can be
# scheduled with the same rule the receipt enforces.
#
# Usage (CI): RESULT_<JOB>=<needs.<job>.result> bash scripts/release-receipt.sh
# Usage (CI): bash scripts/release-receipt.sh --release-run
# Usage (local dry-run): bash scripts/release-receipt.sh — reads "unknown" for
# unset RESULT_* vars, which counts as a failure (fail-closed, not fail-open).
#
# Exit 0 = publishable. Exit 1 = not publishable (receipt still written).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"
MANIFEST="$SCRIPT_DIR/update-manifest.json"
RECEIPT="${RELEASE_RECEIPT_OUT:-$SCRIPT_DIR/release-receipt.json}"

[ -f "$MANIFEST" ] || { echo "ERROR: $MANIFEST не найден"; exit 2; }

# The repository whose main branch release.yml publishes from (its job `if:`).
RELEASE_REPOSITORY="TserenTserenov/FMT-exocortex-template"

# Prints true when this run is the one release.yml would turn into a release.
# Mirrors release.yml: repository gate, event push|workflow_dispatch on main,
# version read from the manifest the same way, release only if the tag
# v<version> does not exist yet. Anything that cannot be determined (no
# version, git unavailable) answers true: the stricter gate applies.
is_release_run() {
  local version
  [ "${GITHUB_REPOSITORY:-}" = "$RELEASE_REPOSITORY" ] || { echo false; return; }
  case "${GITHUB_EVENT_NAME:-}" in
    push|workflow_dispatch) ;;
    *) echo false; return ;;
  esac
  [ "${GITHUB_REF_NAME:-}" = main ] || { echo false; return; }
  version=$(grep -m1 '"version"' "$MANIFEST" \
    | sed 's/.*"version"[[:space:]]*:[[:space:]]*"//;s/".*//')
  if [ -z "$version" ] || ! git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo true
    return
  fi
  if git -C "$SCRIPT_DIR" rev-parse "refs/tags/v$version" >/dev/null 2>&1; then
    echo false
  else
    echo true
  fi
}

if [ "${1:-}" = "--release-run" ]; then
  is_release_run
  exit 0
fi
RELEASE_RUN="$(is_release_run)"

SHA="${RELEASE_RECEIPT_SHA:-$(git -C "$SCRIPT_DIR" rev-parse HEAD)}"
# Same "second version bump in update-manifest.json history" logic
# validate-template.yml's upgrade-test job already uses to find the previous
# published version — reused here, not reimplemented, so the receipt's
# base_sha always agrees with what upgrade-test actually exercised.
BASE_SHA="$(git -C "$SCRIPT_DIR" log --format=%H -- "$MANIFEST" | sed -n '2p')"
# iwe_sha256 (lib/common.sh): bare sha256sum is GNU-only, no shasum/macOS
# fallback (issue #1108).
MANIFEST_HASH="$(iwe_sha256 < "$MANIFEST")"
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
SKIPPED_NAMES=()

for i in "${!CHECK_NAMES[@]}"; do
  name="${CHECK_NAMES[$i]}"
  var="${CHECK_ENV_VARS[$i]}"
  result="${!var:-unknown}"
  case "$result" in
    success) ;;
    skipped)
      # These Windows jobs run on every trigger; skipped bypasses their proof.
      # The macOS job is scheduled on release runs, so a skip there means the
      # release would ship without the macOS proof (#1010a).
      if [ "$name" = issue-1030-windows ] || [ "$name" = guarded-rm-windows ] ||
         [ "$name" = windows-session-guard ] ||
         { [ "$name" = integration-contract-macos ] && [ "$RELEASE_RUN" = true ]; }; then
        PUBLISHABLE=false
        FAILED_NAMES+=("$name:$result")
      else
        SKIPPED_NAMES+=("$name")
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
  --argjson release_run "$RELEASE_RUN" \
  --argjson skipped "$(printf '%s\n' "${SKIPPED_NAMES[@]+"${SKIPPED_NAMES[@]}"}" | jq -R . | jq -s 'map(select(length > 0))')" \
  '{sha: $sha, base_sha: $base_sha, manifest_hash: $manifest_hash,
    generated_at: $generated_at, release_run: $release_run, checks: $checks,
    skipped: $skipped, publishable: $publishable}' \
  > "$RECEIPT"

if [ "${#SKIPPED_NAMES[@]}" -gt 0 ]; then
  echo "  пропущено (не проверялось на этом запуске): ${SKIPPED_NAMES[*]}"
fi
if [ "$PUBLISHABLE" = "true" ]; then
  echo "PASS: publishable=true — $SHA"
else
  echo "FAIL: publishable=false — $SHA"
  echo "  Обязательные проверки с недопустимым результатом: ${FAILED_NAMES[*]}"
  if [ "$RELEASE_RUN" = true ]; then
    echo "  Релизный запуск: macOS-проверка обязательна, пропуск блокирует выпуск."
  fi
  exit 1
fi
