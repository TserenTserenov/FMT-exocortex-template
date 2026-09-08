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
WORKSPACE_SLUG=$(printf '%s' "$WORKSPACE_DIR" | tr '/_.' '-')
COMPUTED_MEMORY="$HOME/.claude/projects/${WORKSPACE_SLUG}/memory"
PHYSICAL_MEMORY=""
if [ -d "$WORKSPACE_DIR/memory" ]; then
    PHYSICAL_MEMORY=$(cd -P -- "$WORKSPACE_DIR/memory" 2>/dev/null && pwd -P) || exit 1
fi
if [ -n "$PHYSICAL_MEMORY" ] && [ -d "$COMPUTED_MEMORY" ]; then
    COMPUTED_PHYSICAL=$(cd -P -- "$COMPUTED_MEMORY" 2>/dev/null && pwd -P) || exit 1
    if [ "$PHYSICAL_MEMORY" != "$COMPUTED_PHYSICAL" ]; then
        echo "Неоднозначная memory-конфигурация: workspace/memory → $PHYSICAL_MEMORY, slug target → $COMPUTED_PHYSICAL" >&2
        exit 1
    fi
fi
MEMORY_DST="${IWE_MEMORY_SRC:-${PHYSICAL_MEMORY:-$COMPUTED_MEMORY}}"

# Restore is a privacy boundary: names which differ from protected ownership
# roots only by case or Unicode compatibility spelling must not enter Claude's
# auto-memory. Resolve one standard-library Python 3 interpreter up front so a
# missing normalizer fails before the first destination write.
RESTORE_STDLIB_PYTHON3=""
for _restore_python_candidate in python3 python; do
    if command -v "$_restore_python_candidate" >/dev/null 2>&1 && \
       "$_restore_python_candidate" -c \
           'import sys; raise SystemExit(sys.version_info[0] != 3)' \
           >/dev/null 2>&1; then
        RESTORE_STDLIB_PYTHON3="$_restore_python_candidate"
        break
    fi
done
unset _restore_python_candidate

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[restore]${NC} $1"; }
warn() { echo -e "${YELLOW}[restore]${NC} $1"; }
err()  { echo -e "${RED}[restore]${NC} $1" >&2; }

