#!/bin/bash
# memory-exocortex-sync.sh — зеркалит изменённый файл memory/* или extensions/* → exocortex/ (WP-033)
# Event: PostToolUse (matcher: Write|Edit|MultiEdit|Bash)
# see TserenTserenov/FMT-exocortex-template#125 (restore — вторая половина истории портируемости)
# see TserenTserenov/FMT-exocortex-template#235 (extensions/ добавлен — DATA-POLICY.md
#   обещает ему ту же защиту, что memory/, а хук раньше проверял только memory/)
# see TserenTserenov/FMT-exocortex-template#411 (Bash-вызовы не имеют .tool_input.file_path
#   и раньше проходили мимо хука незамеченными — команду не парсим (ненадёжно), вместо
#   этого после Bash-события сверяем mtime всего дерева memory/extensions с зеркалом)
#
# Назначение: при каждом изменении файла памяти/расширения держать exocortex/ его
# зеркалом, чтобы переезд на другое устройство / сбой не терял правки, сделанные среди дня.
# Раньше это был ручной `cp + commit` (правило feedback_exocortex_sync) — теперь авто.
#
# Инвариант: exocortex/ ⊇ актуальное состояние memory/ и extensions/ в любой момент,
# кроме day-rhythm-config.yaml: его конфликт-aware синхронизацию откладываем до Day Close.
# extensions/ зеркалится в exocortex/extensions/ (отдельная подпапка — предотвращает
# коллизии имён с memory/, если когда-нибудь совпадут).
# Принципы:
#   - НИКОГДА не блокирует операцию (exit 0 всегда; зеркалирование — побочный эффект).
#   - Дёшево: ранний выход для не-memory/не-extensions файлов до любых тяжёлых операций.
#   - Commit/push сам НЕ делает — это происходит при Close (day-close backup + dirty-repo handling).
#     Хук отвечает только за файловое зеркало, не за git-транспорт. Исключение — канон
#     под freeze (issue #1279): хук лишь запускает в фоне scripts/exocortex-publish.sh.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:${PATH:-}"

# jq нужен для парсинга stdin; нет jq — молча выходим (хук не критичен для операции)
command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Bash-вызов не даёт .tool_input.file_path — какой именно файл под memory/extensions
# он мог тронуть (heredoc, sed -i, cp, mv), надёжно не распарсить из текста команды.
# Вместо угадывания — сверяем mtime всего дерева memory/ и extensions/ с зеркалом
# (обе папки плоские и малочисленные по политике CLAUDE.md §4, дёшево).
if [ "$TOOL_NAME" = "Bash" ] && [ -z "$FILE_PATH" ]; then
    RECONCILE_BASH=1
elif [ -z "$FILE_PATH" ]; then
    exit 0
else
    # Только .md / .yaml / .yml (memory/ и extensions/ оба состоят из таких файлов). Ранний выход для кода/прочего.
    case "$FILE_PATH" in
        *.md|*.yaml|*.yml) ;;
        *) exit 0 ;;
    esac
fi

# Path-схема: override через env > симлинк $WORKSPACE_DIR/memory > пересборка slug.
# ВАЖНО: Claude Code слугифицирует путь проекта, заменяя на '-' не только '/', но и
# '_' и '.'. Если в $HOME есть '_' (напр. username john_doe), реальная папка проекта —
# '-home-john-doe-IWE', а 'tr / -' даёт фантом '-home-john_doe-IWE' → зеркало не пишется.
# Поэтому slug = tr '/_.' '-', а первичный источник — симлинк (не зависит от слугификации).
# issue #1336: резолвим workspace как остальные скрипты конвейера (canon из
# memory/dry-run-contract.md, issues #1233/#784/#785): env WORKSPACE_DIR >
# .iwe-paths (IWE_WORKSPACE) > $HOME/IWE. Раньше хук читал только env/$HOME
# и на установке с нестандартным workspace молча зеркалировал в несуществующий
# путь. Однострочная форма цепочки — байт-в-байт из вайтлиста dry-run-gate.sh.
IWE_PATHS="${IWE_PATHS_FILE:-}"; if [ -z "$IWE_PATHS" ]; then for _c in "$PWD/.iwe-paths" "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-paths" "$HOME/.iwe-paths"; do [ -r "$_c" ] && { IWE_PATHS="$_c"; break; }; done; fi; [ -n "$IWE_PATHS" ] && . "$IWE_PATHS"
WORKSPACE_DIR="${WORKSPACE_DIR:-${IWE_WORKSPACE:-$HOME/IWE}}"
GOVERNANCE_REPO="${GOVERNANCE_REPO:-${IWE_GOVERNANCE_REPO:-DS-strategy}}"
# issue #875: the fallback slug comes from the workspace itself, not from "$HOME" + "-IWE"
# (an install in a folder not named IWE would otherwise mirror another workspace's memory).
WORKSPACE_SLUG=$(echo "$WORKSPACE_DIR" | tr '/_.' '-')
MEMORY_SRC="${IWE_MEMORY_SRC:-$HOME/.claude/projects/${WORKSPACE_SLUG}/memory}"
EXOCORTEX_DST="$WORKSPACE_DIR/$GOVERNANCE_REPO/exocortex"

