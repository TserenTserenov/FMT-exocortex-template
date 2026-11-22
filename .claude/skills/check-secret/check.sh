#!/bin/bash
# check-secret skill backend (B7.7c, WP-212)
# Accepts: a file path or inline text.
# Returns: exit 0 + "OK" or exit 1 + list of matched patterns.
#
# Uses the same regex as pre-commit-secret-scan.sh + secret-leak-block.sh
# (single source of truth — synchronization is desired; currently a copy, future: shared lib).

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$SKILL_DIR/../.." && pwd)"
# shellcheck source=../../lib/iwe-env-bootstrap.sh
source "$CLAUDE_DIR/lib/iwe-env-bootstrap.sh" || exit 1

LOG_FILE="$IWE_ROOT/.claude/logs/check-secret.jsonl"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

input="${*:-}"
if [ -z "$input" ]; then
  echo "Usage: check.sh <file-path-or-text>"
  echo "       cat file.txt | check.sh -"
  exit 2
fi

# If -, read from stdin
if [ "$input" = "-" ]; then
  text=$(cat)
elif [ -f "$input" ]; then
  text=$(cat "$input")
else
  text="$input"
fi

if [ -z "$text" ]; then
  echo "OK: empty input, no secrets detected"
  exit 0
fi

# Patterns (label|regex)
declare -a patterns=(
  "Better Stack API token|ust_[A-Za-z0-9]{20,}"
  "Telegram bot token|[0-9]{8,10}:[A-Za-z0-9_-]{35}"
  "Hex secret in env|(_SECRET|_HMAC|_TOKEN|_API_KEY)[[:space:]]*=[[:space:]]*\"?[a-f0-9]{32,}"
  "Neon API key|napi_[A-Za-z0-9]{30,}"
  "DATABASE_URL with user:pass|postgresql(ql)?://[^:[:space:]]+:[^@[:space:]]{4,}@"
  "Anthropic API key|sk-ant-api[0-9]{2}-[A-Za-z0-9_-]{30,}"
  "GitHub token|gh[poshru]_[A-Za-z0-9]{30,}"
  "AWS access key|AKIA[0-9A-Z]{16}"
  "AWS secret key|[Aa][Ww][Ss].{0,24}([Ss]ecret|[Pp]rivate).{0,24}[=:][[:space:]]*[\"']?[A-Za-z0-9/+=]{40}"
  "Generic 40+ char API token|(_API_KEY|_TOKEN|_KEY)[[:space:]]*=[[:space:]]*\"?[A-Za-z0-9_/+=-]{40,}\"?"
)

violations=""
match_count=0

for entry in "${patterns[@]}"; do
  label="${entry%%|*}"
  pat="${entry#*|}"

  hits=$(printf '%s' "$text" | grep -nE "$pat" || true)
  if [ -n "$hits" ]; then
    violations="${violations}
[$label]
$hits
"
    match_count=$((match_count + 1))
  fi
done

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
input_hash=$(printf '%s' "$text" | shasum -a 256 | cut -c1-16)

if [ -z "$violations" ]; then
  jq -nc \
    --arg ts "$ts" \
    --arg hash "$input_hash" \
    --arg len "${#text}" \
    '{ts:$ts, skill:"check-secret", input_hash:$hash, input_len:($len|tonumber), decision:"clean"}' \
    >> "$LOG_FILE" 2>/dev/null || true
  echo "OK: no secrets detected (input: ${#text} chars)"
  exit 0
fi

jq -nc \
  --arg ts "$ts" \
  --arg hash "$input_hash" \
  --arg cnt "$match_count" \
  '{ts:$ts, skill:"check-secret", input_hash:$hash, decision:"detected", patterns_matched:($cnt|tonumber)}' \
  >> "$LOG_FILE" 2>/dev/null || true

echo ""
echo "🚫 SECRETS DETECTED ($match_count pattern(s)):"
echo "$violations"
echo ""
echo "Actions:"
echo "  - If placeholder/test — replace with [REDACTED] or add '# secret-ok' marker to the line."
echo "  - If real secret — DO NOT publish. Cascade rotation: DP.RUNBOOK.003-cascade-secret-rotation.md"
echo "  - Conduct rule: secrets must never be published to chat as plaintext."
echo ""
exit 1
