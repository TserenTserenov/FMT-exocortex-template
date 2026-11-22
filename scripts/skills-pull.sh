#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# skills-pull.sh — synchronization L1 L1 skills from FMT into personal IWE
# see DP.SC.153, DP.ROLE.056
#
# Policy:
#   - L1 skill in FMT, not in IWE               → copy (new)
#   - L1 skill in FMT, in IWE layer: L3          → SKIP (author customization)
#   - L1 skill in FMT, in IWE layer: L1, no changes → update
#   - L1 skill in FMT, in IWE layer: L1, has changes → PAUSE + report to user
#
# Usage:
#   bash skills-pull.sh [--dry-run] [--force]
#   --force: update L1-skills even with local changes (apply FMT version)

set -uo pipefail

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
FMT_DIR="${IWE_TEMPLATE:-$IWE/IWE}"
IWE_SKILLS="${IWE}/.claude/skills"
FMT_SKILLS="${FMT_DIR}/.claude/skills"
dry_run=false
force=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) dry_run=true; shift ;;
        --force)   force=true; shift ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

log() { echo "$*" >&2; }

if [[ ! -d "$FMT_SKILLS" ]]; then
    log "❌ FMT skills dir not found: $FMT_SKILLS"
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
# (expand ${IWE:-...} → real user path)
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

log "🔄 skills-pull: synchronization L1 skills FMT → IWE"
log "   FMT: $FMT_SKILLS"
log "   IWE: $IWE_SKILLS"
log ""

for fmt_skill_dir in "$FMT_SKILLS"/*/; do
    [[ -d "$fmt_skill_dir" ]] || continue
    skill_id=$(basename "$fmt_skill_dir")
    [[ "$skill_id" == "_template" ]] && continue

    fmt_skill_md="${fmt_skill_dir}SKILL.md"
    if [[ ! -f "$fmt_skill_md" ]]; then
        log "  ⚠️  [$skill_id] no SKILL.md in FMT — skipping"
        (( errors++ )) || true
        continue
    fi

    fmt_layer=$(get_layer "$fmt_skill_md")
    if [[ "$fmt_layer" != "L1" ]]; then
        continue  # We are interested only in L1 skills from FMT
    fi

    iwe_skill_dir="${IWE_SKILLS}/${skill_id}"
    iwe_skill_md="${iwe_skill_dir}/SKILL.md"

    # ── Case 1: skill is absent in IWE → copy ─────────────────────────
    if [[ ! -d "$iwe_skill_dir" ]]; then
        if $dry_run; then
            log "  📥 [$skill_id] NEW — copy from FMT"
        else
            mkdir -p "$iwe_skill_dir"
            cp -r "$fmt_skill_dir"/. "$iwe_skill_dir/"
            # Expand substitutions in SKILL.md
            tmp=$(mktemp)
            apply_iwe_substitutions "$iwe_skill_md" "$tmp"
            mv "$tmp" "$iwe_skill_md"
            log "  ✅ [$skill_id] installed (L1)"
        fi
        (( new_count++ )) || true
        continue
    fi

    # Skill exists in IWE — checking layer
    if [[ ! -f "$iwe_skill_md" ]]; then
        log "  ⚠️  [$skill_id] directory exists, SKILL.md missing — skipping"
        (( errors++ )) || true
        continue
    fi

    iwe_layer=$(get_layer "$iwe_skill_md")

    # ── Case 2: IWE layer: L3 → skip (author customization) ──────────
    if [[ "$iwe_layer" == "L3" ]]; then
        log "  🛡️  [$skill_id] layer: L3 — skipping (author customization)"
        (( skipped_l3++ )) || true
        continue
    fi

    # ── Case 3/4: IWE layer: L1 — check for changes ────────────────────
    # Expand FMT version into a temporary file for comparison
    tmp_fmt=$(mktemp)
    apply_iwe_substitutions "$fmt_skill_md" "$tmp_fmt"

    if diff -q "$tmp_fmt" "$iwe_skill_md" > /dev/null 2>&1; then
        # Case 3: identical → nothing needs to be done
        log "  ✅ [$skill_id] up to date (L1)"
        rm -f "$tmp_fmt"
        continue
    fi

    # Case 4: there are differences
    if $force; then
        if $dry_run; then
            log "  🔄 [$skill_id] update (--force, L1)"
            diff "$iwe_skill_md" "$tmp_fmt" | head -10 || true
        else
            cp -r "$fmt_skill_dir"/. "$iwe_skill_dir/"
            apply_iwe_substitutions "$fmt_skill_md" "$iwe_skill_md"
            log "  ✅ [$skill_id] updated (--force)"
        fi
        (( updated_count++ )) || true
    else
        log "  ⚠️  [$skill_id] CONFLICT: local changes in L1-L1 skill"
        log "       Use --force to force update"
        log "       Or set layer: L3 if this is a custom author modification"
        diff "$iwe_skill_md" "$tmp_fmt" | head -5 || true
        (( conflict_count++ )) || true
    fi
    rm -f "$tmp_fmt"
done

log ""
log "📊 Total: new=$new_count, updated=$updated_count, L3-skipped=$skipped_l3, conflicts=$conflict_count, errors=$errors"

if $dry_run; then
    log "   (dry-run: changes not applied)"
fi

if [[ $conflict_count -gt 0 ]]; then
    log ""
    log "⚠️  $conflict_count conflict(s) require manual resolution."
    log "   Options:"
    log "   1. bash skills-pull.sh --force    # update from FMT (discard local changes.)"
    log "   2. Set layer: L3 in SKILL.md # protect as author customization"
    exit 1
fi

exit 0
