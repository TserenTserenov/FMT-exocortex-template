#!/usr/bin/env bash
# Regression: notify.sh may hand plain messages to a workspace-owned `iwe-tg`
# gate (a digest, for example) only when the workspace opted in, and must behave
# exactly as before when no gate is configured, when the gate refuses, when the
# message has buttons, for the pulse chat, and with --require-delivery.
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
echo called >> "$TMP/curl.calls"
echo '{"ok":true}'
EOF
chmod +x "$TMP/bin/curl"
# Narrow PATH so a real `iwe-tg` installed on the machine running the test is never found.
export PATH="$TMP/bin:/usr/bin:/bin" TEMPLATES_DIR="$TMP/templates" IWE_WORKSPACE="$WS"
unset IWE_GOVERNANCE_REPO IWE_TG_BIN IWE_SCRIPTS

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

echo "== 1 gate exists in governance repo but workspace did not opt in -> direct send"
reset; write_gate "$WS/GOV/scripts/iwe-tg" 0
bash "$NOTIFY" probe plain >/dev/null 2>&1
[ "$(count "$TMP/gate.calls")" = 0 ] && [ "$(count "$TMP/curl.calls")" = 1 ] \
    && pass "no opt-in, no routing" || fail "gate used without opt-in"

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

echo "== 5 gate refuses -> falls back to direct send"
reset; write_gate "$WS/GOV/scripts/iwe-tg" 1; export IWE_GOVERNANCE_REPO=GOV
bash "$NOTIFY" probe plain >/dev/null 2>&1
[ "$(count "$TMP/gate.calls")" = 1 ] && [ "$(count "$TMP/curl.calls")" = 1 ] \
    && pass "gate tried, then direct send" || fail "message lost when gate refused"

echo "== 6 message with buttons -> gate not used"
reset; write_gate "$WS/GOV/scripts/iwe-tg" 0; export IWE_GOVERNANCE_REPO=GOV
bash "$NOTIFY" probe buttons >/dev/null 2>&1
[ "$(count "$TMP/gate.calls")" = 0 ] && [ "$(count "$TMP/curl.calls")" = 1 ] \
    && pass "buttons sent directly" || fail "buttons went through the gate"

echo "== 7 pulse -> gate not used"
reset; write_gate "$WS/GOV/scripts/iwe-tg" 0; export IWE_GOVERNANCE_REPO=GOV
bash "$NOTIFY" pulse plain >/dev/null 2>&1
[ "$(count "$TMP/gate.calls")" = 0 ] && [ "$(count "$TMP/curl.calls")" = 1 ] \
    && pass "pulse sent directly" || fail "pulse went through the gate"

echo "== 8 --require-delivery -> gate not used"
reset; write_gate "$WS/GOV/scripts/iwe-tg" 0; export IWE_GOVERNANCE_REPO=GOV
bash "$NOTIFY" --require-delivery probe plain >/dev/null 2>&1
[ "$(count "$TMP/gate.calls")" = 0 ] && [ "$(count "$TMP/curl.calls")" = 1 ] \
    && pass "delivery guarantee kept" || fail "require-delivery went through the gate"

echo "== 9 text starting with dashes -> passed after the -- separator"
reset; write_gate "$WS/GOV/scripts/iwe-tg" 0; export IWE_GOVERNANCE_REPO=GOV
bash "$NOTIFY" probe dash >/dev/null 2>&1
grep -qx -- '--source synchronizer-notify -- -- not an option' "$TMP/gate.calls" 2>/dev/null \
    && pass "dash text cannot be read as an option" || fail "gate call was: $(cat "$TMP/gate.calls" 2>/dev/null)"

if [ "$fails" -gt 0 ]; then echo "FAILED: $fails" >&2; exit 1; fi
echo "OK"
