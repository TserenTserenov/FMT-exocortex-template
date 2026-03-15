#!/bin/bash
# dt-collect.sh — сбор данных активности для ЦД
#
# Собирает: WakaTime + git stats + Claude Code sessions + WP stats
# Записывает в digital_twins.data JSONB (Neon) через dt-collect-neon.py
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="{{WORKSPACE_DIR}}"
LOG_DIR="{{HOME_DIR}}/logs/synchronizer"
DATE=$(date +%Y-%m-%d)
LOG_FILE="$LOG_DIR/dt-collect-$DATE.log"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

mkdir -p "$LOG_DIR"

# Load env
ENV_FILE="{{HOME_DIR}}/.config/aist/env"
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
    local D7=$(date -v-7d +%Y-%m-%d)
    local WEEK_RESP
    WEEK_RESP=$(curl -s -H "Authorization: Basic $ENCODED" "$API/summaries?start=$D7&end=$DATE" 2>/dev/null || echo "{}")

    # Last 30 days
    local D30=$(date -v-30d +%Y-%m-%d)
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
# 2. Git Stats (все репо в workspace)
# ============================================================

collect_git() {
    python3 -c "
import subprocess, json, os
from datetime import datetime, timedelta

workspace = '$WORKSPACE'
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

result = {
    'commits_today': commits_today,
    'commits_7d': commits_7d,
    'commits_30d': commits_30d,
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
workspace = '$WORKSPACE'
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
    local MEMORY_FILE="$HOME/.claude/projects/{{CLAUDE_PROJECT_SLUG}}/memory/MEMORY.md"

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
            if '| # | ' in line or '| --- |' in line:
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
    local STATE_DIR="{{HOME_DIR}}/.local/state/exocortex"
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

# Merge all into 2_6_coding + 2_7_iwe
MERGED=$(python3 -c "
import json, sys

waka = json.loads('''$WAKA_JSON''')
git = json.loads('''$GIT_JSON''')
sessions = json.loads('''$SESSIONS_JSON''')
wp = json.loads('''$WP_JSON''')
health = json.loads('''$HEALTH_JSON''')

result = {
    '2_6_coding': waka,
    '2_7_iwe': {**git, **sessions, **wp, **health},
}
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
