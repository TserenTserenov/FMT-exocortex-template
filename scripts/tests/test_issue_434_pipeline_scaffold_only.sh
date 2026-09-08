#!/usr/bin/env bash
set -euo pipefail

# issue #434: day-open-pipeline.sh ran the LLM Proxy healthcheck (step 2)
# before the deterministic scaffold (step 3) and aborted the whole run if
# the proxy was unreachable — even though only step 4 (LLM Fill) actually
# needs it. --scaffold-only must skip steps 2 and 4 entirely.
#
# The full pipeline needs a real DS-strategy tree, git state, session-guard,
# and several helper scripts to run end-to-end — too much unrelated
# scaffolding to mock faithfully here. Instead this test extracts the real
# step-2 block by its line markers (same technique already used by
# test_create_wp_weekplan_writer.py for a similarly large production
# script) and runs it standalone with a fake curl/abort, so a future edit
# that removes or narrows the --scaffold-only guard breaks a real,
# observable assertion instead of just a text grep.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PIPELINE="$ROOT/scripts/day-open-pipeline.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

START=$(grep -n '^if \[ "\$SCAFFOLD_ONLY" != "true" \]; then$' "$PIPELINE" | head -1 | cut -d: -f1)
END=$(grep -n '^# 3\. Scaffold$' "$PIPELINE" | head -1 | cut -d: -f1)
if [[ -z "$START" || -z "$END" ]]; then
    echo "FAIL: не нашёл границы блока шага 2 в day-open-pipeline.sh — маркеры сдвинулись?"
    exit 1
fi
STEP2_BLOCK=$(sed -n "${START},$((END - 3))p" "$PIPELINE")

harness() {
    local scaffold_only="$1"
    cat > "$TMP/run.sh" <<HARNESS
set -uo pipefail
SCAFFOLD_ONLY=$scaffold_only
PROXY_IS_LOCAL=false
LLM_PROXY_URL="http://unreachable.invalid:1"
PROXY_PORT=18765
LLM_PROXY_SECRET=""
CURL_CALLS="$TMP/curl-calls"
: > "\$CURL_CALLS"
curl() { echo "1" >> "\$CURL_CALLS"; echo "fail"; return 1; }
abort() { echo "ABORT_CALLED: \$*"; exit 42; }
tg_notify() { :; }
$STEP2_BLOCK
echo "REACHED_STEP_3"
HARNESS
    bash "$TMP/run.sh"
}

OUTPUT_ON=$(harness "true" 2>&1) || true
if echo "$OUTPUT_ON" | grep -q "REACHED_STEP_3" && ! echo "$OUTPUT_ON" | grep -q "ABORT_CALLED" \
   && [[ "$(wc -l < "$TMP/curl-calls")" -eq 0 ]]; then
    echo "PASS (1/2): --scaffold-only пропускает healthcheck целиком, curl не вызывается, abort не срабатывает"
else
    echo "FAIL (1/2): при SCAFFOLD_ONLY=true healthcheck не пропущен как ожидалось"
    echo "$OUTPUT_ON"
    exit 1
fi

OUTPUT_OFF=$(harness "false" 2>&1) || true
if echo "$OUTPUT_OFF" | grep -q "ABORT_CALLED" && ! echo "$OUTPUT_OFF" | grep -q "REACHED_STEP_3"; then
    echo "PASS (2/2): обычный режим (без флага) по-прежнему абортит при недоступном прокси — поведение не ослаблено"
else
    echo "FAIL (2/2): обычный режим перестал абортить при недоступном прокси — регрессия"
    echo "$OUTPUT_OFF"
    exit 1
fi
