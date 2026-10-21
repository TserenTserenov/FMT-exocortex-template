#!/usr/bin/env bash
# routing: helper  skill=day-open  called-by=haiku  deterministic=true
# see DP.SC.159, DP.ROLE.059
# day-open-scaffold.sh — deterministic skeleton generation DayPlan
# see WP-264 (~/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/WP-264-day-open-enforcement.md), Phase2
#
# Principle «Enforcement requires an observer outside the subject» (DP.ARCH.NNN, Phase5):
# sections, extracted from config/files/git/scheduler reports — are generated
# bash'by bash without LLM. Sections, requiring synthesis or MCP, are marked <!-- PENDING: X -->.
# Hook protocol-artifact-validate.sh already validates 11 mandatory sections;
# Phase3 will add a check for the absence of PENDING before PENDING before commit.
#
# INVARIANT: no single render_*() function does a silent skip silent skip.
# When a section is disabled — always output an explicit status in the format:
#   > `flag: false` in `config-file` — section is disabled. No data.
# Violation = skipping a section in DayPlan without DayPlan without explaining the reason.
#
# Usage:
#   bash day-open-scaffold.sh [YYYY-MM-DD] > "${IWE_GOVERNANCE_REPO:-DS-strategy}/current/DayPlan YYYY-MM-DD.md"
#   bash day-open-scaffold.sh                    # date = today
#   bash day-open-scaffold.sh 2026-04-26         # explicit date
#
# All 10 mandatory sections (per hook protocol-artifact-validate.sh) are present.

set -uo pipefail

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_SCRIPTS_DIR="$SCRIPT_DIR"
# issue #455: a stale promoted copy without lib/ next to it used to degrade
# silently (set -uo pipefail, no -e) — every path resolved to root, and the
# scheduler-state check quietly took the wrong branch for three weeks before
# anyone noticed. Missing the library is fatal now, not a silent no-op.
source "$TEMPLATE_SCRIPTS_DIR/lib/common.sh" || {
    echo "FATAL: lib/common.sh not found next to $0 — the promoted copy is outdated, update it together with the template" >&2
    exit 1
}
# issue #329: old fallback assumed $SCRIPT_DIR/.. is always the workspace root —
# false for a promoted copy at <governance-repo>/scripts/, which doubled the repo
# name into every path. iwe_resolve_root() uses env-var precedence instead of
# script-location guessing.
IWE="$(iwe_resolve_root)"
IWE_ROOT="$IWE"
export IWE_ROOT IWE
DATE="${1:-$(date +%Y-%m-%d)}"
CONFIG="$IWE/memory/day-rhythm-config.yaml"
# issue #1149: the path is pasted into Python source text, and Git Bash converts
# `/c/Users/...` only in command-line ARGUMENTS, not inside `-c "..."` code. Windows
# Python then cannot open it and every config-driven section falls back to defaults.
CONFIG_PY="$CONFIG"
if command -v cygpath >/dev/null 2>&1; then
  CONFIG_PY=$(cygpath -m "$CONFIG" 2>/dev/null || printf '%s' "$CONFIG")
fi

# issue #924: day_boundary ("HH:MM", default none = no shift) lets the pilot say
# that work done after midnight but before this hour still belongs to the day
# that's ending, not a new one. Only the auto "today" default is a candidate —
# an explicit date argument is the caller's exact choice and is never
# second-guessed (mirrors the same check in day-open-pipeline.sh, issue #924).
# Scoped to the day_open: block (same precaution as STRATEGY_DAY_NAME in
# day-open-pipeline.sh — a same-named key elsewhere can't hijack this lookup;
# resets on the next top-level key so a later block's own day_boundary can't
# be picked up either) and skips commented-out lines: a bare top-level grep
# would also match the shipped default's commented-out example line,
# silently turning the shift on. Read for any date: the commit window of
# "yesterday" follows the boundary even when the date is given explicitly.
DAY_BOUNDARY=$(awk '
  /^[^[:space:]]/ && !/^day_open:/ { f=0 }
  /^day_open:/ { f=1 }
  f && /day_boundary:/ && !/^[[:space:]]*#/ { print; exit }
' "$CONFIG" 2>/dev/null \
  | sed -E 's/.*day_boundary:[[:space:]]*"?([0-9]{1,2}:[0-9]{2})"?.*/\1/')
if [ -z "${1:-}" ] && [[ "$DAY_BOUNDARY" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
  boundary_min=$(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]} ))
  now_min=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
  if [ "$now_min" -lt "$boundary_min" ]; then
    DATE=$(date -j -v-1d -f "%Y-%m-%d" "$DATE" "+%Y-%m-%d" 2>/dev/null \
      || date -d "$DATE - 1 day" "+%Y-%m-%d" 2>/dev/null)
  fi
fi

# issue #924: the day boundary also decides which commits belong to "yesterday".
# Half-open window [YDAY <boundary>, DATE <boundary>) as "SINCE|UNTIL" for
# `git log`: a commit exactly at the boundary opens the new day, none is counted
# twice. No boundary (or 00:00) keeps the calendar day. KEEP IN SYNC with the
# copy in day-open-pipeline.sh / day-open-scaffold.sh (test_issue_924 compares them).
iwe_day_window() {
  local yday="$1" today="$2" b="${3:-}" bm=0 em
  if [[ "$b" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
    bm=$(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]} ))
  fi
  if [ "$bm" -eq 0 ]; then
    printf '%s 00:00:00|%s 23:59:59' "$yday" "$yday"
    return 0
  fi
  em=$(( bm - 1 ))
  printf '%s %02d:%02d:00|%s %02d:%02d:59' \
    "$yday" $(( bm / 60 )) $(( bm % 60 )) "$today" $(( em / 60 )) $(( em % 60 ))
}

PARAMS_FILE="$IWE/params.yaml"
MULTIPLIER_ENABLED="true"
if [ -f "$PARAMS_FILE" ] && grep -qE '^multiplier_enabled:[[:space:]]*false([[:space:]]*(#.*)?)?$' "$PARAMS_FILE"; then
  MULTIPLIER_ENABLED="false"
fi
if [ "$MULTIPLIER_ENABLED" = "false" ]; then
  BUDGET_FORMAT_HINT='<!-- PENDING: budget — calculate after the plan; multiplier_enabled: false → only «~Yh WP total», without physical time/WakaTime/multiplier. -->'
else
  BUDGET_FORMAT_HINT='<!-- PENDING: budget — calculate after planning, format see. templates-dayplan.md (budget WP total / phys / multiplier). -->'
fi
SERVER_MODE="${IWE_SERVER_MODE:-0}"  # WP-283: 1 = Linux server, Mac-only MCP unavailable

# --- Pre-flight healthcheck (WP-7 PhaseDay-Open-Hardening) ---
PREFLIGHT_JSON=$(bash "$IWE/scripts/day-open-preflight.sh" "$DATE" "$CONFIG" 2>/dev/null || echo '{"calendar":"unknown","scout":"unknown","triage":"unknown"}')
CALENDAR_PF=$(echo "$PREFLIGHT_JSON" | jq -r '.calendar // "unknown"')
CALENDAR_SOURCE=$(iwe_calendar_source "$PARAMS_FILE")  # issue #942: connector | script | none
SCOUT_PF=$(echo "$PREFLIGHT_JSON" | jq -r '.scout // "unknown"')
TRIAGE_PF=$(echo "$PREFLIGHT_JSON" | jq -r '.triage // "unknown"')
MEMORY_PF=$(echo "$PREFLIGHT_JSON" | jq -r '.memory // "unknown"')

# --- Date helpers (cross-platform: macOS BSD date / Linux GNU date) ---
if [[ "$(uname -s)" == "Darwin" ]]; then
  WEEK_NUM=$(date -j -f "%Y-%m-%d" "$DATE" "+%V" 2>/dev/null)
  DOW_NUM=$(date -j -f "%Y-%m-%d" "$DATE" "+%u" 2>/dev/null)
  DAY_NUM=$(date -j -f "%Y-%m-%d" "$DATE" "+%-d" 2>/dev/null)
  MONTH_NUM=$(date -j -f "%Y-%m-%d" "$DATE" "+%-m" 2>/dev/null)
  YEAR=$(date -j -f "%Y-%m-%d" "$DATE" "+%Y" 2>/dev/null)
  MM=$(date -j -f "%Y-%m-%d" "$DATE" "+%m" 2>/dev/null)
  DD=$(date -j -f "%Y-%m-%d" "$DATE" "+%d" 2>/dev/null)
  YDAY=$(date -j -v-1d -f "%Y-%m-%d" "$DATE" "+%Y-%m-%d" 2>/dev/null)
  YDAY_NUM=$(date -j -v-1d -f "%Y-%m-%d" "$DATE" "+%-d" 2>/dev/null)
  YDAY_MNUM=$(date -j -v-1d -f "%Y-%m-%d" "$DATE" "+%-m" 2>/dev/null)
else
  # GNU date (Linux / NixOS)
  WEEK_NUM=$(date -d "$DATE" "+%V" 2>/dev/null)
  DOW_NUM=$(date -d "$DATE" "+%u" 2>/dev/null)
  DAY_NUM=$(date -d "$DATE" "+%-d" 2>/dev/null)
  MONTH_NUM=$(date -d "$DATE" "+%-m" 2>/dev/null)
  YEAR=$(date -d "$DATE" "+%Y" 2>/dev/null)
  MM=$(date -d "$DATE" "+%m" 2>/dev/null)
  DD=$(date -d "$DATE" "+%d" 2>/dev/null)
  YDAY=$(date -d "$DATE - 1 day" "+%Y-%m-%d" 2>/dev/null)
  YDAY_NUM=$(date -d "$DATE - 1 day" "+%-d" 2>/dev/null)
  YDAY_MNUM=$(date -d "$DATE - 1 day" "+%-m" 2>/dev/null)
fi

DOW_NAMES=("" "Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday" "Sunday")
MONTH_NAMES=("" "January" "February" "March" "April" "May" "June" "July" "August" "September" "October" "November" "December")
DOW_RU="${DOW_NAMES[$DOW_NUM]}"
MONTH_RU="${MONTH_NAMES[$MONTH_NUM]}"
YDAY_MONTH_RU="${MONTH_NAMES[$YDAY_MNUM]}"

# --- YAML reader: parse config once, then do pure-bash lookup per call ---
# _YAML_KEYS / _YAML_VALS are parallel arrays built by a single python3 invocation.
#
# WP-7 DOSCAF1 (2026-07-04): the field separator between key and value used to be
# \x01 (introduced 2026-06-26, commit 043864e). /bin/bash on this machine is 3.2.57
# (macOS's frozen pre-GPLv3 build) — verified live that `IFS=$'\x01' read -r k v`
# NEVER splits on that byte under 3.2, in a heredoc, a pipe, or a file-read alike;
# the whole "key+value" glob lands in $k and $v stays empty. Every read_yaml() call
# has therefore returned "" for every real key since 2026-06-26, so every render_*()
# gated on a config flag (news.enabled here, but the same mechanism backs video/
# pomodoro/budget_spread) has been silently taking its "unset" branch regardless of
# what day-rhythm-config.yaml actually says. \x1f (ASCII Unit Separator) splits
# correctly under 3.2 too, per peer-review (kimi-headless, 2026-07-04) — it's the
# stronger choice over a plain tab, which is ordinary whitespace and could
# legitimately appear inside a YAML scalar; \x1f exists specifically to delimit
# fields and cannot occur in a meaningful config value.
_YAML_KEYS=()
_YAML_VALS=()
# Cold review 2026-08-19 (Codex, Critical): under `set -u`, referencing
# _RESOLVED_PYTHON3 below when $CONFIG is absent (the "no config" branch never
# runs, so the variable is never assigned) crashed the whole script instead of
# the intended silent-empty-arrays fallback. Initialized unconditionally here,
# before the config check, so it's always defined either way.
_RESOLVED_PYTHON3=""
if [ -f "$CONFIG" ]; then
  # WP-529 (continuation, 19.08): the F6 shared resolver (scripts/lib/find-python3.sh)
  # is invoked here, inside the existing [ -f "$CONFIG" ] guard, not at script
  # top-level — this branch is already conditional on the config existing, and a
  # top-level resolve would run PyYAML detection even for invocations that never
  # reach a yaml-dependent path (peer-session 2026-08-19-29, codex turn 1: lazy
  # placement, not unconditional). No bare-python3 fallback on resolver failure:
  # the resolver's own first candidate IS bare `python3` from PATH — if it
  # still failed, PATH's python3 already lacks yaml too, so falling back to it
  # would just reproduce the exact defect this migration fixes.
  _RESOLVED_PYTHON3=$("$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/find-python3.sh" 2>/dev/null) || _RESOLVED_PYTHON3=""
