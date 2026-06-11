#!/usr/bin/env bash
# routing: server  deterministic=true
# see DP.SC.159, DP.ROLE.059
# server-calendar.sh — кросс-платформенная замена mcp__ext-google-calendar для server-mode
# see WP-283 (DS-strategy/inbox/WP-283-server-day-open-crossplatform.md)
#
# Выводит готовую markdown-секцию «Календарь» для DayPlan или WeekPlan.
#
# Возможности:
#   - Режим дня (default): события на 1 день, свободные блоки, статусы ⏳/🔄/✅
#   - Режим недели (--week): события на 7 дней, сводка по дням
#   - Классификация: meeting (встречи) vs task (напоминания, тех-операции)
#
# Требует:
#   env: GOOGLE_REFRESH_TOKEN, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET
#   или файл ~/.secrets/google-calendar (строки KEY=VALUE)
#   config: day-rhythm-config.yaml → calendar_ids
#
# Использование:
#   bash server-calendar.sh YYYY-MM-DD [CONFIG_PATH]
#   bash server-calendar.sh --week [YYYY-MM-DD] [CONFIG_PATH]
#   bash server-calendar.sh 2026-05-19

set -uo pipefail

# --- Разбор аргументов ---
WEEK_MODE=false
DATE_ARG=""
CONFIG_ARG=""

