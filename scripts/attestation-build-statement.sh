#!/bin/bash
# attestation-build-statement.sh — WP-529 Ф21 in-toto Statement builder.
#
# Builds the JSON payload that attestation-sign.sh wraps in a DSSE envelope
# and signs. Schema: attestation-statement.schema.json (same directory).
#
# Deliberately built with `jq -n` (not string concatenation) — the payload
# is what gets signed, so a malformed-JSON or injection bug here would be a
# signing-oracle bug, not just a cosmetic one.
#
# Usage: attestation-build-statement.sh \
#   --subject-digest <hex64> --repo-name <owner/repo> --repo-id <int> \
#   --head-sha <hex40> --base-sha <hex40> \
#   --policy-id <string> --policy-digest <hex64> \
#   --verdict pass|fail|conditional [--ttl-hours <int, default 168>]
#
# Output (stdout, on success): the in-toto Statement JSON, one document.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: $0 --subject-digest <hex64> --repo-name <owner/repo> --repo-id <int> --head-sha <hex40> --base-sha <hex40> --policy-id <string> --policy-digest <hex64> --verdict pass|fail|conditional [--ttl-hours <int>]" >&2
  exit 2
}

SUBJECT_DIGEST="" REPO_NAME="" REPO_ID="" HEAD_SHA="" BASE_SHA=""
POLICY_ID="" POLICY_DIGEST="" VERDICT="" TTL_HOURS=168

while [ $# -gt 0 ]; do
  case "$1" in
    --subject-digest) SUBJECT_DIGEST="$2"; shift 2 ;;
    --repo-name) REPO_NAME="$2"; shift 2 ;;
    --repo-id) REPO_ID="$2"; shift 2 ;;
    --head-sha) HEAD_SHA="$2"; shift 2 ;;
    --base-sha) BASE_SHA="$2"; shift 2 ;;
    --policy-id) POLICY_ID="$2"; shift 2 ;;
    --policy-digest) POLICY_DIGEST="$2"; shift 2 ;;
    --verdict) VERDICT="$2"; shift 2 ;;
    --ttl-hours) TTL_HOURS="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

for name in SUBJECT_DIGEST REPO_NAME REPO_ID HEAD_SHA BASE_SHA POLICY_ID POLICY_DIGEST VERDICT; do
  [ -n "${!name}" ] || { echo "ERROR: --${name,,} is required" >&2; usage; }
done

check_hex() {
  local name="$1" value="$2" len="$3"
  printf '%s' "$value" | grep -qE "^[0-9a-f]{$len}\$" || {
    echo "ERROR: $name must be $len lowercase hex chars, got '$value'" >&2
    exit 3
  }
}
check_hex subject-digest "$SUBJECT_DIGEST" 64
check_hex head-sha "$HEAD_SHA" 40
check_hex base-sha "$BASE_SHA" 40
check_hex policy-digest "$POLICY_DIGEST" 64

case "$VERDICT" in
  pass|fail|conditional) ;;
  *) echo "ERROR: --verdict must be pass, fail, or conditional, got '$VERDICT'" >&2; exit 3 ;;
esac

ISSUED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EXPIRES_AT="$(date -u -v+"${TTL_HOURS}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "+${TTL_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)"

STATEMENT="$(jq -n \
  --arg subject_digest "$SUBJECT_DIGEST" \
  --arg repo_name "$REPO_NAME" \
  --argjson repo_id "$REPO_ID" \
  --arg head_sha "$HEAD_SHA" \
  --arg base_sha "$BASE_SHA" \
  --arg policy_id "$POLICY_ID" \
  --arg policy_digest "$POLICY_DIGEST" \
  --arg verdict "$VERDICT" \
  --arg issued_at "$ISSUED_AT" \
  --arg expires_at "$EXPIRES_AT" \
  '{
    "_type": "https://in-toto.io/Statement/v1",
    subject: [{
      name: $repo_name,
      digest: { sha256: $subject_digest },
      annotations: {
        "github.repository_id": $repo_id,
        "git.head_sha": $head_sha,
        "git.base_sha": $base_sha,
        "policy.id": $policy_id,
        "policy.digest.sha256": $policy_digest
      }
    }],
    predicateType: "https://aisystant.io/WP-529/red-team-attestation/v1",
    predicate: {
      verdict: $verdict,
      issued_at: $issued_at,
      expires_at: $expires_at
    }
  }')"

if command -v python3 >/dev/null 2>&1; then
  SCHEMA="$SCRIPT_DIR/attestation-statement.schema.json"
  if [ -f "$SCHEMA" ] && python3 -c "import jsonschema" >/dev/null 2>&1; then
    python3 -c "
import json, sys
import jsonschema
statement = json.loads(sys.argv[1])
schema = json.load(open(sys.argv[2]))
jsonschema.validate(statement, schema)
" "$STATEMENT" "$SCHEMA" || { echo "ERROR: built statement fails its own schema" >&2; exit 4; }
  fi
fi

printf '%s\n' "$STATEMENT"