fi
if [ -n "$_RESOLVED_PYTHON3" ]; then
  while IFS=$'\x1f' read -r k v; do
    _YAML_KEYS+=("$k")
    _YAML_VALS+=("$v")
  done < <("$_RESOLVED_PYTHON3" -c "
import yaml, sys

def flatten(d, prefix=''):
    for k, v in (d or {}).items():
        full = f'{prefix}{k}'
        if isinstance(v, dict):
            yield from flatten(v, full + '.')
        else:
            yield full, '' if v is None else str(v)

# A bare 'except: pass' here made EVERY read_yaml() lookup silently return '' on
# any parse error too — config breakage and deliberate opt-out became
# indistinguishable. Emit an explicit ok/error sentinel instead (bug-2026-06-05,
# bug-2026-06-09, bug-2026-07-04).
try:
    with open('$CONFIG_PY', encoding='utf-8') as f:
        d = yaml.safe_load(f) or {}
    for k, v in flatten(d):
        print(k + '\x1f' + v)
    print('__yaml_parse_ok__\x1ftrue')
except Exception as e:
    print('__yaml_parse_ok__\x1ffalse')
    print('__yaml_parse_error__\x1f' + str(e).replace(chr(10), ' ')[:200])
" 2>/dev/null)
fi

read_yaml() {
  local key="$1" i
  for i in "${!_YAML_KEYS[@]}"; do
    if [ "${_YAML_KEYS[$i]}" = "$key" ]; then
      echo "${_YAML_VALS[$i]}"
      return
    fi
  done
}

# YAML_PARSE_OK=false covers both a parse exception (see sentinel above) and the
# block above being skipped entirely (config missing / no python3) — either way,
# every read_yaml() result for this run is unreliable and callers must say so.
YAML_PARSE_OK="$(read_yaml "__yaml_parse_ok__")"
YAML_PARSE_ERROR="$(read_yaml "__yaml_parse_error__")"
if [ -z "$YAML_PARSE_OK" ]; then
  YAML_PARSE_OK="false"
  YAML_PARSE_ERROR="$CONFIG not found or python3 unavailable"
fi

# --- Deterministic context extractors (WP-7 DAP: strategy + day-close) ---
extract_day_close_carry_over() {
  local yday="$1"
  # issue #545: logs root — by the same contract, as the writer
  # (session-guard.sh): MC-sessions after migration, legacy otherwise. Explicit
  # IWE_SESSIONS_ROOT, if broken, — visible WARN, not a silent miss.
  local sessions_dir
  if ! sessions_dir=$(iwe_sessions_dir); then
    echo "WARN: IWE_SESSIONS_ROOT=${IWE_SESSIONS_ROOT:-} unavailable — falling back to legacy-path $(iwe_resolve_governance_repo "${GOVERNANCE_REPO:-}")/sessions" >&2
    sessions_dir="$IWE/$(iwe_resolve_governance_repo "${GOVERNANCE_REPO:-}")/sessions"
  fi
  local month="${yday:0:7}"
  local carry_over=""

  # 1. Peer-session day-close report.md
  local dc_report
  dc_report=$(find "$sessions_dir/$month" -maxdepth 2 -type f -name "report.md" 2>/dev/null | grep -F "${yday}-" | grep -F "day-close" | head -1)
  if [ -z "$dc_report" ]; then
    dc_report=$(find "$sessions_dir/$month" -maxdepth 1 -type f -name "${yday}-day-close.md" 2>/dev/null | head -1)
  fi
  if [ -z "$dc_report" ]; then
    # Flat layout (logs directly in the root without a month subfolder, without a month subfolder) —
    # fallback path for installations, where the writer was still writing flat (issue #545).
    dc_report=$(find "$sessions_dir" -maxdepth 1 -type f -name "${yday}*day-close*" 2>/dev/null | head -1)
  fi
  if [ -n "$dc_report" ] && [ -f "$dc_report" ]; then
    carry_over=$(awk '
      /^## [0-9]+\. Open Issues/ || /^## Open Issues/ { found=1; next }
      /^## [0-9]+\. / && found { exit }
      /^## / && found && !(/^## [0-9]+\. Open Issues/ || /^## Open Issues/) { exit }
      found { print }
    ' "$dc_report" | sed '/^$/d' | head -20)
    if [ -n "$carry_over" ]; then
      echo "$carry_over"
      return 0
    fi
  fi

  # 2. Yesterday DayPlan archive: section "Tomorrow start with"
  local ydayplan="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/archive/day-plans/DayPlan ${yday}.md"
  if [ -f "$ydayplan" ]; then
    # issue #1149: the LAST heading-like "Tomorrow start with" opens the section (an
    # earlier mention in the body is not the handoff list); the section ends at
    # the next heading, </details>, a rule, or the closing footer line.
    carry_over=$(awk '
      { lines[NR] = $0 }
      /^(#+[[:space:]]+|\*\*)[[:space:]]*Tomorrow start with/ { strict = NR }
      /^[[:space:]]*(-[[:space:]]+)?Tomorrow start with/ { lead = NR }
      /Tomorrow start with/ { loose = NR }
      END {
        start = strict > lead ? strict : lead
        if (!start) start = loose
        if (!start) exit
        for (i = start + 1; i <= NR; i++) {
          l = lines[i]
          if (l ~ /^#+[[:space:]]/ || l ~ /^<\/details>/ || l ~ /^---[[:space:]]*$/ || l ~ /^\*(Closed|Created)/) break
          print l
        }
      }
    ' "$ydayplan" | sed '/^$/d' | head -10)
    if [ -n "$carry_over" ]; then
      echo "$carry_over"
      return 0
    fi
  fi

  echo "none (Day Close for $yday not found)"
}

extract_strategy_context() {
  local week_num="$1"
  # issue #545: journals root — by the same contract, as the writer
  # (session-guard.sh): MC-sessions after migration, legacy otherwise. Explicit
  # IWE_SESSIONS_ROOT, if broken, — visible WARN, not a silent miss.
  local sessions_dir
  if ! sessions_dir=$(iwe_sessions_dir); then
    echo "WARN: IWE_SESSIONS_ROOT=${IWE_SESSIONS_ROOT:-} unavailable — reading legacy-path $(iwe_resolve_governance_repo "${GOVERNANCE_REPO:-}")/sessions" >&2
    sessions_dir="$IWE/$(iwe_resolve_governance_repo "${GOVERNANCE_REPO:-}")/sessions"
  fi
  local strategy_file=""

  # 1. Strategy session markdown. Search current AND previous month: the session for a
  # week usually happens at week start, which can fall in the prior month (W27 session
  # was 2026-06-29, but Day Open runs in 2026-07 — the old current-month-only search
  # missed it and printed "not found").
  local strategy_file d
  for d in "$(date -j -v-0m -f "%Y-%m-%d" "$DATE" "+%Y-%m" 2>/dev/null || date -d "$DATE" "+%Y-%m" 2>/dev/null)" \
           "$(date -j -v-1m -f "%Y-%m-%d" "$DATE" "+%Y-%m" 2>/dev/null || date -d "$DATE -1 month" "+%Y-%m" 2>/dev/null)"; do
    [ -n "$d" ] || continue
    local md="$sessions_dir/$d"
    [ -d "$md" ] || continue
    strategy_file=$(find "$md" -maxdepth 1 -type f -iname "*strategy*W${week_num}*.md" 2>/dev/null | sort | tail -1)
    [ -n "$strategy_file" ] && break
  done

  if [ -n "$strategy_file" ] && [ -f "$strategy_file" ]; then
    # Extract the first matching priorities-like section. This session format uses
    # "## Key Decisions" rather than "## Priorities", so accept both.
    local priorities
    priorities=$(awk '
      /^## (Priorities|Key Decisions)/ { found=1; next }
      /^## / && found { exit }
      found { print }
    ' "$strategy_file" | sed '/^$/d' | head -12)
    if [ -n "$priorities" ]; then
      echo "$priorities"
      return 0
    fi
  fi

  # 2. Fallback: pull R-goal / TOC / priority lines from WeekPlan (formats vary).
  local weekplan
  weekplan=$(ls "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/current"/WeekPlan\ W"${week_num}"*.md 2>/dev/null | head -1)
  if [ -n "$weekplan" ] && [ -f "$weekplan" ]; then
    local tos
    tos=$(grep -E "^\s*[-*]\s*(P[0-9]+|TOC|R[0-9])" "$weekplan" 2>/dev/null | head -10)
    if [ -n "$tos" ]; then
      echo "$tos"
      return 0
    fi
  fi

  echo "not found"
}

# issue #477: mandatory_daily_wps used to be a plain instruction line telling
# the LLM to "apply" the config key — an LLM reading day-rhythm-config.yaml
# can't distinguish a commented-out example from an active setting, so the
# example in the shipped config (still commented out on a fresh install) was
# read as if active. This extractor uses the same PyYAML resolver as
# read_yaml() above (_RESOLVED_PYTHON3), so a commented key is invisible to
# it exactly like every other read_yaml() call — nothing LLM-interpreted.
# List-of-objects shape (wp+min_minutes / category+min_count) doesn't fit
# read_yaml()'s flatten(), hence a dedicated extractor rather than reuse.
extract_mandatory_daily_wps() {
  if [ -z "$_RESOLVED_PYTHON3" ]; then
    echo ""
    return 0
  fi
  "$_RESOLVED_PYTHON3" -c "
import yaml, sys
try:
    with open('$CONFIG_PY', encoding='utf-8') as f:
        d = yaml.safe_load(f) or {}
    items = d.get('mandatory_daily_wps') or []
    for item in items:
        if not isinstance(item, dict):
            print(f'skip: not a dict: {item!r}', file=sys.stderr)
            continue
        if 'wp' in item:
            print(f\"WP-{item['wp']} (min {item.get('min_minutes', '?')} min)\")
        elif 'category' in item:
            print(f\"category «{item['category']}» (min {item.get('min_count', '?')} pcs.)\")
        else:
            print(f'skip: neither wp nor category key: {item!r}', file=sys.stderr)
except Exception as e:
    # Same explicit-sentinel principle as read_yaml() above (bug-2026-06-05 class):
    # a parse failure must not look identical to "key legitimately absent".
    print(f'extract_mandatory_daily_wps: config read failed: {e}', file=sys.stderr)
"
}

# Epoch of 00:00:00 UTC of a YYYY-MM-DD date (BSD date, then GNU date); 0 = unreadable.
# UTC, not local time: a local-midnight difference is 23 or 25 hours short/long
# across a DST change and would round a 4-day-old list down to 3.
_prio_epoch() {
  date -j -u -f "%Y-%m-%d %H:%M:%S" "$1 00:00:00" +%s 2>/dev/null \
    || date -u -d "$1 00:00:00" +%s 2>/dev/null || echo 0
}

read_morning_priorities() {
  local prio_file="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/current/priorities.yaml"

  if [ ! -f "$prio_file" ]; then
    return 0
  fi

  # issue #944: an untrusted list (no/unreadable/far-future date, or older than
  # PRIORITIES_STALE_DAYS) is not printed: one explanatory line only, so the
  # DayPlan falls back to yesterday's carry-over. last_updated is the day the
  # list is FOR (Day Close stores tomorrow's date), so one day ahead is normal.
  local last_updated last_epoch today_epoch diff_days
  last_updated=$(grep "^last_updated:" "$prio_file" 2>/dev/null | sed 's/last_updated:[[:space:]]*//' | tr -d '"' | head -1)
  if [ -z "$last_updated" ]; then
    echo "⚠️ priorities not shown: in priorities.yaml no last_updated date last_updated — update the file"
    return 0
  fi
  # Both dates go through _prio_epoch: the difference is whole calendar days.
  last_epoch=$(_prio_epoch "$last_updated")
  today_epoch=$(_prio_epoch "$(date +%Y-%m-%d)")
  if [ "$last_epoch" -le 0 ] || [ "$today_epoch" -le 0 ]; then
    echo "⚠️ priorities not shown: date last_updated «$last_updated» cannot be parsed (required format YYYY-MM-DD)"
    return 0
  fi
  diff_days=$(( (today_epoch - last_epoch) / 86400 ))
  if [ "$diff_days" -lt -1 ]; then
    echo "⚠️ priorities not shown: date last_updated $last_updated is in the future — check priorities.yaml"
    return 0
  fi
  if [ "$diff_days" -gt "${PRIORITIES_STALE_DAYS:-3}" ]; then
    echo "⚠️ priorities are stale: last updated $last_updated (${diff_days}d ago), list not carried over — update priorities.yaml at Day Close"
    return 0
  fi

  local wps
  wps=$(awk '
    /^today:/ { found=1; next }
    /^[^[:space:]]/ && found { exit }
    found && /^[[:space:]]*-/ {
      gsub(/^[[:space:]]*-[[:space:]]*/,"")
      print "- "$0
    }
  ' "$prio_file" 2>/dev/null)

  if [ -z "$wps" ]; then
    return 0
  fi

  echo "$wps"
}

# The DayPlan "Calendar" section. Omitted when the calendar is switched off
# (params.yaml calendar_source: none, issue #942); for calendar_source: script the
# instruction names server-calendar.sh only, so an agent filling the plan in another
# session is not told to try the connector first.
render_calendar_section() {
  [ "$CALENDAR_PF" = "disabled" ] && return 0
  cat <<CALENDAR_HEAD
<details>
<summary><b>Calendar ($DAY_NUM $MONTH_RU)</b></summary>

CALENDAR_HEAD
  if [ "$CALENDAR_SOURCE" = "script" ]; then
    cat <<CALENDAR_SCRIPT
<!-- PENDING: calendar — source: only bash \$IWE_SCRIPTS/server-calendar.sh $DATE
  (params.yaml: calendar_source: script); do not query the calendar connector.
  Show ALL events of the day (00:00–23:59 MSK). Format: table + row of free blocks ≥1h. -->
CALENDAR_SCRIPT
  else
    cat <<CALENDAR_CONNECTOR
<!-- PENDING: calendar — single source: calendar connector (MCP-tools
  calendar; names depend on the installation, name contains «calendar» case-insensitive, e.g.. mcp__claude_ai_Google_Calendar__* — actual names
  take from the tool list of the current session). Retrieve the list of pilot calendars
  (own + connected shared), then events of each for $DATE (00:00–23:59 MSK).
  Show ALL events of the day across all found calendars.
  If the connector is not available — fallback: bash \$IWE_SCRIPTS/server-calendar.sh $DATE
  (its «credentials not configured» — a fact about the script, not about the calendar; issue #581).
  Format: table + row of free blocks ≥1h. -->
CALENDAR_CONNECTOR
  fi
  cat <<CALENDAR_TABLE

| Time (MSK) | Event | Dur.. | Link to WP |
|-------------|---------|-------|------------|
| <!-- PENDING --> | <!-- PENDING --> | — | — |

⏱ Free blocks ≥1h: <!-- PENDING -->

</details>

CALENDAR_TABLE
}

# --- Strategy_day guard (Phase6 WP-264) ---
# If today is strategy_day → do not generate DayPlan (SKILL.md step 4).
# Returns exit 2; extension handles this code and outputs the message Claude.
# DAY_OPEN_FORCE_STRATEGY_DAY=1 bypasses the guard without changing default behavior —
# an extension point for a caller that wants this scaffold's output on a
# strategy_day too (e.g. to build an "Day Opening" section inside WeekPlan).
# issue #595: an earlier version of this comment named a specific caller
# script (week-open-day-section-patch.sh, WP-484 Phase3) that depends on
# author-only infrastructure (a shared-checkout publish gateway, a private
# LLM proxy) not delivered by this template — the caller itself is out of
# scope here, this flag is the generic, delivered part of the extension point.
# issue #1213: when the config can't be read at all (missing file, no python3),
# an absent key and a broken config both fell through to the same `:-monday`
# default — a config outage on an actual Monday looked identical to a deliberate
# "strategy day is Monday" setting and silently blocked DayPlan generation
# (exit 2) with no visible cause. YAML_PARSE_OK already distinguishes the two;
# only trust the configured/default day when the config was actually readable.
if [ "$YAML_PARSE_OK" = "true" ]; then
  STRATEGY_DAY_NAME=$(read_yaml "day_open.strategy_day" || true)
  case "${STRATEGY_DAY_NAME:-monday}" in
    monday)    STRATEGY_DOW=1 ;;
    tuesday)   STRATEGY_DOW=2 ;;
    wednesday) STRATEGY_DOW=3 ;;
    thursday)  STRATEGY_DOW=4 ;;
    friday)    STRATEGY_DOW=5 ;;
    saturday)  STRATEGY_DOW=6 ;;
    sunday)    STRATEGY_DOW=7 ;;
    *)         STRATEGY_DOW=0 ;;
  esac
  if [ "${DOW_NUM:-0}" = "$STRATEGY_DOW" ] && [ "${DAY_OPEN_FORCE_STRATEGY_DAY:-0}" != "1" ]; then
    exit 2
  fi
else
  echo "day-open-scaffold: WARN: day-rhythm-config.yaml failed to parse ($YAML_PARSE_ERROR) — strategy_day not verified, DayPlan generated as on a regular day" >&2
fi

# --- Section: Pomodoro/rhythm ---
render_pomodoro() {
  local work brk long n
  work=$(read_yaml "pomodoro.work_minutes")
  brk=$(read_yaml "pomodoro.break_minutes")
  long=$(read_yaml "pomodoro.long_break_minutes")
  n=$(read_yaml "pomodoro.sessions_before_long_break")
  echo "**Pomodoros:** ${work:-?} min work / ${brk:-?} min break / ${long:-?} min long break after ${n:-?} sessions"
}

# --- Section: Video (new today) ---
render_video() {
  local enabled
  enabled=$(read_yaml "video.enabled")
  if [ "$enabled" != "True" ]; then
    echo "> \`video.enabled: false\` in \`day-rhythm-config.yaml\` — section disabled. No data."
    return
  fi
  local dirs=("$HOME/Documents/Zoom" "$HOME/Documents/Telemost" "$HOME/Telemost Video Recordings")
  local count=0
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    local n
    n=$(find "$d" -mtime 0 \( -name "*.mp4" -o -name "*.mov" -o -name "*.webm" -o -name "*.m4a" -o -name "*.mp3" \) 2>/dev/null | wc -l | tr -d ' ')
    count=$((count + n))
  done
  if [ "$count" -eq 0 ]; then
    echo "**Video:** 0 new recordings today"
  else
    echo "**Video:** $count new recordings today (directories: Zoom / Telemost / Telemost Video Recordings)"
  fi
}

# DOC5/DOC10 (WP-7): section «World» is rendered ALWAYS.
# When news.enabled: false — section contains an explicit «disabled», is not omitted.
# When true — data from server-news.sh or PENDING-markers.
# DOC5/DOC10 (WP-7) + WP-7 DOSCAF1 (2026-07-04): section «World» is rendered ALWAYS —
# never a silent `return 0` (violates the no-silent-skip invariant at the top of this
# file). Three explicit states: config didn't parse at all / news.enabled: false /
# enabled (data from server-news.sh or PENDING-markers).
render_world() {
  local enabled
  echo "<details>"
  echo "<summary><b>World</b></summary>"
  echo ""
  if [ "$YAML_PARSE_OK" != "true" ]; then
    echo "> ⚠️ \`day-rhythm-config.yaml\` failed to parse ($YAML_PARSE_ERROR) — could not read \`news.enabled\`. No data, until the config is fixed."
    echo ""
    echo "</details>"
    return 0
  fi
  enabled=$(read_yaml "news.enabled")
  if [ "$enabled" != "True" ]; then
    echo "> \`news.enabled: false\` in \`day-rhythm-config.yaml\` — section disabled. No data."
    echo ""
    echo "</details>"
    return 0
  fi
  bash "$IWE/scripts/server-news.sh" "$CONFIG" 2>/dev/null || {
    echo "<!-- PENDING: world — RSS feeds unavailable (server-news.sh failed with an error). Each item = markdown URL. -->"
    echo ""
    echo "> ⚠️ Data-contract: every thesis in the section «World» must contain markdown-link to source [title](url)."
    echo "> If the source is unavailable — use placeholder [source unavailable](n/a) and mark 🔴 in «Requires Attention»."
    echo ""
    echo "**AI/LLM:** <!-- PENDING --> [title](url) · [title](url)"
    echo "**Engineering:** <!-- PENDING --> [title](url) · [title](url)"
    echo "**World Events:** <!-- PENDING --> [title](url) · [title](url)"
  }
  echo ""
  echo "**Summary:** <!-- PENDING: news-lens — 2-4 sentences: which of these news items are relevant to active WPs (WP-350, WP-330, WP-351 etc.). Use context WeekPlan + WP-Registry. -->"
  echo ""
  echo "</details>"
}

# --- Section: Platform Health (feedback-triage report) ---
render_bot_qa() {
  local file="$IWE/DS-agent-workspace/scheduler/feedback-triage/$DATE.md"
  if [ -f "$file" ]; then
    awk '/^\*\*Delta/,/^### ✏️/' "$file" 2>/dev/null | head -40
    echo
    echo "*Full report: \`$file\`*"
  else
    if [ "${TRIAGE_PF:-unknown}" = "fail" ]; then
      echo "**Delta:** ⚠️ Report feedback-triage for $DATE is missing. Scheduler, probably, is not running (downtime ≥1 day)."
    elif [ "${TRIAGE_PF:-unknown}" = "disabled" ]; then
      echo "**Delta:** feedback-triage not installed on this machine"
    else
      echo "**Delta:** no data (report for $DATE is missing)"
    fi
    echo
    echo "| Metric | Value |"
    echo "|---------|----------|"
    echo "| Today | no data |"
    echo "| Urgent | no data |"
  fi
  echo
  # Step 5 SKILL: core smoke synchronously. Previously left as PENDING-placeholder (bug-2026-06-12).
  local smoke_script="$TEMPLATE_SCRIPTS_DIR/day-open-smoke.sh" smoke_json
  if [ -f "$smoke_script" ]; then
    smoke_json=$(bash "$smoke_script" 2>/dev/null)
    if [ -n "$smoke_json" ]; then
      echo "**Smoke-tests:** \`$smoke_json\`"
    else
      echo "**Smoke-tests:** script returned empty — check \`$smoke_script\`"
    fi
  else
    echo "**Smoke-tests:** script not found (\`$smoke_script\`)"
  fi
}

# Portable per-call timeout — no `timeout`/`gtimeout` dependency (often missing on
# macOS, see issue #230). Bounds a backgrounded command to $2 seconds; on timeout,
# kills it and returns whatever it had already written to stdout.
# Usage: run_bounded <seconds> <cmd...>
run_bounded() {
  local secs="$1"; shift
  local out_file start
  out_file=$(mktemp)
  ("$@" >"$out_file" 2>/dev/null) &
  local pid=$!
  start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.2
    [ $((SECONDS - start)) -ge "$secs" ] && { kill "$pid" 2>/dev/null; break; }
  done
  wait "$pid" 2>/dev/null
  cat "$out_file"
  rm -f "$out_file"
}

# iwe_repo_dirs — prints subdirectories containing .git, deduplicated by real
# physical path. Without this repo-symlink alias (e.g.. legacy-repository name,
# left as compat-shim after renaming) is treated as a separate repository
# on equal footing with the original — duplicate rows in activity tables, inflated by a factor of two
# commit counter in «Yesterdays Summary» (discovered 2026-07-17).
iwe_repo_dirs() {
  local repo real seen=""
  for repo in "$@"; do
    [ -d "$repo/.git" ] || continue
    real=$(cd -P "$repo" 2>/dev/null && pwd) || continue
    case " $seen " in
      *" $real "*) continue ;;
    esac
    seen="$seen $real"
    echo "$repo"
  done
}

# --- Section: New issues in repositories (issue sweep, 2 days) ---
# Signal channel from day-open/SKILL.md:54 (previously existed only in the spec, not in code).
# Lazy: cache 1h + fallback when gh is unavailable gh — does not break pipeline (requirement of peer-session 2026-06-04-32).
# Each `gh issue list` is limited to $ISSUE_SWEEP_TIMEOUT seconds (issue #241: on WSL2
# a single hung network call without a time-box would stall the entire sweep for 180s+ with no output).
render_repo_issues() {
  command -v gh >/dev/null 2>&1 || { echo "_gh CLI unavailable — issue sweep skipped._"; return; }
  local cache="/tmp/iwe-issue-sweep-$DATE.md"
  if [ -f "$cache" ] && [ -n "$(find "$cache" -mmin -60 2>/dev/null)" ]; then
    cat "$cache"; return
  fi
  # issue #241 (residual gap): gh auth status makes a network request to GitHub API
  # for token validation — on WSL2 with a problematic network connection it may hang with the same class of
  # bug, that is already fixed for gh issue list below. run_bounded does not forward exit-code
  # of the wrapped command (returns the status cat/rm) — therefore we pass the result via
  # a marker in stdout, and not via "if ! run_bounded ...".
  local auth_ok
  auth_ok=$(run_bounded "${ISSUE_SWEEP_TIMEOUT:-10}" bash -c "gh auth status >/dev/null 2>&1 && echo ok")
  if [ "$auth_ok" != "ok" ]; then
    echo "_gh is not authorized or GitHub is unavailable — issue review skipped (check \`gh auth login\` and network)._"; return
  fi
  local since
  since=$(date -v-2d +%Y-%m-%d 2>/dev/null || date -d "2 days ago" +%Y-%m-%d 2>/dev/null)
  [ -z "$since" ] && { echo "_could not compute filter date — skipping._"; return; }
  local out="" any=0 repo slug rows stale_count stale_url
  while IFS= read -r repo; do
    git -C "$repo" remote get-url origin 2>/dev/null | grep -qi github || continue
    slug=$(basename "$repo")
    # New issues (last 2 days)
    rows=$(run_bounded "${ISSUE_SWEEP_TIMEOUT:-10}" bash -c \
      "cd '$repo' && gh issue list --state open --search 'created:>=$since' \
       --json number,title --jq '.[] | \"| #\(.number) | \(.title) |\"'")
    if [ -n "$rows" ]; then
      out="${out}\n**${slug} (new):**\n\n| # | Title |\n|---|---|\n${rows}\n"
      any=1
    fi
    # Stale issues: open + labeled stale-unattended (pipeline gap fix, issue #pipeline)
    stale_count=$(run_bounded "${ISSUE_SWEEP_TIMEOUT:-10}" bash -c \
      "cd '$repo' && gh issue list --state open --label 'stale-unattended' --json number --jq 'length'")
    [ -z "$stale_count" ] && stale_count=0
    if [ "${stale_count:-0}" -gt 0 ] 2>/dev/null; then
      local remote_url
      remote_url=$(git -C "$repo" remote get-url origin 2>/dev/null \
                   | sed 's|git@github.com:|https://github.com/|; s|\.git$||')
      stale_url="${remote_url}/issues?q=is:open+label:stale-unattended"
      out="${out}\n⚠️ **${slug}:** ${stale_count} stale issues with no activity → [open filter](${stale_url})\n"
      any=1
    fi
  done < <(iwe_repo_dirs "$IWE"/*/)
  if [ "$any" = "1" ]; then
    printf "%b" "$out" | tee "$cache"
  else
    echo "No new issues in the last 2 days. None. Stale-unattended (stale-unattended) none either." | tee "$cache"
  fi
}

# --- Section: Activity overview across all repos (commits, 2 days) — WP-5 Phase 2026-06-11 P2 ---
# Complements issue-sweep: what changed in each repo (including Template IWE / FMT),
# and not only new issues. Signal «where work was happening» for the daily/weekly plan.
render_repo_activity() {
  local since out="" any=0 repo slug n last
  since=$(date -v-2d +%Y-%m-%d 2>/dev/null || date -d "2 days ago" +%Y-%m-%d 2>/dev/null)
  [ -z "$since" ] && { echo "_could not compute filter date — skipping._"; return; }
  out="| Repository | Commits (2d) | Latest |\n|---|---|---|\n"
  # issue #1131: `cut -c1-50` counts bytes under the C/POSIX locale (launchd's
  # EnvironmentVariables carry no LANG/LC_*) and can split a multibyte UTF-8
  # character mid-sequence, corrupting the whole scaffold file for every
  # downstream reader. Resolved once here, not inside the loop (same
  # rationale as the find-python3.sh resolution elsewhere in this file).
  local _resolved_python3
  _resolved_python3=$("$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/find-python3.sh" --stdlib-only 2>/dev/null) || _resolved_python3=""
  while IFS= read -r repo; do
    slug=$(basename "$repo")
    n=$(git -C "$repo" log --since="$since 00:00:00" --oneline 2>/dev/null | wc -l | tr -d ' ')
    [ "${n:-0}" -eq 0 ] && continue
    if [ -n "$_resolved_python3" ]; then
      last=$(git -C "$repo" log -1 --format='%s' 2>/dev/null | "$_resolved_python3" -c "
import sys
line = sys.stdin.buffer.readline().decode('utf-8', errors='replace').rstrip('\n')
print(line if len(line) <= 50 else line[:50] + '…')
")
    else
      last=$(git -C "$repo" log -1 --format='%s' 2>/dev/null | cut -c1-50)
    fi
    out="${out}| ${slug} | ${n} | ${last} |\n"
    any=1
  done < <(iwe_repo_dirs "$IWE"/*/)
  if [ "$any" = "1" ]; then
    printf "%b" "$out"
  else
    echo "No activity in repositories in the last 2 days.."
  fi
}

# --- Section: IWE overnight (traffic light) ---

# issue #866: validate that a stat result is a non-negative integer before using
# it in arithmetic or comparisons. BSD/GNU stat flag differences can produce
# empty or textual output; empty/invalid values must be treated as unknown.
_is_nonneg_int() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# A file created by launchd or by the producer's first write is not proof that
# the scheduled work finished. Each producer has its own completion marker.
triage_report_health() {
  local file="$1" day="$2"
  [ -f "$file" ] || { echo absent; return; }
  # Inspect every status line: a partially written report can contain valid
  # counters followed by a producer error. Table cells start with `|` and may
  # quote a user's ERROR text; they are report data, not producer status.
  if grep -Eq '^[[:space:]]*(WARN|ALARM|ERROR|FATAL|SKIP):' "$file"; then
    echo failed
  elif grep -Fxq "## Report QA: unsatisfied responses ($day)" "$file" &&
       grep -Eq '^- Today: [0-9]+' "$file" &&
       grep -Eq '^- Questions per day: [0-9]+' "$file" &&
       grep -Eq '^- Total questions: [0-9]+' "$file" &&
       grep -Eq '^- Unsatisfied \(🔍\): [0-9]+' "$file"; then
    echo completed
  else
    echo unverified
  fi
}

watchdog_log_health() {
  local file="$1" day="$2"
  [ -f "$file" ] || { echo absent; return; }
  if grep -Eq '(^|[[:space:]])(WARN|ALARM|ERROR|FATAL|SKIP):' "$file"; then
    echo failed
  elif grep -Eq "^\\[$day [0-9]{2}:[0-9]{2}:[0-9]{2}\\] \\[feedback-watchdog\\] (OK:|done:)" "$file"; then
    echo completed
  else
    echo unverified
  fi
}

triage_stdout_health() {
  local file="$1" day="$2" todays_lines
  [ -f "$file" ] || { echo absent; return; }
  todays_lines=$(awk -v prefix="[$day " 'index($0, prefix) == 1' "$file")
  # A nonempty rolling log containing only older runs says nothing about today.
  [ -n "$todays_lines" ] || { [ -s "$file" ] && echo absent || echo unverified; return; }
  if printf '%s\n' "$todays_lines" | grep -Eq '(^|[[:space:]])(WARN|ALARM|ERROR|FATAL|SKIP):'; then
    echo failed
  elif printf '%s\n' "$todays_lines" | grep -Eq '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] \[unsatisfied-report\] done: total=[0-9]+'; then
    echo completed
  else
    echo unverified
  fi
}

render_iwe_status() {
  echo "| Subsystem | Status | Details |"
  echo "|------------|--------|--------|"

  # Per-role launchd agents. issue #412: previously the list of four agents was
  # hardcoded (com.iwe.day-open/com.strategist.notereview/com.pulse.daily/
  # com.aisystant.profiler.recalculate) — on installations where the actual agents present, where the actual agents present
  # different per-role units (for example com.strategist.morning/weekreview),
  # the row could never turn green: the hardcoded agents were always "missing", while the actual
  # installed ones were not checked at all. Instead of a fixed expectation list — we read,
  # what is actually present in ~/Library/LaunchAgents/ on this machine, and check
  # exactly that (the same principle, that non-deploy ⚪ ≠ failure in Scheduler/triage
  # above). The filter is restricted to known IWE-prefixes (not a bare `com.*.plist`,
  # code review found: would have matched any third-party plist — Docker, Adobe,
  # Google Keystone etc.., reproducing the same symptom of never «never
  # green» in reverse, false positives instead of missed entries).
  if command -v launchctl &>/dev/null; then
    local plist_dir="$HOME/Library/LaunchAgents"
    local agents_bad="" agents_checked=0
    if [ -d "$plist_dir" ]; then
      for plist in "$plist_dir"/com.iwe.*.plist "$plist_dir"/com.strategist.*.plist \
                   "$plist_dir"/com.pulse.*.plist "$plist_dir"/com.aisystant.*.plist \
                   "$plist_dir"/com.exocortex.*.plist "$plist_dir"/com.extractor.*.plist; do
        [ -e "$plist" ] || continue
        local agent
        agent=$(basename "$plist" .plist)
        agents_checked=$((agents_checked + 1))
        local line status
        line=$(launchctl list 2>/dev/null | awk -v a="$agent" '$3==a{print}')
        [ -z "$line" ] && { agents_bad="$agents_bad $agent(not loaded)"; continue; }
        status=$(echo "$line" | awk '{print $2}')
        if [ "$status" != "0" ] && [ "$status" != "-" ]; then
          # issue #866: a non-zero exit code may be stale. Show the last log date
          # and mark the result stale when the expected interval has passed.
          local log_path="" log_mtime="" status_file="" status_mtime="" status_result="" last_run="" age_days="" stale_threshold=2 status_is_freshest=""
          case "$agent" in
            com.strategist.weekreview) stale_threshold=8 ;;
          esac
          if command -v plutil &>/dev/null; then
            log_path=$(plutil -extract StandardOutPath raw "$plist" 2>/dev/null || true)
          fi
          log_path="${log_path//\{\{HOME_DIR\}\}/$HOME}"
          if [ -n "$log_path" ] && [ -f "$log_path" ]; then
            log_mtime=$(stat -c %Y "$log_path" 2>/dev/null) ||
                log_mtime=$(stat -f %m "$log_path" 2>/dev/null) ||
                log_mtime=""
          fi
          _is_nonneg_int "$log_mtime" || log_mtime=""

          # issue #866: a manual successful retry updates the per-scenario status
          # file; use its mtime when it is fresher than the agent's log.
          case "$agent" in
            com.strategist.weekreview) status_file="$HOME/logs/strategist/week-review-last-status" ;;
          esac
          if [ -n "$status_file" ] && [ -f "$status_file" ]; then
            status_mtime=$(stat -c %Y "$status_file" 2>/dev/null) ||
                status_mtime=$(stat -f %m "$status_file" 2>/dev/null) ||
                status_mtime=""
            status_result=$(awk -F'\t' 'NR==1 {print $2}' "$status_file" 2>/dev/null || true)
          fi
          _is_nonneg_int "$status_mtime" || status_mtime=""

          if [ -n "$status_mtime" ] && [ -n "$log_mtime" ]; then
            if [ "$status_mtime" -ge "$log_mtime" ]; then
              log_mtime="$status_mtime"
              status_is_freshest=true
            fi
          elif [ -n "$status_mtime" ]; then
            # Status file alone is the freshest signal we have (no agent log).
            log_mtime="$status_mtime"
            status_is_freshest=true
          fi

          if [ -n "$log_mtime" ]; then
            last_run=$(date -r "$log_mtime" '+%Y-%m-%d' 2>/dev/null || date -d "@$log_mtime" '+%Y-%m-%d' 2>/dev/null || true)
            age_days=$(( ( $(date +%s) - log_mtime ) / 86400 ))
          fi
          if [ -n "$age_days" ] && [ "$age_days" -gt "$stale_threshold" ]; then
            agents_bad="$agents_bad $agent(exit=$status, last $last_run, stale)"
          elif [ "$status_result" = "SUCCESS" ] && [ "$status_is_freshest" = true ]; then
            agents_bad="$agents_bad $agent(exit=$status, last ${last_run:-unknown}, recovered)"
          else
            agents_bad="$agents_bad $agent(exit=$status, last ${last_run:-unknown})"
          fi
        fi
      done
    fi
    if [ "$agents_checked" -eq 0 ]; then
      echo "| LaunchAgents | ⚪ | no plist in ~/Library/LaunchAgents — scheduler was not installed here |"
    elif [ -z "$agents_bad" ]; then
      echo "| LaunchAgents | 🟢 | per-role agents OK ($agents_checked) |"
    else
      echo "| LaunchAgents | 🟡 |${agents_bad} |"
    fi
  else
    echo "| LaunchAgents | ⚪ | launchctl unavailable |"
  fi

  # template-sync (FMT last commit)
  if [ -d "$IWE/IWE/.git" ]; then
    local fmt_last
    fmt_last=$(git -C "$IWE/IWE" log -1 --format="%cr" 2>/dev/null || echo "?")
    echo "| template-sync | 🟢 | FMT last commit: $fmt_last |"
  else
    echo "| template-sync | 🔴 | FMT not found |"
  fi

  # Scout findings
  if [ "${SCOUT_PF:-unknown}" = "ok" ]; then
    local scout_dir="$IWE/DS-agent-workspace/scout/results/$YEAR/$MM/$DD"
    if [ -d "$scout_dir" ]; then
      local findings=0 captures=0
      [ -f "$scout_dir/report.md" ] && findings=$(grep -c '^### ' "$scout_dir/report.md" 2>/dev/null || echo 0)
      [ -f "$scout_dir/capture-candidates.md" ] && captures=$(grep -c '^### ' "$scout_dir/capture-candidates.md" 2>/dev/null || echo 0)
      echo "| Scout | 🟢 | $findings findings, $captures capture-candidates |"
    else
      echo "| Scout | 🟡 | no report for $DATE |"
    fi
  elif [ "${SCOUT_PF:-unknown}" = "fail" ]; then
    local last_log
    last_log=$(ls -t "$IWE/DS-autonomous-agents/logs/scout-"*.log 2>/dev/null | head -1 || echo "")
    if [ -n "$last_log" ]; then
      local last_date
      last_date=$(basename "$last_log" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
      echo "| Scout | 🔴 | no report for $DATE. Last log: $last_date (>20 days of downtime) — service diagnostics |"
    else
      echo "| Scout | 🔴 | no report for $DATE. Logs not found — service is not configured |"
    fi
  elif [ "${SCOUT_PF:-unknown}" = "disabled" ]; then
    echo "| Scout | ⚪ | not installed on this machine |"
  elif [ ! -d "$IWE/DS-autonomous-agents" ] && [ ! -d "$IWE/DS-agent-workspace/scout" ]; then
    # issue #920: preflight unavailable AND no Scout directory anywhere — nothing
    # can be broken, so this is "not installed" (⚪), not "could not check" (🟡).
    echo "| Scout | ⚪ | not installed on this machine |"
  else
    echo "| Scout | 🟡 | status Scout is undefined (preflight unavailable) |"
  fi

  # Scheduler / feedback-triage healthcheck with failure mode A/B/C
  # see: peer-session 2026-05-30-07-gap-list-day-open sub-step 4
  # Mode A — cron is not running (no unit, no logs 7+ days)
  # Mode B — cron started, report is empty (all clean, no complaints) = ok 🟢
  # Mode C — unit is loaded, but cron has not fired yet (grace window until 06:30) = 🟡 pending
  local triage_file="$IWE/DS-agent-workspace/scheduler/feedback-triage/$DATE.md"
  local watchdog_log="$HOME/logs/synchronizer/feedback-watchdog-$DATE.log"
  local feedback_triage_log="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/logs/feedback-triage.log"
  # issue #919: the log the scheduler really writes (roles/synchronizer/scripts/scheduler.sh
  # LOG_FILE) — the three names above are never produced on a real install.
  local scheduler_log="$HOME/logs/synchronizer/scheduler-$DATE.log"
  local last_watchdog_log
  last_watchdog_log=$(ls -t "$HOME/logs/synchronizer/feedback-watchdog-"*.log 2>/dev/null | head -1 || echo "")
  local last_feedback_triage_log
  last_feedback_triage_log=$(ls -t "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/logs/feedback-triage"*.log 2>/dev/null | head -1 || echo "")
  # issue #261: old mask matched only legacy-labels (iwe.scheduler etc..), which do not cover
  # do not match either current per-role units, nor even the template com.exocortex.scheduler.plist.
  # WP-5 Ubuntu-audit fact #4: launchctl unconditionally also meant Linux always saw this
  # as false (launchctl doesn't exist there) — iwe_scheduler_active() (lib/common.sh)
  # branches launchd/systemd by what's actually on PATH.
  # issue #347: the old boolean called this "has_launchd_unit" even though the check
  # covers launchd, systemd, crontab and log evidence — and it could not tell
  # "never deployed here" from "deployed and dead", so an install that simply never
  # set up a scheduler got a red Mode A plus a fresh incident file every morning.
  local scheduler_state
  scheduler_state="$(iwe_scheduler_state)"
  local has_launchd_unit=false
  if [ "$scheduler_state" = "active" ]; then
    has_launchd_unit=true
  fi

  # Grace window: feedback-triage starts at 06:00, until 06:30 absence of report — is normal
  local current_hour current_min in_grace_window=false
  current_hour=$(date +%H)
  current_min=$(date +%M)
  if [ "$current_hour" -lt 6 ] || { [ "$current_hour" -eq 6 ] && [ "$current_min" -lt 30 ]; }; then
    in_grace_window=true
  fi

  # issue #1060: scheduler.sh creates this log before dispatch and writes WARN/ALARM
  # on failed tasks, then still writes "dispatch completed". A concurrent healthy
  # strategist run is logged as SKIP, which is neutral but not proof of success.
  local scheduler_log_health=absent
  if [ -f "$scheduler_log" ]; then
    if grep -Eq '(^|[[:space:]])((WARN|ALARM|ERROR|FATAL):|(FAILED|GAVE UP) scenario:)' "$scheduler_log"; then
      scheduler_log_health=failed
    elif grep -Eq '(^|[[:space:]])SKIP:' "$scheduler_log"; then
      scheduler_log_health=deferred
    elif [ -s "$scheduler_log" ] &&
         grep -Eq "^\\[$DATE [0-9]{2}:[0-9]{2}:[0-9]{2}\\] \\[scheduler\\] dispatch started " "$scheduler_log" &&
         grep -Eq "^\\[$DATE [0-9]{2}:[0-9]{2}:[0-9]{2}\\] \\[scheduler\\] dispatch completed$" "$scheduler_log"; then
      scheduler_log_health=completed
    else
      scheduler_log_health=unverified
    fi
  fi

  local triage_report_health watchdog_health triage_stdout_health
  triage_report_health=$(triage_report_health "$triage_file" "$DATE")
  watchdog_health=$(watchdog_log_health "$watchdog_log" "$DATE")
  triage_stdout_health=$(triage_stdout_health "$feedback_triage_log" "$DATE")

  if [ "$scheduler_log_health" = failed ]; then
    echo "| Scheduler/triage | 🔴 | scheduler log for $DATE contains an error — check $scheduler_log |"
  elif [ "$triage_report_health" = failed ] || [ "$watchdog_health" = failed ] || [ "$triage_stdout_health" = failed ]; then
    echo "| Scheduler/triage | 🔴 | triage log or report for $DATE contains an error — check $triage_file, $watchdog_log, $feedback_triage_log |"
  elif [ "$scheduler_log_health" = deferred ]; then
    echo "| Scheduler/triage | 🟡 | run for $DATE deferred from-due to a concurrent run; check that the other run has finished — $scheduler_log |"
  elif [ "$triage_report_health" = unverified ] || [ "$watchdog_health" = unverified ] ||
       [ "$triage_stdout_health" = unverified ]; then
    echo "| Scheduler/triage | 🟡 | file for $DATE exists, but successful completion of triage is not confirmed — check $triage_file, $watchdog_log, $feedback_triage_log |"
  elif [ "$scheduler_log_health" = unverified ]; then
    echo "| Scheduler/triage | 🟡 | scheduler log for $DATE exists, but a clean completed run is not confirmed — check $scheduler_log |"
  elif [ "$scheduler_log_health" = completed ] || [ "$triage_report_health" = completed ] ||
       [ "$watchdog_health" = completed ] || [ "$triage_stdout_health" = completed ]; then
    # Mode B-1: at least one producer finished cleanly and no present producer
    # is failed, deferred or unverified.
    echo "| Scheduler/triage | 🟢 | report or clean run for $DATE confirmed (Mode B ok) |"
  elif [ "$scheduler_state" = "not_deployed" ]; then
    # issue #347: the scheduler was never deployed here -- no unit, no — no unit, nor
    # crontab-entry, not a single log entry in the entire history. This is not a failure, but a non-installation:
    # ⚪ no incident. The real Mode A remains below, under deployed_inactive.
    echo "| Scheduler/triage | ⚪ | scheduler is not deployed on this machine (no unit, no crontab, no logs) — installation: see. roles/ROLE-CONTRACT.md |"
  elif [ "$scheduler_state" = "unknown" ]; then
    # Check was not possible (no user-level systemd bus systemd in WSL/container etc.etc.).
    # «Unable to check» does not resolve to green, nor to red and does not raise an incident.
    echo "| Scheduler/triage | 🟡 | scheduler status could not be checked (service manager query failed with an error) — status unknown |"
  elif [ "$has_launchd_unit" = "true" ] && [ "$in_grace_window" = "true" ]; then
    # Mode C: unit is loaded, but cron has not fired yet (before 06:30)
    echo "| Scheduler/triage | 🟡 | Mode C: unit loaded, waiting cron (06:00) — grace window before 06:30 |"
  elif [ "$has_launchd_unit" = "true" ] && { [ -n "$last_watchdog_log" ] || [ -n "$last_feedback_triage_log" ]; }; then
    # Mode B-2: a historical log proves deployment, not today's completion.
    local last_log_age_days=-1
    local last_log_file=""
    if [ -n "$last_feedback_triage_log" ]; then
      last_log_file="$last_feedback_triage_log"
    else
      last_log_file="$last_watchdog_log"
    fi
    if [ -n "$last_log_file" ]; then
      last_log_age_days=$(( ( $(date +%s) - $(stat -c %Y "$last_log_file" 2>/dev/null || stat -f %m "$last_log_file" 2>/dev/null || echo 0) ) / 86400 ))
    fi
    if [ "$last_log_age_days" -le 1 ] || [ "$last_log_age_days" -eq -1 ]; then
      echo "| Scheduler/triage | 🟡 | Mode B: feedback-triage registered, but for $DATE no confirmed completion; last log $last_log_file |"
    else
      echo "| Scheduler/triage | 🟡 | Mode B: feedback-triage registered, but log has not been updated ${last_log_age_days}d — possibly cron skipped |"
    fi
  elif [ "$has_launchd_unit" = "true" ] && [ -z "$last_watchdog_log" ] && [ -z "$last_feedback_triage_log" ]; then
    # issue #292 follow-up to #261: unit(s) scheduler units are registered (some-one
    # deployed roles on this machine), but NOT A SINGLE feedback-triage log feedback-triage has ever existed
    # NEVER (not only today/recently — ls -t empty across entire history). This is not
    # «cron did not run» (Mode A), this is «role feedback-triage is not deployed on
    # this installation» — absence of the role is not a failure, ⚪. True Mode A (cron
    # infra entirely absent) remains below, under has_launchd_unit=false.
    echo "| Scheduler/triage | ⚪ | role feedback-triage is not deployed on this machine (scheduler unit is present, triage logs have never existed) |"
  else
    # Mode A: cron is not running (no unit in launchctl) + no recent logs
    local last_log_age_days="∞"
    if [ -n "$last_feedback_triage_log" ]; then
      last_log_age_days=$(( ( $(date +%s) - $(stat -c %Y "$last_feedback_triage_log" 2>/dev/null || stat -f %m "$last_feedback_triage_log" 2>/dev/null || echo 0) ) / 86400 ))
    elif [ -n "$last_watchdog_log" ]; then
      last_log_age_days=$(( ( $(date +%s) - $(stat -c %Y "$last_watchdog_log" 2>/dev/null || stat -f %m "$last_watchdog_log" 2>/dev/null || echo 0) ) / 86400 ))
    fi
    # issue #347: the traffic-light row did not name the suppression method — the user found out
    # about the marker, only by reading the source of this script.
    # Absolute path, not a relative one: the absolute path is checked (see. incident_suppress
    # below), and a marker, created from a different directory, would land in the wrong place — suppression would not
    # have taken effect, and the incident would keep appearing every morning.
    local suppress_path="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/.incident-suppress-scheduler-cron-not-fired"
    echo "| Scheduler/triage | 🔴 | **Mode A** (the scheduler was deployed, but it is not running): last log ${last_log_age_days}d ago · suppress repeat: \`touch $suppress_path\` |"

    # issue #347: the incident was recommending macOS-tools on any OS. The branch is selected based on
    # which, which service manager is actually present on the machine.
    local launcher_hint unit_hint
    if command -v launchctl >/dev/null 2>&1; then
      launcher_hint="launchctl"
      unit_hint="~/Library/LaunchAgents/ (plist-files com.exocortex.*, com.strategist.*, com.extractor.*)"
    elif command -v systemctl >/dev/null 2>&1; then
      launcher_hint="systemctl --user"
      unit_hint="~/.config/systemd/user/ (timers iwe-*.timer; check — systemctl --user list-timers)"
    else
      launcher_hint="crontab"
      unit_hint="crontab -l (entries scheduler.sh / iwe-*)"
    fi

    # Auto-create incident-file if none exists for today AND not explicitly suppressed (issue
    # #292: the filename contains the date — [ ! -f incident_file ] never triggered
    # for «today is a different date» again, `status: deferred` in the file from the previous date
    # did not survive a date change. A separate marker without a date — survives.
    local incident_suppress="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/.incident-suppress-scheduler-cron-not-fired"
    local incident_file="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/INCIDENT-scheduler-cron-not-fired-$DATE.md"
    if [ -f "$incident_suppress" ]; then
      echo "  (incident suppressed: $incident_suppress — delete the file, to resume auto--creation)"
    elif [ "${DAY_OPEN_SCAFFOLD_READ_ONLY:-0}" = "1" ]; then
      echo "> ⚠️ Mode A: scheduler is not running. Local draft does not create an incident in governance: \`$incident_file\`. Check the scheduler before the Day Open."
    elif [ ! -f "$incident_file" ]; then
      mkdir -p "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox"
      cat > "$incident_file" <<INCEOF
---
type: incident
incident_id: INC-$DATE-scheduler-cron-not-fired
severity: critical
opened: $DATE
detected_by: day-open-scaffold.sh (auto Mode A)
mode: A (cron not running)
status: open
owner: pilot
related_wp: WP-7, WP-178, WP-356
auto_generated: true
---

# Incident: scheduler/feedback-watchdog not running ($DATE)

## Symptom (auto-detected)

- $launcher_hint: no scheduler unit is registered or active
- Evidence of a past deployment on this machine is present -- otherwise the line would be WP not deployed and this file would not have been created (issue #347) — otherwise the line would be ⚪ «not deployed», and this file would not have been created (issue #347)
- Latest log \`~/logs/synchronizer/scheduler-*.log\` older than 24h (or absent)
- Mode A classification (see. peer-session 2026-05-30-07 §Gap 3)

## Action items

1. Check $unit_hint
2. Reinstall roles: \`bash setup.sh\` (section [5/6]) — or manually via \`roles/ROLE-CONTRACT.md\`
3. Check manual launch of the central dispatcher: \`bash \${IWE_SCRIPTS:-$IWE/IWE/scripts}/../roles/synchronizer/scripts/scheduler.sh dispatch\`

## Auto-generation note

This file was created automatically day-open-scaffold.sh on every detection of Mode A — the file name contains the date, so tomorrows Mode A will create a NEW file with a new date regardless of, what you do with this one (editing frontmatter inside a dated file does not survive a date change — issue #292).

If you decide to postpone the fix and avoid receiving a new incident-file every day — create a marker:
\`\`\`bash
touch "$incident_suppress"
\`\`\`
Delete the marker, to resume auto-creation.
INCEOF
    fi
  fi

  # gate_log activity (Phase1 check)
  local gate_log="$IWE/.claude/logs/gate_log.jsonl"
  if [ -f "$gate_log" ]; then
    local recent
    recent=$(awk -v d="$DATE" '$0 ~ d' "$gate_log" 2>/dev/null | wc -l | tr -d ' ')
    echo "| gate_log | 🟢 | $recent entries for $DATE |"
  else
    echo "| gate_log | 🟡 | $gate_log not found |"
  fi

  # active-wp freshness
  if [ "${MEMORY_PF:-unknown}" = "ok" ]; then
    echo "| active-wp | 🟢 | up to date (<7 days) |"
  elif [ "${MEMORY_PF:-unknown}" = "stale" ]; then
    echo "| active-wp | 🟡 | outdated (>7 days) — update via build-active-wp.py |"
  else
    echo "| active-wp | ⚪ | status undetermined |"
  fi

  # update.sh check (FMT)
  # issue #241 (residual gap): the call performs a network ls-remote/fetch internally —
  # without a time-box the same class of hang on WSL2 reproduces even after
  # fix a3d0b95 (that fix addressed only gh issue list below in the heredoc).
  # issue #278: full --check without --fast compares 500+ files line by line —
  # definitively does not fit within the time-box, the update is silently lost as "checked".
  # --fast (issue #230) compares only the manifest version — one second instead of minutes.
  if [ -d "$IWE/IWE" ]; then
    # issue #406: three defects here previously combined into an evergreen line —
    # (1) the emoji was hardcoded 🟢 without branching; (2) update.sh since then (issue #230/
    # #288) returns 5 different wordings with prefix ✓/⚠ — the old grep on grep on
    # literal "Version matches"/"Version differs" did not cover either the branch
    # «composition changed», nor the current success wording («…match», not
    # «matches»), and on an empty match silently fell through to 🟢; (3) section
    # «Needs Attention» collects only 🟡/🔴 lines — since this line could not
    # become non-green, an available update never appeared there. Emoji
    # is now determined from the first character of the actual output (✓ → 🟢, ⚠ → 🟡),
    # and is not guessed in advance.
    local upd_output upd_emoji upd_status
    upd_output=$(run_bounded "${ISSUE_SWEEP_TIMEOUT:-10}" bash -c \
      "cd '$IWE/IWE' && bash update.sh --check --fast 2>&1")
    upd_status=$(printf '%s\n' "$upd_output" | grep -E '^[✓⚠]' | head -1)
    case "$upd_status" in
        ✓*) upd_emoji="🟢" ;;
        ⚠*) upd_emoji="🟡" ;;
        *) upd_emoji="🟡"; upd_status="${upd_status:-could not determine status (time-out or empty output update.sh --check --fast)}" ;;
    esac
    echo "| Update IWE | $upd_emoji | ${upd_status} |"
  fi

  # Base repos (FPF/SPF/ZP) — fetch + behind count
  for repo in FPF SPF ZP; do
    local d="$IWE/$repo"
    if [ -d "$d/.git" ]; then
      run_bounded "${ISSUE_SWEEP_TIMEOUT:-10}" git -C "$d" fetch --quiet >/dev/null 2>&1
      local behind
      behind=$(git -C "$d" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
      if [ "$behind" -gt 0 ]; then
        echo "| $repo | 🟡 | $behind new commits upstream |"
      else
        echo "| $repo | 🟢 | up to date |"
      fi
    fi
  done
}

# --- Section: Scout (link to report) ---
render_scout() {
  local scout_dir="$IWE/DS-agent-workspace/scout/results/$YEAR/$MM/$DD"
  if [ -d "$scout_dir" ]; then
    local findings=0 captures=0
    [ -f "$scout_dir/report.md" ] && findings=$(grep -c '^### ' "$scout_dir/report.md" 2>/dev/null || echo 0)
    [ -f "$scout_dir/capture-candidates.md" ] && captures=$(grep -c '^### ' "$scout_dir/capture-candidates.md" 2>/dev/null || echo 0)
    echo "> Report for $DAY_NUM $MONTH_RU — $findings findings, $captures capture-candidates"
    echo "> **Review status:** ⬜ not reviewed"
    echo
    echo "Path: \`$scout_dir/\`"
  else
    echo "> No report for $DATE — Scout did not run or has not finished yet"
    echo "> **Review status:** — (no findings)"
  fi
}

# --- Section: Fleeting-notes parsing (fleeting-notes) ---
# Parses inbox/fleeting-notes.md for notes, awaiting a pilot decision: lines **Title**
# (new) and notes marked with ✅proposed in the first line (the agent wrote a proposal, decision
# is up to the pilot; the model may have dropped bold formatting or appended a trailing fragment, #961). Deferred 🔄 do not count.
# If empty → "no notes" without the marker PENDING → LLM does not touch the section.
# If present → table rows with real headings and PENDING for PENDING for Type/Proposal.
# Bold **text** in GitHub does not create anchors — links without #anchor.
render_fleeting_notes() {
  local notes_file="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/fleeting-notes.md"

  # One decision with the safety net (cleanup-processed-notes.py should_keep) and the canary (strategist.sh
  # count_new_bold_notes): the mark "✅proposed" counts in the FIRST line of a note (the line after a --- rule),
  # with or without bold, wherever it stands in that line. A first line that is a quote, a heading, a timestamp, a
  # struck-through note (~~) or a list item is no note title. A bold title alone on a line (**Title**), or followed
  # by the mark, is taken wherever it stands (the legacy rule): a bold line inside a note body is listed, and counted
  # by the canary, too; the safety net looks at the first line only. The printed title has the mark and 🔄 cut out;
  # a title without them stays as typed, and a line with nothing but the mark keeps it so that the row has a name.
  # awk, not grep -i / tolower: Cyrillic case folding depends on the locale, so the mark is spelled out in
  # (p|P) pairs; the no-break space is spelled in octal because [[:space:]] does not cover it in every locale.
  local new_notes
  new_notes=$(awk '
    # the title without the mark and without 🔄; as typed when it has neither, whole when nothing else is left
    function clean(t,   c) {
      c = t
      gsub("[[:space:]]*" mark, "", c)
      gsub(/[[:space:]]*🔄/, "", c)
      if (c == t) return t
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", c)
      return (c == "") ? t : c
    }
    BEGIN {
      mark = "✅([[:space:]]|\302\240)*(p|P)(r|R)(e|E)(d|D)(l|L)(o|O)(zh|Zh)(e|E)(n|N)(o|O)"
      bold = "^[*][*][^*]+[*][*][[:space:]]*(" mark ".*)?$"
      no_title = "^([>#<]|~~|[-+*][[:space:]]|[0-9]+[.)][[:space:]])"
      first = 1
    }
    { sub(/\r$/, "") }
    /^---[[:space:]]*$/ { first = 1; next }
    /^[[:space:]]*$/ { next }
    {
      starts_block = first
      first = 0
      title = ""
      if ($0 ~ bold) {
        title = $0
        sub(/^[*][*]/, "", title)
        sub("[*][*][[:space:]]*(" mark ".*)?$", "", title)
      } else if (starts_block) {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        if (line ~ mark && line !~ no_title) {
          title = line
          sub(mark ".*$", "", title)
          gsub(/[*][*]/, "", title)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", title)
          if (title == "") {
            title = line
            gsub(/[*][*]/, "", title)
          }
        }
      }
      if (title != "") print clean(title)
    }
  ' "$notes_file" 2>/dev/null)

  if [ -z "$new_notes" ]; then
    printf '| no notes | — | — | ✅ |\n'
  else
    while IFS= read -r title; do
      # Link to file without anchor — bold text has no GitHub markdown anchor
      printf '| [«%s»](../inbox/fleeting-notes.md) | <!-- PENDING --> | <!-- PENDING --> | [ ] |\n' "$title"
    done <<< "$new_notes"
  fi
}

# --- Section: Gate-metrics (WP-423 Phase6.4) ---
render_gate_metrics() {
  local script="$TEMPLATE_SCRIPTS_DIR/gate-metrics.sh"
  local log="${HOME}/.iwe/gate-decisions.jsonl"
  echo "<details>"
  echo "<summary><b>Gate-metrics</b></summary>"
  echo ""
  if [ ! -f "$script" ]; then
    echo "> ⚠️ Script gate-metrics.sh not found: \`$script\`"
  elif [ ! -f "$log" ]; then
    echo "> Log gate-decisions log not found: \`$log\`"
    echo "> Run \`iwe-agent-dispatcher.py\` or \`overnight-auditor.sh\`, so that data appears."
  else
    bash "$script" "$log" "$DATE" 2>/dev/null || echo "> ⚠️ gate-metrics.sh exited with an error"
  fi
  echo ""
  echo "</details>"
}

# --- Section: KE-queue (reports pending review) ---
# Counts extraction-reports with status: pending-review. Anchor '^status:' is required:
# without it grep catches status mentions inside report bodies (cross-batch ID awareness, bug-files)
# and inflates the count. Outputs FILE NAMES, not just the count — self-check for the operator.
# SLA for review — ≤24h (DP.SC.004). Replaced manual <!-- PENDING -->, where 10.06.2026
# a false «0 pending-review» while a report was actually pending (bug-2026-06-10-ke-queue-drift).
render_ke_candidates() {
  local dir="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/extraction-reports"
  local files
  files=$(grep -l -- '^status:[[:space:]]*pending-review' "$dir"/*.md 2>/dev/null)
  if [ -z "$files" ]; then
    echo "> Queue is clear — 0 reports are pending review."
    return
  fi
  local count
  count=$(printf '%s\n' "$files" | grep -c . )
  echo "> **$count pending review** (SLA ≤24h, DP.SC.004) → run /apply-captures"
  echo
  printf '%s\n' "$files" | while read -r f; do
    [ -n "$f" ] && echo "- \`$(basename "$f")\`"
  done
}

# --- Section: Content-cleanup backlog (WP-376 surfacing into the plan) ---
# Lists open knowledge-base cleanup signals so the pilot triages them in the plan.
# Open signal = <summary> starts with "CC-NNN" (no leading ~~ strikethrough) and
# carries no checkmark marker. Mirrors render_ke_candidates: graceful skip if absent.
render_content_cleanup() {
  local file="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/current/content-cleanup-backlog.md"
  if [ ! -f "$file" ]; then
    echo "> Knowledge base cleanup signal registry is not configured."
    return
  fi
  # Only CC-entries before the first "## Archive"/"## Resolved" heading are open --
  # resolved entries move under those headings but their <summary> line itself never
  # gets a ✅ marker (only a prose note in "## Metrics"), so filtering on ✅ alone
  # kept surfacing months-old closed signals as "N for review" (found 2026-07-28: CC-103,
  # closed 2026-06-14, still showed up because its heading had no ✅).
  local open
  open=$(awk '/^## (Archive|Resolved)/{exit} {print}' "$file" \
    | grep -E '<summary><strong>CC-[0-9]' || true)
  if [ -z "$open" ]; then
    echo "> Resolved — no open signals."
    return
  fi
  local count
  count=$(printf '%s\n' "$open" | grep -c .)
  echo "> **$count for review** → open the registry and decide on each signal."
  echo
  printf '%s\n' "$open" \
    | sed -E 's#.*<summary><strong>##; s#</strong></summary>.*##' \
    | while read -r title; do
        [ -n "$title" ] && echo "- $title"
      done
  echo
  echo "Registry: \`${IWE_GOVERNANCE_REPO:-DS-strategy}/current/content-cleanup-backlog.md\`"
}

# --- Section: Requires attention (bug 2026-07-15: PENDING synthesis had no source data) ---
# day-open-llm-fill.py fills PENDING chunks in per-section isolation (see its header
# comment) — a chunk never sees any other section's rendered text. This section's old
# PENDING comment asked the model to "collect from steps 1-6", which it structurally
# could not do, so it paraphrased the instruction itself instead of real findings.
# Every check below only reads facts this script already computed elsewhere — no
# synthesis, so no LLM call, matching the file's own "Enforcement requires an observer
# outside the subject" principle at the top of this file.
render_attention() {
  local items=()

  # Carry-over WP explicitly deferred (not folded into today's plan) — extract_day_close_carry_over
  # marks these with "(deferred" (see render output in current/DayPlan for the exact wording).
  if printf '%s' "${DAY_CLOSE_CARRY_OVER:-}" | grep -q '(deferred'; then
    local deferred_count
    deferred_count=$(printf '%s' "$DAY_CLOSE_CARRY_OVER" | grep -c '(deferred')
    items+=("carry-over: $deferred_count WPs from yesterdays Day Close were deferred and did not make it into todays plan — decide, whether to take them")
  fi

  # IWE-traffic-light: any row 🟡/🔴 in the already-rendered table (Scout, Scheduler/triage,
  # Update IWE, FPF/SPF/ZP etc..) — the table itself already carries the specifics, we simply quote it.
  local status_row
  while IFS= read -r status_row; do
    [ -z "$status_row" ] && continue
    items+=("traffic-light: ${status_row}")
  done < <(printf '%s\n' "${IWE_STATUS_TABLE:-}" | grep -E '🟡|🔴' | sed -E 's/^\| *//; s/ *\|$//; s/ *\| */: /g')

  # World without links — we check the already-rendered section directly, without a second PENDING.
  # Explicit «disabled»/«config broken» already visible in the section itself «World» — we do not duplicate it.
  if ! printf '%s' "${WORLD_SECTION:-}" | grep -q 'news.enabled: false\|could not be parsed'; then
    if ! printf '%s' "${WORLD_SECTION:-}" | grep -q '](http'; then
      items+=("World: section has no source links at all — fill in manually")
    fi
  fi

  # KE-SLA: oldest ≥3 days — 🔴, not 🟡 (peer-consensus 2026-05-30-07, see. day-open/SKILL.md).
  local smoke_script="$TEMPLATE_SCRIPTS_DIR/day-open-smoke.sh"
  if [ -f "$smoke_script" ]; then
    local ke_oldest
    ke_oldest=$(bash "$smoke_script" 2>/dev/null | jq -r '.ke_oldest_days // empty' 2>/dev/null)
    if [[ "$ke_oldest" =~ ^[0-9]+$ ]] && [ "$ke_oldest" -ge 3 ]; then
      items+=("🔴 knowledge-entry queue (KE) is growing ${ke_oldest} d. in a row (SLA ≤24h) — process via /apply-captures")
    fi
  fi

  # Org-signals R31 — only rows with status ⚠, everything else (✅) not a pilot signal.
  local orgdev_file="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/current/orgdev-signals.md"
  if [ -f "$orgdev_file" ]; then
    local warn_row
    while IFS= read -r warn_row; do
      [ -z "$warn_row" ] && continue
      items+=("org-signal (R31): ${warn_row}")
    done < <(grep -E '^\|.*⚠' "$orgdev_file" | sed -E 's/^\| *[0-9]+ *\| *//; s/ *\|$//; s/ *\| */: /g')
  fi

  if [ "${#items[@]}" -eq 0 ]; then
    echo "— no signals, requiring attention."
    return
  fi
  local item
  for item in "${items[@]}"; do
    echo "- $item"
  done
}

# --- Section: Yesterday summary (commits stats + sessions) ---
render_yesterday() {
  local total=0 repos=0 window YDAY_SINCE YDAY_UNTIL
  window=$(iwe_day_window "$YDAY" "$DATE" "$DAY_BOUNDARY")
  YDAY_SINCE=${window%%|*}
  YDAY_UNTIL=${window##*|}
  while IFS= read -r repo; do
    local n
    n=$(git -C "$repo" log --since="$YDAY_SINCE" --until="$YDAY_UNTIL" --oneline 2>/dev/null | wc -l | tr -d ' ')
    if [ "$n" -gt 0 ]; then
      total=$((total + n))
      repos=$((repos + 1))
    fi
  done < <(iwe_repo_dirs "$IWE"/*/)
  # "WP closed" needs a real Day Close as its source. If yesterday's close isn't
  # committed, the LLM has no ground truth and invents a count (2026-07-01: "10 closed"
  # was pure hallucination). Detect the close deterministically; only defer to the LLM
  # when it exists. The pipeline's race guard normally prevents this path, but --force
  # runs can still reach it.
  # If the governance repo is missing, the `cd` fails silently and empties dc_committed
  # regardless of the grep below (bug 2026-07-02) — the else-branch then reports
  # "no data" honestly instead of letting the LLM invent a count.
  local dc_committed
  dc_committed=$(cd "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}" && git log --since="$YDAY_SINCE" -i \
    --grep="day-close.*$YDAY" --format=%H 2>/dev/null | head -1)
  # issue #929: same criterion as the pipeline race guard and extract_day_close_carry_over —
  # yesterday's archived DayPlan with the close sections. The commit-message wording is
  # not specified by the day-close protocol, so the grep above is only a secondary signal.
  if [ -z "$dc_committed" ]; then
    local yday_plan="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/archive/day-plans/DayPlan ${YDAY}.md"
    if [ -f "$yday_plan" ] && grep -qE '<summary><b>Day summary</b></summary>|^### Start tomorrow with' "$yday_plan"; then
      dc_committed="archived-plan"
    fi
  fi
  if [ -n "$dc_committed" ]; then
    echo "**Commits:** $total in $repos repos | **WP closed:** <!-- PENDING: count from Day Close report for $YDAY -->"
  else
    echo "**Commits:** $total in $repos repos | **WP closed:** no data (Day Close for $YDAY not found)"
  fi
  echo
  # Extension point: custom hook for additional status signals (e.g.. sleep/heart rate
  # resting). L1 does not know, what exactly the hook prints hook — all logic is in extensions/, which
  # template users without their own extension-extension file will simply not have it.
  if [ -x "$IWE/extensions/day-open.summary-extra.sh" ]; then
    local extra_summary
    if ! extra_summary=$("$IWE/extensions/day-open.summary-extra.sh" "$YDAY"); then
      echo "day-open: extension day-open.summary-extra.sh failed; continuing without its output" >&2
      extra_summary=""
    fi
    [ -n "$extra_summary" ] && { echo "$extra_summary"; echo; }
  fi
  # Sessions consolidation (DAP1-B/1-C, WP-7): include WP sessions from yesterday
  local day_report_file="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/current/DayReport-${YDAY}.md"
  if [ -f "$day_report_file" ]; then
    grep "^| " "$day_report_file" | grep -v "^| WP\|^| Time\|^|---" | sed 's/^/- /'
  else
    # Fallback: scan sessions directly for yesterday if DayReport is absent
    # issue #545: see. extract_day_close_carry_over — journal root per
    # writer contract (MC-sessions / legacy), broken explicit
    # IWE_SESSIONS_ROOT — visible WARN.
    local sessions_dir
    if ! sessions_dir=$(iwe_sessions_dir); then
      echo "WARN: IWE_SESSIONS_ROOT=${IWE_SESSIONS_ROOT:-} unavailable — reading legacy-path $(iwe_resolve_governance_repo "${GOVERNANCE_REPO:-}")/sessions" >&2
      sessions_dir="$IWE/$(iwe_resolve_governance_repo "${GOVERNANCE_REPO:-}")/sessions"
    fi
    local found=0
    # WP-529 (continuation, 19.08): resolved once here, not inside the loop —
    # this whole branch only runs when DayReport is missing (rare fallback), and
    # resolving once before iterating avoids re-running find-python3.sh's full
    # candidate walk on every session_dir.
    local _resolved_python3
    _resolved_python3=$("$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/find-python3.sh" 2>/dev/null) || _resolved_python3=""
    for session_dir in "$sessions_dir/${YDAY:0:7}"/${YDAY}-*/; do
      [ -d "$session_dir" ] || continue
      if [ -f "$session_dir/meta.yaml" ] && [ -n "$_resolved_python3" ]; then
        local wp_id
        wp_id=$("$_resolved_python3" -c "import yaml; d=yaml.safe_load(open('$session_dir/meta.yaml')); print(d.get('task_id','') or '')" 2>/dev/null)
        if [ -n "$wp_id" ]; then
          echo "- $wp_id"
          found=1
        fi
      fi
    done
    if [ "$found" = "0" ]; then
      echo "_No sessions for yesterday_"
    fi
  fi
  echo
  if [ -n "$dc_committed" ]; then
    echo "<!-- PENDING: key — 1-3 significant results from yesterday (requires synthesis from commits) -->"
  else
    echo "_Key highlights will appear after Day Close for $YDAY._"
  fi
}

# --- Section: Compact Dashboard (WP-7 Block DOC) ---
# Output goes to stdout AFTER EOF-block DayPlan via marker ---COMPACT-DASHBOARD---
# Read by agent/pilot as the daily summary; does not go into DayPlan-file.
# INVARIANT: scaffold does NOT populate the top-7 WPs-7 WP — plan is still empty (PENDING).
# Top-7 builds day-open-llm-fill.py from the completed section «Plan for today»
# (function rebuild_compact_dashboard, WP-5 Phase 2026-06-11 P1).
render_compact_dashboard() {
  echo ""
  echo "---COMPACT-DASHBOARD---"
  echo "## Compact Dashboard — $DAY_NUM $MONTH_RU $YEAR ($DOW_RU)"
  echo ""

  # Placeholder for top-7 — will be replaced by LLM-fill after the plan is populated.
  # If you see this line in the final file — it means LLM-fill did not run
  # or rebuild_compact_dashboard did not execute (bug-2026-06-11).
  echo "**Today (top-7 by priority):** <!-- filled by day-open-llm-fill.py from 'Plan for today' -->"
  echo ""

  # Deadlines from calendar (if preflight OK); disabled (calendar_source: none,
  # issue #942) — the line is absent entirely, this is not an incomplete configuration
  if [[ "$CALENDAR_PF" == "ok" ]]; then
    echo "**Calendar:** available — run server-calendar.sh for details"
    echo ""
  elif [[ "$CALENDAR_PF" != "disabled" ]]; then
    echo "**Calendar:** unavailable (${CALENDAR_PF})"
    echo ""
  fi

  # Traffic light — critical items
  echo "**IWE overnight:**"
  # WP-5 Ubuntu-audit actual #4: this used the same pre-#261 legacy label regex as
  # the OTHER launchctl check in this file (fixed above) — AND was unconditional
  # launchctl, so Linux always read 🔴 regardless of the actual systemd timers.
  # issue #347: this line used to collapse every non-active result into 🔴, including
  # "never deployed here" and "the check itself failed" — the same conflation the
  # traffic-light row above carried. Both call sites now read the same four states.
  local short_state short_label
  short_state="$(iwe_scheduler_state)"
  case "$short_state" in
    active)            short_label="🟢" ;;
    deployed_inactive) short_label="🔴 not running" ;;
    not_deployed)      short_label="⚪ not deployed on this machine" ;;
    *)                 short_label="🟡 state unknown" ;;
  esac
  echo "  Scheduler: $short_label"
  local fpf_status fpf_fetch_ok
  # issue #241 (residual gap): the same unprotected git fetch, the same class of hang.
  # run_bounded does not propagate exit-code — the result is passed via a marker in stdout.
  fpf_fetch_ok=$([ -d "$IWE/FPF/.git" ] && run_bounded "${ISSUE_SWEEP_TIMEOUT:-10}" \
    bash -c "git -C '$IWE/FPF' fetch --quiet 2>/dev/null && echo ok")
  if [ "$fpf_fetch_ok" = "ok" ]; then
    local behind; behind=$(git -C "$IWE/FPF" rev-list --count HEAD..origin/main 2>/dev/null || echo "?")
    fpf_status=$( [ "$behind" = "0" ] && echo "🟢" || echo "🟡 new: $behind" )
  else
    fpf_status="⚪ unavailable"
  fi
  echo "  FPF upstream: $fpf_status"
  echo ""
  echo "---END-COMPACT-DASHBOARD---"
}

# --- Section: Self-Development (active draft, deterministic) ---
# The active draft comes from the first entry in the "Priority" table, not the LLM.
# The template's full collection has a status column but does not define an "draft"
# value, while the priority table is the explicit current-work list. "Where I left off"
# is the pilot's own progress — we never fabricate it (see feedback_no_invented_personal_history).
# Sets globals SELF_DEV_BLOCK (details-section body) and SELF_DEV_TABLE_THEME
# (short table-row cell, issue #636) from the same source in one pass. A plain
# `echo`-per-line function called via `SELF_DEV_BLOCK=$(render_self_dev)` would
# run in a subshell, discarding any other global it tries to set — so this
# builds SELF_DEV_BLOCK as a string instead of relying on captured stdout.
render_self_dev() {
  local draft_list="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/drafts/draft-list.md"
  if [ ! -f "$draft_list" ]; then
    SELF_DEV_TABLE_THEME="topic not set — discuss with pilot (drafts/draft-list.md not found)"
    SELF_DEV_BLOCK="**Active draft:** no data (drafts/draft-list.md not found)"
    return
  fi
  # Take the first data row from the template-defined "Priority" table.
  local row
  row=$(awk '
    /^## Priority/ { in_priorities = 1; next }
    in_priorities && /^## / { exit }
    in_priorities && /^\|/ {
      if ($0 ~ /^\|[[:space:]]*#/) next
      if ($0 ~ /^\|[[:space:]]*-+/) next
      # Skip finished rows: the priority table is ordered by draft number, so
      # old published entries sit on top; taking the first row regardless of
      # status resurfaced a May publication as "active" (#560, regression of #417).
      if ($0 ~ /✅|published|published/) next
      print
      exit
    }' "$draft_list")
  if [ -z "$row" ]; then
    SELF_DEV_TABLE_THEME="topic not set — discuss with pilot (no active drafts)"
    SELF_DEV_BLOCK="**Active draft:** no active drafts (priority list is empty or all items are completed)"
    return
  fi
  local dnum path
  dnum=$(echo "$row" | grep -oE 'D-[0-9]+' | head -1)
  path=$(echo "$row" | grep -oE '\([^)]*D-[0-9][^)]*\.md\)' | head -1 | tr -d '()' | sed 's#^\./#drafts/#')
  SELF_DEV_TABLE_THEME="$dnum"
  local draft_line
  if [ -n "$path" ]; then
    draft_line="**Active draft:** [$dnum]($path)"
  else
    draft_line="**Active draft:** $dnum (link could not be parsed in draft-list.md)"
  fi
  SELF_DEV_BLOCK="$draft_line
**Where I left off:** open the draft file — progress is tracked by the pilot.
**Today:** 60-90 min for editing / structuring."
}
# issue #636: table-row theme (SELF_DEV_TABLE_THEME) is deterministic, same
# source as the details block — a scaffold with no real draft used to leave a
# bare [topic] placeholder that the LLM filled in on its own, and the invented
# topic then carried over via Day Close carry-over for weeks
# (feedback_no_invented_personal_history). Called directly, not via `$(...)`,
# so both globals land in this shell rather than a discarded subshell.
SELF_DEV_TABLE_THEME=""
SELF_DEV_BLOCK=""
render_self_dev

# --- Pre-compute sweep list (single call, reused below) ---
# SWEEP_WP_FULL: raw active-wp-sweep.sh output, kept only as input to SWEEP_WP_LIST below.
# WP-7 DOSCAF1 (2026-07-04): no longer feeds an "Active WPs" DayPlan section — that
# section was removed as a duplicate of current/priorities.yaml + current/active-wp.md.
# SWEEP_WP_LIST: WP-NNN IDs for the "Plan for today" PENDING instructions (line ~973) —
# tells the LLM which open WPs beyond priorities.yaml to consider for today's plan.
SWEEP_WP_FULL=$(bash "$IWE/scripts/active-wp-sweep.sh" "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox" "$IWE" 2>/dev/null \
  || echo "<!-- active-wp-sweep: startup error -->")
SWEEP_WP_LIST=$(echo "$SWEEP_WP_FULL" \
  | grep -oE '\*\*WP-[0-9]+\*\*' | tr -d '*' | tr '\n' ' ' | sed 's/  */ /g' || true)

# --- Deterministic context injection (WP-7 DAP) ---
DAY_CLOSE_CARRY_OVER=$(extract_day_close_carry_over "$YDAY" | sed 's/^/  /')
STRATEGY_CONTEXT=$(extract_strategy_context "$WEEK_NUM" | sed 's/^/  /')
MORNING_PRIORITIES=$(read_morning_priorities | sed 's/^/  /')
MANDATORY_DAILY_WPS=$(extract_mandatory_daily_wps 2>/dev/null)

# Captured once (not inlined via $(...) in the heredoc below) so render_attention()
# can read the same rendered text later without re-running server-news.sh a second
# time and without needing render_iwe_status's internal checks duplicated.
IWE_STATUS_TABLE=$(render_iwe_status)
WORLD_SECTION=$(render_world)

# --- Output ---
# issue #496: heading style (details vs markdown) is a per-installation choice,
# not a format migration — the validator already accepts both, so this only
# changes what the generator prints, read from params.yaml.
HEADING_STYLE=$(iwe_heading_style "$PARAMS_FILE")
cat <<EOF | iwe_render_heading_style "$HEADING_STYLE"
---
type: daily-plan
date: $DATE
week: W$WEEK_NUM
status: active
agent: Strategist
generated_by: day-open-scaffold.sh (WP-264 Phase2)
---

# Day Plan: $DAY_NUM $MONTH_RU $YEAR ($DOW_RU)

<!-- URGENT (TIS=U): output ONLY when 🔴 (failed smoke / broken integration / EMERGENCY in priorities.yaml / blocked pipeline). On a green day — «no urgent items». -->
<details>
<summary><b>🚨 Urgent</b></summary>

<!-- PENDING: urgent — if in «Platform Health» contains 🔴 OR in priorities.yaml flag EMERGENCY: table | What | System | Action | ETA |. Otherwise one line: «— no urgent items (green day)». -->

</details>

<details>
<summary><b>Self-development</b></summary>

- **Review the personal guide:** personal guide (repository \`DS-personal-guide\`, or \`personal-guide\` for early non-migrated users — see. \`/connect-guide\`)

$SELF_DEV_BLOCK

</details>

<details open>
<summary><b>Plan for today</b></summary>

<!-- PENDING: today_plan — synthesis of the day plan table.

AUTHORITATIVE SOURCE OF ORDER: «Morning priorities (priorities.yaml)» below.
RULE: EVERY WP from priorities.yaml MUST be in the table — in the same order (first = topmost row).
EXCEPTION: A WP may be omitted only if its status in inbox/WP-NNN.md is explicitly equal to 'done' or 'closed' (or it is marked ✅ in WP-REGISTRY with strikethrough). Before excluding — verify.
PITFALL: «Phase1-Phase3 ✅ closed yesterday» does NOT mean, that the entire WP is closed. Phase ≠ WP. Check status in inbox/WP-NNN.md.
FORBIDDEN: to include in the plan WPs, closed yesterday (present in «closed yesterday» + ✅ in REGISTRY). For example, WP-362 is closed — it is not in the plan.

After priorities.yaml — supplement from carry-over and SWEEP_WP_LIST those WPs, that are not in priorities.yaml and that are still open.
Every WP from «Mandatory daily WPs» below (if the section is not empty) MUST be in the table — the source is already resolved deterministically, not by config text.
KE-row: bash $TEMPLATE_SCRIPTS_DIR/ke-queue-stats.sh --dayplan-row (real budget, not the literal «1h»).
Active WPs to include (from sweep + WeekPlan union): $SWEEP_WP_LIST
-->

**Morning priorities (priorities.yaml):**
${MORNING_PRIORITIES:-  (not set — update current/priorities.yaml)}

**Strategic priorities (from Strategy Session W${WEEK_NUM}):**
${STRATEGY_CONTEXT:-not found}

**Mandatory daily WPs (mandatory_daily_wps):**
${MANDATORY_DAILY_WPS:-  (not set — day-rhythm-config.yaml does not contain an active key mandatory_daily_wps)}

| 🚦 | TVS | # | WP | h | Status |
|----|-----|---|-----|---|--------|
| ⚫ | I | N | **Self-development** — $SELF_DEV_TABLE_THEME | 1-2 | pending |
| 🔴 | U | NNN | **<!-- PENDING -->** | X | pending |

> IUC: **I** = Important (development / critical for R1-R6) · **C** = Current (planned work) · **U** = Urgent (pipeline blocker, duplicated in header 🚨)

**Day budget:** $BUDGET_FORMAT_HINT

**Mandatory check:** WP-7 (bot tech debt, ≥30 min) + ≥1 content WP — <!-- PENDING: verify presence in plan -->

**Carry-over from Day Close yesterday ($YDAY):**
${DAY_CLOSE_CARRY_OVER:-none (Day Close not found)}

</details>

<details>
<summary><b>Notes review</b></summary>

<!-- Source: inbox/fleeting-notes.md. The list contains notes, awaiting pilot decision: bold (**Title**, not yet reviewed) and marked ✅proposed (proposal recorded, decision is up to the pilot; bold formatting may have been lost). Deferred 🔄 do not count. Links without an anchor — bold do not create GitHub-anchors. -->

| Note | Type | Proposal | ✅ |
|---------|-----|-------------|---|
$(render_fleeting_notes)

</details>

$(render_calendar_section)
<details>
<summary><b>Platform health (QA)</b></summary>

$(render_bot_qa)

**IWE overnight (traffic light):**

$IWE_STATUS_TABLE

**New issues in repositories (over the last 2 days):**

$(render_repo_issues)

**Activity by repository (over the last 2 days, including IWE Template IWE):**

$(render_repo_activity)

</details>

<details>
<summary><b>Agent outputs</b></summary>

<details>
<summary><b>Overnight reports</b></summary>

$(render_scout)

</details>

<details>
<summary><b>📚 KE-candidates (Knowledge Extraction)</b></summary>

$(render_ke_candidates)

</details>

$(render_gate_metrics)

<details>
<summary><b>Author knowledge base cleanup</b></summary>

$(render_content_cleanup)

</details>

</details>

<details>
<summary><b>Content-plan</b></summary>

**Strategy:** <!-- PENDING: 1 line from Strategy.md (example: club → Telegram → Zen/Habr, N posts/wk) -->
**TTL overdue:** <!-- PENDING: D-NNN (expired YYYY-MM-DD), ... or «no overdue items» -->
**TTL soon:** <!-- PENDING: D-NNN (expires YYYY-MM-DD, in N days), ... or «none» -->

<!-- PENDING: content — table 1-3 topics from the publication plan W{N}. Source: WeekPlan or Strategy.md. -->

</details>

$WORLD_SECTION

<details>
<summary><b>Week context (W$WEEK_NUM)</b></summary>

<!-- PENDING: bottleneck-week — run /bottleneck-pick --target weekplan --layer intra --horizon week --depth 1 and insert 4-6 lines as the FIRST subsection: SC-failing, Bottleneck, Class (Policy/Resource/Cognitive), Stage 1, Signal. Source: extensions/day-open.after.md:158-191 -->

**Week bottleneck (SC-first, $DATE):** <!-- PENDING -->

<!-- PENDING: week_context — week focus + current budget/multiplier + TOC. Source: ${IWE_GOVERNANCE_REPO:-DS-strategy}/current/WeekPlan W$WEEK_NUM*.md. -->

</details>

<details>
<summary><b>Yesterday summary ($YDAY_NUM $YDAY_MONTH_RU)</b></summary>

$(render_yesterday)

</details>

<details>
<summary><b>Pomodoros/rhythm</b></summary>

$(render_pomodoro)

</details>

<details>
<summary><b>Video</b></summary>

$(render_video)

</details>

<details>
<summary><b>Requires attention</b></summary>

$(render_attention)

</details>

*Created: $DATE (Day Open / day-open-scaffold.sh WP-264 Phase2)*
EOF
