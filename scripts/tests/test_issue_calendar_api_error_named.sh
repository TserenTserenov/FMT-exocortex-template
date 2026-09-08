#!/usr/bin/env bash
set -euo pipefail

# WP-529 Red Team review round 2 (Evgenii, 2026-08-19, defect #4): a Google
# Calendar API error response ({"error":{"code":403,...}}) on a whole
# calendar passed through a silent `continue` — no cid, no code, unlike the
# curl/json branches two steps above it in server-calendar.sh. issue #453
# fixed the same class of drop for a single event's visibility, not for a
# whole calendar's API error. This test fakes a 403 response on one calendar
# and asserts (a) the error is recorded by name+code, not silently dropped,
# and (b) the script's own exit code now signals this specific error class
# (curl/json/private-event drops stay non-fatal by design — Codex's "не
# следует превращать любой непустой errors[] в fatal" concern from the same
# review round; only the "calendar API error" class does).
#
# Cold review 2026-08-19 (Codex, turn 8): day mode and week mode are two
# separate `sys.exit` call sites in server-calendar.sh (day mode's exit was
# added by this same fix — it had no explicit exit at all before), so a
# regression that keeps the day-mode exit code correct while losing it in
# week mode (or vice versa) would not be caught by exercising only one path.
# Both modes are checked below with the SAME 403 fixture.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/curl" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == *oauth2.googleapis.com/token* ]]; then
        echo '{"access_token": "fake-token"}'
        exit 0
    fi
done
cat <<'JSON'
{"error": {"code": 403, "message": "The caller does not have permission"}}
JSON
SH
chmod +x "$TMP/curl"

cat > "$TMP/day-rhythm-config.yaml" <<'YAML'
calendar_ids:
  - forbidden-calendar@example.com
YAML

export GOOGLE_REFRESH_TOKEN="fake-refresh"
export GOOGLE_CLIENT_ID="fake-client"
export GOOGLE_CLIENT_SECRET="fake-secret"
export HOME="$TMP/fakehome"
mkdir -p "$HOME"

FAIL=0

check_mode() {
    local mode_label="$1"
    shift
    set +e
    local output
    output=$(PATH="$TMP:$PATH" bash "$ROOT/scripts/server-calendar.sh" "$@" 2026-08-18 "$TMP/day-rhythm-config.yaml")
    local status=$?
    set -e

    if echo "$output" | grep -q "calendar API error for forbidden-calendar@example.com: code=403"; then
        echo "PASS ($mode_label 1/2): 403-ошибка календаря записана по имени и коду, не пропущена молча"
    else
        echo "FAIL ($mode_label 1/2): ожидалась поимённая запись 403-ошибки, не нашли"
        echo "$output"
        FAIL=1
    fi

    if [[ "$status" -ne 0 ]]; then
        echo "PASS ($mode_label 2/2): скрипт вернул ненулевой exit-код при 403-ошибке календаря"
    else
        echo "FAIL ($mode_label 2/2): ожидался ненулевой exit-код, получили $status"
        echo "$output"
        FAIL=1
    fi
}

check_mode "день"
check_mode "неделя" --week

[ "$FAIL" -eq 0 ]
