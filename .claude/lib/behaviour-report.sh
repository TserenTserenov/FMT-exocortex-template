#!/usr/bin/env bash
# behaviour-report.sh
# see DP.SC.026 (agent behaviour monitoring), WP-229 Phase8
# Pattern aggregator: reads gate_log + all incident-log → summary by P{N}.
#
# Supports two formats:
#   (A) JSON payload from auto-detectors: {"payload": {"pattern": "P1_not_capturing"}}
#   (B) YAML-block from manual entries:   pattern: P5
#
# Usage:
#   behaviour-report.sh [--period YYYY-MM] [--threshold N] [--json]
#
#   --period YYYY-MM   period (default: current month)
#   --threshold N      threshold for the recommendation «create detector» (default: 3)
#   --json             output in JSON instead of text

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./iwe-env-bootstrap.sh
source "$LIB_DIR/iwe-env-bootstrap.sh" || exit 1
PERIOD=$(date +%Y-%m)
THRESHOLD=3
OUTPUT_JSON=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --period) PERIOD="$2"; shift 2 ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    --json) OUTPUT_JSON=1; shift ;;
    *) shift ;;
  esac
done

# Temporary files for aggregation (key=pattern, value=count via sort|uniq -c)
TMP_GATE_ALL=$(mktemp /tmp/br_gate_all.XXXX)
TMP_GATE_FIRED=$(mktemp /tmp/br_gate_fired.XXXX)
TMP_INCIDENTS=$(mktemp /tmp/br_incidents.XXXX)
trap "rm -f $TMP_GATE_ALL $TMP_GATE_FIRED $TMP_INCIDENTS" EXIT

# --- Step 1: gate_log ---
GATE_LOG="$IWE_ROOT/.claude/logs/gate_log.jsonl"
if [ -f "$GATE_LOG" ]; then
  while IFS= read -r line; do
    ts=$(echo "$line" | jq -r '.ts // empty' 2>/dev/null)
    [[ "$ts" != "${PERIOD}"* ]] && continue
    pat=$(echo "$line" | jq -r '.pattern // empty' 2>/dev/null)
    [ -z "$pat" ] && continue
    fired=$(echo "$line" | jq -r '.fired // "false"' 2>/dev/null)
    echo "$pat" >> "$TMP_GATE_ALL"
    [ "$fired" = "true" ] && echo "$pat" >> "$TMP_GATE_FIRED"
  done < "$GATE_LOG"
fi

# --- Step 2: all incident-log files ---
while IFS= read -r logfile; do
  [ -f "$logfile" ] || continue

  # Format A: JSON  "pattern": "P1_not_capturing"
  grep -o '"pattern"[[:space:]]*:[[:space:]]*"[^"]*"' "$logfile" 2>/dev/null \
    | sed 's/.*"pattern"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' \
    >> "$TMP_INCIDENTS" || true

  # Format B: YAML  pattern: P5  (with indent or without; may be "P2, P5 (×3)")
  grep -E 'pattern:[[:space:]]*P[0-9]' "$logfile" 2>/dev/null \
    | grep -oE 'P[0-9]+[a-zA-Z_]*' \
    >> "$TMP_INCIDENTS" || true

done < <(find "$IWE_ROOT" -name "incident-log-${PERIOD}.md" -not -path "*/.git/*" 2>/dev/null)

# --- Step 3: count ---
# Function: count pattern in file
count_pat() {
  local pat="$1" file="$2"
  [ -f "$file" ] || { echo "0"; return; }
  local n
  n=$(grep -c "^${pat}$" "$file" 2>/dev/null) || n=0
  echo "${n:-0}"
}

# Collect the list of all unique patterns
ALL_PATS=$(cat "$TMP_GATE_ALL" "$TMP_GATE_FIRED" "$TMP_INCIDENTS" 2>/dev/null \
  | sort -u)

if [ -z "$ALL_PATS" ]; then
  if [ "$OUTPUT_JSON" = "1" ]; then
    echo "{\"period\":\"$PERIOD\",\"patterns\":[],\"recommendations\":[]}"
  else
    echo "behaviour-report: no data for $PERIOD"
  fi
  exit 1
