#!/usr/bin/env bash
# iwe-notify --direct: the gateway is present and working, yet it is not called;
# one direct Bot API send, one direct-send-log.tsv row with reason
# direct-requested, outcome direct-sent / direct-failed / not-sent (no keys).
# Without the flag the same setup still goes through the gateway.
# The gateway and curl are stubs that record their calls; nothing leaves the host.
set -uo pipefail
NOTIFY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/iwe-notify"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/iwe-notify-direct.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ❌ $1 — fact: ${2:-no data}"; FAIL=$((FAIL + 1)); }

mkdir -p "$WORK/bin" "$WORK/iwe/DS-strategy/scripts"
printf '%s\n' '#!/bin/bash' 'echo "$*" >> "$CURL_CALLS"' \
  'printf "%s" "{\"ok\":true}"' 'exit "${CURL_RC:-0}"' > "$WORK/bin/curl"
printf '%s\n' '#!/bin/bash' 'echo "$*" >> "$GATEWAY_CALLS"' 'exit 0' > "$WORK/iwe/DS-strategy/scripts/iwe-tg"
chmod +x "$WORK/bin/curl" "$WORK/iwe/DS-strategy/scripts/iwe-tg"
export PATH="$WORK/bin:$PATH" CURL_CALLS="$WORK/curl-calls" GATEWAY_CALLS="$WORK/gateway-calls"
export TELEGRAM_BOT_TOKEN=t TELEGRAM_CHAT_ID=c DS_PUBLISH_ADMISSION_DIR="$WORK/adm" IWE_ROOT="$WORK/iwe"
unset IWE_NOTIFY_GATEWAY IWE_GOVERNANCE_REPO
LOG="$WORK/adm/direct-send-log.tsv"
count() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
reset() { rm -f "$CURL_CALLS" "$GATEWAY_CALLS" "$LOG"; }

# direct_case <label> <expected outcome> <expected row outcome> <env...>
direct_case() {
  local label="$1" want="$2" row="$3" out; shift 3
  reset
  out="$(env "$@" "$NOTIFY" --direct --source s-test "text" 2>/dev/null)"
  if [ "$out" = "iwe-notify: outcome=$want" ] && [ "$(count "$GATEWAY_CALLS")" = 0 ] \
    && awk -F'\t' -v r="$row" '$2=="s-test" && $3=="direct-requested" && $4==r' "$LOG" | grep -q .; then
    ok "--direct, $label: gateway not called, outcome $want, row direct-requested"
  else
    bad "--direct, $label" "stdout=$out gateway=$(count "$GATEWAY_CALLS") log=$(cat "$LOG" 2>&1)"
  fi
}
direct_case "Telegram accepted" direct-sent sent
direct_case "Telegram refused" direct-failed failed CURL_RC=22

reset
out="$(TELEGRAM_BOT_TOKEN='' "$NOTIFY" --direct --source s-test "text" 2>/dev/null)"
if [ "$out" = "iwe-notify: outcome=not-sent" ] && [ "$(count "$GATEWAY_CALLS")" = 0 ] && [ "$(count "$CURL_CALLS")" = 0 ]; then
  ok "--direct without keys: nothing sent, gateway not called"
else
  bad "--direct without keys" "stdout=$out gateway=$(count "$GATEWAY_CALLS") curl=$(count "$CURL_CALLS")"
fi

reset
"$NOTIFY" --source s-test "text" >/dev/null 2>&1
if [ "$(count "$GATEWAY_CALLS")" = 1 ] && [ "$(count "$CURL_CALLS")" = 0 ]; then
  ok "without --direct the gateway still decides"
else
  bad "without --direct" "gateway=$(count "$GATEWAY_CALLS") curl=$(count "$CURL_CALLS")"
fi

echo "total: ✅ $PASS  ❌ $FAIL"
[ "$FAIL" -eq 0 ]
