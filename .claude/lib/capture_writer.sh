#!/bin/bash
# capture_writer.sh
# see DP.SC.025 (capture-bus service clause), DP.ROLE.001#R47 (Детектор)
# Writer: принимает JSON event из stdin, пишет в целевой репо (файл) + raw_events (если включён).
# НЕТ fallback — если target_repo не разрешён, событие отклоняется (инвариант OwnerIntegrity).
#
# Input (stdin): JSON
#   {
#     "event_type": "agent_incident|decision_user|...",
#     "payload": {...},
#     "repo_ctx": {"target_repo_hint": "..."}
#   }
# Плюс переменные среды (опционально) от dispatcher:
#   CAPTURE_CWD, CAPTURE_TOOL_FILE, CAPTURE_SESSION_ID, CAPTURE_DETECTOR_NAME
#
# Exit:
#   0 — записано
#   1 — отклонено (target_repo_unresolved или другая ошибка)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./log_formatter.sh
source "$SCRIPT_DIR/log_formatter.sh"

LOG_FILE="${CAPTURE_LOG_FILE:-$HOME/IWE/.claude/logs/capture_log.jsonl}"

# Опциональная пользовательская конфигурация: путь и REL_DIR для агрегации
# инцидентов (если пользователь хочет аккумулировать agent_incident в отдельный
# governance-репо вместо target_repo детектора). Файл вне git (FMT-default — нет файла).
CAPTURE_CONFIG="${CAPTURE_CONFIG:-${IWE_ROOT:-$HOME/IWE}/.claude/capture-config.sh}"
# shellcheck disable=SC1090
[ -f "$CAPTURE_CONFIG" ] && source "$CAPTURE_CONFIG"

EVENT=$(cat)

if [ -z "$EVENT" ]; then
  exit 0  # пустое событие = skip (детектор не обнаружил)
fi

EVENT_TYPE=$(echo "$EVENT" | jq -r '.event_type // empty')
if [ -z "$EVENT_TYPE" ]; then
  log_jsonl "$LOG_FILE" \
    detector="${CAPTURE_DETECTOR_NAME:-unknown}" \
    status=writer_reject \
    reason=missing_event_type
  exit 1
fi

HINT=$(echo "$EVENT" | jq -r '.repo_ctx.target_repo_hint // empty')
FILE_CTX="${CAPTURE_TOOL_FILE:-}"
CWD_CTX="${CAPTURE_CWD:-$PWD}"

# Override: agent_incident с INCIDENT_TARGET_REPO в capture-config.sh пропускает
# resolve_target_repo (агрегация в governance-хаб не зависит от исполнителя).
if [ "$EVENT_TYPE" = "agent_incident" ] && [ -n "${INCIDENT_TARGET_REPO:-}" ]; then
  TARGET_REPO="$INCIDENT_TARGET_REPO"
elif TARGET_REPO=$("$SCRIPT_DIR/resolve_target_repo.sh" --hint="$HINT" --file="$FILE_CTX" --cwd="$CWD_CTX" 2>/tmp/capture_resolve_err); then
  :
else
  REASON=$(cat /tmp/capture_resolve_err 2>/dev/null || echo "unknown")
  rm -f /tmp/capture_resolve_err
  log_jsonl "$LOG_FILE" \
    detector="${CAPTURE_DETECTOR_NAME:-unknown}" \
    event_type="$EVENT_TYPE" \
    status=writer_reject \
    reason="target_repo_unresolved: $REASON"
  exit 1
fi

