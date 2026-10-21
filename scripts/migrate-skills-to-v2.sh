#!/usr/bin/env bash
# routing: migration  one-time=true
# see DP.SC.159, DP.ROLE.059
# migrate-skills-to-v2.sh — migration of existing skills to the standard SKILL.md v2
# see DP.SC.153
#
# Adds missing required fields frontmatter:
#   version, layer, status, triggers
# Does NOT change: name, description, body SKILL.md, existing fields.
#
# layer is determined automatically:
#   - skill is present in IWE/.claude/skills/ → L1
#   - skill is only in the personal IWE → L3
#
# Usage:
#   bash migrate-skills-to-v2.sh [--skills-dir <path>] [--dry-run] [--skill <id>]

set -uo pipefail

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
SKILLS_DIR="${IWE}/.claude/skills"
FMT_SKILLS="${IWE_TEMPLATE:-${IWE}/IWE}/.claude/skills"
dry_run=false
only_skill=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skills-dir) SKILLS_DIR="$2"; shift 2 ;;
        --dry-run) dry_run=true; shift ;;
        --skill) only_skill="$2"; shift 2 ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

log() { echo "$*" >&2; }

# Check whether the field exists in frontmatter
has_field() {
    local file="$1" field="$2"
    sed -n "/^---$/,/^---$/p" "$file" 2>/dev/null | grep "^${field}:" > /dev/null
}

# Determine layer based on the presence of the skill in FMT
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
        log "  ⚠️  [$skill_id] SKILL.md not found — skipping"
        (( errors++ )) || true
        continue
    fi

    # Check whether migration is needed
    needs_fm=false
    ! has_field "$skill_md" "version" && needs_fm=true
    ! has_field "$skill_md" "layer" && needs_fm=true
    ! has_field "$skill_md" "status" && needs_fm=true
    ! has_field "$skill_md" "triggers" && needs_fm=true

    # Skills without frontmatter at all — separate handling is required
    has_frontmatter=true
    head -1 "$skill_md" | grep -q "^---" || has_frontmatter=false

    if ! $needs_fm && $has_frontmatter; then
        log "  ✅ [$skill_id] already v2"
        (( already_ok++ )) || true
        continue
    fi

    layer=$(detect_layer "$skill_id")
    slash_trigger="/${skill_id}"

    if $dry_run; then
        log "  🔄 [$skill_id] migrating: layer=$layer"
        if ! $has_frontmatter; then
            log "     → add frontmatter with name, layer, version, status, triggers"
        else
            ! has_field "$skill_md" "version" && log "     → add version: 1.0.0"
            ! has_field "$skill_md" "layer" && log "     → add layer: $layer"
            ! has_field "$skill_md" "status" && log "     → add status: active"
            ! has_field "$skill_md" "triggers" && log "     → add triggers.slash: [$slash_trigger]"
        fi
        (( migrated++ )) || true
        continue
    fi

    # Apply migration
    tmp=$(mktemp)

    if ! $has_frontmatter; then
        # Add frontmatter at the beginning of the file
        name_from_id=$(head -5 "$skill_md" | grep "^# " | head -1 | sed 's/^# *//' | sed 's/ — .*//' | sed 's/ *(.*)//' || echo "$skill_id")
        {
            echo "---"
            echo "name: ${skill_id}"
            echo "description: \"IWE skill IWE — see. file body\""
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
        # Add missing fields before the closing ---
        python3 - "$skill_md" "$layer" "$slash_trigger" <<'PYEOF' > "$tmp"
import sys, re

filepath, layer, slash = sys.argv[1], sys.argv[2], sys.argv[3]

with open(filepath, 'r') as f:
    content = f.read()

# Find frontmatter (between the first pair of ---)
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

    # Verify that python did not corrupt the file python did not corrupt the file
    if [[ ! -s "$tmp" ]]; then
        log "  ❌ [$skill_id] migration error — file is empty, skipping"
        rm -f "$tmp"
        (( errors++ )) || true
        continue
    fi

    cp "$tmp" "$skill_md"
    rm -f "$tmp"
    log "  ✅ [$skill_id] migrated (layer=$layer)"
    (( migrated++ )) || true
done

log ""
log "📊 Total: migrated=$migrated, already v2=$already_ok, errors=$errors"
if $dry_run; then
    log "   (dry-run: changes not applied)"
fi
