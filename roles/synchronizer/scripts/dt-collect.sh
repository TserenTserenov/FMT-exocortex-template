#!/bin/bash
# dt-collect.sh — сбор данных активности для ЦД (WP-106, WP-139)
#
# Архитектура: ядро (L3, шаблон) + плагины (L4, personal)
#   Ядро: WakaTime, git, sessions, WP, health, multiplier, registry, Pack, notes, scheduler reports
#   Плагины: collectors.d/*.sh — персональные коллекторы (Scout, QA бота, публикации и др.)
#
# Плагин = bash-файл с функцией collect_NAME() → stdout JSON + комментарий TARGET
#   # COLLECTOR: name
#   # TARGET: 2_7_iwe | 2_8_ecosystem | 2_9_knowledge
#   collect_name() { echo '{"key": "value"}' }
#
# Использование:
#   dt-collect.sh           # собрать и записать
#   dt-collect.sh --dry-run # показать JSON, не записывать
#
# Триггер: scheduler.sh dispatch dt-collect (ежедневно, после code-scan)
# Зависимости:
#   WAKATIME_API_KEY  — в ~/.config/aist/env
#   NEON_URL          — в ~/.config/aist/env (connection string)
#   DT_USER_ID        — в ~/.config/aist/env (Ory UUID)

set -euo pipefail

# Cross-platform date offset (macOS + Linux)
portable_date_offset() {
    local days="$1"
    local fmt="${2:-%Y-%m-%d}"
    date -v-${days}d +"$fmt" 2>/dev/null || date -d "$days days ago" +"$fmt" 2>/dev/null
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$HOME/IWE"
GOVERNANCE_DIR="${GOVERNANCE_DIR:-$WORKSPACE/DS-strategy}"
LOG_DIR="$HOME/logs/synchronizer"
DATE=$(date +%Y-%m-%d)
LOG_FILE="$LOG_DIR/dt-collect-$DATE.log"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

mkdir -p "$LOG_DIR"

# Load env
ENV_FILE="$HOME/.config/aist/env"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [dt-collect] $1" | tee -a "$LOG_FILE"
}

log "=== DT Collect Started ==="

# Проверка обязательных env vars (skip при --dry-run)
if [ "$DRY_RUN" = false ]; then
    if [ -z "${NEON_URL:-}" ]; then
        log "NEON_URL not set — skipping"
        exit 0
    fi
    if [ -z "${DT_USER_ID:-}" ]; then
        log "DT_USER_ID not set — skipping"
        exit 0
    fi
fi

# ============================================================
# 1. WakaTime
# ============================================================

collect_wakatime() {
    if [ -z "${WAKATIME_API_KEY:-}" ]; then
        log "WAKATIME_API_KEY not set — skipping WakaTime"
        echo "{}"
        return
    fi

    local ENCODED
    ENCODED=$(echo -n "$WAKATIME_API_KEY" | base64)
    local API="https://wakatime.com/api/v1/users/current"

    # Today
    local TODAY_RESP
    TODAY_RESP=$(curl -s -H "Authorization: Basic $ENCODED" "$API/summaries?start=$DATE&end=$DATE" 2>/dev/null || echo "{}")

    # Last 7 days
    local D7=$(portable_date_offset 7)
    local WEEK_RESP
    WEEK_RESP=$(curl -s -H "Authorization: Basic $ENCODED" "$API/summaries?start=$D7&end=$DATE" 2>/dev/null || echo "{}")

    # Last 30 days
    local D30=$(portable_date_offset 30)
    local MONTH_RESP
    MONTH_RESP=$(curl -s -H "Authorization: Basic $ENCODED" "$API/summaries?start=$D30&end=$DATE" 2>/dev/null || echo "{}")

    python3 -c "
import sys, json

def safe_load(s):
    try:
        return json.loads(s)
    except:
        return {}

today = safe_load('''$TODAY_RESP''')
week = safe_load('''$WEEK_RESP''')
month = safe_load('''$MONTH_RESP''')

def total_seconds(resp):
    try:
        return int(resp['cumulative_total']['seconds'])
    except:
        return 0

def active_days(resp):
    try:
        return sum(1 for d in resp.get('data', []) if d.get('grand_total', {}).get('total_seconds', 0) > 0)
    except:
        return 0

def top_items(resp, key, limit=10):
    agg = {}
    for day in resp.get('data', []):
        for item in day.get(key, []):
            name = item.get('name', '?')
            agg[name] = agg.get(name, 0) + item.get('total_seconds', 0)
    return sorted([{'name': k, 'seconds': int(v)} for k, v in agg.items()],
                  key=lambda x: x['seconds'], reverse=True)[:limit]

result = {
    'coding_seconds_today': total_seconds(today),
    'coding_seconds_7d': total_seconds(week),
    'coding_seconds_30d': total_seconds(month),
    'coding_active_days_30d': active_days(month),
    'top_projects': top_items(month, 'projects', 10),
    'top_languages': top_items(month, 'languages', 5),
    'top_editors': top_items(month, 'editors', 5),
}
print(json.dumps(result))
" 2>/dev/null || echo "{}"
}

