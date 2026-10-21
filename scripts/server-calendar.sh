#!/usr/bin/env bash
# routing: server  deterministic=true
# see DP.SC.159, DP.ROLE.059
# server-calendar.sh — cross-platform replacement mcp__ext-google-calendar for server-mode
# see WP-283 (DS-strategy/inbox/WP-283-server-day-open-crossplatform.md)
#
# Outputs a ready-made markdown-section «Calendar» for DayPlan or WeekPlan.
#
# Features:
#   - Day mode (default): events for 1 day, free blocks, statuses ⏳/🔄/✅
#   - Week mode (--week): events for 7 days, summary by day
#   - Classification: meeting (meetings) vs task (reminders, tech-operations)
#
# Requires:
#   env: GOOGLE_REFRESH_TOKEN, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET
#   or file ~/.secrets/google-calendar (lines KEY=VALUE)
#   config: day-rhythm-config.yaml → calendar_ids (empty list = all
#     available calendars via calendarList, missing key means error calendarList, missing key = error)
#
# Usage:
#   bash server-calendar.sh YYYY-MM-DD [CONFIG_PATH]
#   bash server-calendar.sh --week [YYYY-MM-DD] [CONFIG_PATH]
#   bash server-calendar.sh 2026-05-19
#   bash server-calendar.sh --json [YYYY-MM-DD] [CONFIG_PATH]
#   bash server-calendar.sh --json --tz Asia/Nicosia [YYYY-MM-DD] [CONFIG_PATH]
#
# --tz <IANA name>: only --json honors it. Without it, the queried window is
#   a literal UTC day (unchanged default, every existing caller). With it,
#   the window is the true local day/week in that zone, converted to UTC.
#
# --json: instead of markdown-section prints one JSON-object to stdout —
#   {schema_version, source_version, generated_at, window_start, window_end,
#    events[], errors[], status}. events[] — the same structure, that is built by
#   markdown-mode (summary/start/duration/...), plus id/updated_at/end for
#   machine consumer (WP-389 Phase6, bounded-bounded calendar source for
#   Secretary). Contract: generated_at — the exact moment the Google API was called Google API
#   (snapshot age must be measured from that moment, not from the time of reading
#   downstream-module); on any early exit (no credentials, no
#   calendar_ids, OAuth error) events=[] and status="pending" with the reason in
#   errors[] — the same "always renders" principle, that the markdown mode already maintains markdown-
#   mode, only in machine form instead of placeholder text-placeholder.

set -uo pipefail

SCRIPT_SOURCE_VERSION=1

# Common exit for every early cannot continue "cannot continue" (python3/credentials/
# OAuth/config are missing). $reason goes into both markdown-text, and into JSON
# errors[]; downstream-reader from WP-389 Phase6 does not need to parse markdown,
# in order to distinguish "pending" from a real list of events.
report_pending() {
  local reason="$1"
  if [[ "$JSON_MODE" == true ]]; then
    if [[ -n "${PYTHON3:-}" ]]; then
      # Proper JSON string escaping (control characters included, not just
      # quotes/backslashes) — the one call site before PYTHON3 resolves only
      # ever passes a fixed literal with no embedded data, so the bash
      # fallback below is sufficient there (code review finding, 2026-10-05:
      # $ERROR/$CONFIG in the later call sites are not fixed literals).
      $PYTHON3 -c "
import json, sys
print(json.dumps({
    'schema_version': 1, 'source_version': $SCRIPT_SOURCE_VERSION,
    'generated_at': None, 'window_start': None, 'window_end': None,
    'events': [], 'errors': [sys.argv[1]], 'status': 'pending',
}))
" "$reason"
    else
      local esc="${reason//\\/\\\\}"
      esc="${esc//\"/\\\"}"
      printf '{"schema_version":1,"source_version":%s,"generated_at":null,"window_start":null,"window_end":null,"events":[],"errors":["%s"],"status":"pending"}\n' \
        "$SCRIPT_SOURCE_VERSION" "$esc"
    fi
  else
    echo "📅 **Calendar ($DATE):** ⚠️ PENDING — $reason"
    echo ""
    echo "⏱ Free blocks ≥1h: **not determined**"
  fi
  exit 0
}

