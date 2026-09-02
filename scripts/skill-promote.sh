#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# skill-promote.sh — промоция скилла в платформенный шаблон IWE (v2.1)
# see DP.SC.153, DP.ROLE.056
#
# Поток:
#   1. validate-skill.sh (gate: SKILL.md v2 обязателен)
#   2. Копирует <skill>/ → FMT/.claude/skills/<skill>/
#      - исключает мусор (.DS_Store, .git, .tmp)
#      - делает резервную копию перед перезаписью
#   3. Подстановки путей (HOME/IWE → env vars)
#   4. Устанавливает layer: L1 в FMT-копии SKILL.md
#   5. Запускает validate-fmt-scripts.sh на FMT (ловит хардкоды путей)
#   6. Регенерирует skills-catalog.yaml
#
# Использование:
#   bash skill-promote.sh <путь-к-папке-скилла> [--dry-run]

set -euo pipefail

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
BACKUP_DIR="$FMT_DIR/.backups/skill-promote"

if [[ ! -f "$SRC/SKILL.md" ]]; then
    echo "❌ В папке нет SKILL.md — это не скилл?" >&2
    exit 1
fi

echo "🔄 Промоция скилла: $skill_name/"
echo "   Откуда: $SRC"
echo "   Куда:   $DEST"
echo ""

# ── helpers ──────────────────────────────────────────────────────────────────

# Cross-platform sed -i (macOS requires empty string argument, GNU does not)
if sed --version >/dev/null 2>&1; then
    sed_inplace() { sed -i "$@"; }
else
    sed_inplace() { sed -i '' "$@"; }
fi

# Откат при ошибке
rollback() {
    local backup_path="${1:-}"
    echo "🔄 Откат изменений..." >&2
    rm -rf "$DEST"
    if [[ -n "$backup_path" && -d "$backup_path" ]]; then
        mv "$backup_path" "$DEST"
        echo "✅ Восстановлено из резервной копии" >&2
    fi
}

# Подстановка путей в файле
substitute_file() {
    local file="$1"
    local tmp
    tmp=$(mktemp)
    sed \
        -e "s|$HOME/IWE|\${IWE:-\$HOME/IWE}|g" \
        -e "s|$HOME|\$HOME|g" \
        -e "s|$GOV_REPO_AUTHOR|\${IWE_GOVERNANCE_REPO:-$GOV_REPO_TMPL}|g" \
        -e "s|^layer: L3|layer: L1|" \
        "$file" > "$tmp"
    # Preserve permissions cross-platform. GNU stat (-c) FIRST: on Linux `stat -f` means
    # --file-system and succeeds with garbage (not perms), so a BSD-first probe never falls
    # through to -c there. On macOS `stat -c` fails and falls back to BSD `-f '%Lp'`.
    local mode
    mode=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null || echo "644")
    chmod "$mode" "$tmp"
    mv "$tmp" "$file"
}

# ── Шаг 1. Валидация (gate) ──────────────────────────────────────────────────
VALIDATE_SCRIPT="$FMT_DIR/scripts/validate-skill.sh"
if [[ -f "$VALIDATE_SCRIPT" ]]; then
    echo "--- validate-skill.sh ---"
    if ! bash "$VALIDATE_SCRIPT" "$skill_name" --skills-dir "$(dirname "$SRC")" 2>&1; then
        echo "" >&2
        echo "❌ Промоция заблокирована: validate-skill.sh провалился." >&2
        echo "   Исправьте ошибки и повторите." >&2
        exit 1
    fi
    echo ""
else
    echo "⚠️  validate-skill.sh не найден — пропускаю валидацию (обновите FMT)"
fi

if $dry_run; then
    echo "--- dry-run: SKILL.md после подстановок + layer: L1 ---"
    sed \
        -e "s|$HOME/IWE|\${IWE:-\$HOME/IWE}|g" \
        -e "s|$HOME|\$HOME|g" \
        -e "s|$GOV_REPO_AUTHOR|\${IWE_GOVERNANCE_REPO:-$GOV_REPO_TMPL}|g" \
        -e "s|^layer: L3|layer: L1|" \
        "$SRC/SKILL.md"
    echo "--- конец ---"
    exit 0
fi

