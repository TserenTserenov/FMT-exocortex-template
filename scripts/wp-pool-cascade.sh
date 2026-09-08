#!/bin/bash
# wp-pool-cascade.sh — каскад бинарных фильтров предодобренного пула (WP-503 Ф8)
#
# Отбирает из портфеля РП кандидатов на автономный headless-запуск конвейером.
# Реализует физическую точку гейта из AR.001 §«Headless-конвейер и предодобренный
# пул» (WP-503 Ф7): headless-конвейер не может взять РП в работу без pool: true.
#
# Фильтры по порядку (бинарные, без LLM — сама классификация pool/verification_class
# уже машиночитаема через wp-list.py):
#   1. pool == true                                  (AR.001, явное действие пилота)
#   2. status not in {blocked, pending-pilot-decision} (не блокер — иначе в очередь Секретаря)
#   3. verification_class in {trivial, closed-loop}  (open-loop/problem-framing — не автономно, HD #32)
#
# Tie-break: НАСТОЯЩИЙ tie-break — /bottleneck-pick (LLM-скилл, DP.ROLE.054),
# физически не может быть вызван из bash-скрипта без LLM-сессии. Временный
# дефолт-порядок ниже (priority, затем created) — честный placeholder до Ф9,
# где headless-агент со своей LLM-сессией сможет вызвать /bottleneck-pick.
# Это открытый пункт, не готовое решение — см. WP-503 карточка Ф8.
#
# Usage: wp-pool-cascade.sh [--dry-run] [--probe [--date YYYY-MM-DD]]
# --probe: тот же паттерн, что wp-sync-bundle-batch.sh/wp-secretary-queue.sh —
# IWE_LEDGER_DIR уводится в изолированный temp, TG подавлен, heartbeat не в боевой файл.
set -euo pipefail

IWE_WORKSPACE="${IWE_WORKSPACE:-$HOME/IWE}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
WP_PIPELINE_CARDS_ROOT="${WP_PIPELINE_CARDS_ROOT:-$IWE_WORKSPACE}"
STRATEGY_DIR="$IWE_WORKSPACE/$GOV_REPO"
WP_LIST_SCRIPT="$IWE_WORKSPACE/FMT-exocortex-template/scripts/wp-list.py"
LEDGER_APPEND="$IWE_WORKSPACE/FMT-exocortex-template/scripts/ledger-append.sh"
TELEGRAM_LIB="$IWE_WORKSPACE/FMT-exocortex-template/scripts/lib/telegram.sh"
HEARTBEAT_FILE="$IWE_WORKSPACE/.claude/state/wp-pool-cascade.heartbeat"
LOCK_FILE="$IWE_WORKSPACE/.claude/state/wp-pool-cascade.lock"

DRY_RUN=false
PROBE=false
PROBE_DATE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --probe) PROBE=true; shift ;;
    --date) PROBE_DATE="${2:?--date requires YYYY-MM-DD}"; shift 2 ;;
    *) echo "ERROR: unknown arg $1" >&2; exit 1 ;;
  esac
done

if [[ -n "$PROBE_DATE" ]]; then
  PERIOD="$PROBE_DATE"
else
  PERIOD=$(date +%Y-%m-%d)
fi

if [[ "$PROBE" == "true" ]]; then
  PROBE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/wp-pool-cascade-probe.XXXXXX")
  export IWE_LEDGER_DIR="$PROBE_DIR/ledger"
  mkdir -p "$IWE_LEDGER_DIR"
  HEARTBEAT_FILE="$PROBE_DIR/heartbeat"
  LOCK_FILE="$PROBE_DIR/lock"
  trap 'rm -rf "$PROBE_DIR"' EXIT
  echo "[probe] IWE_LEDGER_DIR=$IWE_LEDGER_DIR (изолирован, боевой ledger не тронут)"
fi

exec 7>"$LOCK_FILE"
if ! flock -n 7; then
  echo "ERROR: другой прогон wp-pool-cascade.sh уже держит лок ($LOCK_FILE)" >&2
  exit 1
fi

[[ -f "$WP_LIST_SCRIPT" ]] || { echo "ERROR: $WP_LIST_SCRIPT не найден" >&2; exit 1; }
[[ -x "$LEDGER_APPEND" ]] || { echo "ERROR: $LEDGER_APPEND не найден или не исполняемый" >&2; exit 1; }

tg_fail() {
  local msg="🚨 wp-pool-cascade.sh: аварийный выход (line $1)"
  if [[ "$PROBE" == "true" ]]; then
    echo "[probe: TG suppressed] $msg"
  elif [[ -f "$TELEGRAM_LIB" ]]; then
    # shellcheck source=lib/telegram.sh
    . "$TELEGRAM_LIB"
    telegram_send "$msg" || echo "WARN: telegram_send упал при отправке FAIL" >&2
  fi
}
trap 'tg_fail $LINENO' ERR

