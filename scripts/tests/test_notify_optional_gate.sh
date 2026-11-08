#!/usr/bin/env bash
# Regression: notify.sh sends through scripts/iwe-notify (WP-568 Ф12 С4,
# peer-session 2026-11-08-06), the one place a template script calls the Bot
# API. Without a gateway it is the same single direct send as before (HTML,
# buttons, ok:true required). A workspace may opt in to its own `iwe-tg`
# gateway (IWE_GOVERNANCE_REPO with scripts/iwe-tg, or IWE_TG_BIN); then the
# gateway gets plain text, its verdict is final (no second send after a
# quarantine) and buttons are dropped. PATH is never searched.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
NOTIFY="$ROOT/roles/synchronizer/scripts/notify.sh"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; fails=$((fails + 1)); }

[ -f "$NOTIFY" ] || { echo "notify.sh not found: $NOTIFY" >&2; exit 1; }

# Fake home with credentials, a template and a curl that only records the call.
export HOME="$TMP/home"
WS="$TMP/ws"
mkdir -p "$HOME/.config/aist" "$TMP/bin" "$TMP/templates" "$WS/GOV/scripts"
printf 'TELEGRAM_BOT_TOKEN=t\nTELEGRAM_CHAT_ID=1\n' > "$HOME/.config/aist/env"
cat > "$TMP/templates/probe.sh" <<'EOF'
build_message() {
    case "$1" in
        dash) printf -- '-- not an option' ;;
        *) printf '<b>probe</b> a &amp; b' ;;
    esac
}
build_buttons() { if [ "$1" = "buttons" ]; then printf '[[{"text":"x","callback_data":"y"}]]'; else printf '[]'; fi; }
EOF
cp "$TMP/templates/probe.sh" "$TMP/templates/pulse.sh"
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/curl.calls"
echo '{"ok":true}'
EOF
chmod +x "$TMP/bin/curl"
# Narrow PATH so a real `iwe-tg` installed on the machine running the test is
# never found; no real iwe-notify or credentials from the caller's environment.
export PATH="$TMP/bin:/usr/bin:/bin" TEMPLATES_DIR="$TMP/templates" IWE_WORKSPACE="$WS"
unset IWE_GOVERNANCE_REPO IWE_TG_BIN IWE_SCRIPTS IWE_TEMPLATE IWE_ROOT IWE_NOTIFY_BIN IWE_NOTIFY_GATEWAY \
    TELEGRAM_PROXY ALL_PROXY TELEGRAM_ENV

write_gate() { # $1 = path, $2 = exit code of the fake gate
    cat > "$1" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/gate.calls"
exit $2
EOF
    chmod +x "$1"
}
reset() {
    rm -f "$TMP/curl.calls" "$TMP/gate.calls" "$WS/GOV/scripts/iwe-tg" "$TMP/bin/iwe-tg" "$TMP/own-gate"
    unset IWE_GOVERNANCE_REPO IWE_TG_BIN
}
count() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

echo "== 1 gate exists in governance repo but workspace did not opt in -> direct send with HTML"
reset; write_gate "$WS/GOV/scripts/iwe-tg" 0
bash "$NOTIFY" probe plain >/dev/null 2>&1
[ "$(count "$TMP/gate.calls")" = 0 ] && [ "$(count "$TMP/curl.calls")" = 1 ] \
    && pass "no opt-in, no routing" || fail "gate used without opt-in"
grep -q "parse_mode=HTML" "$TMP/curl.calls" 2>/dev/null \
    && pass "direct send keeps HTML formatting" || fail "curl call was: $(cat "$TMP/curl.calls" 2>/dev/null)"

echo "== 2 foreign iwe-tg in PATH -> ignored"
reset; write_gate "$TMP/bin/iwe-tg" 0
bash "$NOTIFY" probe plain >/dev/null 2>&1
[ "$(count "$TMP/gate.calls")" = 0 ] && [ "$(count "$TMP/curl.calls")" = 1 ] \
    && pass "PATH is not searched" || fail "iwe-tg from PATH was used"

echo "== 3 opted in via IWE_GOVERNANCE_REPO -> routed to the gate, tags stripped"
reset; write_gate "$WS/GOV/scripts/iwe-tg" 0; export IWE_GOVERNANCE_REPO=GOV
bash "$NOTIFY" probe plain >/dev/null 2>&1
[ "$(count "$TMP/curl.calls")" = 0 ] && pass "no direct send" || fail "direct send despite gate"
grep -qx -- '--source synchronizer-notify -- probe a & b' "$TMP/gate.calls" 2>/dev/null \
    && pass "gate got plain text with source id" || fail "gate call was: $(cat "$TMP/gate.calls" 2>/dev/null)"