# ============================================================
# 2. Git Stats (все репо в {{WORKSPACE_DIR}}/)
# ============================================================

collect_git() {
    python3 -c "
import subprocess, json, os
from datetime import datetime, timedelta

workspace = os.path.expanduser('{{WORKSPACE_DIR}}')
repos = []
for name in sorted(os.listdir(workspace)):
    path = os.path.join(workspace, name)
    if os.path.isdir(os.path.join(path, '.git')):
        repos.append((name, path))

def git_count(path, since):
    try:
        out = subprocess.check_output(
            ['git', '-C', path, 'log', f'--since={since}', '--oneline', '--no-merges'],
            stderr=subprocess.DEVNULL, text=True
        ).strip()
        return len(out.split('\n')) if out else 0
    except:
        return 0

def git_shortstat(path, since):
    try:
        out = subprocess.check_output(
            ['git', '-C', path, 'log', f'--since={since}', '--shortstat', '--no-merges', '--format='],
            stderr=subprocess.DEVNULL, text=True
        ).strip()
        files, ins, dels = 0, 0, 0
        for line in out.split('\n'):
            line = line.strip()
            if not line:
                continue
            import re
            m_f = re.search(r'(\d+) files? changed', line)
            m_i = re.search(r'(\d+) insertions?\(\+\)', line)
            m_d = re.search(r'(\d+) deletions?\(-\)', line)
            if m_f: files += int(m_f.group(1))
            if m_i: ins += int(m_i.group(1))
            if m_d: dels += int(m_d.group(1))
        return files, ins, dels
    except:
        return 0, 0, 0

now = datetime.now()
today = now.strftime('%Y-%m-%d')
d7 = (now - timedelta(days=7)).strftime('%Y-%m-%d')
d30 = (now - timedelta(days=30)).strftime('%Y-%m-%d')

commits_today = sum(git_count(p, '24 hours ago') for _, p in repos)
commits_7d = sum(git_count(p, d7) for _, p in repos)
commits_30d = sum(git_count(p, d30) for _, p in repos)

repos_7d = []
for name, path in repos:
    c = git_count(path, d7)
    if c > 0:
        repos_7d.append({'name': name, 'commits': c})
repos_7d.sort(key=lambda x: x['commits'], reverse=True)

files_7d, ins_7d, dels_7d = 0, 0, 0
for _, path in repos:
    f, i, d = git_shortstat(path, d7)
    files_7d += f
    ins_7d += i
    dels_7d += d

# ADR-009 (WP-109 Ф3): commits_today/7d/30d теперь агрегируются
# из user_events через dt_sync. Здесь -- только уникальные поля
# (repos_active, files_changed, lines), которых нет в sync-iwe.
result = {
    'repos_active_7d': repos_7d[:15],
    'files_changed_7d': files_7d,
    'lines_added_7d': ins_7d,
    'lines_removed_7d': dels_7d,
}
print(json.dumps(result))
" 2>/dev/null || echo "{}"
}

# ============================================================
# 3. Claude Code Sessions
# ============================================================

