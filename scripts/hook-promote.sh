#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# hook-promote.sh — промоция личного хука в платформенный шаблон IWE
#
# Поток: личная папка/<hook>.sh → подстановки → FMT/.claude/hooks/<hook>.sh
#
# Использование:
#   bash hook-promote.sh <путь-к-хуку> [--dry-run]

set -uo pipefail

SRC="${1:-}"
dry_run=false
[[ "${2:-}" == "--dry-run" ]] && dry_run=true

if [[ -z "$SRC" || ! -f "$SRC" ]]; then
    echo "Использование: $0 <путь-к-хуку> [--dry-run]" >&2
    exit 1
fi

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
FMT_DIR="${IWE_TEMPLATE:-$IWE/FMT-exocortex-template}"
GOV_REPO_AUTHOR="${IWE_GOVERNANCE_REPO:-DS-strategy}"
GOV_REPO_TMPL="DS-strategy"

fname=$(basename "$SRC")
DEST="$FMT_DIR/.claude/hooks/$fname"

echo "🔄 Промоция хука: $fname"
echo "   Откуда: $SRC"
echo "   Куда:   $DEST"
echo ""

result=$(sed \
    -e "s|$HOME/IWE|\${IWE:-\$HOME/IWE}|g" \
    -e "s|$HOME|\$HOME|g" \
    -e "s|$GOV_REPO_AUTHOR|\${IWE_GOVERNANCE_REPO:-$GOV_REPO_TMPL}|g" \
    "$SRC")

if $dry_run; then
    echo "--- dry-run: результат после подстановок ---"
    printf '%s\n' "$result"
    echo "--- конец ---"
    exit 0
fi

# Валидация через временный файл
tmp_dir=$(mktemp -d)
tmp_file="$tmp_dir/$fname"
printf '%s\n' "$result" > "$tmp_file"
chmod +x "$tmp_file"

VALIDATOR="$FMT_DIR/scripts/validate-fmt-scripts.sh"
if [[ -f "$VALIDATOR" ]]; then
    if ! bash "$VALIDATOR" "$tmp_dir" 2>&1; then
        rm -rf "$tmp_dir"
        echo "❌ После подстановок остались личные хардкоды. Используй --dry-run." >&2
        exit 1
    fi
fi

# Smoke-тест в изолированном env с шаблонными переменными
echo "   smoke-test с шаблонным окружением..."
smoke_result=0
env -i \
    HOME="/tmp/iwe-smoke-user" \
    IWE="/tmp/iwe-smoke-user/IWE" \
    IWE_GOVERNANCE_REPO="DS-strategy" \
    PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
    bash "$tmp_file" --help > /dev/null 2>&1 || smoke_result=$?

if [[ $smoke_result -eq 127 ]]; then
    rm -rf "$tmp_dir"
    echo "❌ Smoke-тест: exit 127 — хук не запускается в чужом окружении." >&2
    exit 1
fi
echo "   smoke-test: OK (exit $smoke_result)"

cp "$tmp_file" "$DEST"
chmod +x "$DEST"
rm -rf "$tmp_dir"

echo "✅ Промотирован: FMT/.claude/hooks/$fname"

CHANGELOG_SCRIPT="$FMT_DIR/scripts/changelog-append.sh"
if [[ -f "$CHANGELOG_SCRIPT" ]]; then bash "$CHANGELOG_SCRIPT"; fi

MANIFEST_SCRIPT="$FMT_DIR/generate-manifest.sh"
if [[ -f "$MANIFEST_SCRIPT" ]]; then
    echo "🔄 Пересборка update-manifest.json..."
    bash "$MANIFEST_SCRIPT" 2>&1
else
    echo "⚠️  generate-manifest.sh не найден — обнови update-manifest.json вручную"
fi

echo "Следующий шаг:"
echo "  cd $FMT_DIR && git add .claude/hooks/$fname CHANGELOG.md update-manifest.json && git commit -m 'feat: promote $fname to platform'"