# issue #1279: while GOVERNANCE_REPO is frozen the canon is never written. Instead
# of mirroring into it, the hook hands the change to scripts/exocortex-publish.sh
# in the background: it refreshes a durable snapshot (day-close's own copy rules)
# and publishes exocortex/ from an isolated worktree through ds-publish.sh,
# throttled by --if-due. Same default-on condition as session-guard.sh's
# FROZEN_CANONICAL_PATHS (duplicated, not sourced — this hook stays standalone
# by design). A run holding the --canonical-owner right may write the canon, so
# strategist.sh passes IWE_CANONICAL_OWNER for it — a signal from the runner,
# not a permission check.
CANON_FROZEN=""
if [ -z "${IWE_CANONICAL_OWNER:-}" ] && { [ -z "${IWE_FROZEN_CANONICAL_PATH+x}" ] || [ -n "${IWE_FROZEN_CANONICAL_PATH:-}" ]; }; then
    FROZEN_PATH="${IWE_FROZEN_CANONICAL_PATH:-$WORKSPACE_DIR/$GOVERNANCE_REPO}"
    FROZEN_PATH_REAL=$(cd "$FROZEN_PATH" 2>/dev/null && pwd -P) || FROZEN_PATH_REAL=""
    EXOCORTEX_PARENT_REAL=$(cd "$WORKSPACE_DIR/$GOVERNANCE_REPO" 2>/dev/null && pwd -P) || EXOCORTEX_PARENT_REAL=""
    if [ -n "$FROZEN_PATH_REAL" ] && [ -n "$EXOCORTEX_PARENT_REAL" ] && [ "$FROZEN_PATH_REAL" = "$EXOCORTEX_PARENT_REAL" ]; then
        CANON_FROZEN=1
    fi
fi

# Paths KEEP IN SYNC with scripts/exocortex-publish.sh.
EXO_META="${IWE_RUNTIME_DIR:-$WORKSPACE_DIR/.iwe-runtime}/exocortex-publish"
TRIGGER_MIN_INTERVAL="${IWE_EXOCORTEX_TRIGGER_MIN_INTERVAL:-60}"