# --- Argument parsing ---
WEEK_MODE=false
JSON_MODE=false
DATE_ARG=""
CONFIG_ARG=""
# --tz <IANA name>: only --json honors this (see TIME_MIN/TIME_MAX below) —
# markdown/day-open-pipeline.sh callers keep the UTC-day window unchanged,
# a deliberate backward-compat boundary, not an oversight (WP-389 Phase6).
TZ_ARG=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --week) WEEK_MODE=true ;;
        --json) JSON_MODE=true ;;
        --tz)
            # Only consume the next token as the zone if it isn't itself a
            # recognized flag (`--tz --week ...` must not swallow --week as
            # a bogus zone name — code review finding, 2026-10-05, second
            # pass). A missing/flag-like value just leaves TZ_ARG empty;
            # --json then keeps the literal-UTC window, same as omitting
            # --tz entirely.
            case "${2:-}" in
                --* | "") ;;
                *) shift; TZ_ARG="$1" ;;
            esac
            ;;
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) DATE_ARG="$1" ;;
        *) [ -f "$1" ] && CONFIG_ARG="$1" ;;
    esac
    shift
done

DATE="${DATE_ARG:-$(date +%Y-%m-%d)}"
IWE="${IWE_ROOT:-$HOME/IWE}"
CONFIG="${CONFIG_ARG:-$IWE/.iwe-runtime/day-rhythm-config.yaml}"
SECRETS_FILE="${HOME}/.secrets/google-calendar"

# --- Selecting python3 with PyYAML (shared resolver, WP-529 F6 / #453 #463) ---
RESOLVER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/find-python3.sh"
if ! PYTHON3=$("$RESOLVER"); then
  # Explicit dependency error instead of the old lie: a yaml-less interpreter
  # used to surface later as "calendar_ids not found in config" (Evgenii,
  # 18.08). Same PENDING+exit 0 contract as the credentials branch below —
  # the section must always render.
  report_pending "python3 with PyYAML library not found. Install: python3 with library PyYAML. Install: pip3 install pyyaml (or sudo apt install python3-yaml); see. requirements.txt"
fi

# --- Loading credentials ---
if [[ -f "$SECRETS_FILE" ]]; then
  set -a; source "$SECRETS_FILE"; set +a
fi

REFRESH_TOKEN="${GOOGLE_REFRESH_TOKEN:-}"
CLIENT_ID="${GOOGLE_CLIENT_ID:-}"
CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}"

