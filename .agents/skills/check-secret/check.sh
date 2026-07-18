#!/bin/bash
# check-secret skill backend (B7.7c, WP-212)
# Принимает: путь к файлу или inline текст.
# Возвращает: exit 0 + "OK" или exit 1 + список найденных паттернов.
#
# Использует те же regex что pre-commit-secret-scan.sh + secret-leak-block.sh
# (single source of truth — хочется синхронизации; пока копия, future: shared lib).

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

# Если -, читаем из stdin
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

# Паттерны (label|regex)
declare -a patterns=(
  "Better Stack API token|ust_[A-Za-z0-9]{20,}"
  "Telegram bot token|[0-9]{8,10}:[A-Za-z0-9_-]{35}"
  "Hex secret в env|(_SECRET|_HMAC|_TOKEN|_API_KEY)[[:space:]]*=[[:space:]]*\"?[a-f0-9]{32,}"
  "Neon API key|napi_[A-Za-z0-9]{30,}"
  "DATABASE_URL с user:pass|postgresql(ql)?://[^:[:space:]]+:[^@[:space:]]{4,}@"
  "Anthropic API key|sk-ant-api[0-9]{2}-[A-Za-z0-9_-]{30,}"
  "GitHub token|gh[poshru]_[A-Za-z0-9]{30,}"
  "AWS access key|AKIA[0-9A-Z]{16}"
  "Generic 40+ char API token|(_API_KEY|_TOKEN|_KEY)[[:space:]]*=[[:space:]]*\"?[A-Za-z0-9_-]{40,}\"?"
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
echo "Действия:"
echo "  - Если плейсхолдер/тест — заменить на [REDACTED] или добавить '# secret-ok' маркер в строку."
echo "  - Если реальный секрет — НЕ публиковать. Cascade rotation: ~/IWE/DS-ecosystem-development/.../Runbooks/DP.RUNBOOK.003-cascade-secret-rotation.md"
echo "  - Правило поведения: ~/IWE/memory/feedback_behaviour.md Правило 25."
echo ""
exit 1
