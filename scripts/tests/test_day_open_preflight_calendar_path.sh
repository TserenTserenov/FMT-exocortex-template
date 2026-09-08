#!/usr/bin/env bash
set -euo pipefail

# issue #426: day-open-preflight.sh resolves server-calendar.sh via
# "$IWE/scripts/server-calendar.sh" instead of the directory the preflight
# script itself lives in. On installs where $IWE/scripts/ does not exist as
# a standalone directory (server-calendar.sh only ships inside
# FMT-exocortex-template/scripts/), the calendar check silently reports
# "fail" even though the calendar itself is healthy.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Reproduce the layout from the issue: $IWE has no top-level scripts/, only
# FMT-exocortex-template/scripts/ (the template checkout itself).
mkdir -p "$TMP/FMT-exocortex-template/scripts/lib"
cp "$ROOT/scripts/day-open-preflight.sh" "$TMP/FMT-exocortex-template/scripts/"
cp "$ROOT/scripts/lib/common.sh" "$TMP/FMT-exocortex-template/scripts/lib/"

# Minimal server-calendar.sh stand-in: always reports a clean day with
# 2 events, matching the preflight's own "ok" regex.
cat > "$TMP/FMT-exocortex-template/scripts/server-calendar.sh" <<'SH'
#!/usr/bin/env bash
echo "📅 Календарь (test): 2 события."
echo "| 09:00 | Событие A |"
echo "| 14:00 | Событие B |"
SH
chmod +x "$TMP/FMT-exocortex-template/scripts/server-calendar.sh"

# .iwe-runtime marker makes iwe_resolve_root() accept $TMP as workspace root
# without needing IWE_WORKSPACE/IWE_ROOT set explicitly (see common.sh
# iwe_resolve_root: library_root check).
mkdir -p "$TMP/.iwe-runtime"

OUT=$(IWE_WORKSPACE="$TMP" IWE_ROOT="$TMP" \
  bash "$TMP/FMT-exocortex-template/scripts/day-open-preflight.sh" 2026-08-18 2>/dev/null)

CALENDAR_STATUS=$(echo "$OUT" | jq -r '.calendar')

if [ "$CALENDAR_STATUS" = "fail" ]; then
  echo "FAIL (expected, unpatched): calendar reported fail though server-calendar.sh ran cleanly"
  echo "  \$IWE/scripts/server-calendar.sh does not exist in this layout — only"
  echo "  FMT-exocortex-template/scripts/server-calendar.sh does. This is issue #426."
  exit 1
fi

if [ "$CALENDAR_STATUS" != "ok" ]; then
  echo "FAIL (unexpected status): $CALENDAR_STATUS"
  exit 1
fi

echo "PASS: day-open-preflight.sh resolves server-calendar.sh next to itself, not via \$IWE/scripts/"