collect_sessions() {
    local SESSION_LOG="$WORKSPACE/DS-strategy/inbox/open-sessions.log"

    python3 -c "
import json, os, re
from datetime import datetime, timedelta

log_path = '$SESSION_LOG'
now = datetime.now()
d7 = now - timedelta(days=7)
total = 0
recent = 0

if os.path.exists(log_path):
    with open(log_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            total += 1
            # Format: YYYY-MM-DD HH:MM | WP-N | model | description
            m = re.match(r'(\d{4}-\d{2}-\d{2})', line)
            if m:
                try:
                    dt = datetime.strptime(m.group(1), '%Y-%m-%d')
                    if dt >= d7:
                        recent += 1
                except:
                    pass

# Also count from git log (more reliable — sessions leave commits)
import subprocess
workspace = os.path.expanduser('{{WORKSPACE_DIR}}')
git_sessions_7d = 0
for name in os.listdir(workspace):
    path = os.path.join(workspace, name)
    if os.path.isdir(os.path.join(path, '.git')):
        try:
            out = subprocess.check_output(
                ['git', '-C', path, 'log', '--since=7 days ago', '--format=%aI', '--no-merges'],
                stderr=subprocess.DEVNULL, text=True
            ).strip()
            if out:
                dates = set(line[:10] for line in out.split('\n') if line)
                git_sessions_7d += len(dates)
        except:
            pass

result = {
    'claude_sessions_total': max(total, git_sessions_7d),
    'claude_sessions_7d': max(recent, git_sessions_7d),
}
print(json.dumps(result))
" 2>/dev/null || echo "{}"
}

# ============================================================
# 4. WP Stats (from MEMORY.md)
# ============================================================

collect_wp() {
    local MEMORY_FILE="$HOME/.claude/projects/-Users-$(whoami)-IWE/memory/MEMORY.md"

    python3 -c "
import json, os, re

memory_path = '$MEMORY_FILE'
done = 0
in_progress = 0

if os.path.exists(memory_path):
    with open(memory_path) as f:
        in_table = False
        for line in f:
            # Look for the WP table
            if '| # | РП' in line or '| --- |' in line:
                in_table = True
                continue
            if in_table:
                if line.strip() == '' or line.startswith('---'):
                    in_table = False
                    continue
                if '| done' in line.lower() or '~~done~~' in line.lower():
                    done += 1
                elif 'in_progress' in line.lower():
                    in_progress += 1
                elif '| done |' in line:
                    done += 1

result = {
    'wp_completed_total': done,
    'wp_in_progress_count': in_progress,
}
print(json.dumps(result))
" 2>/dev/null || echo "{}"
}

# ============================================================
# 5. Scheduler Health
# ============================================================

collect_health() {
    local STATE_DIR="$HOME/.local/state/exocortex"
    python3 -c "
import json, os
from datetime import datetime

state_dir = '$STATE_DIR'
today = datetime.now().strftime('%Y-%m-%d')
health = 'green'
uptime = 0

if os.path.isdir(state_dir):
    markers = [f for f in os.listdir(state_dir) if not f.startswith('.')]
    dates = set()
    for m in markers:
        parts = m.rsplit('-', 3)
        if len(parts) >= 3:
            date_part = '-'.join(parts[-3:])
            if len(date_part) == 10:
                dates.add(date_part)
    uptime = len(dates)

    # Check if key tasks ran today
    expected = ['code-scan', 'strategist-morning']
    missing = []
    for task in expected:
        found = any(task in m and today in m for m in markers)
        if not found:
            missing.append(task)
    if len(missing) > 0:
        health = 'yellow'
    if len(missing) > 1:
        health = 'red'

result = {
    'scheduler_health': health,
    'exocortex_uptime_days': uptime,
}
print(json.dumps(result))
" 2>/dev/null || echo "{}"
}

# ============================================================
# 6. Multiplier & Budgets (from DayPlan)
# ============================================================

collect_multiplier() {
    local DAYPLAN_DIR="$GOVERNANCE_DIR/current"
    local ARCHIVE_DIR="$GOVERNANCE_DIR/archive/day-plans"

    python3 -c "
import json, os, re, glob
from datetime import datetime, timedelta

today = datetime.now().strftime('%Y-%m-%d')
dayplan_dir = '$DAYPLAN_DIR'
archive_dir = '$ARCHIVE_DIR'
gov_dir = '$GOVERNANCE_DIR'

def parse_hours(s):
    \"\"\"Parse budget string to hours: '2-3h'->2.5, '30 мин'->0.5, '1h'->1.0, '2'->2.0 (bare number = hours)\"\"\"
    s = s.replace('~~', '').strip()
    if not s or s in ('—', '-', 'незаплан.', 'незапл.'):
        return 0.0
    m = re.match(r'(\d+(?:\.\d+)?)\s*-\s*(\d+(?:\.\d+)?)\s*h?\$', s, re.I)
    if m:
        return (float(m.group(1)) + float(m.group(2))) / 2
    m = re.match(r'^(\d+(?:\.\d+)?)\s*h?\$', s, re.I)
    if m:
        return float(m.group(1))
    m = re.match(r'(\d+)\s*мин', s, re.I)
    if m:
        return float(m.group(1)) / 60
    return 0.0

def parse_mult_section_budget(filepath):
    \"\"\"Primary parser: extract 'Бюджет закрыт' from Мультипликатор IWE section.
    Supports two formats:
      - Table cell:  | Бюджет закрыт | ~16.5h (WP-... 10h + ...) |
      - Bullet list: - **Бюджет закрыт:** ~20.05h
    Skips header row '| День | ... | Бюджет закрыт | Мультипликатор |'.\"\"\"
    if not filepath or not os.path.exists(filepath):
        return None
    with open(filepath) as f:
        content = f.read()
    patterns = [
        r'закрыт[^|]*?\|\s*~?\s*(\d+(?:\.\d+)?)\s*h',              # table-cell format
        r'Бюджет\s+закрыт[:\*\s]+~?\s*(\d+(?:\.\d+)?)\s*h',        # bullet/bold format
    ]
    for line in content.split('\\n'):
        if 'Бюджет закрыт' not in line:
            continue
        # Skip header row with 'День | WakaTime | Бюджет закрыт | Мультипликатор'
        if 'WakaTime' in line and 'Мультипликатор' in line:
            continue
        for pat in patterns:
            m = re.search(pat, line)
            if m:
                return float(m.group(1))
    return None

def parse_dayplan_budget_from_table(filepath):
    \"\"\"Fallback parser: sum done-row budgets from WP tables.\"\"\"
    if not filepath or not os.path.exists(filepath):
        return 0.0
    with open(filepath) as f:
        lines = f.readlines()

    total = 0.0
    in_table = False
    header_cols = []

    for line in lines:
        stripped = line.strip()
        if not stripped.startswith('|'):
            if in_table and stripped == '':
                in_table = False
            continue

        cells = [c.strip() for c in stripped.split('|')]
        if cells and cells[0] == '':
            cells = cells[1:]
        if cells and cells[-1] == '':
            cells = cells[:-1]
        if not cells:
            continue

        if 'РП' in stripped and 'Статус' in stripped:
            has_budget_col = any(c in ('h', 'Бюджет') for c in cells)
            in_table = has_budget_col
            header_cols = cells if has_budget_col else []
            continue

        if all(c.replace('-', '').replace(':', '').strip() == '' for c in cells):
            continue
        if not in_table:
            continue

        status_idx = next((i for i, h in enumerate(header_cols) if 'Статус' in h), None)
        budget_idx = next((i for i, h in enumerate(header_cols) if h in ('h', 'Бюджет')), None)
        if status_idx is None or budget_idx is None:
            continue

        status_cell = cells[status_idx].replace('~~', '').strip().lower() if len(cells) > status_idx else ''
        if 'done' not in status_cell:
            continue

        budget_str = cells[budget_idx] if len(cells) > budget_idx else ''
        total += parse_hours(budget_str)
    return total

MONTH_RU = {1:'янв',2:'фев',3:'мар',4:'апр',5:'май',6:'июн',7:'июл',8:'авг',9:'сен',10:'окт',11:'ноя',12:'дек'}

def parse_weekplan_budget_for_date(date_str, gov_dir):
    \"\"\"Secondary fallback: ищет 'Итоги <день> <N> <мес>' в WeekPlan-ах, возвращает 'Бюджет закрыт' из секции.\"\"\"
    from datetime import datetime as _dt
    dt = _dt.strptime(date_str, '%Y-%m-%d')
    day_num = dt.day
    month_ru = MONTH_RU[dt.month]
    wp_patterns = [
        os.path.join(gov_dir, 'archive', 'week-plans', 'WeekPlan W*.md'),
        os.path.join(gov_dir, 'current', 'WeekPlan W*.md'),
    ]
    section_re = re.compile(rf'Итоги\s+\S+\s+{day_num}\s+{month_ru}')
    for pat in wp_patterns:
        for wp in glob.glob(pat):
            with open(wp) as f:
                content = f.read()
            if not section_re.search(content):
                continue
            # Разбить по <details> и найти блок с нужным «Итоги»
            blocks = content.split('<details')
            section = None
            for blk in blocks:
                if section_re.search(blk):
                    end = blk.find('</details>')
                    section = blk[:end] if end >= 0 else blk
                    break
            if section is None:
                continue
            for line in section.split('\\n'):
                if 'Бюджет закрыт' not in line:
                    continue
                if 'WakaTime' in line and 'Мультипликатор' in line:
                    continue
                for pp in (r'закрыт[^|]*?\|\s*~?\s*(\d+(?:\.\d+)?)\s*h',
                           r'Бюджет\s+закрыт[:\*\s]+~?\s*(\d+(?:\.\d+)?)\s*h'):
                    mm = re.search(pp, line)
                    if mm:
                        return float(mm.group(1))
    return None

def parse_dayplan_budget(filepath, date_str=None, gov_dir=None):
    \"\"\"Primary: Мультипликатор-секция DayPlan. Fallback 1: WeekPlan 'Итоги <date>'. Fallback 2: done-строки WP-таблицы.\"\"\"
    primary = parse_mult_section_budget(filepath)
    if primary is not None:
        return primary
    if date_str and gov_dir:
        secondary = parse_weekplan_budget_for_date(date_str, gov_dir)
        if secondary is not None:
            return secondary
    return parse_dayplan_budget_from_table(filepath)

def find_dayplan(date_str):
    \"\"\"Find DayPlan file for a given date in current/ or archive/.\"\"\"
    for d in [dayplan_dir, archive_dir]:
        pattern = os.path.join(d, f'DayPlan {date_str}*')
        matches = glob.glob(pattern)
        if matches:
            return matches[0]
    return None

# Daily budget
daily_budget = parse_dayplan_budget(find_dayplan(today), today, gov_dir)

# Weekly budget: sum all DayPlans from Monday to today
now = datetime.now()
monday = now - timedelta(days=now.weekday())  # Monday of current week
weekly_budget = 0.0
dayplans_found = 0
d = monday
while d <= now:
    ds = d.strftime('%Y-%m-%d')
    dp = find_dayplan(ds)
    if dp:
        dayplans_found += 1
        weekly_budget += parse_dayplan_budget(dp, ds, gov_dir)
    d += timedelta(days=1)

# Loud fail: если DayPlan-ы найдены, а бюджет = 0 → парсер не матчит формат
import sys
if dayplans_found > 0 and weekly_budget == 0:
    print(f'WARNING: parser matched {dayplans_found} DayPlans but returned 0h budget — status/budget regex may be out of date vs current DayPlan format', file=sys.stderr)

result = {
    'daily_budget_closed': round(daily_budget, 1),
    'weekly_budget_closed': round(weekly_budget, 1),
    'dayplans_found_this_week': dayplans_found,
}
print(json.dumps(result))
" 2>/dev/null || echo "{}"
}

# ============================================================
# 7. WP-REGISTRY (full stats from source-of-truth)
# ============================================================

collect_registry() {
    local REGISTRY="$GOVERNANCE_DIR/docs/WP-REGISTRY.md"

    python3 -c "
import json, os, re
from datetime import datetime

registry = '$REGISTRY'
if not os.path.exists(registry):
    print(json.dumps({}))
    exit(0)

with open(registry) as f:
    content = f.read()

done = len(re.findall(r'\| ✅', content))
in_progress = len(re.findall(r'\| 🔄', content))
pending = len(re.findall(r'\| ⏳', content))
archived = len(re.findall(r'\| 📦', content))
merged = len(re.findall(r'\| ↗️', content))

result = {
    'registry_total': done + in_progress + pending + archived + merged,
    'registry_done': done,
    'registry_in_progress': in_progress,
    'registry_pending': pending,
    'registry_archived': archived,
    'registry_merged': merged,
}
print(json.dumps(result))
" 2>/dev/null || echo "{}"
}

# ============================================================
# 8. Pack Entities (knowledge corpus size)
# ============================================================

collect_pack() {
    python3 -c "
import json, os, re

workspace = os.path.expanduser('{{WORKSPACE_DIR}}')
pack_stats = {}
total_md = 0
total_entities = 0

for name in sorted(os.listdir(workspace)):
    if not name.startswith('PACK-'):
        continue
    path = os.path.join(workspace, name)
    if not os.path.isdir(path):
        continue
    md_count = 0
    entity_ids = set()
    for root, dirs, files in os.walk(path):
        dirs[:] = [d for d in dirs if not d.startswith('.')]
        for f in files:
            if f.endswith('.md'):
                md_count += 1
                # Extract entity IDs like DP.ARCH.001, AS.D.007, PD.FORM.004
                m = re.match(r'^([A-Z]{2,4}\.[A-Z]+\.\d{3})', f)
                if m:
                    entity_ids.add(m.group(1))
    pack_stats[name] = {'md_files': md_count, 'entities': len(entity_ids)}
    total_md += md_count
    total_entities += len(entity_ids)

result = {
    'pack_total_md': total_md,
    'pack_total_entities': total_entities,
    'pack_repos': pack_stats,
}
print(json.dumps(result))
" 2>/dev/null || echo "{}"
}

# ============================================================
# 9. Fleeting Notes (inbox velocity)
# ============================================================

collect_notes() {
    local NOTES="$GOVERNANCE_DIR/inbox/fleeting-notes.md"

    python3 -c "
import json, os, re

notes_path = '$NOTES'
if not os.path.exists(notes_path):
    print(json.dumps({}))
    exit(0)

with open(notes_path) as f:
    lines = f.readlines()

new = 0      # **bold** without 🔄
review = 0   # **bold** with 🔄
processed = 0
noise = 0
total = 0

in_content = False
for line in lines:
    s = line.strip()
    if s == '---':
        in_content = not in_content
        continue
    if not in_content:
        continue
    if not s or s.startswith('>') or s.startswith('#'):
        continue
    # Count substantive lines (notes start with - or are list items)
    if s.startswith('- ') or s.startswith('* '):
        total += 1
        if '~~' in s:
            noise += 1
        elif s.startswith('- **') or s.startswith('* **'):
            if '🔄' in s:
                review += 1
            else:
                new += 1
        else:
            processed += 1

result = {
    'notes_total': total,
    'notes_new': new,
    'notes_review': review,
    'notes_processed': processed,
    'notes_noise': noise,
}
print(json.dumps(result))
" 2>/dev/null || echo "{}"
}

# ============================================================
# 11. Scheduler Reports (task success rate)
# ============================================================

collect_scheduler_reports() {
    local REPORTS_DIR="$WORKSPACE/DS-agent-workspace/scheduler/scheduler-reports"

    python3 -c "
import json, os, re, glob
from datetime import datetime, timedelta

reports_dir = '$REPORTS_DIR'
now = datetime.now()

if not os.path.isdir(reports_dir):
    print(json.dumps({}))
    exit(0)

# Count reports and parse latest
reports = sorted(glob.glob(os.path.join(reports_dir, 'SchedulerReport *.md')))
total_reports = len(reports)

# Parse last 7 days
green_days = 0
yellow_days = 0
red_days = 0
streak = 0  # consecutive green days from today backwards

streak_broken = False
for days_back in range(7):
    d = now - timedelta(days=days_back)
    ds = d.strftime('%Y-%m-%d')
    pattern = os.path.join(reports_dir, f'SchedulerReport {ds}*')
    matches = glob.glob(pattern)
    if not matches:
        if not streak_broken:
            streak_broken = True  # gap breaks streak
        continue  # skip missing days, keep counting 7d stats
    with open(matches[0], errors='replace') as f:
        content = f.read(500)
    if '🟢' in content and '🔴' not in content:
        green_days += 1
        if not streak_broken:
            streak += 1
    elif '🔴' in content:
        red_days += 1
        streak_broken = True
    else:
        yellow_days += 1
        streak_broken = True

result = {
    'scheduler_reports_total': total_reports,
    'scheduler_green_7d': green_days,
    'scheduler_yellow_7d': yellow_days,
    'scheduler_red_7d': red_days,
    'scheduler_green_streak': streak,
}
print(json.dumps(result))
" 2>/dev/null || echo "{}"
}

# ============================================================
# Plugin Loader: collectors.d/*.sh (L4 Personal)
# ============================================================
# Each plugin defines a collect_NAME() function and has metadata:
#   # COLLECTOR: name
#   # TARGET: 2_7_iwe | 2_8_ecosystem | 2_9_knowledge
#
# Plugins are sourced (not executed) — they share WORKSPACE, log(), etc.
# Plugin functions must output valid JSON to stdout.
# Missing/broken plugins are skipped gracefully.

COLLECTORS_DIR="$SCRIPT_DIR/collectors.d"
PLUGIN_IWE_JSONS=()
PLUGIN_ECO_JSONS=()
PLUGIN_KNOW_JSONS=()

if [ -d "$COLLECTORS_DIR" ]; then
    for plugin in "$COLLECTORS_DIR"/*.sh; do
        [ -f "$plugin" ] || continue
        plugin_name=$(basename "$plugin" .sh)

        # Read target from comment header
        target=$(grep -m1 '^# TARGET:' "$plugin" | sed 's/^# TARGET:\s*//' | tr -d '[:space:]')
        collector_func=$(grep -m1 '^# COLLECTOR:' "$plugin" | sed 's/^# COLLECTOR:\s*//' | tr -d '[:space:]')

        if [ -z "$collector_func" ] || [ -z "$target" ]; then
            log "SKIP plugin $plugin_name — missing COLLECTOR/TARGET header"
            continue
        fi

        # Source the plugin (defines collect_NAME function)
        source "$plugin"

        # Call the collector function
        log "Collecting plugin: $collector_func..."
        plugin_json=$(collect_"$collector_func" 2>/dev/null || echo "{}")

        # Route JSON to the right target array
        case "$target" in
            2_7_iwe)        PLUGIN_IWE_JSONS+=("$plugin_json") ;;
            2_8_ecosystem)  PLUGIN_ECO_JSONS+=("$plugin_json") ;;
            2_9_knowledge)  PLUGIN_KNOW_JSONS+=("$plugin_json") ;;
            *)              log "WARN plugin $plugin_name — unknown target: $target" ;;
        esac
    done