echo "== 4 opted in via IWE_TG_BIN -> routed to that gate"
reset; write_gate "$TMP/own-gate" 0; export IWE_TG_BIN="$TMP/own-gate"
bash "$NOTIFY" probe plain >/dev/null 2>&1
[ "$(count "$TMP/gate.calls")" = 1 ] && [ "$(count "$TMP/curl.calls")" = 0 ] \
    && pass "explicit gate used" || fail "IWE_TG_BIN ignored"

echo "== 5 gate did not run (exit 1, nothing sent) -> one direct send"
reset; write_gate "$WS/GOV/scripts/iwe-tg" 1; export IWE_GOVERNANCE_REPO=GOV
bash "$NOTIFY" probe plain >/dev/null 2>&1
[ "$(count "$TMP/gate.calls")" = 1 ] && [ "$(count "$TMP/curl.calls")" = 1 ] \
    && pass "gate tried, then direct send" || fail "message lost when the gate did not run"

echo "== 6 gate quarantined (exit 3) -> final, no second send"
reset; write_gate "$WS/GOV/scripts/iwe-tg" 3; export IWE_GOVERNANCE_REPO=GOV
bash "$NOTIFY" probe plain >/dev/null 2>&1
[ "$(count "$TMP/gate.calls")" = 1 ] && [ "$(count "$TMP/curl.calls")" = 0 ] \
    && pass "quarantine is final" || fail "duplicate send after quarantine"

echo "== 7 buttons: through the gate without buttons; without a gate the direct send carries them"
reset; write_gate "$WS/GOV/scripts/iwe-tg" 0; export IWE_GOVERNANCE_REPO=GOV
bash "$NOTIFY" probe buttons >/dev/null 2>&1
[ "$(count "$TMP/gate.calls")" = 1 ] && [ "$(count "$TMP/curl.calls")" = 0 ] \
    && pass "buttons message goes through the gate" || fail "buttons bypassed the gate"
reset
bash "$NOTIFY" probe buttons >/dev/null 2>&1
grep -q "reply_markup=" "$TMP/curl.calls" 2>/dev/null \
    && pass "no gate: buttons in the direct send" || fail "buttons lost: $(cat "$TMP/curl.calls" 2>/dev/null)"

echo "== 8 pulse -> own source id"
reset; write_gate "$WS/GOV/scripts/iwe-tg" 0; export IWE_GOVERNANCE_REPO=GOV
bash "$NOTIFY" pulse plain >/dev/null 2>&1
grep -q -- '^--source pulse -- ' "$TMP/gate.calls" 2>/dev/null \
    && pass "pulse uses source pulse" || fail "gate call was: $(cat "$TMP/gate.calls" 2>/dev/null)"

echo "== 9 --require-delivery: a digest line is not a delivery -> exit 4; direct send -> exit 0"
reset; write_gate "$WS/GOV/scripts/iwe-tg" 0; export IWE_GOVERNANCE_REPO=GOV
bash "$NOTIFY" --require-delivery probe plain >/dev/null 2>&1; rc=$?
[ "$rc" = 4 ] && pass "kept for the digest -> 4" || fail "require-delivery with a digest gate: rc=$rc"
reset
bash "$NOTIFY" --require-delivery probe plain >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(count "$TMP/curl.calls")" = 1 ] && pass "confirmed direct send -> 0" || fail "require-delivery direct: rc=$rc"

echo "== 10 text starting with dashes -> passed after the -- separator"
reset; write_gate "$WS/GOV/scripts/iwe-tg" 0; export IWE_GOVERNANCE_REPO=GOV
bash "$NOTIFY" probe dash >/dev/null 2>&1
grep -qx -- '--source synchronizer-notify -- -- not an option' "$TMP/gate.calls" 2>/dev/null \
    && pass "dash text cannot be read as an option" || fail "gate call was: $(cat "$TMP/gate.calls" 2>/dev/null)"

echo "== 11 the stdout line callers match whole stays exactly as before"
reset
out=$(bash "$NOTIFY" probe plain 2>/dev/null)
printf '%s\n' "$out" | grep -qxF 'Telegram notification sent: probe/plain' \
    && pass "exact 'Telegram notification sent: <agent>/<scenario>' line" || fail "stdout was: $out"

echo "== 12 an older iwe-notify elsewhere (no --html) never shadows the template's own copy"
reset
mkdir -p "$WS/scripts"
printf '#!/usr/bin/env bash\necho "iwe-notify: unknown flag" >&2\nexit 1\n' > "$WS/scripts/iwe-notify"
chmod +x "$WS/scripts/iwe-notify"
bash "$NOTIFY" probe plain >/dev/null 2>&1
[ "$(count "$TMP/curl.calls")" = 1 ] && pass "template copy used, message sent" || fail "older copy shadowed the template's"
rm -f "$WS/scripts/iwe-notify"

if [ "$fails" -gt 0 ]; then echo "FAILED: $fails" >&2; exit 1; fi
echo "OK"