# ── Git status warning ───────────────────────────────────────────────────────
if [[ -d "$FMT_DIR/.git" ]]; then
    git_status=$(git -C "$FMT_DIR" status --short 2>/dev/null || true)
    if [[ -n "$git_status" ]]; then
        echo "⚠️  FMT-репо имеет незакоммиченные изменения:"
        echo "$git_status" | sed 's/^/     /'
        echo "   Промоция продолжится, но рекомендуется чистое состояние."
        echo ""
    fi
fi

# ── Шаг 2. Резервная копия ───────────────────────────────────────────────────
backup_path=""
if [[ -d "$DEST" && -n "$(ls -A "$DEST" 2>/dev/null)" ]]; then
    backup_path="$BACKUP_DIR/${skill_name}-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp -a "$DEST" "$backup_path"
    echo "📦 Резервная копия: $backup_path"
fi

# ── Шаг 3. Копирование директории ────────────────────────────────────────────
rm -rf "$DEST"
mkdir -p "$DEST"
# "$SRC"/. (not "$SRC"/) so the CONTENTS land in $DEST on both BSD (macOS) and GNU (Linux/CI)
# cp. With a bare trailing slash GNU cp nests the source as $DEST/<skill>/ when $DEST exists,
# and the later substitute_file "$DEST/SKILL.md" then fails with "No such file" (CI-only).
cp -a "$SRC"/. "$DEST"/

# ── Шаг 4. Удаление мусора ───────────────────────────────────────────────────
find "$DEST" -type f \( \
    -name ".DS_Store" -o \
    -name "*.bak" -o \
    -name "*.tmp" \
\) -delete 2>/dev/null || true

# ── Шаг 5. Подстановки путей + layer: L1 ─────────────────────────────────────
substitute_file "$DEST/SKILL.md"

# -- Blank USER-SPACE block content on promote (keep markers, clear inner content)
if grep -q '^<!-- USER-SPACE -->' "$DEST/SKILL.md" 2>/dev/null; then
    perl -i -0pe 's/^(<!-- USER-SPACE -->)\n.*?\n(<!-- \/USER-SPACE -->)/$1\n$2/ms' "$DEST/SKILL.md"
fi
# -- Ensure USER-SPACE marker exists in L1 SKILL.md (required by validate-fmt-scripts.sh)
if ! grep -q '^<!-- USER-SPACE -->' "$DEST/SKILL.md" 2>/dev/null; then
    printf '\n<!-- USER-SPACE -->\n<!-- /USER-SPACE -->\n' >> "$DEST/SKILL.md"
fi
# -- Replace install_constants actual values with {{KEY}} placeholders
IC_BLOCK=$(awk '/^install_constants:/{found=1} found && /^[a-z][^:]+:/ && !/^install_constants:/{exit} found{print}' "$DEST/SKILL.md" 2>/dev/null || true)
if [ -n "$IC_BLOCK" ]; then
    while IFS=': ' read -r key val; do
        key="${key#"${key%%[! ]*}"}"
        val="${val#"${val%%[! ]*}"}"
        [[ "$key" =~ ^[A-Z_]+$ ]] && [ -n "$val" ] || continue
        sed_inplace "s|${val}|{{${key}}}|g" "$DEST/SKILL.md"
    done <<< "$IC_BLOCK"
fi

# -- Replace L3-author marker values with {{PLACEHOLDER}} (WP-5 L1/L3-разделение в скиллах)
# Marker syntax: <!-- L3-author: KEY=value, в шаблоне → {{PLACEHOLDER}} -->
# Only quoted occurrences ("value") are substituted — a bare value elsewhere in the file
# (e.g. an illustrative example) is left untouched. Each marker is processed by line number
# (not `|`-joined fields) because `value` itself may legitimately contain `|`; substitution
# uses perl \Q..\E (literal quoting) so sed-special characters in `value` can't break the
# replacement or be misinterpreted. Marker is blanked to a `value`-free resolved form AFTER
# a successful substitution — if perl fails, the marker stays in its original (catchable) form.
while IFS=: read -r lineno marker; do
    [ -n "$lineno" ] || continue
    key=$(printf '%s' "$marker" | sed -E 's/^<!-- L3-author: ([A-Za-z_][A-Za-z0-9_]*)=.*/\1/')
    val=$(printf '%s' "$marker" | sed -E 's/^<!-- L3-author: [A-Za-z_][A-Za-z0-9_]*=(.*), в шаблоне → \{\{[A-Za-z0-9_]+\}\} -->$/\1/')
    placeholder=$(printf '%s' "$marker" | grep -oE '\{\{[A-Za-z0-9_]+\}\}')
    [ -n "$key" ] && [ -n "$val" ] && [ -n "$placeholder" ] || continue
    if perl -i -pe 'BEGIN{$v=shift @ARGV; $p=shift @ARGV} s/\Q"$v"\E/"$p"/g' "$val" "$placeholder" "$DEST/SKILL.md"; then
        sed_inplace -E "s|<!-- L3-author: ${key}=.*, в шаблоне → \{\{[A-Za-z0-9_]+\}\} -->|<!-- L3-author: ${key} was here, replaced with ${placeholder} -->|" "$DEST/SKILL.md"
    fi
