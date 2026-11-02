#!/usr/bin/env bash
# routing: migration  one-time=true
# see DP.SC.159, DP.ROLE.059
# migrate-skills-to-v2.sh — migration of existing skills to the SKILL.md v2 standard
# see DP.SC.153
#
# Adds the missing required frontmatter fields:
#   version, layer, status, triggers
# Does NOT change: name, description, SKILL.md body, existing fields.
#
# layer is determined automatically:
#   - skill exists in FMT-exocortex-template/.claude/skills/ -> L1
#   - skill only in the personal IWE -> L3
#
# Usage:
#   bash migrate-skills-to-v2.sh [--skills-dir <path>] [--dry-run] [--skill <id>]

set -uo pipefail

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
SKILLS_DIR="${IWE}/.claude/skills"
FMT_SKILLS="${IWE_TEMPLATE:-${IWE}/FMT-exocortex-template}/.claude/skills"
dry_run=false
only_skill=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skills-dir) SKILLS_DIR="$2"; shift 2 ;;
        --dry-run) dry_run=true; shift ;;
        --skill) only_skill="$2"; shift 2 ;;
        *) echo "Неизвестный флаг: $1" >&2; exit 1 ;;
    esac
done

log() { echo "$*" >&2; }

# Check whether a field is in the frontmatter
has_field() {
    local file="$1" field="$2"
    sed -n "/^---$/,/^---$/p" "$file" 2>/dev/null | grep "^${field}:" > /dev/null
}

# Determine the layer by whether the skill exists in FMT
detect_layer() {
    local skill_id="$1"
    if [[ -d "${FMT_SKILLS}/${skill_id}" ]]; then
        echo "L1"
    else
        echo "L3"
    fi
}

migrated=0
already_ok=0
errors=0

for skill_dir in "$SKILLS_DIR"/*/; do
    [[ -d "$skill_dir" ]] || continue
    skill_id=$(basename "$skill_dir")
    [[ "$skill_id" == "_template" ]] && continue
    [[ -n "$only_skill" && "$skill_id" != "$only_skill" ]] && continue

    skill_md="${skill_dir}SKILL.md"
    if [[ ! -f "$skill_md" ]]; then
        log "  ⚠️  [$skill_id] SKILL.md не найден — пропускаю"
        (( errors++ )) || true
        continue
    fi

    # Check whether migration is needed
    needs_fm=false
    ! has_field "$skill_md" "version" && needs_fm=true
    ! has_field "$skill_md" "layer" && needs_fm=true
    ! has_field "$skill_md" "status" && needs_fm=true
    ! has_field "$skill_md" "triggers" && needs_fm=true

    # Skills without any frontmatter — need separate handling
    has_frontmatter=true
    head -1 "$skill_md" | grep -q "^---" || has_frontmatter=false

    if ! $needs_fm && $has_frontmatter; then
        log "  ✅ [$skill_id] уже v2"
        (( already_ok++ )) || true
        continue
    fi

    layer=$(detect_layer "$skill_id")
    slash_trigger="/${skill_id}"

    if $dry_run; then
        log "  🔄 [$skill_id] мигрирую: layer=$layer"
        if ! $has_frontmatter; then
            log "     → добавить frontmatter с name, layer, version, status, triggers"
        else
            ! has_field "$skill_md" "version" && log "     → добавить version: 1.0.0"
            ! has_field "$skill_md" "layer" && log "     → добавить layer: $layer"
            ! has_field "$skill_md" "status" && log "     → добавить status: active"
            ! has_field "$skill_md" "triggers" && log "     → добавить triggers.slash: [$slash_trigger]"
        fi
        (( migrated++ )) || true
        continue
    fi

    # Apply the migration
    tmp=$(mktemp)

    if ! $has_frontmatter; then
        # Add frontmatter at the start of the file
        name_from_id=$(head -5 "$skill_md" | grep "^# " | head -1 | sed 's/^# *//' | sed 's/ — .*//' | sed 's/ *(.*)//' || echo "$skill_id")
        {
            echo "---"
            echo "name: ${skill_id}"
            echo "description: \"Скилл IWE — см. тело файла\""
            echo "version: 1.0.0"
            echo "layer: ${layer}"
            echo "status: active"
            echo "triggers:"
            echo "  slash: [${slash_trigger}]"
            echo "  phrases: []"
            echo "---"
            echo ""
            cat "$skill_md"
        } > "$tmp"
    else
        # Add the missing fields before the closing ---
        python3 - "$skill_md" "$layer" "$slash_trigger" <<'PYEOF' > "$tmp"
import sys, re

filepath, layer, slash = sys.argv[1], sys.argv[2], sys.argv[3]

with open(filepath, 'r') as f:
    content = f.read()

# Найти frontmatter (между первыми ---)
fm_match = re.match(r'^---\n(.*?)\n---\n', content, re.DOTALL)
if not fm_match:
    sys.stdout.write(content)
    sys.exit(0)

fm_body = fm_match.group(1)
rest = content[fm_match.end():]

lines = fm_body.split('\n')
new_lines = list(lines)

def has_field(lines, field):
    return any(l.startswith(field + ':') for l in lines)

if not has_field(lines, 'version'):
    new_lines.append('version: 1.0.0')

if not has_field(lines, 'layer'):
    new_lines.append(f'layer: {layer}')

if not has_field(lines, 'status'):
    new_lines.append('status: active')

if not has_field(lines, 'triggers'):
    new_lines.append('triggers:')
    new_lines.append(f'  slash: [{slash}]')
    new_lines.append('  phrases: []')

sys.stdout.write('---\n' + '\n'.join(new_lines) + '\n---\n' + rest)
PYEOF
    fi

    # Check that python did not break the file
    if [[ ! -s "$tmp" ]]; then
        log "  ❌ [$skill_id] ошибка миграции — файл пустой, пропускаю"
        rm -f "$tmp"
        (( errors++ )) || true
        continue
    fi

    cp "$tmp" "$skill_md"
    rm -f "$tmp"
    log "  ✅ [$skill_id] мигрирован (layer=$layer)"
    (( migrated++ )) || true
done

log ""
log "📊 Итого: мигрировано=$migrated, уже v2=$already_ok, ошибок=$errors"
if $dry_run; then
    log "   (dry-run: изменения не применены)"
fi
