#!/usr/bin/env bash
# routing: utility  deterministic=true
# see VR.SC.006 (release-verification-protocol)
#
# sync-version-badge.sh — синхронизация version badge в README.md с CHANGELOG.md
#
# Использование:
#   bash sync-version-badge.sh --check    # проверка drift (CI gate)
#   bash sync-version-badge.sh --fix      # исправление drift (локально / pre-commit)
#   bash sync-version-badge.sh            # --fix по умолчанию

set -uo pipefail

MODE="${1:---fix}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHANGELOG="$REPO_ROOT/CHANGELOG.md"
README="$REPO_ROOT/README.md"

if [[ ! -f "$CHANGELOG" ]]; then
    echo "FAIL: CHANGELOG.md не найден ($CHANGELOG)" >&2
    exit 1
fi

if [[ ! -f "$README" ]]; then
    echo "FAIL: README.md не найден ($README)" >&2
    exit 1
fi

# Извлекаем последнюю версию из CHANGELOG (первая строка ## [X.Y.Z])
CHANGELOG_VERSION=$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$CHANGELOG" \
    | sed 's/^## \[//;s/\]$//' || true)

if [[ -z "$CHANGELOG_VERSION" ]]; then
    echo "FAIL: не удалось извлечь версию из CHANGELOG.md" >&2
    exit 1
fi

# Извлекаем версию из README badge
README_VERSION=$(grep -oE 'version-[0-9]+\.[0-9]+\.[0-9]+' "$README" \
    | sed 's/version-//' | head -n1 || true)

if [[ -z "$README_VERSION" ]]; then
    echo "WARN: version badge не найден в README.md" >&2
    # Если бейджа нет — это не ошибка в режиме check, но и не PASS
    exit 0
fi

if [[ "$CHANGELOG_VERSION" == "$README_VERSION" ]]; then
    echo "PASS: version badge sync ($CHANGELOG_VERSION)"
    exit 0
fi

echo "FAIL: рассинхрон версий!"
echo "  CHANGELOG.md top: $CHANGELOG_VERSION"
echo "  README.md badge:  $README_VERSION"

if [[ "$MODE" == "--check" ]]; then
    echo "  Fix: запусти bash scripts/sync-version-badge.sh --fix"
    exit 1
fi

if [[ "$MODE" == "--fix" ]]; then
    # Обновляем бейдж в README
    sed -i.bak \
        -e "s/version-[0-9]\+\.[0-9]\+\.[0-9]\+/version-$CHANGELOG_VERSION/g" \
        "$README"
    rm -f "$README.bak"
    echo "  FIX: README.md обновлен до $CHANGELOG_VERSION"
    echo "  Следующий шаг: git add README.md && git commit --amend / отдельный коммит"
    exit 0
fi

echo "Использование: $0 [--check | --fix]" >&2
exit 1