fi

# Convert arrays to JSON arrays for Python merge
plugin_iwe_arr=$(printf '%s\n' "${PLUGIN_IWE_JSONS[@]:-}" | python3 -c "import sys,json; parts=[json.loads(l) for l in sys.stdin if l.strip()]; print(json.dumps(parts))" 2>/dev/null || echo "[]")
plugin_eco_arr=$(printf '%s\n' "${PLUGIN_ECO_JSONS[@]:-}" | python3 -c "import sys,json; parts=[json.loads(l) for l in sys.stdin if l.strip()]; print(json.dumps(parts))" 2>/dev/null || echo "[]")
plugin_know_arr=$(printf '%s\n' "${PLUGIN_KNOW_JSONS[@]:-}" | python3 -c "import sys,json; parts=[json.loads(l) for l in sys.stdin if l.strip()]; print(json.dumps(parts))" 2>/dev/null || echo "[]")

# ============================================================
# Merge & Write
# ============================================================

log "Collecting WakaTime..."
WAKA_JSON=$(collect_wakatime)
log "Collecting git stats..."
GIT_JSON=$(collect_git)
log "Collecting Claude sessions..."
SESSIONS_JSON=$(collect_sessions)
log "Collecting WP stats..."
WP_JSON=$(collect_wp)
log "Collecting scheduler health..."
HEALTH_JSON=$(collect_health)
log "Collecting multiplier data..."
MULT_JSON=$(collect_multiplier)
log "Collecting registry stats..."
REGISTRY_JSON=$(collect_registry)
log "Collecting Pack metrics..."
PACK_JSON=$(collect_pack)
log "Collecting fleeting notes..."
NOTES_JSON=$(collect_notes)
log "Collecting scheduler reports..."
SCHED_JSON=$(collect_scheduler_reports)

