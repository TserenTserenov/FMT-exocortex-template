#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/date" <<'SH'
#!/bin/sh
if [ "$1" = "+%Y-%m-%d" ]; then
  case "${TZ:-}" in
    UTC) printf '2026-08-02\n' ;;
    Europe/Moscow) printf '2026-08-03\n' ;;
    *) printf 'unexpected-zone\n' ;;
  esac
  exit 0
fi
exec /bin/date "$@"
SH
chmod +x "$TMP/bin/date"

UTC_DAY=$(TZ=UTC PATH="$TMP/bin:$PATH" bash -c 'source "$1"; calendar_today' _ "$ROOT/scripts/day-close-lock.sh")
MSK_DAY=$(TZ=Europe/Moscow PATH="$TMP/bin:$PATH" bash -c 'source "$1"; calendar_today' _ "$ROOT/scripts/day-close-lock.sh")

[ "$UTC_DAY" = "2026-08-02" ]
[ "$MSK_DAY" = "2026-08-03" ]

echo "PASS: day-close lock follows the installation timezone for calendar dates"
