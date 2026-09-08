#!/usr/bin/env bash
# Regression test for bug #340: fmt-critical-alert.sh must distinguish a fork
# whose upstream has issues disabled from "0 open issues" — exit 2, not the
# silent "0 (✅ clean)" a naive empty-list read would produce.
#
# Earlier version's mock branched on jq-filter substrings (".has_issues",
# ".parent") that never appear literally in the real invocation (the script
# uses one combined --jq '{fork:...,parent:...,has_issues:...}' filter per
# call) and was never actually named `gh`, nor did REPO (the env var it set)
# match what the script reads (IWE_FMT_REPO). The mock was never invoked; the
# old "pass" came from the script's real environment, not the injected
# scenario. This version mirrors the script's real two-call sequence: first
# repos/<fork> to detect the fork+parent, then repos/<upstream> for the
# tracker status that actually decides the exit code.

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
  *"repos/myuser/my-fork"*)
    printf '%s\n' '{"fork":true,"parent":"upstream-owner/upstream-repo","has_issues":true}'
    exit 0
    ;;
  *"repos/upstream-owner/upstream-repo"*)
    printf '%s\n' '{"has_issues":false}'
    exit 0
    ;;
esac

echo "unexpected gh call: $*" >&2
exit 97
EOF
chmod +x "$TMPDIR/gh" "$TMPDIR/jq" "$TMPDIR/curl"

set +e
PATH="$TMPDIR:/usr/bin:/bin" \
IWE_FMT_REPO="myuser/my-fork" \
bash "$ALERT_SCRIPT" --no-telegram >"$TMPDIR/output.txt" 2>&1
EXIT_CODE=$?
set -e

cat "$TMPDIR/output.txt"
echo "Exit code: $EXIT_CODE"

[ "$EXIT_CODE" -eq 2 ] ||
  { echo "FAIL: expected exit 2 for disabled upstream tracker, got $EXIT_CODE" >&2; exit 1; }
grep -q "tracker disabled" "$TMPDIR/output.txt" ||
  { echo "FAIL: disabled-tracker reason not stated in output" >&2; exit 1; }
grep -q "upstream-owner/upstream-repo" "$TMPDIR/output.txt" ||
  { echo "FAIL: fork→upstream redirect not visible in output" >&2; exit 1; }
! grep -q "✅ clean" "$TMPDIR/output.txt" ||
  { echo "FAIL: disabled tracker reported as clean (issue #340 regression)" >&2; exit 1; }

echo "✓ Correctly returned exit 2 for fork with disabled upstream tracker"
