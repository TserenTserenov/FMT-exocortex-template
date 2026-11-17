#!/usr/bin/env bash
# Regression for issue #1558: close-wp.sh took the WP name from a fixed position (parts[3]).
# With a registry whose columns are ordered | # | Название | Статус | P | ... the archive file
# was named after the status cell (WP-NNN-в-процессе-пауза.md). The name column is now found
# by the table header; a missing column or an empty name stops the close before the registry
# row is struck.
#
# Synthetic fixtures under a temporary HOME/TMPDIR; all failures are collected, exit 1 on any.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/close-wp-1558.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/tmp"
export HOME="$TMP/home" TMPDIR="$TMP/tmp"
unset IWE_ROOT IWE_WORKSPACE IWE_GOVERNANCE_REPO IWE_TEMPLATE IWE_SCRIPTS STRATEGY_DIR

GOV=DS-strategy
CLOSE="$ROOT/scripts/close-wp.sh"

PASSES=0
FAILS=0
ok()  { echo "  ✅ PASS: $*"; PASSES=$((PASSES + 1)); }
bad() { echo "  ❌ FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
expect_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2], got [$3]"; fi; }
expect_has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1: [$2] not found in: $3" ;; esac; }

new_ws() {
  local d
  d=$(mktemp -d "$TMP/ws.XXXXXX")
  mkdir -p "$d/$GOV/docs" "$d/$GOV/inbox" "$d/$GOV/archive/wp-contexts"
  printf '%s\n' "$d"
}

run_close() {  # <workspace> -> sets OUT and RC
  OUT=$(IWE_ROOT="$1" IWE_GOVERNANCE_REPO="$GOV" bash "$CLOSE" --wp 77 --summary "closed by the test" 2>&1)
  RC=$?
}

echo "--- #1558 A: standard order | # | P | Название | ... ---"
WS=$(new_ws)
cat > "$WS/$GOV/docs/WP-REGISTRY.md" <<'EOF'
| # | P | Название | Ст | Репо | Бюджет |
|---|---|----------|----|------|--------|
| 77 | P2 | **Demo WP** | 🔄 В процессе, пауза | DS-strategy | 2h |
EOF
run_close "$WS"
expect_eq "standard order: exit 0" 0 "$RC"
if [ -f "$WS/$GOV/archive/wp-contexts/WP-077-demo-wp.md" ]; then ok "standard order: slug from the name column"
else bad "standard order: expected WP-077-demo-wp.md, got: $(ls "$WS/$GOV/archive/wp-contexts")"; fi

echo "--- #1558 B: issue order | # | Название | Статус | P | ... ---"
WS=$(new_ws)
cat > "$WS/$GOV/docs/WP-REGISTRY.md" <<'EOF'
| # | Название | Статус | P | Репо | Бюджет |
|---|----------|--------|---|------|--------|
| 77 | **Demo WP** | 🔄 В процессе, пауза | P2 | DS-strategy | 2h |
EOF
run_close "$WS"
expect_eq "issue order: exit 0" 0 "$RC"
if [ -f "$WS/$GOV/archive/wp-contexts/WP-077-demo-wp.md" ]; then ok "issue order: slug from the name column, not the status"
else bad "issue order: expected WP-077-demo-wp.md, got: $(ls "$WS/$GOV/archive/wp-contexts")"; fi
stray=$(find "$WS/$GOV/archive/wp-contexts" -name '*процессе*' -print)
if [ -n "$stray" ]; then bad "issue order: a status-named archive file was created: $stray"
else ok "issue order: no status-named archive file"; fi

echo "--- #1558 C: no name column -> error, registry untouched ---"
WS=$(new_ws)
cat > "$WS/$GOV/docs/WP-REGISTRY.md" <<'EOF'
| # | P | Задача | Ст |
|---|---|--------|----|
| 77 | P2 | **Demo WP** | 🔄 |
EOF
before=$(cat "$WS/$GOV/docs/WP-REGISTRY.md")
run_close "$WS"
expect_eq "no name column: exit 1" 1 "$RC"
expect_has "no name column: the error names the column" "Название" "$OUT"
expect_eq "no name column: registry unchanged" "$before" "$(cat "$WS/$GOV/docs/WP-REGISTRY.md")"
expect_eq "no name column: no archive file" "" "$(ls "$WS/$GOV/archive/wp-contexts")"

echo "--- #1558 D: empty name -> error, registry untouched ---"
WS=$(new_ws)
cat > "$WS/$GOV/docs/WP-REGISTRY.md" <<'EOF'
| # | P | Название | Ст |
|---|---|----------|----|
| 77 | P2 |  | 🔄 |
EOF
before=$(cat "$WS/$GOV/docs/WP-REGISTRY.md")
run_close "$WS"
expect_eq "empty name: exit 1" 1 "$RC"
expect_eq "empty name: registry unchanged" "$before" "$(cat "$WS/$GOV/docs/WP-REGISTRY.md")"

echo
echo "issue #1558: $PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
