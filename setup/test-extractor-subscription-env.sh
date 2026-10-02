#!/bin/bash
# test-extractor-subscription-env.sh — acceptance test for roles/extractor/scripts/extractor.sh
# load_env(): a connected subscription token must reach the vendor API directly.
#
# tsekh-1, 2026-09-21: ~/.config/aist/env carried ANTHROPIC_BASE_URL (an LLM proxy) and
# load_env sourced it, so the client sent the subscription token to the proxy: 401
# "Invalid or expired token", inbox-check produced no report for days.
#
# Runs the REAL runtime script (copied outside FMT-exocortex-template, where the raw
# template refuses to start) with `on-demand`, a fake `claude` in PATH that dumps its
# own environment for `auth status` and for the working run, and a throwaway HOME.
# No network, no real secrets.
#
# Usage: bash setup/test-extractor-subscription-env.sh

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SELF_DIR")"
RUNTIME_SRC="$REPO_ROOT/roles/extractor/scripts/extractor.sh"
TEST_ROOT="$(mktemp -d)"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

trap 'rm -rf "$TEST_ROOT"' EXIT

PROXY="http://proxy.invalid"
# bash, sed, tr, paste may live outside /usr/bin (NixOS: /run/current-system/sw/bin)
BASH_DIR="$(dirname "$(command -v bash)")"

# Fresh fake HOME; prints its path.
new_home() {
    local h rt
    h=$(mktemp -d "$TEST_ROOT/case.XXXXXX")
    rt="$h/runtime/roles/extractor/scripts"
    mkdir -p "$h/.config/aist" "$h/.secrets" "$h/bin" "$h/logs/extractor" "$rt" \
             "$h/IWE/FMT-exocortex-template/roles/extractor/prompts"
    echo "on-demand prompt" > "$h/IWE/FMT-exocortex-template/roles/extractor/prompts/on-demand.md"
    cp "$RUNTIME_SRC" "$rt/extractor.sh"
    cat > "$h/bin/claude" <<'EOF'
#!/usr/bin/env bash
mode=run
[ "${1:-}" = "auth" ] && mode=auth
{
    printf 'BASE=%s\n' "${ANTHROPIC_BASE_URL:-}"
    printf 'KEY=%s\n' "${ANTHROPIC_API_KEY:-}"
    printf 'AUTHTOK=%s\n' "${ANTHROPIC_AUTH_TOKEN:-}"
    printf 'HEADERS=%s\n' "${ANTHROPIC_CUSTOM_HEADERS:-}"
    printf 'OAUTH=%s\n' "${CLAUDE_CODE_OAUTH_TOKEN:-}"
} > "$FAKE_DUMP.$mode"
exit 0
EOF
    cp "$h/bin/claude" "$h/bin/other-cli"
    # The runtime's notify() runs $NOTIFY_SH_PATH when set: keeps the test silent on any OS.
    printf '#!/usr/bin/env bash\nexit 0\n' > "$h/bin/notify-stub"
    chmod +x "$h/bin/"*
    echo "$h"
}

# Runs the runtime in a clean environment; extra args are env vars for the run.
run_runtime() {
    local h="$1"
    shift
    env -i HOME="$h" PATH="$h/bin:$BASH_DIR:/usr/bin:/bin:/usr/local/bin" FAKE_DUMP="$h/dump" \
        IWE_WORKSPACE="$h/IWE" IWE_TEMPLATE="$h/IWE/FMT-exocortex-template" NOTIFY_SH_PATH="$h/bin/notify-stub" "$@" \
        bash "$h/runtime/roles/extractor/scripts/extractor.sh" on-demand > "$h/out.log" 2>&1
}

# BASE|KEY|AUTHTOK|HEADERS|OAUTH as the fake claude saw it (mode: auth|run).
sig() {
    local f="$1/dump.$2"
    [ -f "$f" ] || { echo "no-dump"; return; }
    sed -e 's/^[A-Z]*=//' "$f" | paste -sd'|' -
}

# Both claude calls (preflight and working run) must see the same environment.
expect() {
    local name="$1" h="$2" want="$3"
    if [ "$(sig "$h" run)" = "$want" ] && [ "$(sig "$h" auth)" = "$want" ]; then
        pass "$name"
    else
        fail "$name — want '$want', got run='$(sig "$h" run)' auth='$(sig "$h" auth)'"
    fi
}

echo "== proxy in aist/env + token in claude-subscription: proxy dropped =="
h=$(new_home)
printf 'ANTHROPIC_BASE_URL="%s"\n' "$PROXY" > "$h/.config/aist/env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=kv-token\n' > "$h/.secrets/claude-subscription"
run_runtime "$h" ANTHROPIC_API_KEY=proxy-key
expect "tsekh-1 shape" "$h" "||||kv-token"

