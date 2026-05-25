#!/bin/bash
# routing: helper  skill=week-close,day-close  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# check-dirty-repos.sh — Скан всех IWE репо на незакоммиченные изменения
# Использование: ./scripts/check-dirty-repos.sh
# Вызывается из Day Close для обнаружения "забытых" файлов.

set -euo pipefail

IWE_DIR="${WORKSPACE_DIR:-$HOME/IWE}"
DIRTY=0
UNPUSHED=0

check_repo() {
    local dir="$1"
    local name="$2"

    if [ ! -d "$dir/.git" ]; then return; fi

    cd "$dir"

    # Uncommitted changes
    local changes=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [ "$changes" -gt 0 ]; then
        echo "⚠️  $name: $changes незакоммиченных файлов"
        git status --porcelain 2>/dev/null | head -5
        [ "$changes" -gt 5 ] && echo "   ... и ещё $((changes - 5))"
        DIRTY=$((DIRTY + 1))
    fi

    # Unpushed commits
    local ahead=$(git rev-list --count HEAD...@{upstream} --left-only 2>/dev/null || echo "0")
    if [ "$ahead" -gt 0 ]; then
        echo "↗️  $name: $ahead незапушенных коммитов"
        UNPUSHED=$((UNPUSHED + 1))
    fi
}

echo "🔍 Скан IWE репозиториев..."
echo ""

# Top-level repos
for dir in "$IWE_DIR"/*/; do
    [ -d "$dir/.git" ] && check_repo "$dir" "$(basename "$dir")"
done

# Nested repos (two levels deep)
for dir in "$IWE_DIR"/*/*/; do
    [ -d "$dir/.git" ] && check_repo "$dir" "$(basename "$(dirname "$dir")")/$(basename "$dir")"
done

echo ""
if [ "$DIRTY" -eq 0 ] && [ "$UNPUSHED" -eq 0 ]; then
    echo "✅ Все репо чистые и запушены"
else
    [ "$DIRTY" -gt 0 ] && echo "⚠️  $DIRTY репо с незакоммиченными изменениями"
    [ "$UNPUSHED" -gt 0 ] && echo "↗️  $UNPUSHED репо с незапушенными коммитами"
fi
