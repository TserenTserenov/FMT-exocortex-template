#!/bin/bash
# routing: hook  trigger=pre-commit  deterministic=true
# see DP.SC.159, DP.ROLE.059
# Blocks staged additions that match the canonical secret corpus.
#
# The hook reports only pattern identifiers and counts. It must never echo a
# matched diff line, secret value or content-derived digest.
#
# Activation: git config core.hooksPath .githooks
# Bypass:     git commit --no-verify (only as an explicit operator decision)
#
# This is local defense in depth: it deliberately uses the helper from the
# current working tree, so protected-branch CI remains the independent control
# against a staged helper modification or an explicit --no-verify bypass.

set -uo pipefail
umask 077
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

if ! repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
  printf 'Pre-commit secret scan unavailable: repository root is unknown.\n' >&2
  exit 2
fi

SECRET_LIB="$repo_root/.claude/hooks/secret-bypass-lib.sh"
if [ ! -r "$SECRET_LIB" ]; then
  SECRET_LIB="${IWE_ROOT:-$HOME/IWE}/.claude/hooks/secret-bypass-lib.sh"
fi
if [ ! -r "$SECRET_LIB" ]; then
  printf 'Pre-commit secret scan unavailable: canonical pattern library is missing.\n' >&2
  exit 2
fi
# shellcheck source=../.claude/hooks/secret-bypass-lib.sh
# shellcheck disable=SC1090,SC1091
. "$SECRET_LIB"
if ! command -v secret_pattern_process >/dev/null 2>&1 \
  || [ ! -x "$SECRET_BYPASS_JQ" ] \
  || [ ! -x "$SECRET_BYPASS_PYTHON" ]; then
  printf 'Pre-commit secret scan unavailable: validated helpers are missing.\n' >&2
  exit 2
fi

if ! staged_diff=$(git diff --cached --diff-filter=ACMR --no-ext-diff --unified=0 -- .); then
  printf 'Pre-commit secret scan unavailable: staged diff could not be read.\n' >&2
  exit 2
fi
if [ -z "$staged_diff" ]; then
  exit 0
fi

# Drop diff metadata and the leading "+" marker. Line indexes returned by the
# helper are internal only; the hook intentionally omits source lines entirely.
added_lines=$(printf '%s\n' "$staged_diff" | sed -n '/^+++ /d; s/^+//p')
if [ -z "$added_lines" ]; then
  exit 0
fi

if ! analysis=$(printf '%s' "$added_lines" | secret_pattern_process detect-text 2>/dev/null) \
  || ! printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -e '
      type == "object"
      and (.pattern_ids | type == "array" and all(.[]; type == "string"))
      and (.patterns | type == "array" and all(.[];
        type == "object"
        and (.pattern_id | type == "string")
        and (.count | type == "number" and . >= 1 and floor == .)))
      and (.match_count | type == "number" and . >= 0 and floor == .)
    ' >/dev/null 2>&1; then
  printf 'Pre-commit secret scan unavailable: staged analysis failed closed.\n' >&2
  exit 2
fi

match_count=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.match_count')
if [ "$match_count" -eq 0 ]; then
  exit 0
fi

pattern_count=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.pattern_ids | length')
printf 'Pre-commit BLOCKED: %s possible secret(s) in %s pattern class(es).\n' \
  "$match_count" "$pattern_count" >&2
printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '
  .patterns[] | "- \(.pattern_id): \(.count) match(es)"
' >&2
printf 'Matched values and source lines are intentionally hidden.\n' >&2
printf 'Use git commit --no-verify only after an explicit operator review.\n' >&2
exit 1
