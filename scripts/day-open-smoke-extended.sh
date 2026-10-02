#!/bin/bash
# day-open-smoke-extended.sh — extended smoke для Day Open (запускается hourly cron, кэш)
# see: peer-сессия 2026-05-30-07-gap-list-day-open подэтап 2
# see: WP-356 «Pipeline Day Open: auto-run checks»
#
# Назначение: проверки, занимающие >2с (dt-collect dry-run, projection cursor age, FPF upstream).
# Запускается hourly cron, результат — в cache-файле.
# Day Open читает cache, не вызывает этот скрипт напрямую.
#
# Вывод: JSON в файл `~/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/current/.smoke-cache.json`
#   {
#     "timestamp": "ISO-8601",
#     "ttl_min": 90,
#     "dt_collect": "ok|fail:<reason>",
#     "projection_cursor_age_min": <int>,
#     "fpf_behind_count": <int>,
#     "elapsed_sec": <float>
#   }
#
# Использование:
#   bash day-open-smoke-extended.sh         # обычный запуск
#   bash day-open-smoke-extended.sh --force # игнорировать TTL, всегда запускать
#
# Failure mode: индивидуальные секции могут возвращать "fail:<reason>", скрипт не падает.

set -uo pipefail

START_TS=$(date +%s)
FORCE=false
[ "${1:-}" = "--force" ] && FORCE=true

IWE_BASE="${IWE_BASE:-$HOME/IWE}"
DS_STRATEGY="$IWE_BASE/${IWE_GOVERNANCE_REPO:-DS-strategy}"
CACHE_FILE="$DS_STRATEGY/current/.smoke-cache.json"
TTL_MIN=90

# Проверить TTL — если cache свежий, не запускаться (если не --force)
if [ "$FORCE" = "false" ] && [ -f "$CACHE_FILE" ]; then
  cache_ts=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
  now_ts=$(date +%s)
  age_min=$(( (now_ts - cache_ts) / 60 ))
  if [ "$age_min" -lt "$TTL_MIN" ]; then
    echo "cache fresh (${age_min}min < ${TTL_MIN}min) — skip" >&2
    exit 0
  fi
fi

# === 1. dt-collect dry-run ===
check_dt_collect() {
  local script="$DS_STRATEGY/scripts/dt-collect.sh"
  if [ ! -x "$script" ]; then
    echo "fail:script-missing"
    return
  fi
  # Запустить dry-run с timeout 30с
  if timeout 30 bash "$script" --dry-run 2>/dev/null >/dev/null; then
    echo "ok"
  else
    echo "fail:exit-$?"
  fi
}

# === 2. Projection cursor age (через Neon) ===
check_projection_cursor() {
  # Без БД-доступа в этом контексте — отметить как unknown
  # TODO: при подключении psql + secrets — прочитать MAX(updated_at) из projection_cursors
  echo "-1"
}

# === 3. FPF upstream check ===
check_fpf_upstream() {
  local fpf="$IWE_BASE/FPF"
  if [ ! -d "$fpf/.git" ]; then
    echo "-1"
    return
  fi
  (cd "$fpf" && git fetch --quiet 2>/dev/null && git rev-list --count HEAD..origin/main 2>/dev/null) || echo "-1"
}

DT_COLLECT=$(check_dt_collect)
PROJECTION=$(check_projection_cursor)
FPF_BEHIND=$(check_fpf_upstream)

END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))
ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$(dirname "$CACHE_FILE")"
cat > "$CACHE_FILE" <<EOF
{
  "timestamp": "$ISO",
  "ttl_min": $TTL_MIN,
  "dt_collect": "$DT_COLLECT",
  "projection_cursor_age_min": $PROJECTION,
  "fpf_behind_count": $FPF_BEHIND,
  "elapsed_sec": $ELAPSED
}
EOF

echo "extended smoke cached → $CACHE_FILE (elapsed ${ELAPSED}s)" >&2
