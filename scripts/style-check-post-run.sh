#!/usr/bin/env bash
# style-check-post-run.sh — response style check Kimi after peer-session (WP-388 Phase9)
#
# Usage: invoked from kimi-peer-adapter.sh or manually
#   bash scripts/style-check-post-run.sh <report-file>
#
# Checks report.md for violations of L0+L1 style rules.
# Writes violations to ~/.iwe/style-violations.log (shared with Claude).
# Level: warning, does not block commit.

set -euo pipefail

REPORT_FILE="${1:-}"
if [ -z "$REPORT_FILE" ] || [ ! -f "$REPORT_FILE" ]; then
    echo "Usage: style-check-post-run.sh <report-file.md>"
    exit 0
fi

LOG_FILE="${HOME}/.iwe/style-violations.log"
mkdir -p "$(dirname "$LOG_FILE")"

TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
AGENT="kimi"
VIOLATIONS=0

check_and_log() {
    local rule="$1"
    local description="$2"
    local pattern="$3"
    local context

    if context=$(grep -nP "$pattern" "$REPORT_FILE" 2>/dev/null | head -3); then
        if [ -n "$context" ]; then
            VIOLATIONS=$((VIOLATIONS + 1))
            echo "$TIMESTAMP | $AGENT | $rule | $description | $(echo "$context" | head -1 | cut -c1-120)" >> "$LOG_FILE"
            echo "  ⚠️  $rule: $description"
        fi
    fi
}

echo "Checking style: $(basename "$REPORT_FILE")"

# R3: path as subject (in sections §1-§4, not in transcripts)
check_and_log "R3" "path as subject" '^\s*`?[a-zA-Z_/.-]+\.(py|md|ts|sh|js|yaml|json)(:[0-9]+)?`?\s+(—|contains|is responsible for|processes|does|creates|stores)'

# R4: passive voice
check_and_log "R4" "passive voice" '(was discovered|was found|was identified|turned out|it turned out that|was(a|o)? (discovered|found|identified))'

# L0.4: bare English markers
check_and_log "L0.4" "bare English marker" '\b(exit\s+0|PASS|FAIL|SHA:\s*[a-f0-9]{7,}|status:\s*done)\b'

# R1: process log
check_and_log "R1" "process log" '^(Reading|Checking|Looking|Searching|Let me|Right now (I will take a look|I will check|I will read)|Reading file|Checking|Searching|Looking)'

# L0.1: service labels in sections §1-§4
check_and_log "L0.1" "service label in synthesis" '(FORM\.[0-9]+|B7\.[0-9]|WP-[0-9]+ (cutover|Phase[0-9]|done))'

if [ "$VIOLATIONS" -gt 0 ]; then
    echo "Violations found: $VIOLATIONS (details in $LOG_FILE)"
else
    echo "No style violations found ✅"
fi

exit 0
