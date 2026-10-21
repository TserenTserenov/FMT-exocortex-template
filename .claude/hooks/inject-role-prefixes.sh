#!/bin/bash
# inject-role-prefixes.sh
# Event: UserPromptSubmit
# see DP.SC.154 (Role prefixes), WP-445 Phase4
#
# Purpose: lazy-lazy injection of full role context ONLY when the user
#   starts a message with a role-prefix (Navigator, / Diagnostician, / ...).
#   Otherwise — empty response (stub already in rules/role-prefixes.md).
#
# Architecture (WP-445, ArchGate Phase3 M2-mitigation):
#   Hot stub:   .claude/rules/role-prefixes.md (~709 bytes, always-loaded)
#   Full:       .claude/rules-lazy/role-prefixes-full.md (~23 KB, lazy)
#   Triggers:   are read DYNAMICALLY from §Activation table full-file — not hardcode.
#
# Savings: ~23 105 bytes (~4 620 tokens) for an ordinary message without a role-prefix.
# Invariant (ArchGate M2): when adding a new role to role-prefixes-full.md §Activation
#   the hook will automatically pick up the new trigger — nothing needs to be changed in the hook.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

command -v jq >/dev/null 2>&1 || { echo '{}'; exit 0; }

INPUT=$(cat 2>/dev/null || echo '{}')

# Extract the UserPromptSubmit prompt (first 100 chars is enough for prefix detection)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null | head -c 100 || echo "")
[ -n "$PROMPT" ] || { echo '{}'; exit 0; }

# Locate the full roles file
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL_FILE="$HOOK_DIR/../rules-lazy/role-prefixes-full.md"
[ -f "$FULL_FILE" ] || { echo '{}'; exit 0; }

# Extract triggers dynamically from §Activation table (M2 mitigation).
# Looks for backtick-quoted strings containing ", ..." in the §Activation section.
# Works with macOS grep/awk — no GNU extensions required.
TRIGGERS=$(awk '/^## Activation/,/^## [^A]/' "$FULL_FILE" 2>/dev/null | \
  grep -o '`[^`]*`' | \
  grep ', \.\.\.' | \
  sed 's/`//g; s/, \.\.\.$//')

[ -n "$TRIGGERS" ] || { echo '{}'; exit 0; }

# Build alternation pattern for grep: each trigger is one line → join with |
PATTERN=$(printf '%s\n' "$TRIGGERS" | tr '\n' '|' | sed 's/|$//')
[ -n "$PATTERN" ] || { echo '{}'; exit 0; }

# Check if prompt starts with any trigger (trigger word + comma at position 0)
# Using grep -iE for case-insensitive match (OrgDev vs orgdev)
if ! printf '%s' "$PROMPT" | grep -qiE "^(${PATTERN}),"; then
  echo '{}'
  exit 0
fi

# Role prefix detected — inject full roles context
FULL_CONTENT=$(awk '/^---$/{n++; if(n==2){found=1; next}} found || n==0' "$FULL_FILE" 2>/dev/null || cat "$FULL_FILE")

CONTEXT="## 🎭 Full role context IWE (loaded by role-prefix)

${FULL_CONTENT}"

jq -n --arg ctx "$CONTEXT" '{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": $ctx
  }
}'
