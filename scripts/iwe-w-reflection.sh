#!/bin/bash
# routing: executor=script  deterministic=true  skill=w-reflection  optimization_priority=1
# see DP.SC.159, DP.ROLE.059
# iwe-w-reflection.sh
# see DP.SC.020 (event-gateway contract — but this command writes DIRECTLY to the DB, not via gateway,
#                because w_reflections not event-stream, but a diagnostics artifact of Diagnostician R28 R28).
# WP-253 Block 2 Phase0.5 — writer for learning.w_reflections.
#
# Usage:
#   iwe-w-reflection.sh <quality_score> [depth_level]
#
# Args:
#   quality_score — 1..5 (CHECK constraint in the DB)
#   depth_level   — 1..3 (default: 2). 1=shallow, 2=medium, 3=deep
#
# Env:
#   IWE_OWNER_ORY_UUID                  — account_id (required)
#   DATABASE_URL_W_REFLECTION_WRITER    — preferred (role w_reflection_writer)
#   DATABASE_URL_LEARNING_DIRECT        — fallback (if writer-writer role is not configured)
#
# Exit: 0 success, 1 invalid args, 2 missing env, 3 DB error.

set -euo pipefail

QUALITY="${1:-}"
DEPTH="${2:-2}"

if ! [[ "$QUALITY" =~ ^[1-5]$ ]]; then
  echo "ERROR: quality_score must be 1..5, got: $QUALITY" >&2
  exit 1
fi
if ! [[ "$DEPTH" =~ ^[1-3]$ ]]; then
  echo "ERROR: depth_level must be 1..3, got: $DEPTH" >&2
  exit 1
fi

if [ -z "${IWE_OWNER_ORY_UUID:-}" ]; then
  echo "ERROR: IWE_OWNER_ORY_UUID env var required" >&2
  exit 2
fi

URL="${DATABASE_URL_W_REFLECTION_WRITER:-${DATABASE_URL_LEARNING_DIRECT:-}}"

if [ -z "$URL" ]; then
  echo "ERROR: DATABASE_URL_W_REFLECTION_WRITER or DATABASE_URL_LEARNING_DIRECT required" >&2
  exit 2
fi

# L2-PRIVACY: explicit WHERE account_id (even though it is an INSERT, but for consistency with reads)
psql "$URL" --quiet -v ON_ERROR_STOP=1 <<SQL
INSERT INTO learning.w_reflections (account_id, session_at, quality_score, depth_level)
VALUES ('${IWE_OWNER_ORY_UUID}'::uuid, NOW(), ${QUALITY}, ${DEPTH});
SQL

echo "[w-reflection] OK: account=${IWE_OWNER_ORY_UUID:0:8}... quality=${QUALITY} depth=${DEPTH}"
