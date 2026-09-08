#!/bin/bash
# requires: IWE_GOVERNANCE_REPO set via iwe-env-bootstrap.sh (fallback: DS-strategy, same as other scripts)
# day-close-lock.sh — git-native cross-machine lock against duplicate Day Close runs (WP-484 Ф2).
#
# Инцидент 17.07: сервер (tsekh-1) и пилот вручную закрыли один день независимо друг от друга,
# gap обнаружился только в момент commit+push. Git log сам по себе неатомарен (read-then-act),
# поэтому источник истины — сам факт push: кто раньше запушил "day-close-start:", тот и работает,
# остальные видят чужой свежий маркер (или reject при попытке запушить свой) и останавливаются
# ДО начала работы, а не после.
#
# Маркеры — ПУСТЫЕ коммиты, созданные через commit-tree (не `git commit --allow-empty`, которая
# не гарантирует пустой diff если в индексе есть чужие staged-файлы — реальный риск в репо, где
# параллельно работают несколько агентов). Два независимых пустых коммита с разными сообщениями
# никогда не конфликтуют при rebase — проверено тестом на реальной гонке.
#
# После push-reject проверка идёт по origin/<branch> НАПРЯМУЮ (git fetch, без rebase) — если
# сначала перебазировать свой маркер поверх новых чужих коммитов и только потом проверять лог,
# собственный только что перебазированный маркер (committer-date обновляется rebase'ом на "сейчас")
# становится самым свежим совпадением и маскирует реальную причину reject'а — ревью нашло это
# эмпирически (reject от ПОСТОРОННЕГО коммита давал ложное "кто-то закрывает день" на каждый раз).
#
# Календарная дата следует системной зоне установки — той же зоне, в которой
# протокол пишет финальный маркер day-close. Epoch-возраст маркера от зоны не зависит.
#
# Двухуровневая защита: сначала быстрый локальный барьер (gateway-lock.py, для двух процессов на
# ОДНОЙ машине), затем git-маркер (для гонки МЕЖДУ машинами — ровно инцидент 17.07). Первый уровень
# не обязателен (gateway недоступен → просто пропускается), второй — единственный источник истины.
#
# Usage: day-close-lock.sh acquire
#   exit 0 — лок взят, можно приступать к закрытию дня
#   exit 1 — день уже закрыт сегодня (найден финальный коммит "day-close: YYYY-MM-DD")
#   exit 3 — кто-то уже закрывает день прямо сейчас (свежий "day-close-start:", локально или на другой машине)
#   exit 2 — git/gateway-операция не удалась однозначно (сеть/хук/окружение) — ретраить снаружи, не считать "уже закрыто"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
GOVERNANCE_REPO="${GOVERNANCE_REPO:-${IWE_GOVERNANCE_REPO:-DS-strategy}}"
REPO_DIR="$WORKSPACE_DIR/$GOVERNANCE_REPO"
TTL_SECONDS=1800  # та же конвенция, что scripts/session-guard.sh HK_MAX_AGE (30 мин)
GATEWAY_LOCK_PY="$REPO_DIR/scripts/lib/gateway-lock.py"

log() { echo "[day-close-lock] $1"; }

calendar_today() {
  date +%Y-%m-%d
}

# Единая точка выхода после того, как локальный маркер-коммит уже создан: откатывает его
# и завершает с нужным кодом — вместо повторения "discard + exit" по трём местам (P2).
abort_after_marker() {
  local code="$1" msg="$2"
  log "$msg"
  discard_local_marker
  exit "$code"
}

# Быстрый барьер для двух процессов на ОДНОЙ машине — необязательный, gateway недоступен → просто
# продолжаем и полагаемся на git-проверку ниже (она единственная работает между машинами).
local_barrier() {
  [ -x "$GATEWAY_LOCK_PY" ] || { log "gateway-lock.py не найден — пропускаю локальный барьер"; return 0; }
  local rc=0
  python3 "$GATEWAY_LOCK_PY" acquire "day-close-lock" "$TTL_SECONDS" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 1 ]; then
    log "Локальный барьер: день уже закрывается на этой машине (gateway lock занят) — выхожу"
    exit 3
  elif [ "$rc" -eq 2 ]; then
    log "gateway недоступен — пропускаю локальный барьер, дальше решает git"
  fi
}