fi

# --- Step 4: summary ---
INCIDENT_FILE_COUNT=$(find "$IWE_ROOT" -name "incident-log-${PERIOD}.md" \
  -not -path "*/.git/*" 2>/dev/null | wc -l | tr -d ' ')

if [ "$OUTPUT_JSON" = "1" ]; then
  # JSON output
  PATTERNS_ARR="["
  RECS_ARR="["
  first_p=1
  first_r=1

  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    gate_total=$(count_pat "$pat" "$TMP_GATE_ALL")
    gate_fired=$(count_pat "$pat" "$TMP_GATE_FIRED")
    incidents=$(count_pat "$pat" "$TMP_INCIDENTS")
    total=$(( gate_fired + incidents ))

    [ "$first_p" = "0" ] && PATTERNS_ARR+=","
    PATTERNS_ARR+="{\"pattern\":\"$pat\",\"gate_total\":$gate_total,\"gate_fired\":$gate_fired,\"incidents\":$incidents,\"total\":$total}"
    first_p=0

    # Recommendations
    rec_code=""
    if [ "$gate_total" -gt 0 ]; then
      fp=$(( gate_total - gate_fired ))
      fp_rate=$(( fp * 100 / gate_total ))
      if [ "$fp_rate" -gt 10 ]; then
        rec_code="revert_gate"
      fi
    fi
    if [ -z "$rec_code" ] && [ "$total" -ge "$THRESHOLD" ]; then
      case "$pat" in
        P1*|P3*|P9*) rec_code="ok" ;;
        *) rec_code="create_detector" ;;
      esac
    fi

    if [ "$rec_code" = "create_detector" ]; then
      [ "$first_r" = "0" ] && RECS_ARR+=","
      RECS_ARR+="{\"pattern\":\"$pat\",\"action\":\"$rec_code\",\"total\":$total}"
      first_r=0
    fi
  done <<< "$ALL_PATS"

  PATTERNS_ARR+="]"
  RECS_ARR+="]"
  echo "{\"period\":\"$PERIOD\",\"threshold\":$THRESHOLD,\"patterns\":${PATTERNS_ARR},\"recommendations\":${RECS_ARR}}"

else
  # Text output
  echo "=== Behaviour Report: ${PERIOD} (threshold: ≥${THRESHOLD} → detector) ==="
  echo ""
  printf "%-30s %10s %12s %11s  %s\n" "Pattern" "gate/fired" "incidents" "total" "Status"
  printf "%-30s %10s %12s %11s  %s\n" "-------" "----------" "---------" "-----" "------"

  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    gate_total=$(count_pat "$pat" "$TMP_GATE_ALL")
    gate_fired=$(count_pat "$pat" "$TMP_GATE_FIRED")
    incidents=$(count_pat "$pat" "$TMP_INCIDENTS")
    total=$(( gate_fired + incidents ))

    # Status
    status=""
    if [ "$gate_total" -gt 0 ]; then
      fp=$(( gate_total - gate_fired ))
      fp_rate=$(( fp * 100 / gate_total ))
      if [ "$fp_rate" -gt 10 ]; then
        status="⚠️  FP ${fp_rate}% → roll back gate"
      fi
    fi
    if [ -z "$status" ] && [ "$total" -ge "$THRESHOLD" ]; then
      case "$pat" in
        P1*|P3*|P9*) status="✅ detector active" ;;
        *)            status="🔴 create detector!" ;;
      esac
    fi
    if [ -z "$status" ]; then
      status="📊 accumulating (${total}/${THRESHOLD})"
    fi

    printf "%-30s %10s %12s %11s  %s\n" \
      "$pat" "${gate_fired}/${gate_total}" "$incidents" "$total" "$status"
  done <<< "$ALL_PATS"

  echo ""
  echo "Sources: gate_log + ${INCIDENT_FILE_COUNT} incident-log file(s) in ~/IWE/"
  echo "Run: ~/.claude/lib/behaviour-report.sh [--period YYYY-MM] [--threshold N] [--json]"
fi

exit 0