for arg in "$@"; do
    if [[ "$arg" == "--week" ]]; then
        WEEK_MODE=true
    elif [[ "$arg" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        DATE_ARG="$arg"
    elif [[ -f "$arg" ]]; then
        CONFIG_ARG="$arg"
    fi
done

DATE="${DATE_ARG:-$(date +%Y-%m-%d)}"
IWE="${IWE_ROOT:-$HOME/IWE}"
CONFIG="${CONFIG_ARG:-$IWE/DS-strategy/exocortex/day-rhythm-config.yaml}"
SECRETS_FILE="${HOME}/.secrets/google-calendar"

# --- Выбираем python3 с PyYAML ---
_find_python3() {
  if python3 -c "import yaml" 2>/dev/null; then echo "python3"; return; fi
  local p
  for p in \
    /nix/store/aj1smkrsnv16lbz9g8qancb04b3kv0va-python3-3.12.8-env/bin/python3 \
    /usr/bin/python3 /usr/local/bin/python3; do
    [[ -x "$p" ]] && "$p" -c "import yaml" 2>/dev/null && { echo "$p"; return; }
  done
  find /nix/store -maxdepth 3 -name "python3" -path "*env*/bin/*" 2>/dev/null | while read -r p; do
    "$p" -c "import yaml" 2>/dev/null && { echo "$p"; return; }
  done
  echo "python3"
}
PYTHON3=$(_find_python3)

# --- Загружаем credentials ---
if [[ -f "$SECRETS_FILE" ]]; then
  set -a; source "$SECRETS_FILE"; set +a
fi

REFRESH_TOKEN="${GOOGLE_REFRESH_TOKEN:-}"
CLIENT_ID="${GOOGLE_CLIENT_ID:-}"
CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}"

if [[ -z "$REFRESH_TOKEN" || -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
  echo "📅 **Календарь ($DATE):** ⚠️ PENDING — Google credentials не настроены. Установить: \`~/.secrets/google-calendar\` (GOOGLE_REFRESH_TOKEN, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET)"
  echo ""
  echo "⏱ Свободных блоков ≥1h: **не определено**"
  exit 0
fi

# --- Получаем access token ---
TOKEN_RESPONSE=$(curl -s -X POST "https://oauth2.googleapis.com/token" \
  -d "client_id=${CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "refresh_token=${REFRESH_TOKEN}" \
  -d "grant_type=refresh_token" 2>/dev/null)

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | $PYTHON3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null)

if [[ -z "$ACCESS_TOKEN" ]]; then
  ERROR=$(echo "$TOKEN_RESPONSE" | $PYTHON3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error_description', d.get('error','unknown')))" 2>/dev/null || echo "unknown")
  echo "📅 **Календарь ($DATE):** ⚠️ PENDING — OAuth error: $ERROR"
  echo ""
  echo "⏱ Свободных блоков ≥1h: **не определено**"
  exit 0
fi

# --- Читаем calendar_ids из конфига ---
CALENDAR_IDS=$($PYTHON3 -c "
import yaml, sys
try:
    with open('$CONFIG') as f: d = yaml.safe_load(f)
    ids = d.get('calendar_ids') or d.get('day_open', {}).get('calendar_ids', [])
    for cid in (ids or []):
        print(cid)
except Exception as e:
    pass
" 2>/dev/null)

if [[ -z "$CALENDAR_IDS" ]]; then
  echo "📅 **Календарь ($DATE):** ⚠️ PENDING — calendar_ids не найдены в конфиге"
  echo ""
  echo "⏱ Свободных блоков ≥1h: **не определено**"
  exit 0
fi

# --- Временной диапазон ---
if [[ "$WEEK_MODE" == true ]]; then
    TIME_MIN="${DATE}T00:00:00Z"
    # +6 дней = неделя
    TIME_MAX=$($PYTHON3 -c "from datetime import datetime, timedelta; d=datetime.strptime('$DATE','%Y-%m-%d')+timedelta(days=6); print(d.strftime('%Y-%m-%dT23:59:59Z'))")
    MODE_LABEL="неделю"
else
    TIME_MIN="${DATE}T00:00:00Z"
    TIME_MAX="${DATE}T23:59:59Z"
    MODE_LABEL="день"
fi

# --- Запрашиваем каждый календарь ---
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

# --- Классификация ---
TASK_EMOJI = {"🔧", "✅", "⏰", "🔔", "📋", "❗", "✔", "☑", "📝", "⚡", "🔄", "🔴", "🟡", "🟢"}
TASK_KEYWORDS = [
    "backup", "stress-test", "stress test", "проверить", "напомнить", "remind",
    "smoke", "test", "report", "проверка", "напоминание", "задача", "todo",
    "review", "ревью", "аудит", "audit", "deploy", "релиз", "release",
    "sync", "синхронизация", "обновить", "update", "очистить", "cleanup"
]

def classify_event(item, duration_min):
    summary = item.get("summary", "")
    summary_lower = summary.lower()
    attendees = item.get("attendees", [])
    # Явные маркеры
    if any(ch in summary for ch in TASK_EMOJI):
        return "task"
    if any(kw in summary_lower for kw in TASK_KEYWORDS):
        return "task"
    # Встреча = несколько участников
    non_self = [a for a in attendees if not a.get("self", False)]
    if len(non_self) >= 1:
        return "meeting"
    # Короткое + без участников = скорее задача
    if duration_min <= 30 and len(attendees) <= 1:
        return "task"
    return "meeting"

def parse_dt(dt_str):
    """Парсит RFC3339 с или без timezone"""
    if not dt_str:
        return None
    # Python 3.11+ supports Z directly; for compatibility replace Z
    try:
        return datetime.fromisoformat(dt_str.replace("Z", "+00:00"))
    except Exception:
        return None

def fmt_time(dt):
    if not dt:
        return "весь день"
    return dt.strftime("%H:%M")

def fmt_date(dt):
    months = ["","января","февраля","марта","апреля","мая","июня","июля","августа","сентября","октября","ноября","декабря"]
    return f"{dt.day} {months[dt.month]}"

def fmt_date_short(dt):
    weekdays = ["Пн","Вт","Ср","Чт","Пт","Сб","Вс"]
    # weekday() returns 0=Mon
    wd = weekdays[dt.weekday()]
    return f"{wd} {dt.day:02d}.{dt.month:02d}"

now = datetime.now(timezone.utc)

def get_status(start_dt, end_dt):
    if not start_dt or not end_dt:
        return "⏳", "предстоит"
    if now < start_dt:
        return "⏳", "предстоит"
    elif now > end_dt:
        return "✅", "завершено"
    else:
        return "🔄", "идёт"

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
        continue

    for item in data.get("items", []):
        summary = item.get("summary", "(без названия)")
        start = item.get("start", {})
        end = item.get("end", {})
        visibility = item.get("visibility", "")
        if visibility == "private":
            continue

        start_dt = parse_dt(start.get("dateTime"))
        end_dt = parse_dt(end.get("dateTime"))
        all_day = "date" in start

        if all_day:
            start_dt = datetime.strptime(start["date"], "%Y-%m-%d").replace(tzinfo=timezone.utc)
            end_dt = datetime.strptime(end["date"], "%Y-%m-%d").replace(tzinfo=timezone.utc) + timedelta(days=1)
            duration_min = 24 * 60
            start_time = "весь день"
        else:
            if start_dt and end_dt:
                duration_min = int((end_dt - start_dt).total_seconds() / 60)
            else:
                duration_min = 0
            start_time = fmt_time(start_dt)

        if duration_min < 60:
            duration = f"{duration_min}м"
        else:
            h = duration_min // 60
            m = duration_min % 60
            duration = f"{h}ч{m:02d}м" if m else f"{h}ч"
        if all_day:
            duration = "весь день"

        ev_type = classify_event(item, duration_min)
        status_emoji, status_text = get_status(start_dt, end_dt)

        all_events.append({
            "start_dt": start_dt.isoformat() if start_dt else None,
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
        })

# Сортируем по дате-времени
all_events.sort(key=lambda e: e["start_dt"] or "")

print(json.dumps({"events": all_events, "errors": errors}, ensure_ascii=False))
PYEOF
)

# --- Формируем markdown ---
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

months = ["","января","февраля","марта","апреля","мая","июня","июля","августа","сентября","октября","ноября","декабря"]
try:
    dt = datetime.strptime(date_str, "%Y-%m-%d")
    day_label = f"{dt.day} {months[dt.month]}"
except Exception:
    day_label = date_str

meetings = [e for e in events if e["type"] == "meeting"]
tasks = [e for e in events if e["type"] == "task"]

# ============ РЕЖИМ НЕДЕЛИ ============
if week_mode:
    n = len(events)
    count_label = f"{n} {'событие' if n==1 else 'события' if 2<=n<=4 else 'событий'}"
    print(f"📅 **Календарь недели ({day_label} — +6 дней):** ✅ {count_label}.")
    print()

    # Группировка по дням
    from collections import OrderedDict
    days = OrderedDict()
    for e in events:
        d = e["date"]
        if d not in days:
            days[d] = []
        days[d].append(e)

    for d, evs in days.items():
        date_obj = datetime.strptime(d, "%Y-%m-%d")
        wd = ["Пн","Вт","Ср","Чт","Пт","Сб","Вс"][date_obj.weekday()]
        label = f"{wd} {date_obj.day} {months[date_obj.month]}"
        m_count = sum(1 for e in evs if e["type"] == "meeting")
        t_count = sum(1 for e in evs if e["type"] == "task")
        tags = []
        if m_count: tags.append(f"{m_count} встреч")
        if t_count: tags.append(f"{t_count} задач")
        print(f"**{label}** ({', '.join(tags)})")
        print()
        print("| 🚦 | Время | Событие | Длит. | Тип |")
        print("|----|-------|---------|-------|-----|")
        for e in evs:
            s = e["summary"].replace("|", chr(92) + "|")
            t = "встреча" if e["type"] == "meeting" else "задача"
            print(f"| {e['status_emoji']} | {e['start_time']} | {s} | {e['duration']} | {t} |")
        print()

    if errors:
        print(f"> ⚠️ Пропущено календарей: {len(errors)} (нет доступа или ошибка)")
    sys.exit(0)

# ============ РЕЖИМ ДНЯ ============
n = len(events)
count_label = f"{n} {'событие' if n==1 else 'события' if 2<=n<=4 else 'событий'}"
print(f"📅 **Календарь ({day_label} {dt.year}):** ✅ {count_label}.")
print()

if meetings:
    print("**Встречи**")
    print("| 🚦 | Время | Событие | Длит. | Связь с РП |")
    print("|----|-------|---------|-------|------------|")
    for e in meetings:
        s = e["summary"].replace("|", chr(92) + "|")
        print(f"| {e['status_emoji']} | {e['start_time']} | {s} | {e['duration']} | — |")
    print()
else:
    print("**Встречи:** нет")
    print()

if tasks:
    print("**Напоминания / Тех-операции**")
    print("| 🚦 | Время | Что | Длит. | Результат |")
    print("|----|-------|-----|-------|-----------|")
    for e in tasks:
        s = e["summary"].replace("|", chr(92) + "|")
        print(f"| {e['status_emoji']} | {e['start_time']} | {s} | {e['duration']} | — |")
    print()
else:
    print("**Напоминания / Тех-операции:** нет")
    print()

# Свободные блоки (только дневной режим, только если есть временные события)
timed_events = [e for e in events if e["start_time"] != "весь день"]
if not timed_events:
    print("⏱ Свободных блоков ≥1h: **весь день** (09:00–22:00)")
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
        print("⏱ Свободных блоков ≥1h: **весь день** (09:00–22:00)")
    else:
        # Рабочий диапазон 09:00–22:00
        work_start = 9 * 60
        work_end = 22 * 60
        busy.sort()
        # Смержим пересекающиеся
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

        # Фильтруем ≥60 мин
        free_strs = []
        for s, e in free_blocks:
            if e - s >= 60:
                sh, sm = s // 60, s % 60
                eh, em = e // 60, e % 60
                free_strs.append(f"{sh:02d}:{sm:02d}–{eh:02d}:{em:02d}")

        if free_strs:
            print(f"⏱ Свободных блоков ≥1h: {', '.join(free_strs)}")
        else:
            print("⏱ Свободных блоков ≥1h: плотный день, свободных окон ≥1h нет")

if errors:
    print()
    print(f"> ⚠️ Пропущено календарей: {len(errors)} (нет доступа или ошибка)")
PYEOF
