#!/usr/bin/env bash
set -euo pipefail

# issue #455: a promoted copy of day-open-scaffold.sh without lib/common.sh
# next to it used to degrade silently (set -uo pipefail, no -e) — every path
# resolved to the filesystem root and the scheduler-state check took the
# wrong branch, producing false incidents for weeks before anyone noticed.
# Missing the library must be a fatal, explicit error instead.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Reproduce a stale promoted copy: the script alone, no lib/ next to it.
cp "$ROOT/scripts/day-open-scaffold.sh" "$TMP/"

set +e
OUTPUT=$(bash "$TMP/day-open-scaffold.sh" 2026-08-18 2>&1)
CODE=$?
set -e

if [[ "$CODE" -eq 0 ]]; then
    echo "FAIL: скрипт без lib/common.sh завершился успешно (issue #455 не устранена)"
    echo "$OUTPUT"
    exit 1
fi

if echo "$OUTPUT" | grep -qi "FATAL.*lib/common.sh"; then
    echo "PASS: отсутствие lib/common.sh — явная фатальная ошибка, не тихая деградация"
else
    echo "FAIL: скрипт упал, но без понятного сообщения про lib/common.sh"
    echo "$OUTPUT"
    exit 1
fi
