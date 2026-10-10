#!/usr/bin/env bash
# issue #1165: verify-skill.sh looked for the Python resolver only at
# <root>/scripts/lib/find-python3.sh. An install has no scripts/ next to .claude/;
# update.sh delivers the resolver as .claude/lib/find-python3.sh. Simulate the
# install layout (no scripts/) and require that the resolver is found.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
check() { if [ "$2" = ok ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.claude"
cp -r "$ROOT/.claude/lib" "$ROOT/.claude/skills" "$T/.claude/"

out="$(cd "$T" && IWE_SCRIPTS= bash .claude/skills/skill-creator/scripts/verify-skill.sh skill-creator .claude/skills 2>&1)"
printf '%s\n' "$out" | grep -q 'Python resolver missing' && r=bad || r=ok
check "resolver is found in the install layout (.claude/lib)" "$r"

# With neither delivered copy nor scripts/ the failure must stay explicit.
rm -rf "$T/.claude/lib"
out="$(cd "$T" && IWE_SCRIPTS= bash .claude/skills/skill-creator/scripts/verify-skill.sh skill-creator .claude/skills 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && printf '%s\n' "$out" | grep -q 'Python resolver missing'; } && r=ok || r=bad
check "missing resolver still fails with an explicit message" "$r"
exit $fail
