#!/usr/bin/env bash
# Contract test for bug #340: fmt-critical-alert.sh must classify API errors
# correctly. Inject a gh API failure and verify exit 2 (critical error), not
# a silent exit 0 / false "clean" report.
#
# Earlier version named its mock "mock-gh.sh" and set a REPO env var — the
# script never reads either: it shells out to the literal command `gh`, and
# reads IWE_FMT_REPO (or GITHUB_USER, or params.yaml), not REPO. The mock was
# never actually invoked; the exit 2 that made the old test "pass" came from
# the script's own real environment (real `gh` failing to resolve a repo it
# was never told about), not from the injected scenario.

set -euo pipefail

TEMPLATE_ROOT="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}"
ALERT_SCRIPT="$TEMPLATE_ROOT/scripts/fmt-critical-alert.sh"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

REAL_JQ=$(command -v jq)
REAL_CURL=$(command -v curl)

cat > "$TMPDIR/jq" <<EOF
#!/usr/bin/env bash
exec "$REAL_JQ" "\$@"
EOF
cat > "$TMPDIR/curl" <<EOF
#!/usr/bin/env bash
exec "$REAL_CURL" "\$@"
EOF

cat > "$TMPDIR/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status")
    exit 0
    ;;
esac

case "$*" in
  *"repos/test-owner/test-repo/issues?"*)
    echo "HTTP 403: API rate limit exceeded" >&2
    exit 1
    ;;
  *"repos/test-owner/test-repo"*)
    printf '%s\n' '{"fork":false,"parent":null,"has_issues":true}'
    exit 0
    ;;
esac

echo "unexpected gh call: $*" >&2
exit 97
EOF
chmod +x "$TMPDIR/gh" "$TMPDIR/jq" "$TMPDIR/curl"

set +e
PATH="$TMPDIR:/usr/bin:/bin" \
IWE_FMT_REPO="test-owner/test-repo" \
bash "$ALERT_SCRIPT" --no-telegram >"$TMPDIR/output" 2>&1
RC=$?
set -e

cat "$TMPDIR/output"

[ "$RC" -eq 2 ] ||
  { echo "FAIL: expected rc=2, got $RC" >&2; exit 1; }
grep -q "gh api failed" "$TMPDIR/output" ||
  { echo "FAIL: API failure was not explicit in output" >&2; exit 1; }
! grep -q "✅ clean" "$TMPDIR/output" ||
  { echo "FAIL: partial failure advertised as clean" >&2; exit 1; }

echo "✓ Contract verified: API failure yields exit 2, not a false clean report"

# #382: CLI parsing must precede config resolution, and .exocortex.env is the
# canonical install config when no process env is exported.
TEST_ROOT="$TMPDIR/workspace"
mkdir -p "$TEST_ROOT"
cat > "$TEST_ROOT/.exocortex.env" <<'EOF'
GITHUB_USER="ignored-user"
IWE_FMT_REPO="test-owner/test-repo"
EOF

set +e
PATH="$TMPDIR:/usr/bin:/bin" IWE_WORKSPACE="$TEST_ROOT" \
  bash "$ALERT_SCRIPT" --no-telegram >"$TMPDIR/env-output" 2>&1
ENV_RC=$?
PATH="$TMPDIR:/usr/bin:/bin" IWE_WORKSPACE="$TEST_ROOT" \
  bash "$ALERT_SCRIPT" --repo test-owner/test-repo --no-telegram >"$TMPDIR/arg-output" 2>&1
ARG_RC=$?
set -e

[ "$ENV_RC" -eq 2 ] && grep -q "gh api failed" "$TMPDIR/env-output" ||
  { echo "FAIL: .exocortex.env repo was not used" >&2; cat "$TMPDIR/env-output" >&2; exit 1; }
[ "$ARG_RC" -eq 2 ] && grep -q "gh api failed" "$TMPDIR/arg-output" ||
  { echo "FAIL: --repo did not override config before early exit" >&2; cat "$TMPDIR/arg-output" >&2; exit 1; }

echo "✓ #382: --repo and .exocortex.env both reach the actual tracker check"
