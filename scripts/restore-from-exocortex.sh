#!/bin/bash
# restore-from-exocortex.sh — восстановление памяти IWE из exocortex-бэкапа (closes #125)
#
# Вторая половина истории портируемости (первая — backup в day-close.sh + авто-зеркало
# memory-exocortex-sync.sh). Применяется на НОВОМ устройстве или после потери/повреждения
# локальной memory/: разворачивает exocortex/ обратно в auto-memory + CLAUDE.md + симлинк.
#
# Использование:
#   restore-from-exocortex.sh [<governance-repo-path>] [--force] [--dry-run]
#
#   <governance-repo-path>  путь к governance-репо (default: $WORKSPACE_DIR/$GOVERNANCE_REPO)
#   --force                 перезаписать НЕпустую memory/ (по умолчанию — отказ)
#   --dry-run               показать что будет сделано, без изменений
#
# Источник: exocortex/ (наполняется day-close.sh --backup и хуком memory-exocortex-sync.sh).
# Path-схема идентична scripts/day-close.sh (v0.35.2): HOME_SLUG + override через env.

set -euo pipefail

# === Парсинг аргументов ===
FORCE=false
DRY_RUN=false
GOV_ARG=""
for arg in "$@"; do
    case "$arg" in
        --force)   FORCE=true ;;
        --dry-run) DRY_RUN=true ;;
        --help|-h)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "Неизвестный флаг: $arg" >&2; exit 1 ;;
        *)  GOV_ARG="$arg" ;;
    esac
done

# === Конфигурация (настраивается через env) ===
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/IWE}"
GOVERNANCE_REPO="${GOVERNANCE_REPO:-${IWE_GOVERNANCE_REPO:-DS-strategy}}"
DS_STRATEGY="${GOV_ARG:-$WORKSPACE_DIR/$GOVERNANCE_REPO}"
EXOCORTEX_SRC="$DS_STRATEGY/exocortex"
# Claude Code слугифицирует путь проекта, заменяя на '-' не только '/', но и '_' и '.'.
# Если в $HOME есть '_' (напр. username john_doe), реальная папка — '-home-john-doe-IWE'.
# tr '/' '-' дал бы фантом '-home-john_doe-IWE' → restore промахнётся мимо auto-memory.
# Здесь symlink-резолв непригоден: на новой машине $WORKSPACE_DIR/memory ещё не создан.
HOME_SLUG=$(echo "$HOME" | tr '/_.' '-')
MEMORY_DST="${IWE_MEMORY_SRC:-$HOME/.claude/projects/${HOME_SLUG}-IWE/memory}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[restore]${NC} $1"; }
warn() { echo -e "${YELLOW}[restore]${NC} $1"; }
err()  { echo -e "${RED}[restore]${NC} $1" >&2; }

run() { if $DRY_RUN; then echo "  [dry-run] $*"; else eval "$*"; fi; }

# === Проверки ===
if [ ! -d "$EXOCORTEX_SRC" ]; then
    err "exocortex не найден: $EXOCORTEX_SRC"
    err "Укажи путь к governance-репо: restore-from-exocortex.sh <path>"
    exit 1
fi

# Отказ от тихой перезаписи населённой memory/ (если не --force)
if [ -d "$MEMORY_DST" ] && [ -n "$(ls -A "$MEMORY_DST" 2>/dev/null)" ] && ! $FORCE && ! $DRY_RUN; then
    err "memory/ уже не пуста: $MEMORY_DST"
    err "Это похоже на существующую инсталляцию. Для перезаписи — --force (или --dry-run для превью)."
    exit 1
fi

log "Источник:    $EXOCORTEX_SRC"
log "Назначение:  $MEMORY_DST"
$DRY_RUN && warn "режим --dry-run: изменения не применяются"

# === Шаг 1: memory-файлы (всё кроме CLAUDE.md) → auto-memory ===
run "mkdir -p \"$MEMORY_DST\""
mem_count=0
shopt -s nullglob
for f in "$EXOCORTEX_SRC"/*.md "$EXOCORTEX_SRC"/*.yaml "$EXOCORTEX_SRC"/*.yml; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    [ "$fname" = "CLAUDE.md" ] && continue   # CLAUDE.md восстанавливается в workspace, не в memory/
    run "cp \"$f\" \"$MEMORY_DST/$fname\""
    mem_count=$((mem_count + 1))
done
shopt -u nullglob
log "memory-файлов восстановлено: $mem_count"

# === Шаг 2: CLAUDE.md → workspace root ===
if [ -f "$EXOCORTEX_SRC/CLAUDE.md" ]; then
    run "cp \"$EXOCORTEX_SRC/CLAUDE.md\" \"$WORKSPACE_DIR/CLAUDE.md\""
    log "CLAUDE.md восстановлен → $WORKSPACE_DIR/CLAUDE.md"
else
    warn "CLAUDE.md в exocortex отсутствует — пропуск"
fi

# === Шаг 3: симлинк $WORKSPACE_DIR/memory → auto-memory ===
LINK="$WORKSPACE_DIR/memory"
if [ -L "$LINK" ]; then
    current=$(readlink "$LINK")
    if [ "$current" = "$MEMORY_DST" ]; then
        log "Симлинк memory/ уже корректен"
    else
        warn "Симлинк memory/ указывает на $current (ожидалось $MEMORY_DST) — пересоздаю"
        run "rm \"$LINK\" && ln -s \"$MEMORY_DST\" \"$LINK\""
    fi
elif [ -e "$LINK" ]; then
    warn "$LINK существует и НЕ симлинк — не трогаю (разбери вручную)"
else
    run "ln -s \"$MEMORY_DST\" \"$LINK\""
    log "Симлинк создан: $LINK → $MEMORY_DST"
fi

echo ""
if $DRY_RUN; then
    warn "dry-run завершён. Для применения — запусти без --dry-run."
else
    log "Восстановление завершено. Перезапусти Claude Code для загрузки memory/."
fi
