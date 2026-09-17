#!/usr/bin/env bash
# post-update-check-skills.sh — post-update detector for SKILL.md routing blocks (WP-350 Ф18)
# routing: executor=script deterministic=true
# see DP.SC.159, DP.ROLE.059
#
# Usage: bash post-update-check-skills.sh
# Run after update.sh to verify that routing blocks in modified SKILL.md are preserved.

set -uo pipefail

IWE="${IWE_ROOT:-$HOME/IWE}"
SKILLS_DIR="$IWE/.claude/skills"
EXIT_CODE=0

echo "=== Post-update SKILL.md routing check ==="

for skill in consent w-reflection check-secret transcribe; do
    skill_file="$SKILLS_DIR/$skill/SKILL.md"
    if [[ ! -f "$skill_file" ]]; then
        echo "❌ MISSING: $skill_file"
        EXIT_CODE=1
        continue
    fi
    if grep -q "routing:" "$skill_file"; then
        echo "✅ $skill: routing block present"
    else
        echo "⚠️  $skill: routing block LOST — restore from git or re-apply WP-350 Ф18"
        EXIT_CODE=1
    fi
done

if [[ $EXIT_CODE -eq 0 ]]; then
    echo "=== All routing blocks intact ==="
else
    echo "=== ACTION REQUIRED: some routing blocks missing ==="
fi

exit $EXIT_CODE
