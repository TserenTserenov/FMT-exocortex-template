#!/usr/bin/env bash
# test_issue_877_llm_proxy_default.sh - regression for issue #877.
#
# scripts/day-open-pipeline.sh defaulted LLM_PROXY_URL to the maintainer's
# private Railway gateway. A user install has no secret for it, so the morning
# pipeline died on an anonymous probe (HTTP 401) that read like a key-rotation
# problem; meanwhile setup.sh wrote PLATFORM_LLM_PROXY_URL for every user and no
# script ever read it. Contract now:
#   1. no built-in gateway address in the shipped script (or its seed snapshot);
#   2. resolution: LLM_PROXY_URL > PLATFORM_LLM_PROXY_URL (environment, then the
#      workspace env file) > empty; the platform value's "/v1" suffix is stripped
#      because the calls append their own "/v1/...";
#   3. empty -> step 2 aborts with a direct "not configured" message and never
#      probes an empty URL;
#   4. setup.sh no longer records the dead platform endpoint as an active value.
# The real blocks are extracted from the script, not re-typed.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
PIPELINE="$ROOT/scripts/day-open-pipeline.sh"
SEED_PIPELINE="$ROOT/seed/strategy/scripts/day-open-pipeline.sh"
SETUP="$ROOT/setup.sh"
COMMON="$ROOT/scripts/lib/common.sh"

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- extract the real resolution block: marker comment .. line before PROXY_PORT= ---
awk '
  /^# issue #877: the shipped script carries NO built-in gateway address/ { on = 1 }
  /^PROXY_PORT=/ { on = 0 }
  on { print }
' "$PIPELINE" > "$TMP/resolve.sh"
if [ ! -s "$TMP/resolve.sh" ] || ! grep -q 'LLM_PROXY_URL=' "$TMP/resolve.sh"; then
    bad "could not extract the resolution block (markers moved?)"
    echo "Result: $fail FAIL"
    exit 1
fi

# resolve <case-name> [VAR=value ...] : run the block in a clean shell, print the result.
# DS_STRATEGY/IWE point at a throwaway tree that carries the real lib/common.sh.
resolve() {
    local name="$1"; shift
    local ds="$TMP/$name/ds" iwe="$TMP/$name/iwe"
    mkdir -p "$ds/scripts/lib" "$iwe"
    cp "$COMMON" "$ds/scripts/lib/common.sh"
    [ -f "$TMP/$name.envfile" ] && cp "$TMP/$name.envfile" "$iwe/.exocortex.env"
    # The pipeline defines its own tg_notify() before this block; sourcing lib/common.sh
    # (which defines a different one) must not replace it. A sentinel stands in for it.
    env -i PATH="$PATH" HOME="$TMP/$name/home" DS_STRATEGY="$ds" IWE="$iwe" CLOBBER_LOG="$TMP/clobber.log" "$@" \
        bash -c '
            tg_notify() { echo SENTINEL_PIPELINE_TG_NOTIFY; }
            before=$(declare -f tg_notify)
            . "$1"
            [ "$(declare -f tg_notify)" = "$before" ] || echo "tg_notify clobbered in case $2" >> "$CLOBBER_LOG"
            printf "%s" "$LLM_PROXY_URL"
        ' _ "$TMP/resolve.sh" "$name" 2>"$TMP/$name.err"
}

expect() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then ok "$name (got: '${got}')"; else bad "$name: expected '$want', got '$got'"; fi
}

expect "nothing configured -> empty (no private default)" "" \
    "$(resolve none)"
expect "explicit LLM_PROXY_URL wins over the platform value" "https://explicit.example" \
    "$(resolve explicit LLM_PROXY_URL=https://explicit.example PLATFORM_LLM_PROXY_URL=https://platform.example/v1)"
expect "PLATFORM_LLM_PROXY_URL from the environment, '/v1' stripped" "https://platform.example" \
    "$(resolve envplat PLATFORM_LLM_PROXY_URL=https://platform.example/v1)"

printf '%s\n' 'GITHUB_USER="someone"' 'PLATFORM_LLM_PROXY_URL="https://file.example/v1/"' > "$TMP/fromfile.envfile"
expect "PLATFORM_LLM_PROXY_URL from the workspace env file (quoted, trailing slash)" "https://file.example" \
    "$(resolve fromfile)"

