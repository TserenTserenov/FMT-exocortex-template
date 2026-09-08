#!/bin/bash
# test-build-runtime-preserves-live-state.sh — regression test for
# bug-2026-09-02-build-runtime-wipes-live-session-state: a rebuild used to
# `rm -rf` the ENTIRE previous .iwe-runtime/ on swap, silently destroying
# live operational state that other scripts (session-guard.sh and friends)
# keep directly under it — sessions/*.open, isolate-push-attempts/, etc. —
# even though .iwe-runtime/ is documented as build-only/regenerable.
#
# Runs the REAL build-runtime.sh against a throwaway --workspace, not a
# reimplementation of its swap logic.
#
# Usage: bash setup/test-build-runtime-preserves-live-state.sh

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SELF_DIR")"
BUILD_SCRIPT="$REPO_ROOT/setup/build-runtime.sh"
TEST_WORKSPACE="${BUILD_RUNTIME_TEST_WORKSPACE:-/tmp/iwe-build-runtime-test-$$}"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_WORKSPACE"; exit "$rc"; }
trap cleanup EXIT INT TERM

mkdir -p "$TEST_WORKSPACE"
ENV_FILE="$TEST_WORKSPACE/.exocortex.env"
cat > "$ENV_FILE" <<EOF
HOME_DIR="$HOME"
USER_NAME="$(id -un)"
WORKSPACE_DIR="$TEST_WORKSPACE"
CLAUDE_PATH="$(command -v claude || echo /usr/local/bin/claude)"
CLAUDE_PROJECT_SLUG="test"
TIMEZONE_HOUR="3"
TIMEZONE_DESC="UTC"
GITHUB_USER="test-user"
GOVERNANCE_REPO="DS-strategy"
IWE_TEMPLATE="$REPO_ROOT"
IWE_RUNTIME="$TEST_WORKSPACE/.iwe-runtime"
EOF

echo "--- Первая сборка: создаёт .iwe-runtime/ с нуля ---"
if bash "$BUILD_SCRIPT" --workspace "$TEST_WORKSPACE" --env-file "$ENV_FILE" --quiet >"$TEST_WORKSPACE/build1.log" 2>&1; then
    pass "первая сборка прошла"
else
    fail "первая сборка упала: $(cat "$TEST_WORKSPACE/build1.log")"
fi
[ -d "$TEST_WORKSPACE/.iwe-runtime/roles/extractor" ] && pass "roles/extractor на месте после первой сборки" \
    || fail "roles/extractor отсутствует после первой сборки"

echo "--- Сею живое состояние, которое build-runtime.sh не производит сам ---"
mkdir -p "$TEST_WORKSPACE/.iwe-runtime/sessions" "$TEST_WORKSPACE/.iwe-runtime/isolate-push-attempts"
echo "live-session-marker" > "$TEST_WORKSPACE/.iwe-runtime/sessions/claude-code-999.open"
echo "live-isolate-attempt" > "$TEST_WORKSPACE/.iwe-runtime/isolate-push-attempts/attempt.json"
# A top-level FILE, not just directories (open-sessions.log lives exactly like
# this in the real .iwe-runtime/) — the fix's `[ -e ... ] || mv` check must not
# assume every surviving entry is a directory.
echo "live-log-line" > "$TEST_WORKSPACE/.iwe-runtime/open-sessions.log"

echo "--- Вторая сборка: должна пересобрать roles/, но не тронуть живое состояние ---"
if bash "$BUILD_SCRIPT" --workspace "$TEST_WORKSPACE" --env-file "$ENV_FILE" --quiet >"$TEST_WORKSPACE/build2.log" 2>&1; then
    pass "вторая сборка прошла"
else
    fail "вторая сборка упала: $(cat "$TEST_WORKSPACE/build2.log")"
fi

if [ -f "$TEST_WORKSPACE/.iwe-runtime/sessions/claude-code-999.open" ] \
   && [ "$(cat "$TEST_WORKSPACE/.iwe-runtime/sessions/claude-code-999.open")" = "live-session-marker" ]; then
    pass "живой маркер сессии пережил пересборку"
else
    fail "живой маркер сессии ПОТЕРЯН при пересборке (это и есть баг 2026-09-02)"
fi

if [ -f "$TEST_WORKSPACE/.iwe-runtime/isolate-push-attempts/attempt.json" ]; then
    pass "isolate-push-attempts/ пережил пересборку"
else
    fail "isolate-push-attempts/ ПОТЕРЯН при пересборке"
fi

if [ -f "$TEST_WORKSPACE/.iwe-runtime/open-sessions.log" ] \
   && [ "$(cat "$TEST_WORKSPACE/.iwe-runtime/open-sessions.log")" = "live-log-line" ]; then
    pass "живой файл верхнего уровня (не директория) пережил пересборку"
else
    fail "живой файл верхнего уровня ПОТЕРЯН при пересборке"
fi

[ -d "$TEST_WORKSPACE/.iwe-runtime/roles/extractor" ] && pass "roles/extractor всё ещё на месте после второй сборки" \
    || fail "roles/extractor пропал после второй сборки"

NEW_HASH=$(cat "$TEST_WORKSPACE/.iwe-runtime/.build-hash" 2>/dev/null)
[ -n "$NEW_HASH" ] && pass "build-hash присутствует после пересборки (roles/ реально регенерируется, не просто сохраняется старьё)" \
    || fail "build-hash отсутствует после пересборки"

echo ""
echo "============================================"
echo "  Results: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
echo "============================================"
[ "$FAIL_COUNT" -eq 0 ]
