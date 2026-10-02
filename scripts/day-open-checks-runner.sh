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

# Universal checks belong to the template; user checks are additional. The old
# fallback let any custom split file (including an agent-only file) replace the
# baseline, so a truncated DayPlan could pass with zero universal checks.
# Discover each set separately and run the baseline last, so it validates the
# final DayPlan even if a custom bash block changed it. No user file is copied,
# changed, or ignored (issue #635's preserve requirement).
TEMPLATE_EXT_DIR="$IWE_TEMPLATE/extensions"
BASELINE_FILES=$(find_day_open_hook_files "$TEMPLATE_EXT_DIR" "checks")
BASELINE_STATUS=$?
if [ "$BASELINE_STATUS" -ne 0 ] || [ -z "$BASELINE_FILES" ]; then
  echo "❌ day-open-checks-runner: no template day-open.checks*.md found in $TEMPLATE_EXT_DIR — universal checks unavailable. Commit BLOCKED."
  exit 1
fi
USER_FILES=$(find_day_open_hook_files "$EXT_DIR" "checks")
USER_STATUS=$?
if [ "$USER_STATUS" -ne 0 ]; then
  echo "❌ day-open-checks-runner: could not enumerate $EXT_DIR — user checks may be missing. Commit BLOCKED."
  exit 1
fi

CHECKS_FILES="$BASELINE_FILES"
if [ "$(cd "$TEMPLATE_EXT_DIR" && pwd -P)" = "$(cd "$EXT_DIR" && pwd -P)" ]; then
  # A self-contained checkout may use one directory as both template and
  # workspace. The discovery sets then contain the same files: run each once.
  echo "  ℹ️  Template and workspace checks share $EXT_DIR — running each file once"
elif [ -n "$USER_FILES" ]; then
  CHECKS_FILES=$(printf '%s\n%s' "$USER_FILES" "$BASELINE_FILES")
  echo "  ℹ️  Running user checks from $EXT_DIR, then template checks from $TEMPLATE_EXT_DIR"
else
  echo "  ℹ️  $EXT_DIR has no day-open.checks*.md — using template checks from $TEMPLATE_EXT_DIR"
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
if [ "$DAYOPEN_HOOK_BLOCKS_RUN" -eq 0 ]; then
  echo "❌ day-open-checks-runner: no executable bash checks ran. Commit BLOCKED."
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
