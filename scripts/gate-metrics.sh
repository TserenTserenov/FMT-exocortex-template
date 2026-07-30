#!/usr/bin/env bash
# gate-metrics.sh -- WP-436: measure reflex/passthrough/llm routing from gate-decisions.jsonl
#
# History: written for WP-423 Ф6.4 ("dummy test: % tasks without LLM"). That phase
# closed 2026-06-21 as "mechanism verified, coverage metric N/A" -- this script no
# longer gates a closure decision for it. It now just reports the live split for
# whoever is reading gate-decisions.jsonl (currently WP-436's headless-executor door).
#
# routing=passthrough (WP-436 Ф5б, added 2026-07-08): a caller that set
# GateInput.self_decided=True -- e.g. a watchdog's own quiet-branch verdict -- and
# hit no catalog reflex. Before this, such calls fell back to routing=llm even
# though no model was ever consulted: ~850 of ~930 "llm" records in the first two
# weeks of this journal were exactly this (deploy-watchdog's silent nightly runs).
#
# Date filter (2026-07-28, WP-7 Ф-DayOpen-2026-07-28-FourFindings): without it, the
# journal is read cover-to-cover from whenever it was first created (no rotation) --
# a DayPlan reader sees "369 задач" and reasonably assumes "today", when it's actually
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
    echo "Журнал решений диспетчера не найден: $GATE_LOG"
    echo "Запустите диспетчер заданий или ночной аудит, чтобы появились данные."
    exit 1
fi

# Validate JSONL before analysis so jq errors produce a clear message.
if ! jq -s '.[]' "$GATE_LOG" >/dev/null 2>&1; then
    echo "Журнал решений повреждён или содержит не-JSON строки: $GATE_LOG"
    exit 1
fi

# jq's startswith() over the raw ISO8601 timestamp -- "2026-07-28" matches
# "2026-07-28T07:06:37Z" without needing a date-parsing library for a same-day check.
JQ_FILTER="."
PERIOD_LABEL="за период"
if [[ -n "$DATE_FILTER" ]]; then
    JQ_FILTER=". | select(.timestamp != null and (.timestamp | startswith(\"$DATE_FILTER\")))"
    PERIOD_LABEL="за $DATE_FILTER"
fi

# TOTAL comes from jq's own parsed-object count, not `wc -l`: a blank line or a future
# unknown `routing` value would inflate wc -l's count without landing in any of the
# three buckets below, silently making the percentages not add up to 100%.
TOTAL=$(jq -s "[.[] | $JQ_FILTER] | length" "$GATE_LOG")
if [[ "$TOTAL" -eq 0 ]]; then
    if [[ -n "$DATE_FILTER" ]]; then
        echo "За $DATE_FILTER записей в журнале нет (диспетчер не запускался или ещё не завершил ни одной задачи)."
    else
        echo "Журнал решений пуст: заданий пока не маршрутизировалось."
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

echo "Как диспетчер разобрал задания $PERIOD_LABEL:"
echo "  всего заданий: $TOTAL"
echo "  решено рефлексом, без вызова модели: $REFLEX ($REFLEX_PCT%)"
echo "  решил сам вызывающий, без рефлекса и без ИИ: $PASSTHROUGH ($PASSTHROUGH_PCT%)"
echo "  реально потребовали ИИ: $LLM ($LLM_PCT%)"
if [[ "$OTHER" -gt 0 ]]; then
    echo "  неизвестный тип маршрута (не reflex/passthrough/llm): $OTHER — проверьте журнал"
fi
echo ""
echo "Чем обрабатывали рефлексом:"
# handler names are raw values from the log; show each with its count
jq -r "$JQ_FILTER | select(.routing == \"reflex\" and .handler != null and .handler != \"\") | .handler" "$GATE_LOG" | sort | uniq -c | sort -rn | sed 's/^ *\([0-9][0-9]*\) /  \1 × /'

if [[ "$LLM" -gt 0 ]]; then
    echo ""
    echo "Задания, реально потребовавшие ИИ (топ-10):"
    jq -r "$JQ_FILTER | select(.routing == \"llm\") | .task_id" "$GATE_LOG" | sort | uniq -c | sort -rn | head -10 | sed 's/^ *\([0-9][0-9]*\) /  \1 × /'
fi