# mtime_epoch FILE — GNU stat first (BSD "stat -f" means something else on Linux).
mtime_epoch() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Throttle: no second background run while one is alive (it is told about the
# change through run.pending and repeats), and at most one launch per
# TRIGGER_MIN_INTERVAL seconds, so a persistently failing snapshot cannot pile
# up processes. Returns 0 when a new run should be launched.
frozen_trigger_due() {
    local pid last now
    mkdir -p "$EXO_META" 2>/dev/null || return 1
    pid=$(cat "$EXO_META/run.active" 2>/dev/null) || pid=""
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        : > "$EXO_META/run.pending"
        return 1
    fi
    if [ -f "$EXO_META/trigger.stamp" ]; then
        last=$(mtime_epoch "$EXO_META/trigger.stamp") || last=0
        now=$(date +%s)
        [ $((now - last)) -ge "$TRIGGER_MIN_INTERVAL" ] || return 1
    fi
    : > "$EXO_META/trigger.stamp"
}

# Starts the publisher detached: all descriptors go to its log, so the hook never
# waits for it and always exits 0.
trigger_frozen_publish() {
    local hook_dir publisher="" c
    frozen_trigger_due || return 0
    hook_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || hook_dir=""
    for c in "${IWE_SCRIPTS:-}/exocortex-publish.sh" "$WORKSPACE_DIR/scripts/exocortex-publish.sh" \
             "${IWE_TEMPLATE:-$WORKSPACE_DIR/FMT-exocortex-template}/scripts/exocortex-publish.sh" \
             "${hook_dir:+$hook_dir/../../scripts/exocortex-publish.sh}"; do
        case "$c" in /*) [ -f "$c" ] && { publisher="$c"; break; } ;; esac
    done
    if [ -z "$publisher" ]; then
        echo "memory-exocortex-sync: $GOVERNANCE_REPO под freeze, exocortex-publish.sh не найден — зеркало пропущено (issue #1279)" >&2
        return 0
    fi
    WORKSPACE_DIR="$WORKSPACE_DIR" GOVERNANCE_REPO="$GOVERNANCE_REPO" \
        bash "$publisher" run --background --if-due >/dev/null 2>&1 </dev/null || true
    echo "memory-exocortex-sync: $GOVERNANCE_REPO под freeze — снимок памяти обновляется и публикуется в фоне через изолированную копию (issue #1279), канон не пишется" >&2
}

# Канонический реальный путь memory/. Приоритет — симлинк $WORKSPACE_DIR/memory
# (указывает на auto-memory независимо от правил слугификации); fallback — MEMORY_SRC.
if [ -z "${IWE_MEMORY_SRC:-}" ] && [ -d "$WORKSPACE_DIR/memory" ]; then
    MEMORY_REAL=$(cd "$WORKSPACE_DIR/memory" 2>/dev/null && pwd -P) || exit 0
else
    MEMORY_REAL=$(cd "$MEMORY_SRC" 2>/dev/null && pwd -P) || exit 0
fi
EXTENSIONS_REAL=$(cd "$WORKSPACE_DIR/extensions" 2>/dev/null && pwd -P) || EXTENSIONS_REAL=""

mirror_file() {
    local src_dir="$1" dst_dir="$2" fname="$3"
    [ -f "$src_dir/$fname" ] || return 1
    mkdir -p "$dst_dir" 2>/dev/null || return 1
    cp "$src_dir/$fname" "$dst_dir/$fname" 2>/dev/null
}

if [ -n "${RECONCILE_BASH:-}" ]; then
    reconcile_dir() {
        local src_dir="$1" dst_dir="$2" skip_day_rhythm="${3:-0}"
        [ -d "$src_dir" ] || return 0
        find "$src_dir" -maxdepth 1 -type f \( -name '*.md' -o -name '*.yaml' -o -name '*.yml' \) 2>/dev/null |
        while IFS= read -r f; do
            local fname; fname=$(basename "$f")
            # day-rhythm has a conflict-aware Day Close contract (#536). A raw
            # hook cp would bypass the empty-calendar guard and destroy its
            # byte-preserving decision, so neither direct nor Bash reconcile
            # may mirror this root file.
            if [ "$skip_day_rhythm" = "1" ] && [ "$fname" = "day-rhythm-config.yaml" ]; then
                continue
            fi
            if [ ! -f "$dst_dir/$fname" ] || [ "$f" -nt "$dst_dir/$fname" ]; then
                mirror_file "$src_dir" "$dst_dir" "$fname"
            fi
        done
    }
    if [ -n "$CANON_FROZEN" ]; then
        # Cheap change detection against the snapshot stamp (path KEEP IN SYNC
        # with scripts/exocortex-publish.sh): no change, no background run.
        STAMP="$EXO_META/snapshot.stamp"
        CHANGED=""
        if [ ! -f "$STAMP" ]; then
            CHANGED=1
        else
            for d in "$MEMORY_REAL" "$EXTENSIONS_REAL"; do
                [ -n "$d" ] && [ -d "$d" ] || continue
                if [ -n "$(find "$d" -maxdepth 1 -type f \( -name '*.md' -o -name '*.yaml' -o -name '*.yml' \) -newer "$STAMP" 2>/dev/null | head -n 1)" ]; then
                    CHANGED=1; break
                fi
            done
        fi
        [ -n "$CHANGED" ] && trigger_frozen_publish
        exit 0
    fi
    reconcile_dir "$MEMORY_REAL" "$EXOCORTEX_DST" 1
    [ -n "$EXTENSIONS_REAL" ] && reconcile_dir "$EXTENSIONS_REAL" "$EXOCORTEX_DST/extensions"
    exit 0
fi

# Реальный каталог изменённого файла (резолвим возможный симлинк-путь)
FILE_DIR=$(cd "$(dirname "$FILE_PATH")" 2>/dev/null && pwd -P) || exit 0
FNAME=$(basename "$FILE_PATH")

# Файл должен лежать ПРЯМО в memory/ или в extensions/ (плоская структура обеих папок)
if [ -n "$CANON_FROZEN" ]; then
    if [ "$FILE_DIR" = "$MEMORY_REAL" ] || { [ -n "$EXTENSIONS_REAL" ] && [ "$FILE_DIR" = "$EXTENSIONS_REAL" ]; }; then
        trigger_frozen_publish
    fi
    exit 0
fi
if [ "$FILE_DIR" = "$MEMORY_REAL" ]; then
    [ "$FNAME" = "day-rhythm-config.yaml" ] && exit 0
    mirror_file "$MEMORY_REAL" "$EXOCORTEX_DST" "$FNAME"
elif [ -n "$EXTENSIONS_REAL" ] && [ "$FILE_DIR" = "$EXTENSIONS_REAL" ]; then
    mirror_file "$EXTENSIONS_REAL" "$EXOCORTEX_DST/extensions" "$FNAME"
fi

exit 0