printf '%s\n' 'GITHUB_USER="someone"' '# PLATFORM_LLM_PROXY_URL=' > "$TMP/commented.envfile"
expect "commented placeholder (what setup.sh writes now) resolves to empty" "" \
    "$(resolve commented)"

# Installs made before the fix carry the dead address older setup.sh wrote as an active value.
expect "legacy dead platform address in the environment is ignored" "" \
    "$(resolve legacyenv PLATFORM_LLM_PROXY_URL=https://llm.aisystant.com/v1)"
if grep -q 'legacy placeholder' "$TMP/legacyenv.err"; then ok "the legacy value is ignored WITH a note on stderr"; else bad "legacy value ignored silently"; fi
printf '%s\n' 'PLATFORM_LLM_PROXY_URL=https://llm.aisystant.com/v1' > "$TMP/legacyfile.envfile"
expect "legacy dead platform address in the workspace env file is ignored" "" \
    "$(resolve legacyfile)"
expect "a different user-supplied platform URL is NOT swallowed by the legacy rule" "https://my.gateway.example" \
    "$(resolve mine PLATFORM_LLM_PROXY_URL=https://my.gateway.example/v1)"

# The calls append their own "/v1/...": an explicit value with the suffix must not double it.
expect "explicit LLM_PROXY_URL with '/v1/' suffix is normalised (no /v1/v1)" "https://host.example" \
    "$(resolve explicitv1 LLM_PROXY_URL=https://host.example/v1/)"
expect "explicit local URL is untouched" "http://localhost:18765" \
    "$(resolve local LLM_PROXY_URL=http://localhost:18765)"

if [ -s "$TMP/clobber.log" ]; then
    bad "reading the workspace env file replaced the pipeline's own tg_notify(): $(cat "$TMP/clobber.log")"
else
    ok "the pipeline's own tg_notify() survives the resolution block (probe mode keeps suppressing Telegram)"
fi

# --- extract the real step-2 guard and run it with a fake abort/curl ---
awk '
  /^# issue #877: no gateway address resolved/ { on = 1 }
  on { print }
  on && /^fi$/ { exit }
' "$PIPELINE" > "$TMP/guard.sh"
if [ ! -s "$TMP/guard.sh" ]; then
    bad "could not extract the step-2 guard (markers moved?)"
else
    run_guard() {
        LLM_PROXY_URL="$1" bash -c '
            abort() { echo "ABORT_CALLED: $*"; exit 42; }
            curl() { echo "CURL_CALLED"; }
            . "$1"
            echo "GUARD_PASSED"
        ' _ "$TMP/guard.sh" 2>&1
    }
    OUT=$(run_guard "")
    if grep -q 'ABORT_CALLED' <<<"$OUT" && grep -q 'LLM_PROXY_URL' <<<"$OUT" && ! grep -q 'CURL_CALLED' <<<"$OUT"; then
        ok "empty gateway -> abort with a direct message naming LLM_PROXY_URL, no probe"
    else
        bad "empty gateway did not abort cleanly: $OUT"
    fi
    if grep -qi 'api-key problem\|not an API' <<<"$OUT"; then
        ok "the message says explicitly that this is not a key problem"
    else
        bad "the message does not steer away from key rotation: $OUT"
    fi
    OUT=$(run_guard "https://gateway.example")
    if grep -q 'GUARD_PASSED' <<<"$OUT" && ! grep -q 'ABORT_CALLED' <<<"$OUT"; then
        ok "configured gateway passes the guard"
    else
        bad "configured gateway wrongly blocked: $OUT"
    fi
fi

# --- static: no private address in the script, its seed snapshot, or setup.sh's active config ---
for f in "$PIPELINE" "$SEED_PIPELINE"; do
    if grep -q 'iwe-llm-proxy-production' "$f"; then
        bad "private gateway address still present in ${f#$ROOT/}"
    else
        ok "no private gateway address in ${f#$ROOT/}"
    fi
done
if grep -q '^PLATFORM_LLM_PROXY_URL=' "$SETUP"; then
    bad "setup.sh still writes an ACTIVE PLATFORM_LLM_PROXY_URL"
else
    ok "setup.sh writes no active PLATFORM_LLM_PROXY_URL (commented placeholder only)"
fi

echo "Result: $fail FAIL"
[ "$fail" -eq 0 ]
