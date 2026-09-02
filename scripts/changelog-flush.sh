#!/usr/bin/env bash
# routing: helper  skill=week-close  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# changelog-flush.sh — переименовывает [Unreleased] → конкретную версию в CHANGELOG.md
#
# Использование:
#   bash changelog-flush.sh --version 0.31.0 [--dry-run]
#
# Если [Unreleased] нет — сначала вызвать changelog-append.sh.

set -uo pipefail

FMT_DIR="${IWE_TEMPLATE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CHANGELOG="$FMT_DIR/CHANGELOG.md"
dry_run=false
version=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) dry_run=true ;;
        --version) version="${2:-}"; shift ;;
    esac
    shift
done

if [[ -z "$version" ]]; then
    echo "Использование: $0 --version X.Y.Z [--dry-run]" >&2
    exit 1
fi

# #9 High-2 (ревью Ф14): после первого flush пустой заголовок [Unreleased]
# остаётся навсегда — проверка «заголовок существует» стала бы мёртвой и
# позволила бы чеканить пустые релизы. Сторож требует НЕПУСТОГО содержимого
# между [Unreleased] и следующим версионным заголовком.
UNRELEASED_CONTENT=$(awk '
    /^## \[Unreleased\]/ { in_u=1; next }
    in_u && /^## \[/ { exit }
    in_u && NF { print }
' "$CHANGELOG" 2>/dev/null)
if [ -z "$UNRELEASED_CONTENT" ]; then
    echo "⚠️  Секция [Unreleased] пуста или отсутствует. Сначала запусти: IWE_TEMPLATE=\"$FMT_DIR\" bash \"$FMT_DIR/scripts/changelog-append.sh\"" >&2
    exit 1
fi

today=$(date +%Y-%m-%d)
new_header="## [$version] — $today"

if $dry_run; then
    echo "dry-run: заменить '## [Unreleased] — ...' → '$new_header'"
    grep '## \[Unreleased\]' "$CHANGELOG"
    exit 0
fi

# 2026-08-23 (живой сбой перед v0.38.8): flush ПЕРЕИМЕНОВЫВАЛ заголовок
# [Unreleased] в версию — секция исчезала, changelog-append писал в пустоту,
# следующий бамп видел «нечего выпускать». awk вместо sed: заголовок остаётся
# на месте пустой секцией, версия вставляется новой секцией под ним
# (переносы строк в replacement непортируемы между GNU и BSD sed).
_flush_tmp="$CHANGELOG.flush.$$"
awk -v hdr="$new_header" '
    !done && /^## \[Unreleased\]/ { print "## [Unreleased]"; print ""; print hdr; done=1; next }
    { print }
' "$CHANGELOG" > "$_flush_tmp" && mv "$_flush_tmp" "$CHANGELOG" || {
    echo "❌ flush не применён (сбой awk/mv)" >&2
    rm -f "$_flush_tmp"
    exit 1
}

echo "✅ [Unreleased] → [$version] ($today), пустой заголовок [Unreleased] сохранён"
echo "Следующий шаг:"
echo "  cd $FMT_DIR && git add CHANGELOG.md && git commit -m 'chore: release v$version'"
