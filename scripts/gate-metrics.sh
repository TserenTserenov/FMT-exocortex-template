#!/usr/bin/env bash
# gate-metrics.sh -- WP-436: measure reflex/passthrough/llm routing from gate-decisions.jsonl
#
# History: written for WP-423 Phase6.4 ("dummy test: % tasks without LLM"). That phase
# closed 2026-06-21 as "mechanism verified, coverage metric N/A" -- this script no
# longer gates a closure decision for it. It now just reports the live split for
# whoever is reading gate-decisions.jsonl (currently WP-436's headless-executor door).
#
# routing=passthrough (WP-436 Phase5b, added 2026-07-08): a caller that set
# GateInput.self_decided=True -- e.g. a watchdog's own quiet-branch verdict -- and
# hit no catalog reflex. Before this, such calls fell back to routing=llm even
# though no model was ever consulted: ~850 of ~930 "llm" records in the first two
# weeks of this journal were exactly this (deploy-watchdog's silent nightly runs).
#
# Date filter (2026-07-28, WP-7 Phase-DayOpen-2026-07-28-FourFindings): without it, the
# journal is read cover-to-cover from whenever it was first created (no rotation) --
# a DayPlan reader sees "369 tasks" and reasonably assumes "today", when it's actually
# 5+ weeks of accumulated history. Filtering by timestamp prefix keeps the script's
# own semantics (period since the log started) available via the positional arg while
# giving day-open-scaffold.sh a way to ask for "today only".
#
# Usage: bash gate-metrics.sh [path/to/gate-decisions.jsonl] [YYYY-MM-DD]

set -euo pipefail

GATE_LOG="${1:-${HOME}/.iwe/gate-decisions.jsonl}"
DATE_FILTER="${2:-}"

# All echoed text is user-facing (pilot reads it in the DayPlan) -> Russian, plain words.
if [[ ! -f "$GATE_LOG" ]]; then
    echo "Dispatcher decision log not found: $GATE_LOG"
    echo "Run the task dispatcher or the nightly audit, so that data appears."
    exit 1
fi

# Validate JSONL before analysis so jq errors produce a clear message.
if ! jq -s '.[]' "$GATE_LOG" >/dev/null 2>&1; then
    echo "Decision log is corrupted or contains non-JSON lines: $GATE_LOG"
    exit 1
fi

# jq's startswith() over the raw ISO8601 timestamp -- "2026-07-28" matches
# "2026-07-28T07:06:37Z" without needing a date-parsing library for a same-day check.
JQ_FILTER="."
PERIOD_LABEL="for the period"
if [[ -n "$DATE_FILTER" ]]; then
    JQ_FILTER=". | select(.timestamp != null and (.timestamp | startswith(\"$DATE_FILTER\")))"
    PERIOD_LABEL="for $DATE_FILTER"
fi

# TOTAL comes from jq's own parsed-object count, not `wc -l`: a blank line or a future
# unknown `routing` value would inflate wc -l's count without landing in any of the
# three buckets below, silently making the percentages not add up to 100%.
TOTAL=$(jq -s "[.[] | $JQ_FILTER] | length" "$GATE_LOG")
if [[ "$TOTAL" -eq 0 ]]; then
    if [[ -n "$DATE_FILTER" ]]; then
        echo "For $DATE_FILTER no records found in the log (dispatcher was not started or has not yet completed any task)."
    else
        echo "Decision log is empty: no tasks have been routed yet."
    fi
    exit 0
fi

REFLEX=$(jq -s "[.[] | $JQ_FILTER | select(.routing == \"reflex\")] | length" "$GATE_LOG")
PASSTHROUGH=$(jq -s "[.[] | $JQ_FILTER | select(.routing == \"passthrough\")] | length" "$GATE_LOG")
LLM=$(jq -s "[.[] | $JQ_FILTER | select(.routing == \"llm\")] | length" "$GATE_LOG")
OTHER=$((TOTAL - REFLEX - PASSTHROUGH - LLM))
REFLEX_PCT=$(python3 -c "print(f'{$REFLEX/$TOTAL*100:.1f}')")
PASSTHROUGH_PCT=$(python3 -c "print(f'{$PASSTHROUGH/$TOTAL*100:.1f}')")
LLM_PCT=$(python3 -c "print(f'{$LLM/$TOTAL*100:.1f}')")

echo "How the dispatcher routed tasks $PERIOD_LABEL:"
echo "  total tasks: $TOTAL"
echo "  resolved by reflex, without calling the model: $REFLEX ($REFLEX_PCT%)"
echo "  resolved by the caller itself, without reflex and without AI: $PASSTHROUGH ($PASSTHROUGH_PCT%)"
echo "  actually required AI: $LLM ($LLM_PCT%)"
if [[ "$OTHER" -gt 0 ]]; then
    echo "  unknown route type (not reflex/passthrough/llm): $OTHER — check the log"
fi
echo ""
echo "What was handled by reflex:"
# handler names are raw values from the log; show each with its count
jq -r "$JQ_FILTER | select(.routing == \"reflex\" and .handler != null and .handler != \"\") | .handler" "$GATE_LOG" | sort | uniq -c | sort -rn | sed 's/^ *\([0-9][0-9]*\) /  \1 × /'

if [[ "$LLM" -gt 0 ]]; then
    echo ""
    echo "Tasks, that actually required AI (top-10):"
    jq -r "$JQ_FILTER | select(.routing == \"llm\") | .task_id" "$GATE_LOG" | sort | uniq -c | sort -rn | head -10 | sed 's/^ *\([0-9][0-9]*\) /  \1 × /'
fi
