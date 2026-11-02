#!/usr/bin/env bash
# test_wp568_strategist_auth_and_retry_message.sh - regression for WP-568 (02.11.2026).
#
# 1. strategist.sh sent headless runs through the gateway in ANTHROPIC_BASE_URL,
#    which drops the `tools` array: week-review waited 6 x 5 min on "502 upstream
#    error" three times a night. prefer_subscription_over_proxy() must drop the
#    gateway env once a subscription token is available, and only then.
# 2. A scheduler retry event of week-review was rendered as a finished review
#    (the WeekPlan title). The message template must stay silent for it.
# The real function and the real template are used, not re-typed copies.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
STRATEGIST="$ROOT/roles/strategist/scripts/strategist.sh"
TEMPLATE="$ROOT/roles/synchronizer/scripts/templates/strategist.sh"

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

awk '/^prefer_subscription_over_proxy\(\) \{/ { on = 1 } on { print } on && /^}/ { exit }' \
    "$STRATEGIST" > "$TMP/fn.sh"
grep -q 'unset ANTHROPIC_BASE_URL' "$TMP/fn.sh" || { bad "could not extract prefer_subscription_over_proxy"; exit 1; }

# run_case <home-setup> [extra env...] -> prints "BASE=<value> TOKEN=<set|unset>"
run_case() {
    local home="$TMP/home-$1"; shift
    mkdir -p "$home/.secrets"
    env -i PATH="$PATH" HOME="$home" AI_CLI=/bin/claude CLAUDE_PATH=/bin/claude \
        ANTHROPIC_BASE_URL=https://gateway.invalid ANTHROPIC_API_KEY=k "$@" bash -c '
        log() { :; }
        . "$1"
        prefer_subscription_over_proxy
        printf "BASE=%s TOKEN=%s\n" "${ANTHROPIC_BASE_URL:-}" "${CLAUDE_CODE_OAUTH_TOKEN:+set}"
    ' _ "$TMP/fn.sh"
}

mkdir -p "$TMP/home-raw/.secrets" && printf 'tok-raw\n' > "$TMP/home-raw/.secrets/claude_code_oauth_token"
out=$(run_case raw)
[ "$out" = "BASE= TOKEN=set" ] && ok "token file: gateway env dropped, token exported" || bad "token file: $out"

mkdir -p "$TMP/home-kv/.secrets" && printf 'export CLAUDE_CODE_OAUTH_TOKEN="tok-kv" # note\n' > "$TMP/home-kv/.secrets/claude-subscription"
out=$(run_case kv)
[ "$out" = "BASE= TOKEN=set" ] && ok "key=value file: gateway env dropped" || bad "key=value file: $out"

out=$(run_case none)
[ "$out" = "BASE=https://gateway.invalid TOKEN=" ] && ok "no token: gateway env kept" || bad "no token: $out"

out=$(run_case raw IWE_STRATEGIST_USE_API_ENV=1)
[ "$out" = "BASE=https://gateway.invalid TOKEN=" ] && ok "opt-out keeps the gateway" || bad "opt-out: $out"

out=$(run_case raw AI_CLI=/bin/other-cli)
[ "$out" = "BASE=https://gateway.invalid TOKEN=" ] && ok "non-Claude AI_CLI untouched" || bad "non-Claude: $out"

grep -q '^    prefer_subscription_over_proxy$' "$STRATEGIST" \
    && ok "run_claude applies the policy before the model call" \
    || bad "prefer_subscription_over_proxy is not called"

# --- retry message ---
WS="$TMP/ws"; mkdir -p "$WS/DS-strategy/current"
printf '# WeekPlan W44: 2026-10-26\n' > "$WS/DS-strategy/current/WeekPlan W44 2026-10-26.md"
render() {
    env -i PATH="$PATH" IWE_WORKSPACE="$WS" IWE_GOVERNANCE_REPO=DS-strategy "$@" bash -c '
        . "$1"; build_message week-review' _ "$TEMPLATE"
}
[ -z "$(render RETRY_EVENT=first-fail)" ] && ok "retry first-fail: silent" || bad "retry first-fail rendered: $(render RETRY_EVENT=first-fail)"
[ -z "$(render RETRY_EVENT=giving-up)" ] && ok "retry giving-up: silent" || bad "retry giving-up rendered"
case "$(render)" in *"Week-Review завершён"*) ok "real success still rendered" ;; *) bad "success not rendered: $(render)" ;; esac

echo "Result: $fail FAIL"
[ "$fail" -eq 0 ]
