#!/usr/bin/env bash
# Verify the skill with the shared Python/PyYAML dependency resolver.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# issue #1165: an install has no scripts/ next to .claude/, but update.sh delivers the
# resolver as .claude/lib/find-python3.sh. Search the delivered copy first, then the
# configured scripts dir, then the template layout (<root>/scripts/lib).
RESOLVER=""
for candidate in \
    "$SCRIPT_DIR/../../../lib/find-python3.sh" \
    "${IWE_SCRIPTS:+$IWE_SCRIPTS/lib/find-python3.sh}" \
    "$SCRIPT_DIR/../../../../scripts/lib/find-python3.sh"; do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
        RESOLVER="$candidate"
        break
    fi
done
if [ -z "$RESOLVER" ]; then
    echo "FAIL: Python resolver missing (looked in .claude/lib, \$IWE_SCRIPTS/lib, scripts/lib)" >&2
    exit 1
fi
if ! PYTHON=$(bash "$RESOLVER"); then
    echo "FAIL: skill verification requires Python 3.10+ and PyYAML" >&2
    exit 1
fi
status=0
"$PYTHON" "$SCRIPT_DIR/verify-skill.py" "$@" || status=$?
# Usage errors (argparse exits 2) leave no skill to check the routing block of.
[ "$status" -eq 2 ] && exit 2

# issue #894: the routing block is checked by the same validate_entry code the
# catalog generator and route-task.sh --validate use, not by rules of its own.
# The routing block is mandatory: a skill without one fails.
SKILL_DIR="${2:-.claude/skills}/${1:-}"
GENERATOR=""
for candidate in \
    "$SCRIPT_DIR/../../../../scripts/generate-executor-catalog.py" \
    "${IWE_TEMPLATE:+$IWE_TEMPLATE/scripts/generate-executor-catalog.py}" \
    "$SCRIPT_DIR/../../../../FMT-exocortex-template/scripts/generate-executor-catalog.py" \
    "${IWE_SCRIPTS:+$IWE_SCRIPTS/generate-executor-catalog.py}"; do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
        GENERATOR="$candidate"
        break
    fi
done
if [ -n "$GENERATOR" ]; then
    "$PYTHON" "$GENERATOR" --validate-skill "$SKILL_DIR" || status=1
elif [ -f "$SKILL_DIR/SKILL.md" ]; then
    echo "FAIL: $SKILL_DIR: the routing block cannot be checked, generate-executor-catalog.py was not found (looked in scripts/, \$IWE_TEMPLATE/scripts, FMT-exocortex-template/scripts, \$IWE_SCRIPTS)" >&2
    status=1
fi
exit "$status"