run_cmd() {
    if $DRY_RUN; then
        printf '  [dry-run]'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

memory_restore_path_is_protected() {
    "$RESTORE_STDLIB_PYTHON3" - "$1" <<'PYEOF'
import sys
import unicodedata


def canonical_component(component):
    return unicodedata.normalize(
        "NFKC", unicodedata.normalize("NFKC", component).casefold()
    )


protected_roots = {
    ".git",
    ".day-close-backup-quarantine",
    "quarantine",
    "agent-fault-profile",
    "hindsight",
    "decisions",
    "extensions",
    "rules",
}
protected_files = {
    "claude.md",
    "params.yaml",
    "day-rhythm-config.yaml",
    ".day-close-backup-manifest.json",
    ".day-close-backup-incomplete",
    ".day-close-backup.lock",
}

try:
    relative = sys.argv[1]
    first, separator, _remainder = relative.partition("/")
    canonical_first = canonical_component(first)
except (IndexError, TypeError, ValueError):
    raise SystemExit(2)

is_protected = canonical_first in protected_roots or (
    not separator and canonical_first in protected_files
)
raise SystemExit(0 if is_protected else 1)
PYEOF
}

root_entry_has_exact_name() {
    "$RESTORE_STDLIB_PYTHON3" - "$EXOCORTEX_SRC" "$1" <<'PYEOF'
import os
import sys


try:
    names = os.listdir(sys.argv[1])
except OSError:
    raise SystemExit(2)
raise SystemExit(0 if sys.argv[2] in names else 1)
PYEOF
}

atomic_restore_copy() {
    local src="$1" dst="$2" label="$3" parent tmp
    parent=$(dirname -- "$dst")
    if $DRY_RUN; then
        echo "  [dry-run] atomic copy $src -> $dst"
        return 0
    fi
    mkdir -p -- "$parent"
    if [ -e "$dst" ] && [ ! -f "$dst" ] && [ ! -L "$dst" ]; then
        err "$label: назначение не является обычным файлом: $dst"
        return 1
    fi
    tmp=$(mktemp -- "$parent/.$(basename -- "$dst").tmp.XXXXXX") || {
        err "$label: не удалось создать временный файл"
        return 1
    }
    if ! cp -p -- "$src" "$tmp"; then
        rm -f -- "$tmp"
        err "$label: не удалось подготовить атомарную копию"
        return 1
    fi
    if [ -L "$dst" ] && ! rm -- "$dst"; then
        rm -f -- "$tmp"
        err "$label: не удалось убрать конечный симлинк"
        return 1
    fi
    if ! mv -f -- "$tmp" "$dst"; then
        rm -f -- "$tmp"
        err "$label: атомарная замена не удалась"
        return 1
    fi
}

atomic_restore_claude() {
    local src="$1" dst="$2" parent tmp
    parent=$(dirname -- "$dst")
    if $DRY_RUN; then
        printf '  [dry-run] render CLAUDE.md atomically: %q -> %q\n' "$src" "$dst"
        return 0
    fi
    mkdir -p -- "$parent"
    if [ -e "$dst" ] && [ ! -f "$dst" ] && [ ! -L "$dst" ]; then
        err "CLAUDE.md: назначение не является обычным файлом: $dst"
        return 1
    fi
    tmp=$(mktemp -- "$parent/.CLAUDE.md.render.XXXXXX") || {
        err "CLAUDE.md: не удалось создать временный файл"
        return 1
    }
    if ! sed "s|{{HOME_DIR}}|$HOME_SED_SAFE|g" "$src" > "$tmp"; then
        rm -f -- "$tmp"
        err "CLAUDE.md: подстановка HOME не выполнена"
        return 1
    fi
    if [ -L "$dst" ] && ! rm -- "$dst"; then
        rm -f -- "$tmp"
        err "CLAUDE.md: не удалось убрать конечный симлинк"
        return 1
    fi
    if ! mv -f -- "$tmp" "$dst"; then
        rm -f -- "$tmp"
        err "CLAUDE.md: атомарная замена не удалась"
        return 1
    fi
}

# === Проверки ===
if [ ! -d "$EXOCORTEX_SRC" ]; then
    err "exocortex не найден: $EXOCORTEX_SRC"
    err "Укажи путь к governance-репо: restore-from-exocortex.sh <path>"
    exit 1
fi

if [ -z "$RESTORE_STDLIB_PYTHON3" ]; then
    err "Для безопасного восстановления нужен Python 3 (Unicode-защита приватных путей)"
    exit 1
fi

PARAMS_SRC="$EXOCORTEX_SRC/params.yaml"
PARAMS_DST="$WORKSPACE_DIR/params.yaml"
DAY_RHYTHM_SRC="$EXOCORTEX_SRC/day-rhythm-config.yaml"
DAY_RHYTHM_DST="$MEMORY_DST/day-rhythm-config.yaml"
PARAMS_SRC_PRESENT=false
if root_entry_has_exact_name "params.yaml"; then
    PARAMS_SRC_PRESENT=true
else
    exact_entry_rc=$?
    if [ "$exact_entry_rc" -ne 1 ]; then
        err "Не удалось безопасно проверить имя params.yaml в exocortex"
        exit 1
    fi
fi
DAY_RHYTHM_SRC_PRESENT=false
if root_entry_has_exact_name "day-rhythm-config.yaml"; then
    DAY_RHYTHM_SRC_PRESENT=true
else
    exact_entry_rc=$?
    if [ "$exact_entry_rc" -ne 1 ]; then
        err "Не удалось безопасно проверить имя day-rhythm-config.yaml в exocortex"
        exit 1
    fi
fi
if $PARAMS_SRC_PRESENT && [ -L "$PARAMS_SRC" ]; then
    err "params.yaml в exocortex является симлинком; восстановление остановлено до записи"
    exit 1
fi
if $DAY_RHYTHM_SRC_PRESENT && [ -L "$DAY_RHYTHM_SRC" ]; then
    err "day-rhythm-config.yaml в exocortex является симлинком; восстановление остановлено до записи"
    exit 1
fi

# Отказ от тихой перезаписи населённой memory/ (если не --force)
if [ -d "$MEMORY_DST" ] && [ -n "$(ls -A -- "$MEMORY_DST" 2>/dev/null)" ] && ! $FORCE && ! $DRY_RUN; then
    err "memory/ уже не пуста: $MEMORY_DST"
    err "Это похоже на существующую инсталляцию. Для перезаписи — --force (или --dry-run для превью)."
    exit 1
fi

log "Источник:    $EXOCORTEX_SRC"
log "Назначение:  $MEMORY_DST"
$DRY_RUN && warn "режим --dry-run: изменения не применяются"

# === Шаг 1: memory-файлы → auto-memory ===
run_cmd mkdir -p -- "$MEMORY_DST"
mem_count=0
# issue #343, вторая половина: плоский glob по верхнему уровню возвращал только
# memory/*.md и молча терял подпапки — memory/reference/agent-core.md не восстанавливался
# даже из бэкапа, где он есть. find обходит дерево целиком, относительный путь
# сохраняется, поэтому вложенность доезжает как есть.
while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    rel="${f#"$EXOCORTEX_SRC"/}"
    # Workspace-level files and private/multi-writer subtrees have their own
    # restore destinations or owners. Compare their first component after
    # NFKC+casefold so case-insensitive filesystems and Unicode aliases cannot
    # leak them into Claude auto-memory.
    if memory_restore_path_is_protected "$rel"; then
        continue
    else
        protection_rc=$?
        if [ "$protection_rc" -ne 1 ]; then
            err "Небезопасный относительный путь в exocortex; восстановление остановлено"
            exit 1
        fi
    fi
    run_cmd mkdir -p -- "$MEMORY_DST/$(dirname -- "$rel")"
    run_cmd cp -- "$f" "$MEMORY_DST/$rel"
    mem_count=$((mem_count + 1))
done < <(find -- "$EXOCORTEX_SRC" -type f \( -name '*.md' -o -name '*.yaml' -o -name '*.yml' \) -print0 2>/dev/null)
log "memory-файлов восстановлено: $mem_count"

# Day-rhythm is an owned root artefact in exocortex, but its live destination
# remains auto-memory. Keep it out of the generic scan (including case/NFKC
# aliases) and restore only the canonical regular file explicitly.
if $DAY_RHYTHM_SRC_PRESENT && [ -f "$DAY_RHYTHM_SRC" ]; then
    atomic_restore_copy "$DAY_RHYTHM_SRC" "$DAY_RHYTHM_DST" \
        "day-rhythm-config.yaml" || exit 1
    log "day-rhythm-config.yaml восстановлен → $DAY_RHYTHM_DST"
else
    warn "day-rhythm-config.yaml в exocortex отсутствует — пропуск"
fi

# === Шаг 1b: extensions/ → workspace (issue #235: exocortex/extensions/ зеркалится
# хуком memory-exocortex-sync.sh с 2026-07-11; бэкапы старше этой даты его не содержат) ===
EXTENSIONS_DST="$WORKSPACE_DIR/extensions"
if [ -d "$EXOCORTEX_SRC/extensions" ]; then
    if [ -d "$EXTENSIONS_DST" ] && [ -n "$(ls -A -- "$EXTENSIONS_DST" 2>/dev/null)" ] && ! $FORCE && ! $DRY_RUN; then
        warn "extensions/ уже не пуста: $EXTENSIONS_DST — пропуск (для перезаписи — --force)"
    else
        run_cmd mkdir -p -- "$EXTENSIONS_DST"
        ext_count=0
        shopt -s nullglob
        for f in "$EXOCORTEX_SRC/extensions"/*.md; do
            [ -f "$f" ] || continue
            fname=$(basename -- "$f")
            run_cmd cp -- "$f" "$EXTENSIONS_DST/$fname"
            ext_count=$((ext_count + 1))
        done
        shopt -u nullglob
        log "extensions-файлов восстановлено: $ext_count"
    fi
else
    warn "exocortex/extensions/ отсутствует (бэкап старее фикса #235, или extensions/ был пуст) — пропуск"
fi

# === Шаг 1c: rules/ → workspace ===
RULES_DST="$WORKSPACE_DIR/.claude/rules"
if [ -d "$EXOCORTEX_SRC/rules" ]; then
    if [ -d "$RULES_DST" ] && [ -n "$(ls -A -- "$RULES_DST" 2>/dev/null)" ] && ! $FORCE && ! $DRY_RUN; then
        warn "rules/ уже не пуста: $RULES_DST — пропуск (для восстановления — --force)"
    else
        run_cmd mkdir -p -- "$RULES_DST"
        rules_count=0
        while IFS= read -r -d '' f; do
            [ -f "$f" ] || continue
            rel="${f#"$EXOCORTEX_SRC/rules/"}"
            run_cmd mkdir -p -- "$RULES_DST/$(dirname -- "$rel")"
            run_cmd cp -- "$f" "$RULES_DST/$rel"
            rules_count=$((rules_count + 1))
        done < <(find -- "$EXOCORTEX_SRC/rules" -type f -print0 2>/dev/null)
        log "rules-файлов восстановлено: $rules_count"
    fi
else
    warn "exocortex/rules/ отсутствует (старый бэкап) — пропуск"
fi

# === Шаг 2: CLAUDE.md → workspace root ===
# issue #217: прямая подстановка {{HOME_DIR}} -> $HOME делает восстановление
# ОС-агностичным (бэкап пишется на плейсхолдере в day-close.sh, шаг 1).
# $HOME стоит в replacement-части sed s/// — экранируем & и \, иначе HOME с &
# трактуется как «весь совпавший текст» и портит путь (cold-review находка).
HOME_SED_SAFE=$(printf '%s' "$HOME" | sed 's/[|&\]/\\&/g')
if [ -f "$EXOCORTEX_SRC/CLAUDE.md" ]; then
    atomic_restore_claude "$EXOCORTEX_SRC/CLAUDE.md" "$WORKSPACE_DIR/CLAUDE.md" || exit 1
    log "CLAUDE.md восстановлен → $WORKSPACE_DIR/CLAUDE.md"
else
    warn "CLAUDE.md в exocortex отсутствует — пропуск"
fi

# params.yaml belongs in the workspace root. Existing user configuration is
# never overwritten implicitly; --force is the explicit recovery decision.
if $PARAMS_SRC_PRESENT && [ -f "$PARAMS_SRC" ]; then
    if { [ -e "$PARAMS_DST" ] || [ -L "$PARAMS_DST" ]; } && ! $FORCE; then
        warn "params.yaml уже существует в workspace — пропуск (для перезаписи — --force)"
    else
        atomic_restore_copy "$PARAMS_SRC" "$PARAMS_DST" "params.yaml" || exit 1
        log "params.yaml восстановлен → $PARAMS_DST"
    fi
else
    warn "params.yaml в exocortex отсутствует — пропуск"
fi

# === Шаг 3: симлинк $WORKSPACE_DIR/memory → auto-memory ===
LINK="$WORKSPACE_DIR/memory"
if [ -L "$LINK" ]; then
    current=$(readlink -- "$LINK")
    if [ "$current" = "$MEMORY_DST" ]; then
        log "Симлинк memory/ уже корректен"
    else
        warn "Симлинк memory/ указывает на $current (ожидалось $MEMORY_DST) — пересоздаю"
        run_cmd rm -- "$LINK"
        run_cmd ln -s -- "$MEMORY_DST" "$LINK"
    fi
elif [ -e "$LINK" ]; then
    warn "$LINK существует и НЕ симлинк — не трогаю (разбери вручную)"
else
    run_cmd ln -s -- "$MEMORY_DST" "$LINK"
    log "Симлинк создан: $LINK → $MEMORY_DST"
fi

echo ""
if $DRY_RUN; then
    warn "dry-run завершён. Для применения — запусти без --dry-run."
else
    log "Восстановление завершено. Перезапусти Claude Code для загрузки memory/."
fi
