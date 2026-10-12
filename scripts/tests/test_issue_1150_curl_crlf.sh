#!/usr/bin/env bash
# Regression coverage for issue #1150 (update.sh on Windows):
#   1. the SSL revocation flag is detected through `curl --help all` — the
#      short `curl --help` never lists --ssl-revoke-best-effort;
#   2. the repo pins LF line endings (.gitattributes), so a clone made with
#      core.autocrlf=true does not read as hundreds of "modified" files.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
UPDATE="$ROOT/update.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

# Run the real detector block against a fake curl whose short help hides the
# flag and whose full help lists it (the behaviour of the real tool).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ] && [ "${2:-}" = "all" ]; then
    printf '%s\n' "$FAKE_CURL_FULL_HELP"
else
    echo " -L, --location   Follow redirects"
fi
EOF
chmod +x "$TMP/bin/curl"

detect() {
    local full_help="$1"
    FAKE_CURL_FULL_HELP="$full_help" PATH="$TMP/bin:$PATH" OSTYPE=msys bash -c '
        '"$(sed -n '/^_CURL_SSL_OPT=""$/,/^esac$/p' "$UPDATE")"'
        printf "%s" "$_CURL_SSL_OPT"
    '
}

got=$(detect "     --ssl-revoke-best-effort  Ignore missing revocation info")
if [ "$got" = "--ssl-revoke-best-effort" ]; then
    pass "best-effort flag found through curl --help all"
else
    fail_test "expected --ssl-revoke-best-effort, got '$got'"
fi

got=$(detect "     --ssl-no-revoke  Disable revocation checks")
if [ "$got" = "--ssl-no-revoke" ]; then
    pass "falls back to --ssl-no-revoke"
else
    fail_test "expected --ssl-no-revoke, got '$got'"
fi

got=$(detect "     --location  Follow redirects")
if [ -z "$got" ]; then pass "no flag when curl offers neither"; else fail_test "unexpected flag '$got'"; fi

# --- 2. LF is pinned for the working tree.
if grep -qE '^\* +text=auto +eol=lf$' "$ROOT/.gitattributes" 2>/dev/null \
   && grep -qE '^\*\.sh +text +eol=lf$' "$ROOT/.gitattributes"; then
    pass ".gitattributes pins LF for all text and shell scripts"
else
    fail_test ".gitattributes does not pin LF line endings"
fi

exit $fail
