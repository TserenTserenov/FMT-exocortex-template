#!/usr/bin/env bash
# routing: helper  skill=week-close,day-close  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# changelog-append.sh — идемпотентное обновление секции [Unreleased] в CHANGELOG.md
#
# Собирает git-коммиты с даты последней версии → пишет/заменяет блок [Unreleased].
# Идемпотентен: можно вызывать сколько угодно раз подряд — дубликатов не будет.
#
# Использование:
#   bash changelog-append.sh [--dry-run]
#
# Для фиксации версии (Unreleased → X.Y.Z):
#   bash changelog-flush.sh --version 0.32.0

set -uo pipefail

FMT_DIR="${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template}"
CHANGELOG="$FMT_DIR/CHANGELOG.md"
dry_run=false

while [[ $# -gt 0 ]]; do
    case "$1" in --dry-run) dry_run=true ;; esac
    shift
done

if [[ ! -f "$CHANGELOG" ]]; then
    echo "❌ CHANGELOG.md не найден: $CHANGELOG" >&2
    exit 1
fi

# Найти дату последней именованной версии (пропускаем [Unreleased])
last_date=$(grep '## \[[0-9]' "$CHANGELOG" | head -1 | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' || true)
if [[ -z "$last_date" ]]; then
    echo "⚠️  Не нашёл дату последней версии в CHANGELOG — собираю все коммиты." >&2
    last_date="1970-01-01"
fi

# Б2: --after exclusive — вычитаем 1 день чтобы не потерять коммиты дня выпуска
# Б4: git -C вместо cd, чтобы не зависеть от cwd при ошибке IWE_TEMPLATE
since_date=$(date -d "$last_date - 1 day" +%Y-%m-%d 2>/dev/null \
    || date -v-1d -j -f "%Y-%m-%d" "$last_date" +%Y-%m-%d 2>/dev/null \
    || echo "$last_date")
commits=$(git -C "$FMT_DIR" log --after="$since_date" --format="%h %s" 2>/dev/null || true)

if [[ -z "$commits" ]]; then
    echo "ℹ️  Нет новых коммитов с $last_date — [Unreleased] не нужен."
    exit 0
fi

# Группировка по типу
added=""
fixed=""
changed=""

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    hash="${line%% *}"
    msg="${line#* }"
    case "$msg" in
        feat*|feat\(*) added+="- \`$hash\` $msg"$'\n' ;;
        fix*|fix\(*)   fixed+="- \`$hash\` $msg"$'\n' ;;
        test*|docs*)   changed+="- \`$hash\` $msg"$'\n' ;;
        template-sync*) ;;  # авто-коммиты template-sync — пропускаем
        *)             changed+="- \`$hash\` $msg"$'\n' ;;
    esac
done <<< "$commits"

# Если все коммиты были пропущены (template-sync) — ничего не делать
if [[ -z "$added" && -z "$fixed" && -z "$changed" ]]; then
    echo "ℹ️  Только авто-коммиты template-sync — [Unreleased] не нужен."
    exit 0
fi

# Собрать блок [Unreleased]
today=$(date +%Y-%m-%d)
new_block="## [Unreleased] — обновлено $today"$'\n'$'\n'
[[ -n "$added"   ]] && new_block+="### Added"$'\n'$'\n'"${added}"$'\n'
[[ -n "$changed" ]] && new_block+="### Changed"$'\n'$'\n'"${changed}"$'\n'
[[ -n "$fixed"   ]] && new_block+="### Fixed"$'\n'$'\n'"${fixed}"$'\n'

if $dry_run; then
    echo "--- dry-run: блок [Unreleased] ---"
    printf '%s\n' "$new_block"
    echo "--- конец ---"
    exit 0
fi

# Идемпотентность: удалить старый [Unreleased] блок если есть
tmp=$(mktemp)
awk '
    /^## \[Unreleased\]/ { skip=1; next }
    skip && /^## \[/     { skip=0 }
    !skip                { print }
' "$CHANGELOG" > "$tmp"

# Препендить новый блок после заголовка (до первой строки ## [)
header_end=$(grep -n '^## \[' "$tmp" | head -1 | cut -d: -f1)
if [[ -z "$header_end" ]]; then
    # Б1: CHANGELOG без именованных версий — корректная запись
    { cat "$tmp"; echo; printf '%s\n' "$new_block"; } > "$CHANGELOG"
else
    head_lines=$((header_end - 1))
    { head -n "$head_lines" "$tmp"; echo; printf '%s\n' "$new_block"; tail -n +"$header_end" "$tmp"; } > "$CHANGELOG"
fi

rm -f "$tmp"
echo "✅ [Unreleased] обновлён в CHANGELOG.md (коммиты с $last_date)"