# Routing: event_type → target_path внутри репо
YYYY_MM=$(date +%Y-%m)
case "$EVENT_TYPE" in
  agent_incident)
    # HD «Лог ≠ Инцидент ≠ State file» (DP.D.049): по умолчанию инцидент пишется
    # в target_repo детектора (рядом с исполнителем). Override через capture-config.sh:
    #   INCIDENT_TARGET_REPO — абсолютный путь к governance-репо для агрегации.
    #   INCIDENT_REL_DIR     — префикс директории внутри репо (default: "inbox").
    if [ -n "${INCIDENT_TARGET_REPO:-}" ]; then
      TARGET_REPO="$INCIDENT_TARGET_REPO"
    fi
    REL_DIR="${INCIDENT_REL_DIR:-inbox}"
    REL_PATH="${REL_DIR}/incident-log-${YYYY_MM}.md"
    FORMAT="markdown"
    ;;
  decision_user)
    REL_PATH="decisions/decision-log-${YYYY_MM}.md"
    FORMAT="markdown"
    ;;
  gate_fired)
    REL_PATH=".claude/logs/gate-log-${YYYY_MM}.jsonl"
    FORMAT="jsonl"
    ;;
  verification_result)
    SLUG=$(echo "$EVENT" | jq -r '.payload.slug // "unknown"')
    REL_PATH="inbox/verify-$(date +%Y-%m-%d)-${SLUG}.md"
    FORMAT="markdown"
    ;;
  drift_detected)
    REL_PATH="inbox/drift-$(date +%Y-%m-%d).md"
    FORMAT="markdown"
    ;;
  *)
    log_jsonl "$LOG_FILE" \
      detector="${CAPTURE_DETECTOR_NAME:-unknown}" \
      event_type="$EVENT_TYPE" \
      status=writer_reject \
      reason=unknown_event_type
    exit 1
    ;;
esac

TARGET_PATH="$TARGET_REPO/$REL_PATH"
mkdir -p "$(dirname "$TARGET_PATH")"

# Append to target file
TS_ISO=$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")
if [ "$FORMAT" = "jsonl" ]; then
  echo "$EVENT" | jq -c --arg ts "$TS_ISO" '. + {ts: $ts}' >> "$TARGET_PATH"
else
  # markdown entry
  {
    echo ""
    echo "## $TS_ISO — $EVENT_TYPE"
    echo ""
    echo '```json'
    echo "$EVENT" | jq .
    echo '```'
  } >> "$TARGET_PATH"
fi

# raw_events INSERT (WP-109 Ф7b, Ф8.4 DONE → разблокировано)
# Гейт: CAPTURE_RAW_EVENTS=1 + IWE_DATABASE_URL задан + psql доступен.
# Graceful degradation: если что-то из этого отсутствует — молча пропускаем.
if [ "${CAPTURE_RAW_EVENTS:-0}" = "1" ]; then
  DB_URL="${IWE_DATABASE_URL:-}"
  if [ -z "$DB_URL" ] && [ -n "${IWE_DB_ENV_FILE:-}" ] && [ -f "$IWE_DB_ENV_FILE" ]; then
    DB_URL=$(grep '^DATABASE_URL=' "$IWE_DB_ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2-)
  fi

  PSQL_BIN=$(which psql 2>/dev/null || true)

  if [ -n "$DB_URL" ] && [ -n "$PSQL_BIN" ]; then
    # external_id: хэш от event_type + session_id + ts (idempotency key)
    EXT_ID=$(echo "${EVENT_TYPE}:${SESSION_ID:-no-session}:${TS_ISO}" | md5sum | awk '{print $1}')
    PAYLOAD_JSON=$(echo "$EVENT" | jq -c '.')

    PSQL_SQL="INSERT INTO development.raw_events (source, external_id, payload, fetched_at)
              VALUES ('iwe', '${EXT_ID}', '${PAYLOAD_JSON}'::jsonb, NOW())
              ON CONFLICT (source, external_id, fetched_at) DO NOTHING;"

    if echo "$PSQL_SQL" | "$PSQL_BIN" "$DB_URL" -q 2>/tmp/capture_psql_err_$$ ; then
      log_jsonl "$LOG_FILE" \
        detector="${CAPTURE_DETECTOR_NAME:-unknown}" \
        event_type="$EVENT_TYPE" \
        status=raw_inserted \
        ext_id="$EXT_ID"
    else
      psql_err=$(cat /tmp/capture_psql_err_$$ 2>/dev/null | head -c 200)
      log_jsonl "$LOG_FILE" \
        detector="${CAPTURE_DETECTOR_NAME:-unknown}" \
        event_type="$EVENT_TYPE" \
        status=raw_insert_failed \
        reason="${psql_err:-unknown}"
    fi
    rm -f /tmp/capture_psql_err_$$
  fi
fi

log_jsonl "$LOG_FILE" \
  detector="${CAPTURE_DETECTOR_NAME:-unknown}" \
  event_type="$EVENT_TYPE" \
  status=fired \
  latency_ms="${CAPTURE_DETECTOR_LATENCY_MS:-}" \
  target_repo="$TARGET_REPO" \
  target_path="$REL_PATH"

exit 0
