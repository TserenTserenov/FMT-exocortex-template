#!/usr/bin/env bash
# test_issue_836_reflection.sh — the reflection template must tell the pilot
# to save into history/<year-month>/: the guide renderer reads reflections only
# from month folders, a flat history/ file was silently ignored (issue #836).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$ROOT/.claude/skills/personal-guide-render/templates/reflection-template.md"
if grep -qF 'history/{{ГОД-МЕСЯЦ}}/{{ДАТА}}-reflection.md' "$T" && ! grep -qF 'history/{{ДАТА}}-reflection' "$T"; then
    echo "PASS: issue #836 reflection save path"
else
    echo "FAIL: issue #836 reflection template still points to a flat history/ path"; exit 1
fi
