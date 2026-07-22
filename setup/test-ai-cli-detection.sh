#!/bin/bash
# Regression test: setup.sh обнаруживает настраиваемый AI CLI и печатает его версию.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iwe-ai-cli-test.XXXXXX")"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/workspace"
FAKE_CLI="$TEST_DIR/bin/test-codex"
printf '%s\n' '#!/bin/sh' 'echo "test-codex 1.2.3"' > "$FAKE_CLI"
chmod +x "$FAKE_CLI"

OUTPUT=$(PATH="$TEST_DIR/bin:$PATH" \
    AI_CLI_CANDIDATES="test-codex" \
    SETUP_CI=1 \
    WORKSPACE_DIR="$TEST_DIR/workspace" \
    bash "$TEMPLATE_DIR/setup.sh" --dry-run 2>&1)

echo "$OUTPUT" | grep -Fq "AI Agent: test-codex ($FAKE_CLI)"
echo "$OUTPUT" | grep -Fq "Version: test-codex 1.2.3"
echo "$OUTPUT" | grep -Fq "AI CLI:         test-codex (test-codex 1.2.3)"
grep -Fq 'AI_CLI_CANDIDATES:-claude codex kimi-code kimi hermes' "$TEMPLATE_DIR/setup.sh"

echo "PASS: AI CLI detection includes Codex and reports command/version"
