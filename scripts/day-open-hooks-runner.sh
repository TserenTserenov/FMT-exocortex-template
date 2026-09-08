#!/bin/bash
# day-open-hooks-runner.sh — runs extensions/day-open.<hook>*.md bash-block
# hooks for the "before" and "after" points of the Day Open pipeline
# (WP-529 Ф11). "checks" stays on its own dedicated day-open-checks-runner.sh
# — its exact CLI/output is depended on by existing tests and the pipeline's
# commit gate, and unlike before/after it always ships a default extension
# file, so an absent one is an error there, not here (see below).
#
# Usage: day-open-hooks-runner.sh <before|after>
# Exit: 0 — no extensions/day-open.<hook>*.md present (silent no-op: before/
#           after are optional user extensions, no default ships for them —
#           unlike "checks", so absence is not an error) OR all hooks passed.
#       1 — a hook block failed, a hook file contributed zero bash blocks
#           (same "\`\`\`bash fencing typo" trap issue #466 fixed for checks),
#           extensions/ itself is missing/unreadable (every install ships
#           it — that is a broken install, not "no hooks"), or a hook file
#           vanished/became unreadable between discovery and read.
#       2 — bad usage.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/day-open-hooks.sh
. "$SCRIPT_DIR/lib/day-open-hooks.sh"

HOOK="${1:-}"
case "$HOOK" in
  before|after) ;;
  *)
    echo "usage: $0 <before|after>" >&2
    exit 2
    ;;
esac

IWE="${IWE_ROOT:-$HOME/IWE}"
EXT_DIR="$IWE/extensions"
export HOME
export IWE

HOOK_FILES=$(find_day_open_hook_files "$EXT_DIR" "$HOOK")
FIND_STATUS=$?
if [ "$FIND_STATUS" -ne 0 ]; then
  echo "❌ day-open-hooks-runner ($HOOK): could not enumerate $EXT_DIR (missing/unreadable) — treating as failure, not as 'no hooks'."
  exit 1
fi

if [ -z "$HOOK_FILES" ]; then
  exit 0
fi

# Not `run_day_open_hook_files ... || { ... }` — a function call that is
# itself part of an `||`/`if`/`!` test suppresses `errexit` transitively for
# everything inside it WITHIN THE SAME SHELL EXECUTION CONTEXT, including a
# nested subshell that re-declares `set -e` (Codex review, 2026-08-28:
# verified this is not hypothetical — `foo() { ( set -e; false; echo x ); };
# foo || true` prints "x"). Does not apply across a process boundary — the
# pipeline's own `bash day-open-hooks-runner.sh before || abort ...` call is
# fine, since that's a separate `bash` process, not a same-shell function
# call. Capture the exit status as its own statement first.
run_day_open_hook_files "$HOOK_FILES"
RUN_STATUS=$?
if [ "$RUN_STATUS" -ne 0 ]; then
  echo "❌ day-open-hooks-runner ($HOOK): could not track hook results (mktemp failure) — treating as failure."
  exit 1
fi

if [ "$DAYOPEN_HOOK_BLOCKS_FAILED" -gt 0 ]; then
  echo ""
  echo "❌ day-open-hooks-runner ($HOOK): $DAYOPEN_HOOK_BLOCKS_FAILED/$DAYOPEN_HOOK_BLOCKS_RUN block(s) failed."
  exit 1
fi

echo "✅ day-open-hooks-runner ($HOOK): all $DAYOPEN_HOOK_BLOCKS_RUN hook(s) passed."
exit 0
