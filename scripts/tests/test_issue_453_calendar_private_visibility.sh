#!/usr/bin/env bash
set -euo pipefail

# issue #453: server-calendar.sh drops private-visibility events without any
# trace — the returned "errors" list stays empty, so the shown event count
# silently matches the (already-filtered) event count and looks consistent.
# This test fakes the Google Calendar HTTP layer (a stand-in "curl" ahead of
# the real one in PATH) with two events, one of them visibility:private, and
# asserts the skip is now recorded in errors instead of vanishing silently.

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
{"items": [
  {"summary": "Открытая встреча", "start": {"dateTime": "2026-08-18T10:00:00+03:00"}, "end": {"dateTime": "2026-08-18T10:30:00+03:00"}, "visibility": "default"},
  {"summary": "Личный приём", "start": {"dateTime": "2026-08-18T11:00:00+03:00"}, "end": {"dateTime": "2026-08-18T11:30:00+03:00"}, "visibility": "private"}
]}
JSON
SH
chmod +x "$TMP/curl"

cat > "$TMP/day-rhythm-config.yaml" <<'YAML'
calendar_ids:
  - primary
YAML

export GOOGLE_REFRESH_TOKEN="fake-refresh"
export GOOGLE_CLIENT_ID="fake-client"
export GOOGLE_CLIENT_SECRET="fake-secret"
export HOME="$TMP/fakehome"
mkdir -p "$HOME"

OUTPUT=$(PATH="$TMP:$PATH" bash "$ROOT/scripts/server-calendar.sh" 2026-08-18 "$TMP/day-rhythm-config.yaml")

if echo "$OUTPUT" | grep -q "Открытая встреча"; then
    echo "PASS (1/2): непубличное событие по-прежнему показывается"
else
    echo "FAIL (1/2): открытое событие пропало из вывода"
    echo "$OUTPUT"
    exit 1
fi

# "Личный приём" must appear exactly once — inside the explicit skip notice,
# never as a row in the rendered events table (that would mean it leaked
# through the visibility filter instead of being reported and dropped).
MENTIONS=$(echo "$OUTPUT" | grep -c "Личный приём")
if [[ "$MENTIONS" -ne 1 ]]; then
    echo "FAIL (2/2): ожидалось ровно одно упоминание приватного события (в предупреждении), нашли $MENTIONS"
    echo "$OUTPUT"
    exit 1
fi

if echo "$OUTPUT" | grep -q "| .* | Личный приём |"; then
    echo "FAIL (2/2): приватное событие попало в таблицу отображаемых событий"
    echo "$OUTPUT"
    exit 1
fi

if echo "$OUTPUT" | grep -qi "skipped private event"; then
    echo "PASS (2/2): пропуск приватного события зафиксирован явно, не молча"
else
    echo "FAIL (2/2): приватное событие пропущено без единой пометки — issue #453 не устранена"
    echo "$OUTPUT"
    exit 1
fi