WP_LIST_OUT=$(python3 "$WP_LIST_SCRIPT" --list-cards --governance-repo "$GOV_REPO" \
  --iwe-root "$WP_PIPELINE_CARDS_ROOT" \
  --format json --fields wp,status,pool,verification_class,priority,created 2>/dev/null)

# Три бинарных фильтра в один проход — сортировка (priority затем created) как
# временный tie-break, см. комментарий вверху файла про /bottleneck-pick.
CANDIDATES=$(echo "$WP_LIST_OUT" | python3 -c "
import json, sys

cards = json.load(sys.stdin)
blocked = {'blocked', 'pending-pilot-decision'}
autonomous_classes = {'trivial', 'closed-loop'}

candidates = [
    c for c in cards
    if c.get('pool') == 'true'
    and c.get('status') not in blocked
    and c.get('verification_class') in autonomous_classes
]

# Временный tie-break (priority строкой P0..P5, created ISO-дата — оба сортируемы
# лексикографически как есть; P0 раньше P1, более ранняя дата раньше поздней).
candidates.sort(key=lambda c: (c.get('priority') or 'P9', c.get('created') or '9999-99-99'))

for c in candidates:
    print(json.dumps(c))
")

# Сколько карточек вообще имеют pool:true — нужно только для heartbeat-сообщения
# (COUNT показывает выживших после ВСЕХ фильтров, разница = сколько отсеяно
# status/verification_class фильтрами, не только pool-фильтром).
POOL_TRUE_COUNT=$(echo "$WP_LIST_OUT" | python3 -c "
import json, sys
cards = json.load(sys.stdin)
print(sum(1 for c in cards if c.get('pool') == 'true'))
")

touch "$HEARTBEAT_FILE" 2>/dev/null || true

# Heartbeat (2026-08-05, WP-503 находка пир-сессии с Codex): «0 кандидатов»
# и «конвейер не запустился вовсе» выглядели для пилота неразличимо — оба
# молчание. tg_fail (ERR trap выше) уже покрывает падение с ненулевым exit;
# этот сигнал закрывает случай «отработал штатно, просто нечего исполнять».
# PROBE/DRY_RUN подавляют реальную отправку тем же принципом, что и остальные
# TG-вызовы в этом файле.
send_pool_heartbeat() {
  local count="$1" pool_true="$2"
  local filtered=$(( pool_true - count ))
  local msg="🫀 wp-pool-cascade: ${count} кандидат(ов) отобрано, ${filtered} отфильтровано (в пуле всего ${pool_true})"
  if [[ "$PROBE" == "true" ]] || [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run/probe: TG heartbeat suppressed] $msg"
    return 0
  fi
  if [[ -f "$TELEGRAM_LIB" ]]; then
    # shellcheck source=lib/telegram.sh
    . "$TELEGRAM_LIB"
    telegram_send "$msg" || echo "WARN: telegram_send упал при отправке heartbeat" >&2
  fi
}

if [[ -z "$CANDIDATES" ]]; then
  echo "wp-pool-cascade: нет кандидатов (ни одного РП с pool:true, не blocked, класс trivial/closed-loop)"
  send_pool_heartbeat 0 "$POOL_TRUE_COUNT"
  [[ "$PROBE" == "true" ]] && echo "=== PROBE SUMMARY ===" && echo "candidates=0" && echo "🟢 PROBE: прогон завершён без аварийного выхода (пустой список — валидный исход)"
  exit 0
fi

COUNT=0
while IFS= read -r candidate_json; do
  [[ -z "$candidate_json" ]] && continue
  COUNT=$((COUNT + 1))
  WP_NUM=$(echo "$candidate_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['wp'])")
  echo "Кандидат #$COUNT: WP-$WP_NUM"

  if [[ "$DRY_RUN" == "true" ]]; then
    continue
  fi

  DATA_JSON=$(echo "$candidate_json" | python3 -c "
import json, sys
c = json.load(sys.stdin)
print(json.dumps({
    'wp': c['wp'],
    'priority': c.get('priority') or '',
    'verification_class': c.get('verification_class') or '',
    'rank': $COUNT,
}))
")
  bash "$LEDGER_APPEND" day "$PERIOD" pool_candidate_selected "$DATA_JSON" wp-pool-cascade
done <<< "$CANDIDATES"

touch "$HEARTBEAT_FILE" 2>/dev/null || true

echo "wp-pool-cascade: $COUNT кандидат(ов) отобрано"
if [[ "$COUNT" -gt 1 ]]; then
  echo "NOTE: несколько кандидатов — временный tie-break по priority/created применён; настоящий tie-break через /bottleneck-pick не реализован (Ф9)"
fi
send_pool_heartbeat "$COUNT" "$POOL_TRUE_COUNT"

if [[ "$PROBE" == "true" ]]; then
  echo "=== PROBE SUMMARY ==="
  echo "candidates=$COUNT"
  echo "🟢 PROBE: прогон завершён без аварийного выхода"
fi
