#!/usr/bin/env bash
# capture_fixture.sh — shared fixture builder for capture-bus.sh contract tests.
#
# capture-bus.sh resolves its own directory via `dirname "${BASH_SOURCE[0]}"`
# (HOOK_DIR/CLAUDE_DIR), so it must run from a real .claude/hooks/ layout, not
# a lone copy in a bare tmpdir — a bare copy either can't find lib/config at
# all, or (when run from its real location without a stdin payload) exits
# immediately via the empty-stdin guard before reaching any detector. Building
# a minimal-but-complete .claude/ tree sidesteps both traps.

setup_capture_fixture() {
  local template_root=$1
  local fixture_root=$2

  mkdir -p \
    "$fixture_root/.claude/hooks" \
    "$fixture_root/.claude/lib" \
    "$fixture_root/.claude/config" \
    "$fixture_root/.claude/logs"

  cp "$template_root/.claude/hooks/capture-bus.sh" \
    "$fixture_root/.claude/hooks/"
  cp "$template_root/.claude/lib/iwe-env-bootstrap.sh" \
    "$template_root/.claude/lib/log_formatter.sh" \
    "$template_root/.claude/lib/capture_writer.sh" \
    "$fixture_root/.claude/lib/"

  export WORKSPACE_DIR="$fixture_root"
  export IWE_ROOT="$fixture_root"
  export IWE_TEMPLATE="$template_root"
  export CAPTURE_LOG_FILE="$fixture_root/.claude/logs/capture_log.jsonl"
}
