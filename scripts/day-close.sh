#!/bin/bash
# day-close.sh — Автоматические шаги Day Close (backup + reindex + linear sync)
#
# Вызывается Claude из протокола Day Close (protocol-close.md § День, шаг 4).
# Объединяет три механических операции в одну команду.
#
# Использование:
#   day-close.sh              # все три шага
#   day-close.sh --backup     # только backup
#   day-close.sh --reindex    # только reindex
#   day-close.sh --linear     # только linear sync
#
# Конфигурация: Пути заданы через переменные ниже — настроить при установке.

set -euo pipefail

# === КОНФИГУРАЦИЯ (настроить при установке) ===
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/IWE}"
DS_STRATEGY="$WORKSPACE_DIR/DS-strategy"
MEMORY_SRC="$HOME/.claude/projects/-Users-$(whoami)-IWE/memory"
EXOCORTEX_DST="$DS_STRATEGY/exocortex"
# MCP reindex — опциональный компонент (WP-187 iwe-knowledge Gateway заменяет локальный knowledge-mcp).
# Переопределить путь можно через env IWE_SELECTIVE_REINDEX.
SELECTIVE_REINDEX="${IWE_SELECTIVE_REINDEX:-$WORKSPACE_DIR/DS-MCP/knowledge-mcp/scripts/selective-reindex.sh}"
SOURCES_JSON="${IWE_SOURCES_JSON:-$WORKSPACE_DIR/DS-MCP/knowledge-mcp/scripts/sources.json}"
SOURCES_PERSONAL_JSON="${IWE_SOURCES_PERSONAL_JSON:-$WORKSPACE_DIR/DS-MCP/knowledge-mcp/scripts/sources-personal.json}"
# Linear sync: путь читается из params.yaml (ключ linear_sync_path)
PARAMS_YAML="$WORKSPACE_DIR/params.yaml"
LINEAR_SYNC=""
if [ -f "$PARAMS_YAML" ]; then
  _raw=$(python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); print(d.get('linear_sync_path',''))" "$PARAMS_YAML" 2>/dev/null || echo "")
  if [ -n "$_raw" ]; then
    LINEAR_SYNC="${_raw/#\~/$HOME}"
  fi
fi
LOG_FILE="${IWE_DAY_CLOSE_LOG:-$HOME/logs/day-close.log}"
# === /КОНФИГУРАЦИЯ ===

# Цвета
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[day-close]${NC} $1"; }
warn() { echo -e "${YELLOW}[day-close]${NC} $1"; }
err() { echo -e "${RED}[day-close]${NC} $1" >&2; }

