#!/bin/bash
# routing: helper  skill=day-close  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# day-close.sh — Автоматические шаги Day Close (backup + reindex + linear sync + sessions)
#
# Вызывается Claude из протокола Day Close (protocol-close.md § День, шаг 4).
# Объединяет четыре механических операции в одну команду.
#
# Использование:
#   day-close.sh                # все четыре шага
#   day-close.sh --backup       # только backup
#   day-close.sh --reindex      # только reindex
#   day-close.sh --linear       # только linear sync
#   day-close.sh --sessions     # только консолидация сессий дня (DAP1-B, WP-7)
#
# Конфигурация: Пути заданы через переменные ниже — настроить при установке.

set -euo pipefail

# === КОНФИГУРАЦИЯ (настроить при установке) ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
GOVERNANCE_REPO="${GOVERNANCE_REPO:-${IWE_GOVERNANCE_REPO:-DS-strategy}}"
DS_STRATEGY="$WORKSPACE_DIR/$GOVERNANCE_REPO"
# Slug derived from WORKSPACE_DIR (not $HOME) so it matches Claude's project key
# regardless of workspace location. Override via IWE_MEMORY_SRC if needed.
WORKSPACE_SLUG=$(echo "$WORKSPACE_DIR" | tr '/_ ' '-')
MEMORY_SRC="${IWE_MEMORY_SRC:-$HOME/.claude/projects/${WORKSPACE_SLUG}/memory}"
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

  # One-time cleanup: legacy nested directory left over from a deprecated recursive-backup prompt.
  if [ -d "$EXOCORTEX_DST/memory" ]; then
    warn "  Removing legacy nested directory: $EXOCORTEX_DST/memory"
    rm -rf "$EXOCORTEX_DST/memory"
  fi

  # Mirror *.md/*.yaml/*.yml from auto-memory; --delete prunes files removed upstream.
  # CLAUDE.md is excluded so the workspace copy below isn't deleted by --delete.
  # day-rhythm-config.yaml is excluded here and handled separately via merge (see below)
  # to preserve user-configured keys (e.g. calendar_ids) from being overwritten by template defaults.
  rsync -a --delete \
    --exclude='CLAUDE.md' \
    --exclude='day-rhythm-config.yaml' \
    --include='*.md' --include='*.yaml' --include='*.yml' \
    --exclude='*' \
    "$MEMORY_SRC/" "$EXOCORTEX_DST/"

  # Merge day-rhythm-config.yaml: use auto-memory as base, preserve non-empty user values in dst.
  # User-configurable keys protected: day_open.calendar_ids
  local rhythm_src="$MEMORY_SRC/day-rhythm-config.yaml"
  local rhythm_dst="$EXOCORTEX_DST/day-rhythm-config.yaml"
  if [ -f "$rhythm_src" ]; then
    if [ ! -f "$rhythm_dst" ]; then
      cp "$rhythm_src" "$rhythm_dst"
    else
      python3 - "$rhythm_src" "$rhythm_dst" << 'PYEOF'
import sys, yaml

src_path, dst_path = sys.argv[1], sys.argv[2]
with open(src_path) as f:
    src_data = yaml.safe_load(f) or {}
with open(dst_path) as f:
    dst_data = yaml.safe_load(f) or {}

merged = dict(src_data)

# Preserve non-empty user values from dst (L4 config, user-editable keys)
USER_KEYS = [("day_open", "calendar_ids")]
for section, key in USER_KEYS:
    dst_val = dst_data.get(section, {}).get(key)
    if dst_val:  # preserve non-empty dst value over template default
        merged.setdefault(section, {})[key] = dst_val

with open(dst_path, "w") as f:
    yaml.dump(merged, f, default_flow_style=False, allow_unicode=True)
PYEOF
    fi
  fi

  # issue #217: обратная подстановка $HOME -> {{HOME_DIR}} делает бэкап ОС-агностичным
  # (симметрично прямой подстановке в setup.sh и restore-from-exocortex.sh).
  if [ -f "$WORKSPACE_DIR/CLAUDE.md" ]; then
    sed "s|$HOME|{{HOME_DIR}}|g" "$WORKSPACE_DIR/CLAUDE.md" > "$EXOCORTEX_DST/CLAUDE.md"
  fi

  if [ -f "$WORKSPACE_DIR/AGENTS.md" ]; then
    sed "s|$HOME|{{HOME_DIR}}|g" "$WORKSPACE_DIR/AGENTS.md" > "$EXOCORTEX_DST/AGENTS.md"
  fi

  local count
  count=$(find "$EXOCORTEX_DST" -maxdepth 1 -type f \( -name '*.md' -o -name '*.yaml' -o -name '*.yml' \) | wc -l | tr -d ' ')
  log "  Синхронизировано: $count файлов → $EXOCORTEX_DST/"
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

