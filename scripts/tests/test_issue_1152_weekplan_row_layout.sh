#!/usr/bin/env bash
# issue #1152 / #1170: create-wp.sh wrote the WeekPlan row by the seed layout
# (`# | РП | h | ...`). A table `🚦 | РП | Работа | Часы (потолок) | Источник | Ставка |
# Статус | Репо` keeps the number in «РП» and the title in «Работа»; the row used to put
# the title into «РП» and leave the rest empty while reporting success.
set -euo pipefail

TEMPLATE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
export TMPDIR
export HOME="$TMPDIR/home"
mkdir -p "$HOME"

cp -R "$TEMPLATE_ROOT/seed/strategy" "$TMPDIR/strategy"
export IWE_ROOT="$TMPDIR"
export IWE_GOVERNANCE_REPO="strategy"

cat > "$TMPDIR/strategy/current/WeekPlan W1.md" <<'EOF'
# План недели

## План недели

| 🚦 | РП | Работа | Часы (потолок) | Источник | Ставка | Статус | Репо |
|----|----|--------|----------------|----------|--------|--------|------|
| 🟢 | WP-1 | Старый РП | 2 | — | — | pending | DS-old |
EOF

bash "$TEMPLATE_ROOT/scripts/create-wp.sh" \
  --title "Правила склейки" --budget 4h --priority P2 --verification-class closed-loop \
  --no-consent-check --no-artifactor-check --repo DS-newsmonitor >"$TMPDIR/create.out" 2>&1 || {
  cat "$TMPDIR/create.out" >&2; exit 1; }

row=$(grep 'Правила склейки' "$TMPDIR/strategy/current/WeekPlan W1.md")
fail=0
check() { if [ "$2" = ok ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

IFS='|' read -r -a cells <<< "$row"
# cells[0] is the empty text before the first pipe; the 8 table cells follow.
[ "${#cells[@]}" -eq 9 ] && r=ok || r=bad
check "row has the 8 table cells" "$r"
printf '%s' "${cells[2]}" | grep -qE '^ *WP-[0-9]+ *$' && r=ok || r=bad
check "«РП» holds the WP number" "$r"
printf '%s' "${cells[3]}" | grep -q 'Правила склейки' && r=ok || r=bad
check "«Работа» holds the title" "$r"
printf '%s' "${cells[4]}" | grep -qE '^ *4 *$' && r=ok || r=bad
check "«Часы (потолок)» holds the budget" "$r"
printf '%s' "${cells[8]}" | grep -q 'DS-newsmonitor' && r=ok || r=bad
check "«Репо» holds the repo" "$r"
exit $fail