echo "== every proxy variable in aist/env: all dropped =="
h=$(new_home)
printf 'ANTHROPIC_BASE_URL="%s"\nANTHROPIC_API_KEY=k\nANTHROPIC_AUTH_TOKEN=a\nANTHROPIC_CUSTOM_HEADERS="X: y"\n' "$PROXY" > "$h/.config/aist/env"
printf 'raw-token\n' > "$h/.secrets/claude_code_oauth_token"
run_runtime "$h"
expect "full proxy set" "$h" "||||raw-token"

echo "== no token: proxy env is left alone =="
h=$(new_home)
printf 'ANTHROPIC_BASE_URL="%s"\n' "$PROXY" > "$h/.config/aist/env"
run_runtime "$h" ANTHROPIC_API_KEY=proxy-key
expect "no token" "$h" "$PROXY|proxy-key|||"

echo "== IWE_EXTRACTOR_USE_API_ENV=1: API/proxy env kept, token withheld =="
h=$(new_home)
printf 'ANTHROPIC_BASE_URL="%s"\n' "$PROXY" > "$h/.config/aist/env"
printf 'raw-token\n' > "$h/.secrets/claude_code_oauth_token"
run_runtime "$h" IWE_EXTRACTOR_USE_API_ENV=1 ANTHROPIC_API_KEY=proxy-key
expect "use API env" "$h" "$PROXY|proxy-key|||"

echo "== non-Claude AI_CLI keeps its environment but never gets the Claude token =="
h=$(new_home)
printf 'ANTHROPIC_BASE_URL="%s"\n' "$PROXY" > "$h/.config/aist/env"
printf 'raw-token\n' > "$h/.secrets/claude_code_oauth_token"
run_runtime "$h" AI_CLI="$h/bin/other-cli" ANTHROPIC_API_KEY=proxy-key
if [ "$(sig "$h" run)" = "$PROXY|proxy-key|||" ]; then
    pass "non-Claude CLI"
else
    fail "non-Claude CLI — got '$(sig "$h" run)'"
fi

echo "== KEY=value secret file is parsed, not executed =="
h=$(new_home)
printf 'touch %s/pwned\nOTHER_VAR=leak\nCLAUDE_CODE_OAUTH_TOKEN="kv-token"\r\n' "$h" > "$h/.secrets/claude-subscription"
run_runtime "$h"
expect "kv parsed" "$h" "||||kv-token"
if [ -e "$h/pwned" ]; then fail "the secret file was executed as shell"; else pass "the secret file was not executed"; fi

echo "== empty raw file falls back to claude-subscription =="
h=$(new_home)
: > "$h/.secrets/claude_code_oauth_token"
printf 'CLAUDE_CODE_OAUTH_TOKEN=kv-token\n' > "$h/.secrets/claude-subscription"
run_runtime "$h"
expect "empty raw -> kv" "$h" "||||kv-token"

echo "== explicit env token beats the files =="
h=$(new_home)
printf 'raw-token\n' > "$h/.secrets/claude_code_oauth_token"
run_runtime "$h" CLAUDE_CODE_OAUTH_TOKEN=env-token
expect "env wins" "$h" "||||env-token"

echo "== AI_CLI given as a bare command name is still recognised as Claude =="
h=$(new_home)
printf 'ANTHROPIC_BASE_URL="%s"\n' "$PROXY" > "$h/.config/aist/env"
printf 'raw-token\n' > "$h/.secrets/claude_code_oauth_token"
run_runtime "$h" AI_CLI=claude
expect "AI_CLI=claude" "$h" "||||raw-token"

echo "== KEY=value file: last line wins, trailing comment ignored =="
h=$(new_home)
printf 'CLAUDE_CODE_OAUTH_TOKEN=old-token\nCLAUDE_CODE_OAUTH_TOKEN=new-token # rotated\n' > "$h/.secrets/claude-subscription"
run_runtime "$h"
expect "kv last line" "$h" "||||new-token"

echo "== explicit env token beats a token defined in aist/env =="
h=$(new_home)
printf 'CLAUDE_CODE_OAUTH_TOKEN=file-token\n' > "$h/.config/aist/env"
run_runtime "$h" CLAUDE_CODE_OAUTH_TOKEN=env-token
expect "env beats ENV_FILE" "$h" "||||env-token"

echo "== token defined only in aist/env is used =="
h=$(new_home)
printf 'CLAUDE_CODE_OAUTH_TOKEN=file-token\n' > "$h/.config/aist/env"
run_runtime "$h"
expect "ENV_FILE token" "$h" "||||file-token"

echo ""
echo "PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