# --- Шаг 4: Консолидация сессий дня (DAP1-B, WP-7) ---
do_session_consolidation() {
  log "Шаг 4/4: Консолидация сессий дня"

  local today
  today=$(date +%Y-%m-%d)
  local month_dir
  month_dir=$(date +%Y-%m)
  local sessions_root="$DS_STRATEGY/sessions/$month_dir"
  local output_file="$DS_STRATEGY/current/sessions-today.md"

  if [ ! -d "$sessions_root" ]; then
    warn "  Папка sessions/$month_dir не найдена — пропуск"
    return 0
  fi

  # Сканируем meta.yaml для сессий сегодняшнего дня
  local entries=()
  while IFS= read -r meta; do
    local session_dir
    session_dir=$(dirname "$meta")
    local session_id
    session_id=$(basename "$session_dir")

    # Читаем task_id и task_description из meta.yaml (python для YAML)
    local task_id task_desc start_time
    task_id=$(python3 -c "
import sys, yaml
with open('$meta') as f:
    d = yaml.safe_load(f)
print(d.get('task_id', '') or '')
" 2>/dev/null || echo "")
    task_desc=$(python3 -c "
import sys, yaml
with open('$meta') as f:
    d = yaml.safe_load(f)
desc = d.get('task_description', '') or ''
print(desc[:80] + ('...' if len(desc) > 80 else ''))
" 2>/dev/null || echo "")
    start_time=$(python3 -c "
import sys, yaml
with open('$meta') as f:
    d = yaml.safe_load(f)
t = str(d.get('start_time', '') or '')
print(t[11:16] if len(t) >= 16 else '')
" 2>/dev/null || echo "")

    # Только если task_id не пустой — WP-явная сессия
    if [ -n "$task_id" ]; then
      entries+=("| $start_time | $task_id | $task_desc |")
    fi
  done < <(find "$sessions_root" -maxdepth 2 -name "meta.yaml" 2>/dev/null \
    | while IFS= read -r f; do
        # Проверяем дату в meta.yaml
        date_val=$(python3 -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
print(str(d.get('date','') or ''))
" 2>/dev/null || echo "")
        if [ "$date_val" = "$today" ]; then
          echo "$f"
        fi
      done | sort)

  mkdir -p "$(dirname "$output_file")"

  if [ ${#entries[@]} -eq 0 ]; then
    log "  Нет WP-сессий за $today — sessions-today.md не записан"
    return 0
  fi

  {
    echo "<!-- sessions-today: $today — auto-generated by day-close.sh -->"
    echo "## Сессии дня $today"
    echo ""
    echo "| Время | РП | Задача |"
    echo "|-------|----|--------|"
    for e in "${entries[@]}"; do
      echo "$e"
    done
    echo ""
  } > "$output_file"

  log "  Записано ${#entries[@]} сессий → $(basename "$output_file")"
}

# --- Лог ---
write_log() {
  local date_str
  date_str=$(date "+%Y-%m-%d %H:%M")
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "$date_str | day-close | backup=$1 reindex=$2 linear=$3 sessions=$4" >> "$LOG_FILE"
}

# --- Main ---
main() {
  local do_all=true
  local run_backup=false
  local run_reindex=false
  local run_linear=false
  local run_sessions=false

  for arg in "$@"; do
    case "$arg" in
      --backup)   run_backup=true; do_all=false ;;
      --reindex)  run_reindex=true; do_all=false ;;
      --linear)   run_linear=true; do_all=false ;;
      --sessions) run_sessions=true; do_all=false ;;
      --help|-h)
        echo "Использование: day-close.sh [--backup] [--reindex] [--linear] [--sessions]"
        echo "  Без аргументов — все четыре шага"
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
    run_sessions=true
  fi

  log "=== Day Close (автоматические шаги) ==="

  local backup_status="skip" reindex_status="skip" linear_status="skip" sessions_status="skip"

  if $run_backup; then
    if do_backup; then backup_status="ok"; else backup_status="fail"; fi
  fi

  if $run_reindex; then
    if do_reindex; then reindex_status="ok"; else reindex_status="fail"; fi
  fi

  if $run_linear; then
    if do_linear; then linear_status="ok"; else linear_status="fail"; fi
  fi

  if $run_sessions; then
    if do_session_consolidation; then sessions_status="ok"; else sessions_status="fail"; fi
  fi

  write_log "$backup_status" "$reindex_status" "$linear_status" "$sessions_status"

  log "=== Готово ==="
  log "  backup=$backup_status  reindex=$reindex_status  linear=$linear_status  sessions=$sessions_status"
}

main "$@"
