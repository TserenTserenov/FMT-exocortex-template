#!/bin/bash
# test-build-runtime-author-sourced.sh — WP-529 F276 item 8 (17.11.2026 incident):
# in the author's installation (params.yaml: author_mode: true) the root is the
# source of `.claude/sync-manifest.yaml` and of every path in
# `.github/author-sourced-paths.txt`. A runtime rebuild used to copy the
# template's version over the root's file (on two of the author's machines), which stopped the
# root's own update. In author_mode such a file is left alone and only shown by
# `--diff`; outside author_mode the copy stays as it was.
#
# Runs the REAL build-runtime.sh against throwaway workspaces.
#
# Usage: bash setup/test-build-runtime-author-sourced.sh

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SELF_DIR")"
BUILD_SCRIPT="$REPO_ROOT/setup/build-runtime.sh"
TMP_ROOT=$(mktemp -d)

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
trap 'rm -rf "$TMP_ROOT"' EXIT

ROOT_MANIFEST_TEXT="# root-owned sync manifest — must survive a runtime rebuild"
TEMPLATE_MANIFEST="$REPO_ROOT/.claude/sync-manifest.yaml"

# make_workspace DIR AUTHOR(true|false) — a workspace with its own env file,
# a params.yaml and a root-owned .claude/sync-manifest.yaml.
make_workspace() {
    local ws="$1" author="$2"
    mkdir -p "$ws/.claude"
    cat > "$ws/.exocortex.env" <<EOF
HOME_DIR="$HOME"
USER_NAME="$(id -un)"
WORKSPACE_DIR="$ws"
CLAUDE_PATH="/usr/local/bin/claude"
CLAUDE_PROJECT_SLUG="test"
TIMEZONE_HOUR="3"
TIMEZONE_DESC="UTC"
GITHUB_USER="test-user"
GOVERNANCE_REPO="DS-strategy"
IWE_TEMPLATE="$REPO_ROOT"
IWE_RUNTIME="$ws/.iwe-runtime"
EOF
    printf 'author_mode: %s\n' "$author" > "$ws/params.yaml"
    printf '%s\n' "$ROOT_MANIFEST_TEXT" > "$ws/.claude/sync-manifest.yaml"
}

build() { # build WS [extra args...] -> stdout+stderr in $WS/build.log, returns rc
    local ws="$1"; shift
    bash "$BUILD_SCRIPT" --workspace "$ws" --env-file "$ws/.exocortex.env" "$@" >"$ws/build.log" 2>&1
}

echo "--- 1. author_mode: rebuild keeps the root's .claude/sync-manifest.yaml ---"
AUTH="$TMP_ROOT/author"
make_workspace "$AUTH" true
if build "$AUTH"; then pass "rebuild in author_mode succeeded"; else fail "rebuild failed: $(cat "$AUTH/build.log")"; fi
if [ "$(cat "$AUTH/.claude/sync-manifest.yaml")" = "$ROOT_MANIFEST_TEXT" ]; then
    pass "root .claude/sync-manifest.yaml left untouched"
else
    fail "root .claude/sync-manifest.yaml was overwritten by the template copy"
fi
if grep -q 'sync-manifest.yaml' "$AUTH/build.log"; then
    pass "rebuild names the kept file"
else
    fail "rebuild kept the file silently: $(cat "$AUTH/build.log")"
fi

echo "--- 2. author_mode: --diff shows the difference, does not write ---"
build "$AUTH" --diff
if grep -q 'sync-manifest.yaml' "$AUTH/build.log"; then
    pass "--diff reports the author-sourced file that differs from the template"
else
    fail "--diff is silent about the author-sourced file: $(cat "$AUTH/build.log")"
fi
[ "$(cat "$AUTH/.claude/sync-manifest.yaml")" = "$ROOT_MANIFEST_TEXT" ] \
    && pass "--diff wrote nothing" || fail "--diff changed the root file"

echo "--- 3. author_mode: a missing author-sourced file is still seeded ---"
AUTH2="$TMP_ROOT/author-empty"
make_workspace "$AUTH2" true
mv "$AUTH2/.claude/sync-manifest.yaml" "$TMP_ROOT/moved-aside.yaml"
build "$AUTH2" --quiet || fail "rebuild failed: $(cat "$AUTH2/build.log")"
if cmp -s "$TEMPLATE_MANIFEST" "$AUTH2/.claude/sync-manifest.yaml"; then
    pass "missing file seeded from the template"
else
    fail "missing author-sourced file was not seeded"
fi

echo "--- 4. ordinary install: the template copy is delivered as before ---"
USERWS="$TMP_ROOT/user"
make_workspace "$USERWS" false
build "$USERWS" --quiet || fail "rebuild failed: $(cat "$USERWS/build.log")"
if cmp -s "$TEMPLATE_MANIFEST" "$USERWS/.claude/sync-manifest.yaml"; then
    pass "non-author install receives the template .claude/sync-manifest.yaml"
else
    fail "non-author install did not receive the template copy"
fi

echo ""
echo "PASS: $PASS_COUNT  FAIL: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
