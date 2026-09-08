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
#   - Commit/push НЕ делает — это происходит при Close (day-close backup + dirty-repo handling).
#     Хук отвечает только за файловое зеркало, не за git-транспорт.

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
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/IWE}"
GOVERNANCE_REPO="${GOVERNANCE_REPO:-${IWE_GOVERNANCE_REPO:-DS-strategy}}"
HOME_SLUG=$(echo "$HOME" | tr '/_.' '-')
MEMORY_SRC="${IWE_MEMORY_SRC:-$HOME/.claude/projects/${HOME_SLUG}-IWE/memory}"
EXOCORTEX_DST="$WORKSPACE_DIR/$GOVERNANCE_REPO/exocortex"

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
    reconcile_dir "$MEMORY_REAL" "$EXOCORTEX_DST" 1
    [ -n "$EXTENSIONS_REAL" ] && reconcile_dir "$EXTENSIONS_REAL" "$EXOCORTEX_DST/extensions"
    exit 0
fi

# Реальный каталог изменённого файла (резолвим возможный симлинк-путь)
FILE_DIR=$(cd "$(dirname "$FILE_PATH")" 2>/dev/null && pwd -P) || exit 0
FNAME=$(basename "$FILE_PATH")

# Файл должен лежать ПРЯМО в memory/ или в extensions/ (плоская структура обеих папок)
if [ "$FILE_DIR" = "$MEMORY_REAL" ]; then
    [ "$FNAME" = "day-rhythm-config.yaml" ] && exit 0
    mirror_file "$MEMORY_REAL" "$EXOCORTEX_DST" "$FNAME"
elif [ -n "$EXTENSIONS_REAL" ] && [ "$FILE_DIR" = "$EXTENSIONS_REAL" ]; then
    mirror_file "$EXTENSIONS_REAL" "$EXOCORTEX_DST/extensions" "$FNAME"
fi

exit 0