# Возвращает: "closed" | "start:<age_seconds>" | "" (пусто — сегодня ничего не было).
# $1 — git-ref для проверки (по умолчанию HEAD; для пост-reject проверки — origin/<branch>,
# НЕ локальный HEAD после rebase, см. комментарий в заголовке файла).
check_today_history() {
  local ref="${1:-HEAD}"
  local today; today=$(calendar_today)
  local log_lines
  log_lines=$(git log "$ref" --since="${today} 00:00" --format="%ct %s" 2>/dev/null || true)

  if echo "$log_lines" | grep -q "day-close: ${today}"; then
    echo "closed"
    return
  fi

  local start_line
  start_line=$(echo "$log_lines" | grep "day-close-start: ${today}" | head -1 || true)
  if [ -n "$start_line" ]; then
    local ts now
    ts=$(echo "$start_line" | awk '{print $1}')
    now=$(date +%s)
    echo "start:$(( now - ts ))"
    return
  fi

  echo ""
}

# Коммит гарантированно без diff (не зависит от состояния индекса, в отличие от --allow-empty).
create_start_marker() {
  local who="$1" today="$2"
  local parent tree new
  parent=$(git rev-parse HEAD) || return 1
  tree=$(git rev-parse 'HEAD^{tree}') || return 1
  new=$(git commit-tree -p "$parent" -m "day-close-start: ${today} by ${who}" "$tree") || return 1
  git update-ref HEAD "$new" || return 1
}

# Откатывает локальный незапушенный маркер к последнему известному состоянию origin — если мы
# зависли в rebase (для пустых коммитов маловероятно, но не исключено), сначала выходим из него.
discard_local_marker() {
  local git_dir rm_dir ra_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 0
  rm_dir="$git_dir/rebase-merge"; ra_dir="$git_dir/rebase-apply"
  { [ -d "$rm_dir" ] || [ -d "$ra_dir" ]; } && { git rebase --abort >/dev/null 2>&1 || log "git rebase --abort не удался — возможно локальный rebase-стейт остался, проверить вручную"; }
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [ -n "$branch" ] && git rev-parse "origin/$branch" >/dev/null 2>&1; then
    git reset --mixed "origin/$branch" >/dev/null 2>&1 \
      || log "не удалось откатить локальный маркер к origin/$branch — проверить вручную (git status)"
  fi
}

acquire() {
  cd "$REPO_DIR" || { log "не удалось перейти в $REPO_DIR — окружение не настроено, эскалирую"; exit 2; }

  local_barrier

  git pull --rebase --autostash || { log "git pull failed — не рискуем работать на устаревшей истории"; exit 2; }

  local state
  state=$(check_today_history)
  if [ "$state" = "closed" ]; then
    log "День уже закрыт сегодня (найден коммит day-close:) — выхожу, повторный прогон не нужен"
    exit 1
  fi
  if [[ "$state" == start:* ]]; then
    local age="${state#start:}"
    if [ "$age" -lt "$TTL_SECONDS" ]; then
      log "Кто-то уже закрывает день прямо сейчас (маркер моложе ${TTL_SECONDS}s, возраст ${age}s) — выхожу"
      exit 3
    fi
    log "Найден протухший day-close-start (возраст ${age}s ≥ ${TTL_SECONDS}s) — считаю осиротевшим, продолжаю"
  fi

  local who today branch
  who="${IWE_AGENT:-$(whoami)}@$(hostname -s)"
  today=$(calendar_today)
  branch=$(git rev-parse --abbrev-ref HEAD)
  create_start_marker "$who" "$today" || { log "Не удалось создать маркер-коммит — эскалирую"; exit 2; }

  if git push; then
    log "Lock acquired: day-close-start: ${today} by ${who}"
    return 0
  fi

  # Push отклонён. Проверяем origin/<branch> НАПРЯМУЮ через fetch, БЕЗ rebase: если сначала
  # перебазировать свой маркер, он сам станет "самым свежим" в логе и замаскирует реальную
  # причину reject'а (в т.ч. посторонний, не связанный с day-close коммит) — см. заголовок файла.
  git fetch origin "$branch" || abort_after_marker 2 "git fetch после reject не удался — эскалирую"

  state=$(check_today_history "origin/$branch")
  if [ "$state" = "closed" ] || { [[ "$state" == start:* ]] && [ "${state#start:}" -lt "$TTL_SECONDS" ]; }; then
    abort_after_marker 3 "После reject подтверждено: день уже закрывается/закрыт кем-то другим на origin — выхожу"
  fi

  # На origin нет конкурента — reject был вызван чем-то посторонним. Безопасно перебазировать
  # свой маркер поверх актуального origin и повторить push.
  git rebase --autostash "origin/$branch" || abort_after_marker 2 "rebase после fetch не удался — эскалирую"
  git push || abort_after_marker 2 "Повторный push не удался — эскалирую"
  log "Lock acquired на втором заходе: day-close-start: ${today} by ${who}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    acquire) acquire ;;
    *) echo "Usage: $0 acquire" >&2; exit 2 ;;
  esac
fi
