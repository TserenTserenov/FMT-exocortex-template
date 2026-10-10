#!/usr/bin/env bash
# issue #1146: day-open-smoke-extended.sh writes current/.smoke-cache.json into the
# governance repo; the seed .gitignore did not list it, so every Day Open left an
# untracked file. The seed now ignores it, and the script adds a local exclude entry
# for installs created from an older seed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
check() { if [ "$2" = ok ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

grep -qxF 'current/.smoke-cache.json' "$ROOT/seed/strategy/.gitignore" && r=ok || r=bad
check "seed .gitignore lists the cache" "$r"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
git init -q "$T/ds"
mkdir -p "$T/ds/current"
BLOCK="$(sed -n '/^EXCLUDE_FILE=/,/^fi$/p' "$ROOT/scripts/day-open-smoke-extended.sh")"
# The block is run twice on purpose: the second run proves it is idempotent.
DS_STRATEGY="$T/ds"
eval "$BLOCK"
eval "$BLOCK"
echo '{}' > "$T/ds/current/.smoke-cache.json"
if [ -z "$(git -C "$T/ds" status --short)" ]; then r=ok; else r=bad; fi
check "cache file is not shown by git status" "$r"
n=$(grep -cxF 'current/.smoke-cache.json' "$T/ds/.git/info/exclude")
[ "$n" = 1 ] && r=ok || r=bad
check "exclude entry added once (idempotent)" "$r"
exit $fail
