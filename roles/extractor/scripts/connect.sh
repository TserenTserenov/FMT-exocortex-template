#!/usr/bin/env bash
# connect.sh — one-time setup: connect Extractor to the operator's Claude subscription.
#
#   connect.sh          interactive: `claude setup-token` → paste token → save → verify
#   connect.sh --check  verify the already-saved token only (no browser login)
#
# WP-5 Phase46: for a regular template user (no personal server infra like the
# platform author's sops-nix setup) this must be one command + one interactive
# browser login, no manual system-file editing.
#
# Why the human pastes the token instead of the script capturing it: Anthropic's
# docs say `claude setup-token` "prints the token to the terminal without
# saving it" — there is no machine-readable output contract to parse, and
# piping its stdout would break its TTY-driven prompts (browser URL, paste-code
# step). So the command runs with an inherited terminal and the user pastes the
# printed value once. Format check before saving guards against pasting the
# wrong line.
#
# Read-only code without {{PLACEHOLDER}}s: run straight from $IWE_TEMPLATE
# (see .claude/runtime-overlay.yaml), it is not copied into .iwe-runtime/.
set -euo pipefail

SECRET_DIR="$HOME/.secrets"
SECRET_PATH="$SECRET_DIR/claude_code_oauth_token"
TOKEN_PREFIX="sk-ant-oat"   # documented long-lived token format: sk-ant-oat01-...
TOKEN_MIN_LENGTH=40
CLAUDE_PATH="$(command -v claude 2>/dev/null || true)"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# One cheap end-to-end call with ONLY the given token in the environment.
# CLAUDE_CODE_OAUTH_TOKEN takes precedence over a keychain/file login
# (`claude auth status` reports authMethod=oauth_token when it is set), so a
# green result proves this token works, not the operator's interactive login.
verify_token() {
    local token="$1"
    local out
    out="$(mktemp)"
    echo "Verifying connection with a test call......"
    if CLAUDE_CODE_OAUTH_TOKEN="$token" "$CLAUDE_PATH" -p "Reply with one word: OK: OK" \
        --allowedTools "" --no-session-persistence </dev/null >"$out" 2>&1; then
        rm -f "$out"
        return 0
    fi
    echo "Test call did not succeed. Claude Code response:. Response Claude Code:" >&2
    sed 's/^/  /' "$out" >&2
    rm -f "$out"
    return 1
}

save_token() {
    local token="$1"
    mkdir -p "$SECRET_DIR"
    chmod 700 "$SECRET_DIR"
    # umask 077: the file is never world-readable, not even between create and chmod.
    ( umask 077 && printf '%s' "$token" > "$SECRET_PATH" )
    chmod 600 "$SECRET_PATH"
    echo "Saved: $SECRET_PATH"
}

read_token_interactively() {
    local token line
    read -rsp "Paste the token, printed above (input hidden): " token
    echo >&2
    # A long token wraps across several terminal lines when the window is
    # narrow; pasting the whole block delivers all of them at once, so the
    # rest is already sitting in the input buffer right behind the first
    # line. Manual single-line entry leaves nothing queued, so the
    # non-blocking read below times out immediately and changes nothing.
    while IFS= read -rs -t 0.3 line; do
        [ -n "$line" ] || break
        token="${token}${line}"
    done
    # Paste often carries a trailing newline or surrounding spaces.
    token="$(printf '%s' "$token" | tr -d '[:space:]')"
    [ -n "$token" ] || die "empty — nothing was saved."
    case "$token" in
        "$TOKEN_PREFIX"*) ;;
        *) die "the string does not look like a subscription token (expected prefix '${TOKEN_PREFIX}…'). Nothing was saved — re-run the script and paste exactly what, was printed by 'claude setup-token'." ;;
    esac
    [ "${#token}" -ge "$TOKEN_MIN_LENGTH" ] || die "the string is too short to be a token (${#token} characters). Nothing was saved."
    printf '%s' "$token"
}

run_check_only() {
    [ -f "$SECRET_PATH" ] || die "no saved token found ($SECRET_PATH) — run without --check, to connect."
    verify_token "$(<"$SECRET_PATH")" || exit 1
    echo "Token is valid — Extractor is connected."
}

run_full_setup() {
    [ -t 0 ] || die "an interactive terminal is required (the script opens a browser and waits for input)."

    echo "Connecting the Extractor to your subscription Claude Code."
    echo "An active subscription is required Pro/Max/Team/Enterprise (not a regular API-key)."
    [ -f "$SECRET_PATH" ] && echo "An already saved token ($SECRET_PATH) will be replaced with the new one."
    echo
    echo "Now launching 'claude setup-token' — a browser will open for sign-in."
    echo "After sign-in the command will print a string of the form ${TOKEN_PREFIX}01-…"
    echo "You will need to copy it and paste it here."
    echo
    read -rp "Continue? [Y/n]: " confirm
    case "${confirm:-Y}" in
        n|N) echo "Cancelled."; exit 1 ;;
    esac

    echo
    "$CLAUDE_PATH" setup-token || die "'claude setup-token' failed with an error (sign-in was cancelled or there is no active subscription). Nothing was saved."
    echo

    local token
    token="$(read_token_interactively)" || exit 1
    save_token "$token"
    echo
    verify_token "$token" || die "token was saved, but it does not work. Re-check without signing in again: bash $0 --check"

    echo "Done — Extractor is connected to your subscription."
    echo "Next step (optional): automatic inbox-check — bash \$IWE_TEMPLATE/roles/extractor/install.sh"
}

[ -n "$CLAUDE_PATH" ] || die "command 'claude' not found in PATH — install Claude Code CLI first Claude Code CLI."

case "${1:-}" in
    "")        run_full_setup ;;
    --check)   run_check_only ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *)         die "unknown argument '$1'. Usage: $0 [--check]" ;;
esac
