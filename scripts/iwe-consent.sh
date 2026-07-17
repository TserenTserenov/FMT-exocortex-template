#!/bin/bash
# routing: executor=script  deterministic=true  skill=consent  optimization_priority=1
# see DP.SC.159, DP.ROLE.059
# iwe-consent.sh
# WP-253 Блок 2 Ф0.6 — opt-in / opt-out / status для learning.tracking_consent.
#
# Usage:
#   iwe-consent.sh status                # показать текущий consent
#   iwe-consent.sh opt-in [scope1,scope2] # default: stage_evaluation
#   iwe-consent.sh opt-out               # opt_in=FALSE (сохраняет историю)
#   iwe-consent.sh revoke                # DELETE row (GDPR — полное удаление)
#
# Env:
#   IWE_OWNER_ORY_UUID                  — account_id (обязателен)
#   DATABASE_URL_CONSENT_WRITER         — preferred (миграция 113)
#   DATABASE_URL_LEARNING_DIRECT        — fallback

set -euo pipefail

ACTION="${1:-status}"
SCOPE="${2:-stage_evaluation}"

if [ -z "${IWE_OWNER_ORY_UUID:-}" ]; then
  echo "ERROR: IWE_OWNER_ORY_UUID env var required" >&2
  exit 2
fi

URL="${DATABASE_URL_CONSENT_WRITER:-${DATABASE_URL_LEARNING_DIRECT:-}}"

if [ -z "$URL" ]; then
  echo "ERROR: DATABASE_URL_CONSENT_WRITER or DATABASE_URL_LEARNING_DIRECT required" >&2
  exit 2
fi

case "$ACTION" in
  status)
    psql "$URL" --quiet -c "SELECT account_id, opt_in, scope, opted_at FROM learning.tracking_consent WHERE account_id = '${IWE_OWNER_ORY_UUID}'::uuid;"
    ;;
  opt-in)
    SCOPE_ARR=$(echo "$SCOPE" | tr ',' '|' | awk -F'|' '{for(i=1;i<=NF;i++) printf "'\''%s'\''%s", $i, (i<NF?",":"")}')
    psql "$URL" --quiet -v ON_ERROR_STOP=1 <<SQL
INSERT INTO learning.tracking_consent (account_id, opt_in, scope)
VALUES ('${IWE_OWNER_ORY_UUID}'::uuid, TRUE, ARRAY[${SCOPE_ARR}])
ON CONFLICT (account_id) DO UPDATE
SET opt_in = TRUE, scope = EXCLUDED.scope, opted_at = NOW();
SQL
    echo "[consent] opt-in OK: scope=[${SCOPE}]"
    ;;
  opt-out)
    psql "$URL" --quiet -v ON_ERROR_STOP=1 -c "UPDATE learning.tracking_consent SET opt_in = FALSE, opted_at = NOW() WHERE account_id = '${IWE_OWNER_ORY_UUID}'::uuid;"
    echo "[consent] opt-out OK (история сохранена, для полного удаления — revoke)"
    ;;
  revoke)
    psql "$URL" --quiet -v ON_ERROR_STOP=1 -c "DELETE FROM learning.tracking_consent WHERE account_id = '${IWE_OWNER_ORY_UUID}'::uuid;"
    echo "[consent] revoke OK (row удалена, GDPR right to erasure)"
    ;;
  *)
    echo "ERROR: unknown action '$ACTION'. Use: status | opt-in [scope] | opt-out | revoke" >&2
    exit 1
    ;;
esac
