#!/usr/bin/env bash
# routing: helper  skill=audit-installation  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# validate-skill.sh — validation SKILL.md v2 (pre-promote checklist)
# see DP.SC.153, DP.ROLE.057
#
# Checks:
#   - Required frontmatter fields frontmatter (name, description, version, layer, status, triggers)
#   - Format semver for version
#   - Allowed values layer (L1|L3) and status (active|experimental|deprecated)
#   - Presence of at least one slash-trigger
#   - depends_on depends_on references existing skills (warning, not a blocker)
#
# Usage:
#   bash validate-skill.sh <skill-id> [--skills-dir <path>]
#
# Exit 0 = OK, Exit 1 = validation error

set -uo pipefail

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
SKILLS_DIR="${IWE}/.claude/skills"
skill_id=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skills-dir) SKILLS_DIR="$2"; shift 2 ;;
        -*)           echo "Unknown flag: $1" >&2; exit 1 ;;
        *)            [[ -z "$skill_id" ]] && skill_id="$1" || { echo "Extra argument: $1" >&2; exit 1; }; shift ;;
    esac
done

if [[ -z "$skill_id" ]]; then
    echo "Usage: $0 <skill-id> [--skills-dir <path>]" >&2
    exit 1
fi

skill_md="${SKILLS_DIR}/${skill_id}/SKILL.md"
if [[ ! -f "$skill_md" ]]; then
    echo "❌ SKILL.md not found: $skill_md" >&2
    exit 1
fi

errors=0
warnings=0

fail() { echo "  ❌ $*"; (( errors++ )) || true; }
warn() { echo "  ⚠️  $*"; (( warnings++ )) || true; }
ok()   { echo "  ✅ $*"; }

echo "🔍 Validating skill: $skill_id"
echo "   File: $skill_md"
echo ""

# ── 1. Presence of frontmatter ──────────────────────────────────────────────────
if ! head -1 "$skill_md" | grep -q "^---"; then
    fail "Missing frontmatter (file does not start with ---)"
    echo ""
    echo "📊 Total: errors=$errors, warnings=$warnings"
    exit 1
fi

# Helper function: get field value from frontmatter
get_field() {
    local field="$1"
    sed -n "/^---$/,/^---$/p" "$skill_md" 2>/dev/null \
      | grep "^${field}:" \
      | head -1 \
      | sed "s/^${field}: *//" \
      | sed 's/^"\(.*\)"$/\1/' \
      | sed "s/^'\(.*\)'$/\1/" \
      | tr -d '\r'
}

# ── 2. Required fields ────────────────────────────────────────────────────
name_val=$(get_field "name")
if [[ -z "$name_val" ]]; then
    fail "Field 'name' is missing or empty"
else
    ok "name: $name_val"
fi

desc_val=$(get_field "description")
if [[ -z "$desc_val" ]]; then
    fail "Field 'description' is missing or empty"
elif echo "$desc_val" | grep -qi "TODO"; then
    fail "description contains TODO-placeholder: $desc_val"
else
    ok "description: ${desc_val:0:60}..."
fi

version_val=$(get_field "version")
if [[ -z "$version_val" ]]; then
    fail "Field 'version' is missing"
elif ! echo "$version_val" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    fail "version is not semver: '$version_val' (expected X.Y.Z)"
else
    ok "version: $version_val"
fi

layer_val=$(get_field "layer")
if [[ -z "$layer_val" ]]; then
    fail "Field 'layer' is missing"
elif [[ "$layer_val" != "L1" && "$layer_val" != "L3" ]]; then
    fail "layer must be L1 or L3 (got: '$layer_val')"
else
    ok "layer: $layer_val"
fi

status_val=$(get_field "status")
if [[ -z "$status_val" ]]; then
    fail "Field 'status' is missing"
elif [[ "$status_val" != "active" && "$status_val" != "experimental" && "$status_val" != "deprecated" ]]; then
    fail "status must be active|experimental|deprecated (got: '$status_val')"
else
    ok "status: $status_val"
fi

# ── 3. triggers ─────────────────────────────────────────────────────────────
if ! sed -n "/^---$/,/^---$/p" "$skill_md" | grep "^triggers:" > /dev/null; then
    fail "Field 'triggers' is missing"
else
    slash_val=$(sed -n '/^triggers:/,/^[a-z]/p' "$skill_md" \
        | grep "slash:" \
        | sed 's/.*slash: *\[//;s/\].*//' \
        | tr -d ' ')
    if [[ -z "$slash_val" || "$slash_val" == "" ]]; then
        fail "triggers.slash is empty — at least one slash-trigger (e.g.. [/${skill_id}])"
    else
        ok "triggers.slash: [$slash_val]"
    fi
fi

# ── 4. Checking depends_on (warning) ─────────────────────────────────
catalog="${IWE}/.claude/skills-catalog.yaml"
depends_line=$(grep "^depends_on:" "$skill_md" 2>/dev/null | head -1 || echo "")
if [[ -n "$depends_line" ]] && [[ "$depends_line" != "# depends_on: []" ]]; then
    deps=$(echo "$depends_line" | sed 's/^depends_on: *//;s/\[//;s/\]//;s/,/ /g')
    for dep in $deps; do
        dep=$(echo "$dep" | tr -d ' ')
        [[ -z "$dep" ]] && continue
        if [[ -f "$catalog" ]]; then
            if ! grep -q "^  - id: ${dep}$" "$catalog" 2>/dev/null; then
                warn "depends_on: skill '${dep}' not found in skills-catalog.yaml"
            else
                ok "depends_on: ${dep} ✓ (in catalog)"
            fi
        else
            warn "depends_on: skills-catalog.yaml not found — skipping check"
        fi
    done
fi

# ── 5. Checking TODO-placeholders in body ────────────────────────────────────────
todo_count=$(grep -c "^TODO\b\|^\*\*.*TODO\|: TODO$" "$skill_md" 2>/dev/null) || todo_count=0
if [[ "$todo_count" -gt 0 ]]; then
    warn "In the body of SKILL.md found TODO-placeholders: $todo_count (recommended to fill in before promote)"
fi

# ── 6. Deprecated without sunset ────────────────────────────────────────────────
if [[ "$status_val" == "deprecated" ]]; then
    sunset_val=$(get_field "sunset")
    if [[ -z "$sunset_val" ]]; then
        warn "status: deprecated without field 'sunset:' — it is recommended to specify the removal date"
    fi
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "📊 Total: errors=$errors, warnings=$warnings"

if [[ $errors -gt 0 ]]; then
    echo "❌ Skill did NOT pass validation — fix the errors before promote"
    exit 1
else
    echo "✅ Skill passed validation"
    if [[ $warnings -gt 0 ]]; then
        echo "   (${warnings} warnings — do not block promote, but it is recommended to fix them)"
    fi
    exit 0
fi
