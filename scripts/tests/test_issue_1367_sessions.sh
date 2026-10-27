#!/usr/bin/env bash
# #1367: ordinary ORZ files and peer meta.yaml both reach sessions-today.md.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

today=$(date +%Y-%m-%d)
month=$(date +%Y-%m)
day=$(date +%d)
WS="$TMP/ws"
SESSIONS="$WS/MC-sessions/$month"
OUTPUT="$WS/DS-strategy/current/sessions-today.md"
mkdir -p "$SESSIONS/$day/$today-02-peer" "$WS/DS-strategy/current" "$TMP/home"

cat > "$SESSIONS/$today-01-flat.md" <<EOF
---
date: $today
type: work
wp: WP-7
duration_h: 1
agent: Codex
artifacts: []
---

# Сессия $today — Обычная задача
EOF

cat > "$SESSIONS/$day/$today-02-peer/meta.yaml" <<EOF
date: "$today"
session_id: "$today-02-peer"
task_id: "WP-8"
task_description: "Пир-сессия"
start_time: "${today}T08:20:00Z"
EOF

# Same peer session also has an ORZ file: count it once, from meta.yaml.
cat > "$SESSIONS/$today-02-peer.md" <<EOF
---
date: $today
type: work
wp: WP-8
duration_h: 1
agent: Codex
artifacts: []
---

# Сессия $today — Дубликат пир-сессии
EOF

cat > "$SESSIONS/$today-03-wrong-date.md" <<'EOF'
---
date: 2020-01-01
wp: WP-9
---
# Чужая дата
EOF

cat > "$SESSIONS/$today-04-no-wp.md" <<EOF
---
date: $today
wp: ""
---
# Нет РП
EOF

PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null)}"
env -i PATH="$PATH" HOME="$TMP/home" PYTHONUSERBASE="$PYTHONUSERBASE" \
  WORKSPACE_DIR="$WS" IWE_ROOT="$WS" \
  IWE_WORKSPACE="$WS" IWE_GOVERNANCE_REPO=DS-strategy \
  IWE_SESSIONS_ROOT="$WS/MC-sessions" IWE_DAY_CLOSE_LOG="$TMP/day-close.log" \
  bash "$ROOT/scripts/day-close.sh" --sessions > "$TMP/day-close.out" 2>&1

if [ ! -f "$OUTPUT" ]; then
  echo 'FAIL: sessions-today.md was not created' >&2
  cat "$TMP/day-close.out" >&2
  exit 1
fi

rows=$(grep -c '^| .* | WP-' "$OUTPUT" || true)
if [ "$rows" -ne 2 ]; then
  printf 'FAIL: expected 2 sessions, got %s\n' "$rows" >&2
  cat "$OUTPUT" >&2
  exit 1
fi
grep -qF 'WP-7' "$OUTPUT"
grep -qF 'Обычная задача' "$OUTPUT"
grep -qF 'WP-8' "$OUTPUT"
grep -qF 'Пир-сессия' "$OUTPUT"
if grep -qE 'WP-9|Дубликат|Нет РП' "$OUTPUT"; then
  echo 'FAIL: included a different date, duplicate, or WP-less session' >&2
  cat "$OUTPUT" >&2
  exit 1
fi

echo 'OK: #1367 session consolidation'
