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
exec "$PYTHON" "$SCRIPT_DIR/verify-skill.py" "$@"