# --- Шаг 1: Backup memory/ + CLAUDE.md → exocortex/ ---
do_backup() {
  log "Шаг 1/3: Backup memory/ → exocortex/"

  if [ ! -d "$MEMORY_SRC" ]; then
    err "Memory source not found: $MEMORY_SRC"
    return 1
  fi

  mkdir -p "$EXOCORTEX_DST"

  local count=0
  for f in "$MEMORY_SRC"/*.md "$MEMORY_SRC"/*.yaml "$MEMORY_SRC"/*.yml; do
    [ -f "$f" ] || continue
    cp "$f" "$EXOCORTEX_DST/"
    count=$((count + 1))
  done

  if [ -f "$WORKSPACE_DIR/CLAUDE.md" ]; then
    cp "$WORKSPACE_DIR/CLAUDE.md" "$EXOCORTEX_DST/CLAUDE.md"
    count=$((count + 1))
  fi

  log "  Скопировано: $count файлов → $EXOCORTEX_DST/"
}

# --- Шаг 2: Knowledge-MCP reindex ---
do_reindex() {
  log "Шаг 2/3: Knowledge-MCP reindex"

  if [ ! -x "$SELECTIVE_REINDEX" ]; then
    warn "  selective-reindex.sh не найден: $SELECTIVE_REINDEX — пропуск"
    return 0
  fi

  # Маппинг dir→source+config из L2 (sources.json) и L4 (sources-personal.json)
  # Python резолвит path→git-root, чтобы связать dirname репо с source-именем.
  local dir_map
  dir_map=$(python3 - "$SOURCES_JSON" "$SOURCES_PERSONAL_JSON" << 'PYEOF'
import sys, json, os
for config_path in sys.argv[1:]:
    if not os.path.exists(config_path):
        continue
    for s in json.load(open(config_path)):
        resolved = os.path.expanduser(s["path"])
        while not os.path.isdir(os.path.join(resolved, ".git")) and resolved != "/":
            resolved = os.path.dirname(resolved)
        if resolved == "/":
            continue
        print(f"{os.path.basename(resolved)}\t{s['source']}\t{config_path}")
PYEOF
  ) || { warn "  Mapping build failed — пропуск reindex"; return 0; }

  # Определяем, какие Pack/DS были изменены сегодня
  local l2_sources="" l4_sources=""
  for repo in "$WORKSPACE_DIR"/PACK-* "$WORKSPACE_DIR"/DS-*; do
    [ -d "$repo/.git" ] || continue
    local repo_name
    repo_name=$(basename "$repo")
    local today_commits
    today_commits=$(git -C "$repo" log --since="today 00:00" --oneline --no-merges 2>/dev/null | wc -l | tr -d ' ')
    if [ "$today_commits" -gt 0 ]; then
      local match
      match=$(echo "$dir_map" | awk -F'\t' -v d="$repo_name" '$1==d {print $2"\t"$3; exit}')
      if [ -n "$match" ]; then
        local src cfg
        src=$(echo "$match" | cut -f1)
        cfg=$(echo "$match" | cut -f2)
        if [ "$cfg" = "$SOURCES_JSON" ]; then
          l2_sources="$l2_sources $src"
        else
          l4_sources="$l4_sources $src"
        fi
      else
        log "  ⚠ $repo_name: не в sources — пропуск"
      fi
    fi
  done

  if [ -z "$l2_sources" ] && [ -z "$l4_sources" ]; then
    log "  Нет изменений в индексируемых источниках — пропуск reindex"
    return 0
  fi

  # Вызов 1: L2 источники (sources.json — дефолт selective-reindex)
  if [ -n "$l2_sources" ]; then
    log "  L2 источники:$l2_sources"
    # shellcheck disable=SC2086
    "$SELECTIVE_REINDEX" $l2_sources
  fi

  # Вызов 2: L4 источники (sources-personal.json через SOURCES_CONFIG)
  if [ -n "$l4_sources" ]; then
    log "  L4 источники:$l4_sources"
    # shellcheck disable=SC2086
    SOURCES_CONFIG="$SOURCES_PERSONAL_JSON" "$SELECTIVE_REINDEX" $l4_sources
  fi
}

# --- Шаг 3: Linear sync ---
do_linear() {
  log "Шаг 3/3: Linear sync"

  if [ ! -x "$LINEAR_SYNC" ]; then
    warn "  linear-sync.sh не найден: $LINEAR_SYNC — пропуск"
    return 0
  fi

  "$LINEAR_SYNC"
}

# --- Лог ---
write_log() {
  local date_str
  date_str=$(date "+%Y-%m-%d %H:%M")
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "$date_str | day-close | backup=$1 reindex=$2 linear=$3" >> "$LOG_FILE"
}

# --- Main ---
main() {
  local do_all=true
  local run_backup=false
  local run_reindex=false
  local run_linear=false

  for arg in "$@"; do
    case "$arg" in
      --backup)  run_backup=true; do_all=false ;;
      --reindex) run_reindex=true; do_all=false ;;
      --linear)  run_linear=true; do_all=false ;;
      --help|-h)
        echo "Использование: day-close.sh [--backup] [--reindex] [--linear]"
        echo "  Без аргументов — все три шага"
        exit 0
        ;;
      *)
        err "Неизвестный аргумент: $arg"
        exit 1
        ;;
    esac
  done

  if $do_all; then
    run_backup=true
    run_reindex=true
    run_linear=true
  fi

  log "=== Day Close (автоматические шаги) ==="

  local backup_status="skip" reindex_status="skip" linear_status="skip"

  if $run_backup; then
    if do_backup; then backup_status="ok"; else backup_status="fail"; fi
  fi

  if $run_reindex; then
    if do_reindex; then reindex_status="ok"; else reindex_status="fail"; fi
  fi

  if $run_linear; then
    if do_linear; then linear_status="ok"; else linear_status="fail"; fi
  fi

  write_log "$backup_status" "$reindex_status" "$linear_status"

  log "=== Готово ==="
  log "  backup=$backup_status  reindex=$reindex_status  linear=$linear_status"
}

main "$@"
