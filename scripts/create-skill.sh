#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# create-skill.sh — create scaffold new skill IWE (SKILL.md v2)
# see DP.SC.153, DP.ROLE.057
#
# Usage:
#   bash create-skill.sh <skill-id> [--layer L1|L3] [--owner-role R6] [--skills-dir <path>]
#
# After creation:
#   1. Fill in SKILL.md v2 (promise, algorithm, failure mode)
#   2. bash validate-skill.sh <skill-id>
#   3. Smoke-test
#   4. If L1 → bash skill-promote.sh ...

set -uo pipefail

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
SKILLS_DIR="${IWE}/.claude/skills"
layer="L3"
owner_role=""
skill_id=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skills-dir) SKILLS_DIR="$2"; shift 2 ;;
        --layer)      layer="$2"; shift 2 ;;
        --owner-role) owner_role="$2"; shift 2 ;;
        -*)           echo "Unknown flag: $1" >&2; exit 1 ;;
        *)            [[ -z "$skill_id" ]] && skill_id="$1" || { echo "Extra argument: $1" >&2; exit 1; }; shift ;;
    esac
done

if [[ -z "$skill_id" ]]; then
    echo "Usage: $0 <skill-id> [--layer L1|L3] [--owner-role R#] [--skills-dir <path>]" >&2
    exit 1
fi

# Validation skill-id: kebab-case, lowercase only
if ! echo "$skill_id" | grep -qE '^[a-z][a-z0-9-]*$'; then
    echo "❌ skill-id must be kebab-case (lowercase letters, digits, hyphen): $skill_id" >&2
    exit 1
fi

# Validation layer
if [[ "$layer" != "L1" && "$layer" != "L3" ]]; then
    echo "❌ --layer must be L1 or L3 (received: $layer)" >&2
    exit 1
fi

# Check that the skill does not exist
skill_dir="${SKILLS_DIR}/${skill_id}"
if [[ -d "$skill_dir" ]]; then
    echo "❌ Skill already exists: $skill_dir" >&2
    echo "   Choose a different id or use the existing skill." >&2
    exit 1
fi

# Check for duplicate name in skills-catalog.yaml
catalog="${IWE}/.claude/skills-catalog.yaml"
if [[ -f "$catalog" ]]; then
    if grep -q "^  - id: ${skill_id}$" "$catalog" 2>/dev/null; then
        echo "❌ Skill '$skill_id' already in catalog. Choose a different id." >&2
        exit 1
    fi
fi

# Create directory and SKILL.md v2
mkdir -p "$skill_dir"

# Optional line owner_role
owner_line=""
[[ -n "$owner_role" ]] && owner_line="
owner_role: ${owner_role}               # role-skill owner role"

cat > "${skill_dir}/SKILL.md" <<SKILLEOF
---
# see DP.SC.153, DP.ROLE.057
name: ${skill_id}
description: "TODO: one line — what the skill does"
version: 1.0.0
layer: ${layer}
status: active${owner_line}
triggers:
  slash: [/${skill_id}]
  phrases: []
# depends_on: []
---

# /${skill_id} — TODO: Skill name

> **Role:** TODO: [R# Name]
> **Trigger:** TODO: [when it is invoked]
> **Service Clause:** DP.SC.153

## Promise (contract) (contract)

**Input:** TODO
**Output:** TODO
**Invariant:** TODO

## Algorithm

### Step 1. TODO

TODO

## Failure mode

| Scenario | Behavior |
|---------|-----------|
| TODO | TODO |
SKILLEOF

echo "✅ Skill created: ${skill_dir}/SKILL.md"
echo ""
echo "Next steps:"
echo "  1. Fill in SKILL.md (description, promise, algorithm, failure mode)"
echo "  2. bash validate-skill.sh ${skill_id}"
echo "  3. Smoke-test: invoke /${skill_id} and verify that it works"
echo "  4. If the skill belongs to strategic/facilitation categories — add id to RECALL_SKILLS hindsight_trigger.py for LLM-retain"
if [[ "$layer" == "L1" ]]; then
    FMT_DIR="${IWE_TEMPLATE:-${IWE}/IWE}"
    echo "  4. bash ${FMT_DIR}/scripts/skill-promote.sh ${skill_dir}/"
fi
