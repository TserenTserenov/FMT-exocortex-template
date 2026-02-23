#!/bin/bash
# Fetch WakaTime stats for Strategist prompts
# Usage: fetch-wakatime.sh <mode>
#   mode: "day"  — yesterday's summary (for day-plan)
#         "week" — current + previous week (for week-review)

set -e

ENV_FILE="$HOME/.config/aist/env"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

if [ -z "$WAKATIME_API_KEY" ]; then
    echo "WAKATIME_API_KEY not set"
    exit 0  # graceful — don't break strategist if no key
fi

ENCODED=$(echo -n "$WAKATIME_API_KEY" | base64)
API="https://wakatime.com/api/v1/users/current"

waka_fetch() {
    local url="$1"
    curl -s -H "Authorization: Basic $ENCODED" "$url" 2>/dev/null
}

format_projects() {
    # stdin: JSON array of project objects → markdown table rows
    python3 -c "
import sys, json
data = json.load(sys.stdin)
if not data:
    print('| (нет данных) | — |')
else:
    for p in sorted(data, key=lambda x: x.get('total_seconds', 0), reverse=True)[:10]:
        name = p.get('name', '?')
        text = p.get('text', '0 secs')
        print(f'| {name} | {text} |')
" 2>/dev/null || echo "| (ошибка парсинга) | — |"
}

format_languages() {
    python3 -c "
import sys, json
data = json.load(sys.stdin)
if not data:
    print('| (нет данных) | — |')
else:
    for l in sorted(data, key=lambda x: x.get('total_seconds', 0), reverse=True)[:5]:
        name = l.get('name', '?')
        text = l.get('text', '0 secs')
        print(f'| {name} | {text} |')
" 2>/dev/null || echo "| (ошибка парсинга) | — |"
}

mode="${1:-day}"

case "$mode" in
    "day")
        # Yesterday's summary
        YESTERDAY=$(date -v-1d +%Y-%m-%d)
        RESPONSE=$(waka_fetch "$API/summaries?start=$YESTERDAY&end=$YESTERDAY")

        TOTAL=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['cumulative_total']['text'])" 2>/dev/null || echo "н/д")
        PROJECTS_JSON=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); json.dump(d['data'][0].get('projects',[]), sys.stdout)" 2>/dev/null || echo "[]")
        LANGS_JSON=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); json.dump(d['data'][0].get('languages',[]), sys.stdout)" 2>/dev/null || echo "[]")

        cat <<EOF
## WakaTime: вчера ($YESTERDAY)

**Общее время:** $TOTAL

**По проектам:**

| Проект | Время |
|--------|-------|
$(echo "$PROJECTS_JSON" | format_projects)

**По языкам:**

| Язык | Время |
|------|-------|
$(echo "$LANGS_JSON" | format_languages)
EOF
        ;;

    "week")
        # Current week (Mon-today) + previous week
        # Current week
        DOW=$(date +%u)  # 1=Mon
        DAYS_SINCE_MON=$((DOW - 1))
        MON_THIS=$(date -v-${DAYS_SINCE_MON}d +%Y-%m-%d)
        TODAY=$(date +%Y-%m-%d)

        # Previous week
        MON_PREV=$(date -v-$((DAYS_SINCE_MON + 7))d +%Y-%m-%d)
        SUN_PREV=$(date -v-$((DAYS_SINCE_MON + 1))d +%Y-%m-%d)

        RESP_THIS=$(waka_fetch "$API/summaries?start=$MON_THIS&end=$TODAY")
        RESP_PREV=$(waka_fetch "$API/summaries?start=$MON_PREV&end=$SUN_PREV")

        TOTAL_THIS=$(echo "$RESP_THIS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['cumulative_total']['text'])" 2>/dev/null || echo "н/д")
        TOTAL_PREV=$(echo "$RESP_PREV" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['cumulative_total']['text'])" 2>/dev/null || echo "н/д")

        # Aggregate projects across days for current week
        PROJECTS_THIS=$(echo "$RESP_THIS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
agg = {}
for day in d.get('data', []):
    for p in day.get('projects', []):
        name = p['name']
        agg[name] = agg.get(name, 0) + p.get('total_seconds', 0)
result = [{'name': k, 'total_seconds': v, 'text': f'{int(v//3600)}h {int((v%3600)//60)}m'} for k,v in agg.items()]
json.dump(result, sys.stdout)
" 2>/dev/null || echo "[]")

        PROJECTS_PREV=$(echo "$RESP_PREV" | python3 -c "
import sys, json
d = json.load(sys.stdin)
agg = {}
for day in d.get('data', []):
    for p in day.get('projects', []):
        name = p['name']
        agg[name] = agg.get(name, 0) + p.get('total_seconds', 0)
result = [{'name': k, 'total_seconds': v, 'text': f'{int(v//3600)}h {int((v%3600)//60)}m'} for k,v in agg.items()]
json.dump(result, sys.stdout)
" 2>/dev/null || echo "[]")

        LANGS_THIS=$(echo "$RESP_THIS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
agg = {}
for day in d.get('data', []):
    for l in day.get('languages', []):
        name = l['name']
        agg[name] = agg.get(name, 0) + l.get('total_seconds', 0)
result = [{'name': k, 'total_seconds': v, 'text': f'{int(v//3600)}h {int((v%3600)//60)}m'} for k,v in agg.items()]
json.dump(result, sys.stdout)
" 2>/dev/null || echo "[]")

        cat <<EOF
## WakaTime: статистика рабочего времени

### Текущая неделя ($MON_THIS — $TODAY)

**Общее время:** $TOTAL_THIS

**По проектам:**

| Проект | Время |
|--------|-------|
$(echo "$PROJECTS_THIS" | format_projects)

**По языкам:**

| Язык | Время |
|------|-------|
$(echo "$LANGS_THIS" | format_languages)

### Предыдущая неделя ($MON_PREV — $SUN_PREV)

**Общее время:** $TOTAL_PREV

**По проектам:**

| Проект | Время |
|--------|-------|
$(echo "$PROJECTS_PREV" | format_projects)

**Сравнение:** текущая $TOTAL_THIS vs предыдущая $TOTAL_PREV
EOF
        ;;

    *)
        echo "Usage: $0 {day|week}"
        exit 1
        ;;
esac
