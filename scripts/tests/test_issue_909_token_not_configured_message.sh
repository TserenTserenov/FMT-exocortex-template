#!/usr/bin/env bash
# Regression coverage for issue #909 (message half; the connect.sh multi-line
# paste half was already fixed by commit 049a074 before this issue was
# filed, verified separately, not touched here).
#
# load_claude_subscription_token() in extractor.sh silently did nothing when
# neither secret file existed. The only diagnostic a missing token ever
# produced was the later "протух или отозван" (expired/revoked) ERROR after
# a failed AI CLI call -- indistinguishable from a token that really did
# expire, and an interactive run can mask the gap entirely by falling back
# to the CLI's own separate login. A launchd/headless run has no such
# fallback and just fails, every night, looking exactly like an expired
# token. This test isolates the function (extractor.sh's bottom `case`
# dispatches real work and is not source-safe for unit testing) and checks
# both the missing-token and present-token paths.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SCRIPT="$ROOT/roles/extractor/scripts/extractor.sh"

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
LOG_FILE="$WORKDIR/extractor.log"
log() { printf '%s\n' "$*" >> "$LOG_FILE"; }

eval "$(sed -n '/^load_claude_subscription_token()/,/^}/p' "$SCRIPT")"

# Case 1: neither secret file exists -- the new distinct WARN must fire, and
# no token gets exported (nothing to distinguish from a real one downstream).
HOME="$WORKDIR/empty-home" unset CLAUDE_CODE_OAUTH_TOKEN
mkdir -p "$WORKDIR/empty-home"
: > "$LOG_FILE"
(
  HOME="$WORKDIR/empty-home"
  unset CLAUDE_CODE_OAUTH_TOKEN
  load_claude_subscription_token
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    echo "UNEXPECTED_TOKEN_SET" >> "$LOG_FILE"
  fi
)
if grep -q 'WARN: токен не настроен' "$LOG_FILE"; then
    pass "missing-token case logs the distinct 'not configured' warning"
else
    fail_test "missing-token case did not log the new distinct warning (got: $(cat "$LOG_FILE"))"
fi
if grep -q 'протух или отозван' "$LOG_FILE"; then
    fail_test "missing-token case must not reuse the misleading 'expired/revoked' wording"
else
    pass "missing-token case does not claim the token 'expired' (it was simply never set)"
fi
if grep -q 'UNEXPECTED_TOKEN_SET' "$LOG_FILE"; then
    fail_test "CLAUDE_CODE_OAUTH_TOKEN got set even though no source file exists"
else
    pass "no token variable is exported when nothing was found"
fi

# Case 2: a real token file exists -- must load silently, no warning, no
# regression on the working path.
mkdir -p "$WORKDIR/real-home/.secrets"
printf 'sk-ant-oat01-thisisaplaceholdertoken\n' > "$WORKDIR/real-home/.secrets/claude_code_oauth_token"
: > "$LOG_FILE"
LOADED_TOKEN=""
(
  HOME="$WORKDIR/real-home"
  unset CLAUDE_CODE_OAUTH_TOKEN
  load_claude_subscription_token
  printf '%s' "${CLAUDE_CODE_OAUTH_TOKEN:-}" > "$WORKDIR/loaded-token.txt"
)
LOADED_TOKEN=$(cat "$WORKDIR/loaded-token.txt")
if [ "$LOADED_TOKEN" = "sk-ant-oat01-thisisaplaceholdertoken" ]; then
    pass "existing-token case still loads the token correctly (no regression)"
else
    fail_test "existing-token case failed to load the token, got: '$LOADED_TOKEN'"
fi
if grep -q 'WARN: токен не настроен' "$LOG_FILE"; then
    fail_test "existing-token case must not warn about a missing token"
else
    pass "existing-token case stays silent (no false warning)"
fi

if [ "$fail" -eq 0 ]; then
    echo "✅ test_issue_909_token_not_configured_message: all checks passed"
fi
exit "$fail"
