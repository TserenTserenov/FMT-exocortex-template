#!/bin/bash
# day-open-smoke.sh — core smoke для Day Open (≤10с)
# see: peer-сессия 2026-05-30-07-gap-list-day-open подэтап 2
# see: WP-356 «Pipeline Day Open: auto-run checks»
#
# Назначение: быстрая проверка здоровья ключевых подсистем для светофора DayPlan.
# Только быстрые операции (≤2с каждая, суммарно ≤10с).
# Расширенные проверки → day-open-smoke-extended.sh (hourly cron + кэш).
#
# Вывод: JSON в stdout, одна строка с полями:
#   scheduler_pulse: "ok" | "stale:<days>d" | "missing"
#   ke_count: <int>
#   ke_oldest_days: <int>
#   elapsed_sec: <float>
#
# Использование:
#   bash day-open-smoke.sh
#   bash day-open-smoke.sh --human   # формат для светофора DayPlan
#
# Зависимости:
#   - python3 (для JSON)
#   - ~/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/extraction-reports/ (для KE-count)
#   - ~/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/current/.scheduler-last-run (primary scheduler pulse)
#
# Failure mode: любая проверка возвращает sentinel ("missing" / -1), не падает.

set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

START_TS=$(date +%s)
HUMAN_MODE=false
[ "${1:-}" = "--human" ] && HUMAN_MODE=true

IWE_BASE="${IWE_BASE:-$HOME/IWE}"
DS_STRATEGY="$IWE_BASE/${IWE_GOVERNANCE_REPO:-DS-strategy}"

# === 1. Scheduler pulse (primary: локальный файл, fallback: статус launchctl) ===
scheduler_pulse() {
  local pulse_file="$DS_STRATEGY/current/.scheduler-last-run"
  if [ -f "$pulse_file" ]; then
    local last_ts
    last_ts=$(stat -f %m "$pulse_file" 2>/dev/null || stat -c %Y "$pulse_file" 2>/dev/null || echo 0)
    local now_ts age_hours
    now_ts=$(date +%s)
    age_hours=$(( (now_ts - last_ts) / 3600 ))
    if [ "$age_hours" -lt 26 ]; then
      echo "ok"
    elif [ "$age_hours" -lt 168 ]; then
      echo "stale:$(( age_hours / 24 ))d"
    else
      echo "stale:$(( age_hours / 24 ))d"
    fi
  else
    # Fallback: launchd (macOS) / systemd --user (Linux) via iwe_scheduler_active
    # (lib/common.sh) — WP-5 Ubuntu-audit факт #4: the bare launchctl call always
    # read "missing" on Linux.
    if iwe_scheduler_active; then
      echo "registered-no-pulse"
    else
      echo "missing"
    fi
  fi
}

# === 2. KE-очередь (count + oldest) ===
ke_stats() {
  local ke_dir="$DS_STRATEGY/inbox/extraction-reports"
  if [ ! -d "$ke_dir" ]; then
    echo "0 -1"
    return
  fi
  # Count only reports still waiting (frontmatter status: pending, or legacy
  # pending-review). Applied reports stay in the folder, so a raw *.md count
  # never drops to zero and oldest-age tracks history, not the queue (#548).
  # Parse mirrors ke-queue-stats.sh (first frontmatter block only; body
  # mentions like '# status: pending' must not count) — keep both in sync.
  local pending_files count
  pending_files=$(
    for f in "$ke_dir"/*.md; do
      [ -f "$f" ] || continue
      awk '/^---/{if(seen){exit} seen=1; next} seen && /^status:[[:space:]]*pending(-review)?$/{print FILENAME; exit}' "$f"
    done
  )
  if [ -z "$pending_files" ]; then
    echo "0 0"
    return
  fi
  count=$(printf '%s\n' "$pending_files" | grep -c .)
  # oldest pending age in days; stat differs between BSD/macOS and GNU/Linux (#548)
  local oldest_ts now_ts age_days
  if [ "$(uname -s)" = "Darwin" ]; then
    oldest_ts=$(printf '%s\n' "$pending_files" | tr '\n' '\0' | xargs -0 stat -f "%m" 2>/dev/null | sort -n | head -1)
  else
    oldest_ts=$(printf '%s\n' "$pending_files" | tr '\n' '\0' | xargs -0 stat -c "%Y" 2>/dev/null | sort -n | head -1)
  fi
  if [ -z "$oldest_ts" ]; then
    echo "$count -1"
    return
  fi
  now_ts=$(date +%s)
  age_days=$(( (now_ts - oldest_ts) / 86400 ))
  echo "$count $age_days"
}

SCHED=$(scheduler_pulse)
read -r KE_COUNT KE_OLDEST <<< "$(ke_stats)"

END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))

if [ "$HUMAN_MODE" = "true" ]; then
  # Формат для светофора DayPlan
  case "$SCHED" in
    ok)               sched_emoji="🟢"; sched_desc="scheduler-pulse свежий (<26h)" ;;
    registered-no-pulse) sched_emoji="🟡"; sched_desc="scheduler зарегистрирован, но нет локального pulse-файла" ;;
    missing)          sched_emoji="🔴"; sched_desc="Mode A: scheduler не зарегистрирован (launchd/systemd)" ;;
    stale:*)          sched_emoji="🟡"; sched_desc="scheduler-pulse устарел ($SCHED)" ;;
    *)                sched_emoji="❓"; sched_desc="unknown: $SCHED" ;;
  esac

  if [ "$KE_OLDEST" -ge 3 ] 2>/dev/null; then
    ke_emoji="🔴"
  elif [ "$KE_COUNT" -gt 20 ] 2>/dev/null; then
    ke_emoji="🟡"
  elif [ "$KE_COUNT" -gt 0 ] 2>/dev/null; then
    ke_emoji="🟡"
  else
    ke_emoji="🟢"
  fi

  echo "| Scheduler/триаж | $sched_emoji | $sched_desc |"
  echo "| KE-очередь | $ke_emoji | $KE_COUNT отчётов, oldest ${KE_OLDEST}д |"
  echo "| Core smoke elapsed | — | ${ELAPSED}s |"
else
  # JSON для машинного потребления
  cat <<EOF
{"scheduler_pulse":"$SCHED","ke_count":$KE_COUNT,"ke_oldest_days":$KE_OLDEST,"elapsed_sec":$ELAPSED}
EOF
fi
