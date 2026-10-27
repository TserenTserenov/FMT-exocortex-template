#!/usr/bin/env bash
# #1362: Day Open must read yesterday's strategy-day summary from WeekReport.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

WS="$TMP/ws"
CURRENT="$WS/DS-strategy/current"
ARCHIVE="$WS/DS-strategy/archive/week-reports"
REPORT="WeekReport W44 2026-10-26.md"
mkdir -p "$CURRENT" "$ARCHIVE" "$WS/memory" "$TMP/home"
ln -s "$ROOT/scripts" "$WS/scripts"

scaffold() {
  env -i PATH="$PATH" HOME="$TMP/home" IWE_ROOT="$WS" IWE_WORKSPACE="$WS" \
    IWE_GOVERNANCE_REPO=DS-strategy DAY_OPEN_FORCE_STRATEGY_DAY=1 \
    bash "$ROOT/scripts/day-open-scaffold.sh" 2026-10-27 2>/dev/null
}

expect() {
  local label="$1" output="$2" needle="$3"
  if [[ "$output" != *"$needle"* ]]; then
    printf 'FAIL: %s: missing %s\n' "$label" "$needle" >&2
    exit 1
  fi
}

reject() {
  local label="$1" output="$2" needle="$3"
  if [[ "$output" == *"$needle"* ]]; then
    printf 'FAIL: %s: unexpected %s\n' "$label" "$needle" >&2
    exit 1
  fi
}

cat > "$CURRENT/$REPORT" <<'EOF'
# WeekReport W44

<details>
<summary><b>Итоги Понедельник 26.10</b></summary>

**Сводка:** стратегический день завершён.

**Завтра начать с (вт 27.10):**
- РП-7: проверить выпуск

</details>
EOF

out=$(scaffold)
expect 'strategy-day handoff' "$out" 'РП-7: проверить выпуск'
expect 'summary source' "$out" 'итоги в WeekReport'
reject 'real summary is not absent' "$out" 'Day Close за 2026-10-26 не найден'
reject 'bold marker is not handoff text' "$out" $'\n**\n'

cat > "$CURRENT/$REPORT" <<'EOF'
<details>
<summary><b>Итоги Воскресенье 25.10</b></summary>
**Завтра начать с:**
- Чужой перенос
</details>
EOF
out=$(scaffold)
reject 'wrong day stays out' "$out" 'Чужой перенос'
expect 'wrong day is not evidence' "$out" 'Day Close за 2026-10-26 не найден'

cat > "$CURRENT/$REPORT" <<'EOF'
<details>
<summary><b>Итоги Понедельник 26.10</b></summary>
**Завтра начать с:**
- Незавершённый раздел
<details>
<summary><b>Итоги Вторник 27.10</b></summary>
- Другой день
</details>
EOF
out=$(scaffold)
reject 'unclosed details stays out' "$out" 'Незавершённый раздел'
expect 'unclosed details is not evidence' "$out" 'Day Close за 2026-10-26 не найден'

cat > "$CURRENT/$REPORT" <<'EOF'
<details>
<summary><b>Итоги Понедельник 26.10</b></summary>
**Сводка:** перенос не записан.
</details>
EOF
out=$(scaffold)
expect 'missing entry point is explicit' "$out" 'точка входа не зафиксирована'
expect 'summary still found' "$out" 'итоги в WeekReport'

mv "$CURRENT/$REPORT" "$ARCHIVE/$REPORT"
out=$(scaffold)
expect 'archived summary is read' "$out" 'итоги в WeekReport'

echo 'OK: #1362 strategy-day carry-over'