# Merge all: core (L3) + plugins (L4)
MERGED=$(python3 -c "
import json, sys

waka = json.loads('''$WAKA_JSON''')
git = json.loads('''$GIT_JSON''')
sessions = json.loads('''$SESSIONS_JSON''')
wp = json.loads('''$WP_JSON''')
health = json.loads('''$HEALTH_JSON''')
mult = json.loads('''$MULT_JSON''')
registry = json.loads('''$REGISTRY_JSON''')
pack = json.loads('''$PACK_JSON''')
notes = json.loads('''$NOTES_JSON''')
sched = json.loads('''$SCHED_JSON''')

# Plugin data (arrays of dicts)
p_iwe = json.loads('''$plugin_iwe_arr''')
p_eco = json.loads('''$plugin_eco_arr''')
p_know = json.loads('''$plugin_know_arr''')

# 2_7_iwe: core + plugins
iwe = {**git, **sessions, **wp, **health, **mult, **registry, **sched}
for p in p_iwe:
    iwe.update(p)

# Daily multiplier
waka_today = waka.get('coding_seconds_today', 0)
budget_today = mult.get('daily_budget_closed', 0)
if waka_today > 0 and budget_today > 0:
    iwe['daily_multiplier'] = round(budget_today / (waka_today / 3600), 2)

# Weekly multiplier
waka_7d = waka.get('coding_seconds_7d', 0)
budget_week = mult.get('weekly_budget_closed', 0)
if waka_7d > 0 and budget_week > 0:
    iwe['weekly_multiplier'] = round(budget_week / (waka_7d / 3600), 2)

# 2_8_ecosystem: plugins only (QA, publications, etc.)
ecosystem = {}
for p in p_eco:
    ecosystem.update(p)

# 2_9_knowledge: core (Pack, notes) + plugins (Scout, etc.)
knowledge = {**pack, **notes}
for p in p_know:
    knowledge.update(p)

# ADR-009 (WP-109 Ф3): 2_6_coding теперь агрегируется из user_events
# через dt_sync (бот). dt-collect больше не пишет 2_6_coding в digital_twins.
# WakaTime данные остаются в iwe для расчёта multiplier.
result = {
    '2_7_iwe': iwe,
}
# Only include sections with data
if ecosystem:
    result['2_8_ecosystem'] = ecosystem
if knowledge:
    result['2_9_knowledge'] = knowledge

print(json.dumps(result, indent=2, ensure_ascii=False))
" 2>/dev/null)

if [ -z "$MERGED" ] || [ "$MERGED" = "{}" ]; then
    log "ERROR: empty merge result"
    exit 1
fi

log "Merged JSON:"
echo "$MERGED" >> "$LOG_FILE"

if [ "$DRY_RUN" = true ]; then
    echo "$MERGED"
    log "DRY RUN — not writing to Neon"
    exit 0
fi

# Write to Neon
log "Writing to Neon (user_id=$DT_USER_ID)..."
python3 "$SCRIPT_DIR/dt-collect-neon.py" "$DT_USER_ID" "$MERGED" 2>>"$LOG_FILE"
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    log "=== DT Collect Completed Successfully ==="
    "$SCRIPT_DIR/notify.sh" synchronizer dt-collect 2>/dev/null || true
else
    log "ERROR: dt-collect-neon.py exited with $EXIT_CODE"
fi