done < <(grep -noE '<!-- L3-author: [A-Za-z_][A-Za-z0-9_]*=[^,]+, в шаблоне → \{\{[A-Za-z0-9_]+\}\} -->' "$DEST/SKILL.md" 2>/dev/null)

# Подстановки в .sh скрипты скилла (рекурсивно)
while IFS= read -r -d '' f; do
    substitute_file "$f"
done < <(find "$DEST" -type f -name "*.sh" -print0 2>/dev/null)

echo "✅ Промотирован: FMT/.claude/skills/$skill_name/ (layer: L1)"

# ── Шаг 6. Валидация FMT на хардкоды путей ───────────────────────────────────
FMT_VALIDATE_SCRIPT="$FMT_DIR/scripts/validate-fmt-scripts.sh"
if [[ -f "$FMT_VALIDATE_SCRIPT" ]]; then
    echo "--- validate-fmt-scripts.sh ---"
    if ! bash "$FMT_VALIDATE_SCRIPT" "$FMT_DIR/scripts" 2>&1; then
        echo "" >&2
        echo "❌ Промоция не прошла валидацию FMT (хардкоды путей)." >&2
        rollback "$backup_path"
        exit 1
    fi
    echo ""
else
    echo "⚠️  validate-fmt-scripts.sh не найден — пропускаю FMT-валидацию"
fi

# ── Шаг 7. Регенерация каталогов (author + FMT) ──────────────────────────────
CATALOG_SCRIPT="$FMT_DIR/scripts/generate-skills-catalog.sh"
if [[ -f "$CATALOG_SCRIPT" ]]; then
    echo "🔄 Регенерация skills-catalog.yaml (author)..."
    bash "$CATALOG_SCRIPT" 2>&1
    echo "🔄 Регенерация skills-catalog.yaml (FMT)..."
    bash "$CATALOG_SCRIPT" \
        --skills-dir "$FMT_DIR/.claude/skills" \
        --output "$FMT_DIR/.claude/skills-catalog.yaml" 2>&1
    if [[ -f "$FMT_DIR/.claude/skills-catalog.yaml" ]]; then
        sed -i.bak "s|^skills_dir: .*|skills_dir: .claude/skills|" "$FMT_DIR/.claude/skills-catalog.yaml"
        rm -f "$FMT_DIR/.claude/skills-catalog.yaml.bak"
    fi
fi

CHANGELOG_SCRIPT="$FMT_DIR/scripts/changelog-append.sh"
if [[ -f "$CHANGELOG_SCRIPT" ]]; then IWE_TEMPLATE="$FMT_DIR" bash "$CHANGELOG_SCRIPT"; fi

# ── Шаг 8. Запись в promotion-status.yaml (WP-7/PZ-6) ────────────────────────
PROMOTE_COMMON="$FMT_DIR/scripts/promote-common.sh"
if [[ -f "$PROMOTE_COMMON" ]]; then
    # shellcheck source=./promote-common.sh
    source "$PROMOTE_COMMON"
    record_promotion ".claude/skills/$skill_name" "skill" "" "" "na"
fi

# ── Шаг 9. Пересборка манифеста ──────────────────────────────────────────────
MANIFEST_SCRIPT="$FMT_DIR/generate-manifest.sh"
if [[ -f "$MANIFEST_SCRIPT" ]]; then
    echo "🔄 Пересборка update-manifest.json..."
    bash "$MANIFEST_SCRIPT" 2>&1
else
    echo "⚠️  generate-manifest.sh не найден — обнови update-manifest.json вручную"
fi

echo ""
echo "Следующий шаг:"
echo "  cd $FMT_DIR && git add .claude/skills/$skill_name .claude/skills-catalog.yaml CHANGELOG.md promotion-status.yaml update-manifest.json"
echo "  git commit -m 'feat(WP-7/SP1): promote skill $skill_name to platform (L1)'"
