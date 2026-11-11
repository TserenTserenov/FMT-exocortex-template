#!/usr/bin/env bash
# Regression: notify.sh sends a byte-identical message for one <agent>/<scenario>
# only once per calendar day (bug 11.11.2026: the day-plan digest arrived 2-3 times
# a morning because the scenario runner and the prompt that tells the model to run
# notify.sh both sent it). Observations checked here:
#   1. the first send reaches the transport and writes the marker;
#   2. the same text again is skipped without a transport call;
#   3. a changed text is sent;
#   4. --force resends an identical text;
#   5. a failed delivery leaves no marker, so the next attempt still sends;
#   6. a scenario outside the allowlist is never suppressed (identical repeats stay).
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
NOTIFY="$ROOT/roles/synchronizer/scripts/notify.sh"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; fails=$((fails + 1)); }

[ -f "$NOTIFY" ] || { echo "notify.sh not found: $NOTIFY" >&2; exit 1; }

export HOME="$TMP/home"
export IWE_RUNTIME="$TMP/runtime"
# The guard is an allowlist; the probe scenarios below are the ones under test.
export IWE_NOTIFY_DEDUPE="probe/day-plan probe/broken"
CALLS="$TMP/curl.calls"
mkdir -p "$HOME/.config/aist" "$TMP/bin" "$TMP/templates"
printf 'TELEGRAM_BOT_TOKEN=t\nTELEGRAM_CHAT_ID=1\n' > "$HOME/.config/aist/env"

# The template decides the text: one fixed message, one that changes, one that fails.
cat > "$TMP/templates/probe.sh" <<'EOF'
build_message() {
    case "$1" in
        changed) printf '<b>plan</b> v2' ;;
        broken)  printf '<b>broken</b>' ;;
        *)       printf '<b>plan</b> v1' ;;
    esac
}
build_buttons() { printf '[]'; }
EOF

# A curl stub: 'ok' unless the failure switch file exists.
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
[ -f "$TMP/fail" ] && { echo '{"ok":false,"description":"stub failure"}'; exit 0; }
echo '{"ok":true}'
EOF
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
export TEMPLATES_DIR="$TMP/templates"

calls() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0; }
marker() { ls "$IWE_RUNTIME/state/notify-sent"/*.last 2>/dev/null | head -1; }

# 1. First send goes out and leaves a marker.
out=$(bash "$NOTIFY" probe day-plan 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "first send exited $rc (expected 0)"
[ "$(calls)" = 1 ] || fail "first send: expected 1 transport call, got $(calls)"
printf '%s' "$out" | grep -q "^Telegram notification sent: probe/day-plan$" \
    || fail "first send: no 'sent' line in output"
[ -n "$(marker)" ] || fail "first send: no marker written"

# 2. The same text again: skipped, no second transport call.
out=$(bash "$NOTIFY" probe day-plan 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "duplicate: expected exit 0 (already delivered), got $rc"
printf '%s' "$out" | grep -q "^SKIP: duplicate notification probe/day-plan" \
    || fail "duplicate: no SKIP line (got: $(printf '%s' "$out" | head -1))"
[ "$(calls)" = 1 ] || fail "duplicate: transport was called again ($(calls) calls)"

# 3. A different text for the same scenario is not a duplicate.
out=$(bash "$NOTIFY" probe changed 2>&1); rc=$?
[ "$(calls)" = 2 ] || fail "changed text: expected 2 transport calls, got $(calls)"
printf '%s' "$out" | grep -q "^Telegram notification sent: probe/changed$" \
    || fail "changed text: no 'sent' line"

# 4. --force resends an identical text.
out=$(bash "$NOTIFY" --force probe day-plan 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "--force: exited $rc"
printf '%s' "$out" | grep -q "^Telegram notification sent: probe/day-plan$" \
    || fail "--force: no 'sent' line"
[ "$(calls)" = 3 ] || fail "--force: expected 3 transport calls, got $(calls)"

# 5. A failed delivery writes no marker: the next attempt must still send.
touch "$TMP/fail"
bash "$NOTIFY" probe broken >/dev/null 2>&1
out=$(bash "$NOTIFY" probe broken 2>&1)
rm -f "$TMP/fail"
printf '%s' "$out" | grep -q "^SKIP: duplicate notification probe/broken" \
    && fail "failed delivery: the second attempt was suppressed as a duplicate"
printf '%s' "$out" | grep -qE "^(Telegram notification sent|Telegram send FAILED): probe/broken" \
    || fail "failed delivery: no send attempt line on the retry"

# 6. A scenario outside the allowlist keeps the old behaviour: identical text twice
#    is two sends (the guard must not silence legitimate repeats).
before=$(calls)
bash "$NOTIFY" probe unlisted >/dev/null 2>&1
out=$(bash "$NOTIFY" probe unlisted 2>&1)
[ "$(calls)" = "$((before + 2))" ] || fail "unlisted scenario: expected 2 sends, transport calls went $before -> $(calls)"
printf '%s' "$out" | grep -q "^SKIP: duplicate" && fail "unlisted scenario: suppressed as a duplicate"

if [ "$fails" -eq 0 ]; then
    echo "OK: notify.sh duplicate guard holds (6 observations)"
    exit 0
fi
echo "FAILED: $fails observation(s)" >&2
exit 1
