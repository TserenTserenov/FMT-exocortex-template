#!/bin/bash
# day-open-checks-runner.sh — парсер и исполнитель bash-блоков из extensions/day-open.checks.md
# see WP-7 Ф-DayOpen-Enforcement DOE2
# NOTE: checks.md is a trusted local source (not shared/untrusted input).

set -uo pipefail
# -u: fail on unset variables
# -o pipefail: catch errors in pipelines
# Intentionally no -e: we collect errors across blocks, not abort on first failure.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/day-open-hooks.sh
. "$SCRIPT_DIR/lib/day-open-hooks.sh"

IWE="${IWE_ROOT:-$HOME/IWE}"
IWE_TEMPLATE="${IWE_TEMPLATE:-$IWE/FMT-exocortex-template}"
EXT_DIR="$IWE/extensions"
DAYPLAN="${1:-}"

# Find current DayPlan if not provided
if [ -z "$DAYPLAN" ]; then
  DAYPLAN=$(find "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/current" -maxdepth 1 -name "DayPlan *.md" -type f 2>/dev/null | head -1)
fi

if [ -z "$DAYPLAN" ] || [ ! -f "$DAYPLAN" ]; then
  echo "❌ DayPlan not found in current/ — nothing to check"
  exit 1
fi

export FILE="$DAYPLAN"
export CFG="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/exocortex/day-rhythm-config.yaml"
export HOME
export IWE

# Same convention as .claude/scripts/load-extensions.sh: single file
# `day-open.checks.md` or split files `day-open.checks.*.md` (issue #466 —
# the old hardcoded single path made the split convention invisible here).
CHECKS_FILES=$(find_day_open_hook_files "$EXT_DIR" "checks")
FIND_STATUS=$?

# extensions/ is deliberately empty until the user adds a customization
# (extensions/README.md: "update.sh never touches this dir") — setup.sh does
# not seed it, so a fresh install has no $EXT_DIR/day-open.checks*.md at all.
# The template still ships its own universal-invariant default (WP-529 Ф7);
# fall back to it ONLY when the workspace copy has nothing, so a pilot who
# has customized their own extensions/day-open.checks.md keeps using theirs
# unchanged (issue #635).
if [ "$FIND_STATUS" -ne 0 ] || [ -z "$CHECKS_FILES" ]; then
  TEMPLATE_EXT_DIR="$IWE_TEMPLATE/extensions"
  CHECKS_FILES=$(find_day_open_hook_files "$TEMPLATE_EXT_DIR" "checks")
  FIND_STATUS=$?
  if [ "$FIND_STATUS" -eq 0 ] && [ -n "$CHECKS_FILES" ]; then
    echo "  ℹ️  $EXT_DIR has no day-open.checks*.md — using template default from $TEMPLATE_EXT_DIR"
  fi
fi

if [ "$FIND_STATUS" -ne 0 ] || [ -z "$CHECKS_FILES" ]; then
  echo "❌ day-open-checks-runner: no day-open.checks*.md found in $EXT_DIR or $IWE_TEMPLATE/extensions — nothing to check"
  exit 1
fi

# Not `run_day_open_hook_files ... || { ... }` — see scripts/day-open-hooks-runner.sh
# for why a function call inside `||`/`if`/`!` suppresses `errexit` transitively,
# including in a nested subshell that re-declares `set -e` (Codex review,
# 2026-08-28). Capture the exit status as its own statement first.
run_day_open_hook_files "$CHECKS_FILES"
RUN_STATUS=$?
if [ "$RUN_STATUS" -ne 0 ]; then
  echo "❌ day-open-checks-runner: could not track check results (mktemp failure). Commit BLOCKED."
  exit 1
fi

if [ "$DAYOPEN_HOOK_BLOCKS_FAILED" -gt 0 ]; then
  echo ""
  echo "❌ day-open-checks-runner: $DAYOPEN_HOOK_BLOCKS_FAILED/$DAYOPEN_HOOK_BLOCKS_RUN block(s) failed. Commit BLOCKED."
  exit 1
else
  echo "✅ day-open-checks-runner: all $DAYOPEN_HOOK_BLOCKS_RUN check(s) passed."
  exit 0
fi
