#!/usr/bin/env bash
# routing: helper  skill=week-close,day-close  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# changelog-append.sh — идемпотентное обновление секции [Unreleased] в CHANGELOG.md
#
# Собирает git-коммиты с даты последней версии → пишет/заменяет блок [Unreleased].
# Идемпотентен: можно вызывать сколько угодно раз подряд — дубликатов не будет.
#
# Использование:
#   IWE_TEMPLATE=/path/to/FMT bash changelog-append.sh
#   bash changelog-append.sh --dry-run
#
# Для фиксации версии (Unreleased → X.Y.Z):
#   bash changelog-flush.sh --version 0.32.0

set -uo pipefail

dry_run=false

while [[ $# -gt 0 ]]; do
    case "$1" in --dry-run) dry_run=true ;; esac
    shift
done

# Write mode must never guess the target checkout. In author worktrees the
# historical fallback pointed at the canonical clone and silently modified it.
FMT_DIR="${IWE_TEMPLATE:-}"
if [[ -z "$FMT_DIR" ]]; then
    if ! $dry_run; then
        echo "❌ Режим записи требует явную цель: IWE_TEMPLATE=/path/to/FMT" >&2
        exit 2
    fi
    FMT_DIR="${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template"
    echo "⚠️  IWE_TEMPLATE не задан; dry-run читает fallback: $FMT_DIR" >&2
fi
CHANGELOG="$FMT_DIR/CHANGELOG.md"

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
# WP-7 Ф62 п.4: %(trailers:key=Changelog-Tag) достаёт классификацию (security/
# migration/behavior/optional) одним проходом вместе с hash+subject — DRR
# decisions/2026-08/2026-08-10-wp-7-arhgeyt-changelog-klassifikaciya-bez-lts.md.
commits=$(git -C "$FMT_DIR" log --after="$since_date" \
    --format='%h%x09%s%x09%(trailers:key=Changelog-Tag,valueonly,separator=%x2c)' 2>/dev/null || true)

if [[ -z "$commits" ]]; then
    echo "ℹ️  Нет новых коммитов с $last_date — [Unreleased] не нужен."
    exit 0
fi

# Группировка по типу
added=""
fixed=""
changed=""

VALID_CHANGELOG_TAGS="security migration behavior optional"

is_valid_changelog_tag() {
    local candidate="$1"
    for valid in $VALID_CHANGELOG_TAGS; do
        [[ "$candidate" == "$valid" ]] && return 0
    done
    return 1
}

while IFS=$'\t' read -r hash msg rawtag; do
    [[ -z "$hash" ]] && continue

    # Берём первое значение trailer'а, входящее в allowlist; остальное игнорируем.
    # Нет валидного тега → рендерим БЕЗ бирки, не подставляем "optional" молча
    # (DRR: "нет метки ≠ безопасно, просто не классифицировано").
    tag=""
    if [[ -n "$rawtag" ]]; then
        IFS=',' read -ra tag_candidates <<< "$rawtag"
        for candidate in "${tag_candidates[@]}"; do
            # найдено code review 13.08: "security, migration" (пробел после
            # запятой) даёт кандидата " migration" — без trim он не совпадёт
            # с allowlist и валидный тег молча потеряется, если стоит вторым.
            candidate="${candidate#"${candidate%%[![:space:]]*}"}"
            candidate="${candidate%"${candidate##*[![:space:]]}"}"
            if is_valid_changelog_tag "$candidate"; then
                tag="$candidate"
                break
            fi
        done
        # Диагностика только на реальной неоднозначности (несколько значений)
        # или невалидном единственном значении — не шумим на валидном одиночном
        # случае (пир-ревью с Codex, 2026-08-13).
        if [[ -n "$tag" && "${#tag_candidates[@]}" -gt 1 ]]; then
            # найдено verify-подагентом 13.08: тег фактически найден и
            # отрендерен — сообщение не должно говорить "без метки".
            echo "⚠️  Changelog-Tag неоднозначен в коммите $hash: '$rawtag' — беру первый валидный '$tag'" >&2
        elif [[ -z "$tag" ]]; then
            echo "⚠️  Changelog-Tag невалиден в коммите $hash: '$rawtag' — рендерю без метки" >&2
        fi
    fi

    prefix=""
    [[ -n "$tag" ]] && prefix="[$tag] "

    case "$msg" in
        feat*|feat\(*) added+="- ${prefix}\`$hash\` $msg"$'\n' ;;
        fix*|fix\(*)   fixed+="- ${prefix}\`$hash\` $msg"$'\n' ;;
        test*|docs*)   changed+="- ${prefix}\`$hash\` $msg"$'\n' ;;
        template-sync*) ;;  # авто-коммиты template-sync — пропускаем
        *)             changed+="- ${prefix}\`$hash\` $msg"$'\n' ;;
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
