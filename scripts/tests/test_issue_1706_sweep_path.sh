#!/usr/bin/env bash
# Regression for #1706: the session-prep prompt told the agent to run the active-WP
# sweep from the workspace scripts folder. An install whose scripts live elsewhere
# (IWE_SCRIPTS set, the template's own scripts/) could not find it. The prompt must name
# the sweep through ${IWE_SCRIPTS:-$HOME/IWE/scripts}, as week-review.md already does.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROMPT="$ROOT/roles/strategist/prompts/session-prep.md"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

[ -f "$PROMPT" ] || { echo "FAIL: prompt not found: $PROMPT"; exit 1; }

# 1. No mention resolves the sweep from the workspace scripts folder any more.
# shellcheck disable=SC2016  # the pattern is a regular expression, nothing should expand
if grep -nE '(\{\{WORKSPACE_DIR\}\}|~/IWE|\$WORKSPACE(_DIR)?)/scripts/active-wp-sweep\.sh' "$PROMPT" >/dev/null; then
    bad "the prompt still names the sweep under the workspace scripts folder"
else
    pass "the prompt does not name the sweep under the workspace scripts folder"
fi

# 2. Both mentions (the bullet and the quoted source) use the IWE_SCRIPTS form.
cmds="$(grep -oE 'bash "\$\{IWE_SCRIPTS:-[^}]*\}/active-wp-sweep\.sh"' "$PROMPT")"
count="$(printf '%s\n' "$cmds" | grep -c . || true)"
if [ "$count" -eq 2 ]; then
    pass "both mentions use the IWE_SCRIPTS form"
else
    bad "expected 2 mentions through IWE_SCRIPTS, found $count"
fi

# 3. The command the prompt hands to the agent really finds the sweep: first through
#    IWE_SCRIPTS (an install whose scripts folder is not under the workspace), then through
#    the fallback when IWE_SCRIPTS is not set.
cmd="$(printf '%s\n' "$cmds" | head -1)"
mkdir -p "$TMP/elsewhere" "$TMP/home/IWE/scripts"
printf '#!/bin/sh\necho SWEEP-FROM-IWE_SCRIPTS\n' > "$TMP/elsewhere/active-wp-sweep.sh"
printf '#!/bin/sh\necho SWEEP-FROM-HOME\n' > "$TMP/home/IWE/scripts/active-wp-sweep.sh"

out="$(env -i PATH="$PATH" HOME="$TMP/home" IWE_SCRIPTS="$TMP/elsewhere" bash -c "$cmd" 2>&1)"
if [ "$out" = "SWEEP-FROM-IWE_SCRIPTS" ]; then
    pass "the command finds the sweep through IWE_SCRIPTS"
else
    bad "with IWE_SCRIPTS set the command printed: ${out:-<nothing>}"
fi

out="$(env -i PATH="$PATH" HOME="$TMP/home" bash -c "$cmd" 2>&1)"
if [ "$out" = "SWEEP-FROM-HOME" ]; then
    pass "the command falls back to \$HOME/IWE/scripts when IWE_SCRIPTS is not set"
else
    bad "without IWE_SCRIPTS the command printed: ${out:-<nothing>}"
fi

exit "$fail"