if [[ -z "$REFRESH_TOKEN" || -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
  report_pending "Google credentials not configured. Set up: ~/.secrets/google-calendar (GOOGLE_REFRESH_TOKEN, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET)"
fi

# --- Fetching access token ---
TOKEN_RESPONSE=$(curl -s -X POST "https://oauth2.googleapis.com/token" \
  -d "client_id=${CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "refresh_token=${REFRESH_TOKEN}" \
  -d "grant_type=refresh_token" 2>/dev/null)

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | $PYTHON3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null)

if [[ -z "$ACCESS_TOKEN" ]]; then
  ERROR=$(echo "$TOKEN_RESPONSE" | $PYTHON3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error_description', d.get('error','unknown')))" 2>/dev/null || echo "unknown")
  report_pending "OAuth error: $ERROR"
fi

# --- Reading calendar_ids from config ---
# issue #489: empty calendar_ids documented as "all available calendars",
# not as "not configured" — sentinel distinguishes missing key (MISSING) from
# explicit empty list (empty stdout, but not MISSING).
CONFIG_READ=$($PYTHON3 -c "
import yaml, sys
try:
    with open('$CONFIG') as f: d = yaml.safe_load(f) or {}
    if 'calendar_ids' in d:
        ids = d.get('calendar_ids')
    elif 'calendar_ids' in d.get('day_open', {}):
        ids = d['day_open']['calendar_ids']
    else:
        print('MISSING')
        sys.exit(0)
    for cid in (ids or []):
        print(cid)
except Exception as e:
    print(f'server-calendar: config read failed: {e}', file=sys.stderr)
    print('MISSING')
")

if [[ "$CONFIG_READ" == "MISSING" ]]; then
  report_pending "key calendar_ids is absent in config ($CONFIG)"
fi

CALENDAR_IDS="$CONFIG_READ"

if [[ -z "$CALENDAR_IDS" ]]; then
  # Empty list = documented "all available calendars" (day-rhythm-config.yaml
  # comment), not a configuration error — requesting full list from Google.
  CALENDAR_IDS=$($PYTHON3 << PYEOF
import subprocess, urllib.parse, json, sys
access_token = "${ACCESS_TOKEN}"
url = "https://www.googleapis.com/calendar/v3/users/me/calendarList"
page_token = ""
ids = []
while True:
    params = "minAccessRole=reader"
    if page_token:
        params += f"&pageToken={urllib.parse.quote(page_token)}"
    result = subprocess.run(
        ["curl", "-s", "-H", f"Authorization: Bearer {access_token}", f"{url}?{params}"],
        capture_output=True, text=True, timeout=15
    )
    if result.returncode != 0:
        print(f"server-calendar: calendarList curl failed: {result.stderr}", file=sys.stderr)
        break
    try:
        data = json.loads(result.stdout)
    except Exception as e:
        print(f"server-calendar: calendarList parse failed: {e}", file=sys.stderr)
        break
    if "error" in data:
        print(f"server-calendar: calendarList API error: {data['error'].get('message', data['error'])}", file=sys.stderr)
        break
    for item in data.get("items", []):
        ids.append(item["id"])
    page_token = data.get("nextPageToken", "")
    if not page_token:
        break
for cid in ids:
    print(cid)
PYEOF
  )
  if [[ -z "$CALENDAR_IDS" ]]; then
    report_pending "calendar_ids is empty (all available calendars), but auto-detection via calendarList returned no calendars"
  fi
fi

# --- Time range ---
if [[ -n "$TZ_ARG" && "$JSON_MODE" == true ]]; then
    # True local-day (or local-week) boundary converted to UTC, not a
    # literal UTC-day window — scoped to --json: markdown/day-open-
    # pipeline.sh callers keep today's UTC-day window unchanged (WP-389 Phase6,
    # code review 2026-10-05: treating DATE as a UTC day silently shifts the
    # queried window by the zone's UTC offset — e.g. for a UTC+3 zone, events
    # in the first ~3h of true local today fall outside it, and the window
    # instead reaches ~3h into the *next* local day).
    SPAN_DAYS=0
    [[ "$WEEK_MODE" == true ]] && SPAN_DAYS=6
    # Command substitution, not `read < <(...)`: the latter's `read` exit
    # status reflects `read` itself, not the substituted command, so a bad
    # --tz value (unknown zone, missing tzdata) would fall through with
    # TIME_MIN/TIME_MAX silently empty instead of hitting report_pending
    # like every other early-exit in this script (code review finding,
    # 2026-10-05, second pass).
    TZ_WINDOW_OUT=$($PYTHON3 -c "
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo
zone = ZoneInfo('$TZ_ARG')
start_local = datetime.strptime('$DATE', '%Y-%m-%d').replace(tzinfo=zone)
end_local = start_local + timedelta(days=$SPAN_DAYS, hours=23, minutes=59, seconds=59)
print(start_local.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
      end_local.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
" 2>/dev/null)
    if [[ $? -ne 0 || -z "$TZ_WINDOW_OUT" ]]; then
        report_pending "invalid timezone --tz '$TZ_ARG' or window calculation failure (tzdata?)"
    fi
    read -r TIME_MIN TIME_MAX <<< "$TZ_WINDOW_OUT"
    if [[ "$WEEK_MODE" == true ]]; then MODE_LABEL="week"; else MODE_LABEL="day"; fi
elif [[ "$WEEK_MODE" == true ]]; then
    TIME_MIN="${DATE}T00:00:00Z"
    # +6 days = week
    TIME_MAX=$($PYTHON3 -c "from datetime import datetime, timedelta; d=datetime.strptime('$DATE','%Y-%m-%d')+timedelta(days=6); print(d.strftime('%Y-%m-%dT23:59:59Z'))")
    MODE_LABEL="week"
else
    TIME_MIN="${DATE}T00:00:00Z"
    TIME_MAX="${DATE}T23:59:59Z"
    MODE_LABEL="day"
fi

# --- Querying each calendar ---
EVENTS_JSON=$($PYTHON3 << PYEOF
# -*- coding: utf-8 -*-
import json, subprocess, urllib.parse, sys, re
from datetime import datetime, timezone, timedelta

calendar_ids = """${CALENDAR_IDS}""".strip().split('\n')
time_min = "${TIME_MIN}"
time_max = "${TIME_MAX}"
access_token = "${ACCESS_TOKEN}"
week_mode = True if "${WEEK_MODE}" == "true" else False
date_arg = "${DATE}"

all_events = []
errors = []

# --- Classification ---
TASK_EMOJI = {"🔧", "✅", "⏰", "🔔", "📋", "❗", "✔", "☑", "📝", "⚡", "🔄", "🔴", "🟡", "🟢"}
TASK_KEYWORDS = [
    "backup", "stress-test", "stress test", "check", "remind", "remind",
    "smoke", "test", "report", "check", "reminder", "task", "todo",
    "review", "review", "audit", "audit", "deploy", "release", "release",
    "sync", "synchronization", "update", "update", "cleanup", "cleanup"
]

def classify_event(item, duration_min):
    summary = item.get("summary", "")
    summary_lower = summary.lower()
    attendees = item.get("attendees", [])
    # Explicit markers
    if any(ch in summary for ch in TASK_EMOJI):
        return "task"
    if any(kw in summary_lower for kw in TASK_KEYWORDS):
        return "task"
    # Meeting = multiple attendees
    non_self = [a for a in attendees if not a.get("self", False)]
    if len(non_self) >= 1:
        return "meeting"
    # Short + no attendees = more likely a task
    if duration_min <= 30 and len(attendees) <= 1:
        return "task"
    return "meeting"

def parse_dt(dt_str):
    """Parses RFC3339 with or without timezone"""
    if not dt_str:
        return None
    # Python 3.11+ supports Z directly; for compatibility replace Z
    try:
        return datetime.fromisoformat(dt_str.replace("Z", "+00:00"))
    except Exception:
        return None

def fmt_time(dt):
    if not dt:
        return "all day"
    return dt.strftime("%H:%M")

def fmt_date(dt):
    months = ["","January","February","March","April","May","June","July","August","September","October","November","December"]
    return f"{dt.day} {months[dt.month]}"

def fmt_date_short(dt):
    weekdays = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
    # weekday() returns 0=Mon
    wd = weekdays[dt.weekday()]
    return f"{wd} {dt.day:02d}.{dt.month:02d}"

now = datetime.now(timezone.utc)

def get_status(start_dt, end_dt):
    if not start_dt or not end_dt:
        return "⏳", "upcoming"
    if now < start_dt:
        return "⏳", "upcoming"
    elif now > end_dt:
        return "✅", "completed"
    else:
        return "🔄", "in progress"

for cid in calendar_ids:
    if not cid.strip():
        continue
    encoded = urllib.parse.quote(cid.strip(), safe='')
    url = f"https://www.googleapis.com/calendar/v3/calendars/{encoded}/events"
    params = f"timeMin={urllib.parse.quote(time_min)}&timeMax={urllib.parse.quote(time_max)}&singleEvents=true&orderBy=startTime&maxResults=100"

    result = subprocess.run(
        ["curl", "-s", "-H", f"Authorization: Bearer {access_token}", f"{url}?{params}"],
        capture_output=True, text=True, timeout=15
    )

    if result.returncode != 0:
        errors.append(f"curl error for {cid}")
        continue

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        errors.append(f"json error for {cid}")
        continue

    if "error" in data:
        # Evgenii Red Team review 2026-08-19 (defect #4): this continue was
        # silent — no cid, no error code, unlike the curl/json branches two
        # steps up. issue #453 (below) fixed the same class of drop for a
        # single event's visibility, not for a whole calendar's API error
        # (403 on a calendar the token lacks access to, 404 on a deleted
        # calendar, etc.) — that one stayed silent.
        #
        # Cold review 2026-08-19: Google's error envelope is normally
        # {"error": {"code": ...}}, but a malformed/truncated response body
        # (or a non-standard error shape from a proxy) could put a string or
        # null there instead of a dict — calling .get() on a non-dict raises
        # AttributeError and would crash the whole calendar loop on one bad
        # response instead of recording it as an error like every other item
        # here.
        error_field = data.get("error")
        err_code = error_field.get("code", "?") if isinstance(error_field, dict) else "?"
        errors.append(f"calendar API error for {cid}: code={err_code}")
        continue

    for item in data.get("items", []):
        summary = item.get("summary", "(no title)")
        start = item.get("start", {})
        end = item.get("end", {})
        visibility = item.get("visibility", "")
        if visibility == "private":
            # issue #453: record the drop — a silently vanished event is
            # indistinguishable from a consistent count downstream. Re-applied
            # after the 2026-08-19 template-sync reverted commit 4744cb1
            # (root↔template drift; see WP-529 F6 / WP-485).
            errors.append(f"skipped private event: {summary}")
            continue

        start_dt = parse_dt(start.get("dateTime"))
        end_dt = parse_dt(end.get("dateTime"))
        all_day = "date" in start

        if all_day:
            start_dt = datetime.strptime(start["date"], "%Y-%m-%d").replace(tzinfo=timezone.utc)
            end_dt = datetime.strptime(end["date"], "%Y-%m-%d").replace(tzinfo=timezone.utc) + timedelta(days=1)
            duration_min = 24 * 60
            start_time = "all day"
        else:
            if start_dt and end_dt:
                duration_min = int((end_dt - start_dt).total_seconds() / 60)
            else:
                duration_min = 0
            start_time = fmt_time(start_dt)

        if duration_min < 60:
            duration = f"{duration_min}m"
        else:
            h = duration_min // 60
            m = duration_min % 60
            duration = f"{h}h{m:02d}m" if m else f"{h}h"
        if all_day:
            duration = "all day"

        ev_type = classify_event(item, duration_min)
        status_emoji, status_text = get_status(start_dt, end_dt)

        all_events.append({
            "start_dt": start_dt.isoformat() if start_dt else None,
            "end_dt": end_dt.isoformat() if end_dt else None,
            "start_time": start_time,
            "date": start_dt.strftime("%Y-%m-%d") if start_dt else date_arg,
            "date_short": fmt_date_short(start_dt) if start_dt else "",
            "summary": summary,
            "duration": duration,
            "duration_min": duration_min,
            "type": ev_type,
            "status_emoji": status_emoji,
            "status_text": status_text,
            "all_day": all_day,
            # For machine consumer (WP-389 Phase6): stable_id survives
            # overwrite summary/time of the same event, updated_at — for
            # detecting a changed event without comparing all fields.
            "stable_id": item.get("id", ""),
            "calendar_id": cid.strip(),
            "updated_at": item.get("updated"),
        })

# Sort by date-time
all_events.sort(key=lambda e: e["start_dt"] or "")

print(json.dumps({"events": all_events, "errors": errors}, ensure_ascii=False))
PYEOF
)

# --- Machine output (--json): envelope with snapshot age instead of markdown ---
if [[ "$JSON_MODE" == true ]]; then
  $PYTHON3 << PYEOF
# -*- coding: utf-8 -*-
import json
from datetime import datetime, timezone

try:
    data = json.loads("""${EVENTS_JSON}""")
except Exception:
    data = {"events": [], "errors": ["parse error"]}

events = data.get("events", [])
errors = data.get("errors", [])
has_calendar_api_error = any(e.startswith("calendar API error for") for e in errors)

print(json.dumps({
    "schema_version": 1,
    "source_version": ${SCRIPT_SOURCE_VERSION},
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "window_start": "${TIME_MIN}",
    "window_end": "${TIME_MAX}",
    "events": events,
    "errors": errors,
    "status": "degraded" if has_calendar_api_error else "ok",
}, ensure_ascii=False))

import sys
sys.exit(1 if has_calendar_api_error else 0)
PYEOF
  exit $?
fi

# --- Build markdown ---
$PYTHON3 << PYEOF
# -*- coding: utf-8 -*-
import json, sys
from datetime import datetime, timezone

try:
    data = json.loads("""${EVENTS_JSON}""")
except Exception:
    data = {"events": [], "errors": ["parse error"]}

events = data.get("events", [])
errors = data.get("errors", [])
date_str = "${DATE}"
week_mode = True if "${WEEK_MODE}" == "true" else False

# Cold review 2026-08-19 (Codex, WP-529 Red Team round 2): this script always
# exited 0 regardless of errors[] — the current caller (day-open-pipeline.sh)
# runs it with a trailing "|| true" and reads errors from this JSON, so a
# non-zero exit would not break it — but the script had no exit-status
# signal at all for interactive runs, cron/monitoring, or future callers.
# Only the "calendar API error" class (defect #4 above: 403/5xx-style
# Google API errors on a
# whole calendar, not a single event) counts as degraded — curl/json parse
# errors and skipped-private-event notices are the same partial-result class
# this script already tolerated before this fix and stay non-fatal, matching
# Codex's "should not treat every non-empty errors[] as fatal" concern
# from turn 1. String-prefix match, not a new typed error field: the errors[]
# list stays flat strings, only this one class has a distinguishing prefix.
has_calendar_api_error = any(e.startswith("calendar API error for") for e in errors)

months = ["","January","February","March","April","May","June","July","August","September","October","November","December"]
try:
    dt = datetime.strptime(date_str, "%Y-%m-%d")
    day_label = f"{dt.day} {months[dt.month]}"
except Exception:
    day_label = date_str

meetings = [e for e in events if e["type"] == "meeting"]
tasks = [e for e in events if e["type"] == "task"]

# ============ WEEK MODE ============
if week_mode:
    n = len(events)
    count_label = f"{n} {'event' if n==1 else 'events' if 2<=n<=4 else 'events'}"
    print(f"📅 **Week calendar ({day_label} — +6 days):** ✅ {count_label}.")
    print()

    # Group by day
    from collections import OrderedDict
    days = OrderedDict()
    for e in events:
        d = e["date"]
        if d not in days:
            days[d] = []
        days[d].append(e)

    for d, evs in days.items():
        date_obj = datetime.strptime(d, "%Y-%m-%d")
        wd = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"][date_obj.weekday()]
        label = f"{wd} {date_obj.day} {months[date_obj.month]}"
        m_count = sum(1 for e in evs if e["type"] == "meeting")
        t_count = sum(1 for e in evs if e["type"] == "task")
        tags = []
        if m_count: tags.append(f"{m_count} meetings")
        if t_count: tags.append(f"{t_count} tasks")
        print(f"**{label}** ({', '.join(tags)})")
        print()
        print("| 🚦 | Time | Event | Dur.. | Type |")
        print("|----|-------|---------|-------|-----|")
        for e in evs:
            s = e["summary"].replace("|", "\\\\|")
            t = "meeting" if e["type"] == "meeting" else "task"
            print(f"| {e['status_emoji']} | {e['start_time']} | {s} | {e['duration']} | {t} |")
        print()

    if errors:
        print(f"> ⚠️ Skipped during parsing: {len(errors)}")
        for err in errors:
            print(f">   - {err}")
    sys.exit(1 if has_calendar_api_error else 0)

# ============ DAY MODE ============
n = len(events)
count_label = f"{n} {'event' if n==1 else 'events' if 2<=n<=4 else 'events'}"
print(f"📅 **Calendar ({day_label} {dt.year}):** ✅ {count_label}.")
print()

if meetings:
    print("**Meetings**")
    print("| 🚦 | Time | Event | Dur. | Link to WP |")
    print("|----|-------|---------|-------|------------|")
    for e in meetings:
        s = e["summary"].replace("|", "\\\\|")
        print(f"| {e['status_emoji']} | {e['start_time']} | {s} | {e['duration']} | — |")
    print()
else:
    print("**Meetings:** none")
    print()

if tasks:
    print("**Reminders / Tech-operations**")
    print("| 🚦 | Time | What | Dur. | Result |")
    print("|----|-------|-----|-------|-----------|")
    for e in tasks:
        s = e["summary"].replace("|", "\\\\|")
        print(f"| {e['status_emoji']} | {e['start_time']} | {s} | {e['duration']} | — |")
    print()
else:
    print("**Reminders / Tech-operations:** none")
    print()

# Free blocks (day mode only, only when timed events exist)
timed_events = [e for e in events if e["start_time"] != "all day"]
if not timed_events:
    print("⏱ Free blocks ≥1h: **all day** (09:00–22:00)")
else:
    busy = []
    for e in timed_events:
        t = e["start_time"]
        try:
            h, m = map(int, t.split(":"))
            busy.append((h * 60 + m, h * 60 + m + e["duration_min"]))
        except Exception:
            pass

    if not busy:
        print("⏱ Free blocks ≥1h: **all day** (09:00–22:00)")
    else:
        # Working range 09:00–22:00
        work_start = 9 * 60
        work_end = 22 * 60
        busy.sort()
        # Merge overlapping
        merged = [busy[0]]
        for s, e in busy[1:]:
            if s <= merged[-1][1]:
                merged[-1] = (merged[-1][0], max(merged[-1][1], e))
            else:
                merged.append((s, e))
        free_blocks = []
        if merged[0][0] > work_start:
            free_blocks.append((work_start, merged[0][0]))
        for i in range(len(merged) - 1):
            free_blocks.append((merged[i][1], merged[i+1][0]))
        if merged[-1][1] < work_end:
            free_blocks.append((merged[-1][1], work_end))

        # Filter ≥60 min
        free_strs = []
        for s, e in free_blocks:
            if e - s >= 60:
                sh, sm = s // 60, s % 60
                eh, em = e // 60, e % 60
                free_strs.append(f"{sh:02d}:{sm:02d}–{eh:02d}:{em:02d}")

        if free_strs:
            print(f"⏱ Free blocks ≥1h: {', '.join(free_strs)}")
        else:
            print("⏱ Free blocks ≥1h: packed day, free windows ≥1h none")

if errors:
    print()
    print(f"> ⚠️ Skipped during parsing: {len(errors)}")
    for err in errors:
        print(f">   - {err}")

sys.exit(1 if has_calendar_api_error else 0)
PYEOF
