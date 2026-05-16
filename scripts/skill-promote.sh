#!/usr/bin/env bash
# skill-promote.sh — промоция личного скилла в платформенный шаблон IWE
#
# Поток: личная папка/<skill>/ → подстановки в SKILL.md → FMT/.claude/skills/<skill>/
#
# Использование:
#   bash skill-promote.sh <путь-к-папке-скилла> [--dry-run]

set -uo pipefail

SRC="${1:-}"
dry_run=false
[[ "${2:-}" == "--dry-run" ]] && dry_run=true

if [[ -z "$SRC" || ! -d "$SRC" ]]; then
    echo "Использование: $0 <путь-к-папке-скилла> [--dry-run]" >&2
    echo "Скилл = директория с SKILL.md внутри" >&2
    exit 1
fi

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
FMT_DIR="${IWE_TEMPLATE:-$IWE/FMT-exocortex-template}"
GOV_REPO_AUTHOR="${IWE_GOVERNANCE_REPO:-DS-strategy}"
GOV_REPO_TMPL="DS-strategy"

skill_name=$(basename "$SRC")
DEST="$FMT_DIR/.claude/skills/$skill_name"

if [[ ! -f "$SRC/SKILL.md" ]]; then
    echo "❌ В папке нет SKILL.md — это не скилл?" >&2
    exit 1
fi

echo "🔄 Промоция скилла: $skill_name/"
echo "   Откуда: $SRC"
echo "   Куда:   $DEST"
echo ""

if $dry_run; then
    echo "--- dry-run: SKILL.md после подстановок ---"
    sed \
        -e "s|$HOME/IWE|\${IWE:-\$HOME/IWE}|g" \
        -e "s|$HOME|\$HOME|g" \
        -e "s|$GOV_REPO_AUTHOR|\${IWE_GOVERNANCE_REPO:-$GOV_REPO_TMPL}|g" \
        "$SRC/SKILL.md"
    echo "--- конец ---"
    exit 0
fi

# Скопировать всю директорию
mkdir -p "$DEST"
cp -r "$SRC"/. "$DEST/"

# Применить подстановки к SKILL.md
tmp=$(mktemp)
sed \
    -e "s|$HOME/IWE|\${IWE:-\$HOME/IWE}|g" \
    -e "s|$HOME|\$HOME|g" \
    -e "s|$GOV_REPO_AUTHOR|\${IWE_GOVERNANCE_REPO:-$GOV_REPO_TMPL}|g" \
    "$DEST/SKILL.md" > "$tmp"
mv "$tmp" "$DEST/SKILL.md"

# Применить подстановки ко всем .sh в скилле
for f in "$DEST"/*.sh; do
    [[ -f "$f" ]] || continue
    tmp=$(mktemp)
    sed \
        -e "s|$HOME/IWE|\${IWE:-\$HOME/IWE}|g" \
        -e "s|$HOME|\$HOME|g" \
        -e "s|$GOV_REPO_AUTHOR|\${IWE_GOVERNANCE_REPO:-$GOV_REPO_TMPL}|g" \
        "$f" > "$tmp"
    mv "$tmp" "$f"
    chmod +x "$f"
done

echo "✅ Промотирован: FMT/.claude/skills/$skill_name/"
echo "Следующий шаг:"
echo "  cd $FMT_DIR && git add .claude/skills/$skill_name && git commit -m 'feat: promote skill $skill_name to platform'"
