#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# skills-pull.sh — synchronization of L1 skills from FMT into the personal IWE
# see DP.SC.153, DP.ROLE.056
#
# Policy:
#   - L1 skill in FMT, absent in IWE               → copy (new)
#   - L1 skill in FMT, in IWE layer: L3          → SKIP (author's customization)
#   - L1 skill in FMT, in IWE layer: L1, unchanged → update
#   - L1 skill in FMT, in IWE layer: L1, changed → PAUSE + report to the user
#
# Usage:
#   bash skills-pull.sh [--dry-run] [--force]
#   --force: update L1 skills even with local changes (apply the FMT version)

set -uo pipefail

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
FMT_DIR="${IWE_TEMPLATE:-$IWE/FMT-exocortex-template}"
IWE_SKILLS="${IWE}/.claude/skills"
FMT_SKILLS="${FMT_DIR}/.claude/skills"
dry_run=false
force=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) dry_run=true; shift ;;
        --force)   force=true; shift ;;
        *) echo "Неизвестный флаг: $1" >&2; exit 1 ;;
    esac
done

log() { echo "$*" >&2; }

if [[ ! -d "$FMT_SKILLS" ]]; then
    log "❌ FMT skills dir не найден: $FMT_SKILLS"
    exit 1
fi

mkdir -p "$IWE_SKILLS"

# Helper function: get layer from SKILL.md
get_layer() {
    local skill_md="$1"
    sed -n '/^---$/,/^---$/p' "$skill_md" 2>/dev/null \
        | grep "^layer:" | head -1 \
        | sed 's/^layer: *//' | tr -d '\r'
}

# Apply substitutions when copying from FMT → IWE
# (expand ${IWE:-...} → the user's real path)
apply_iwe_substitutions() {
    local src="$1" dst="$2"
    sed \
        -e "s|\${IWE:-\$HOME/IWE}|${IWE}|g" \
        -e "s|\${IWE_GOVERNANCE_REPO:-DS-strategy}|${IWE_GOVERNANCE_REPO:-DS-strategy}|g" \
        "$src" > "$dst"
}

new_count=0
updated_count=0
skipped_l3=0
conflict_count=0
errors=0

log "🔄 skills-pull: синхронизация L1 скиллов FMT → IWE"
log "   FMT: $FMT_SKILLS"
log "   IWE: $IWE_SKILLS"
log ""

for fmt_skill_dir in "$FMT_SKILLS"/*/; do
    [[ -d "$fmt_skill_dir" ]] || continue
    skill_id=$(basename "$fmt_skill_dir")
    [[ "$skill_id" == "_template" ]] && continue

    fmt_skill_md="${fmt_skill_dir}SKILL.md"
    if [[ ! -f "$fmt_skill_md" ]]; then
        log "  ⚠️  [$skill_id] нет SKILL.md в FMT — пропуск"
        (( errors++ )) || true
        continue
    fi

    fmt_layer=$(get_layer "$fmt_skill_md")
    if [[ "$fmt_layer" != "L1" ]]; then
        continue  # We are only interested in L1 skills from FMT
    fi

    iwe_skill_dir="${IWE_SKILLS}/${skill_id}"
    iwe_skill_md="${iwe_skill_dir}/SKILL.md"

    # ── Case 1: the skill is absent in IWE → copy ───────────────────────────
    if [[ ! -d "$iwe_skill_dir" ]]; then
        if $dry_run; then
            log "  📥 [$skill_id] НОВЫЙ — скопировать из FMT"
        else
            mkdir -p "$iwe_skill_dir"
            cp -r "$fmt_skill_dir"/. "$iwe_skill_dir/"
            # Expand substitutions in SKILL.md
            tmp=$(mktemp)
            apply_iwe_substitutions "$iwe_skill_md" "$tmp"
            mv "$tmp" "$iwe_skill_md"
            log "  ✅ [$skill_id] установлен (L1)"
        fi
        (( new_count++ )) || true
        continue
    fi

    # The skill exists in IWE — look at layer
    if [[ ! -f "$iwe_skill_md" ]]; then
        log "  ⚠️  [$skill_id] директория есть, SKILL.md нет — пропуск"
        (( errors++ )) || true
        continue
    fi

    iwe_layer=$(get_layer "$iwe_skill_md")

    # ── Case 2: IWE layer: L3 → skip (author's customization) ───────────────
    if [[ "$iwe_layer" == "L3" ]]; then
        log "  🛡️  [$skill_id] layer: L3 — пропуск (авторская кастомизация)"
        (( skipped_l3++ )) || true
        continue
    fi

    # ── Case 3/4: IWE layer: L1 — check for changes ────────────────────────
    # Expand the FMT version into a temporary file for comparison
    tmp_fmt=$(mktemp)
    apply_iwe_substitutions "$fmt_skill_md" "$tmp_fmt"

    if diff -q "$tmp_fmt" "$iwe_skill_md" > /dev/null 2>&1; then
        # Case 3: identical → nothing to do
        log "  ✅ [$skill_id] актуален (L1)"
        rm -f "$tmp_fmt"
        continue
    fi

    # Case 4: there are differences
    if $force; then
        if $dry_run; then
            log "  🔄 [$skill_id] обновить (--force, L1)"
            diff "$iwe_skill_md" "$tmp_fmt" | head -10 || true
        else
            cp -r "$fmt_skill_dir"/. "$iwe_skill_dir/"
            apply_iwe_substitutions "$fmt_skill_md" "$iwe_skill_md"
            log "  ✅ [$skill_id] обновлён (--force)"
        fi
        (( updated_count++ )) || true
    else
        log "  ⚠️  [$skill_id] КОНФЛИКТ: локальные изменения в L1-скилле"
        log "       Используй --force для принудительного обновления"
        log "       Или установи layer: L3 если это авторская кастомизация"
        diff "$iwe_skill_md" "$tmp_fmt" | head -5 || true
        (( conflict_count++ )) || true
    fi
    rm -f "$tmp_fmt"
done

log ""
log "📊 Итого: новых=$new_count, обновлено=$updated_count, L3-пропущено=$skipped_l3, конфликтов=$conflict_count, ошибок=$errors"

if $dry_run; then
    log "   (dry-run: изменения не применены)"
fi

if [[ $conflict_count -gt 0 ]]; then
    log ""
    log "⚠️  $conflict_count конфликта(ов) требуют ручного разрешения."
    log "   Варианты:"
    log "   1. bash skills-pull.sh --force    # обновить из FMT (потерять локальные изм.)"
    log "   2. Установить layer: L3 в SKILL.md # защитить как авторскую кастомизацию"
    exit 1
fi

exit 0
