#!/usr/bin/env bash
# Contract: a new WP keeps its strategic basis explicit and rejects inconsistent links.
set -euo pipefail

TEMPLATE_ROOT="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cp -R "$TEMPLATE_ROOT/seed/strategy" "$TMPDIR/strategy"
export IWE_ROOT="$TMPDIR"
export IWE_GOVERNANCE_REPO="strategy"

bash "$TEMPLATE_ROOT/scripts/create-wp.sh" \
  --title "Проверка связи РП" --budget 1h --priority P4 --no-consent-check \
  --hypothesis H-101 --hypothesis-relation tests >"$TMPDIR/create.out"

WP_FILE=$(find "$TMPDIR/strategy/inbox" -type f -name 'WP-*.md' | head -1)
grep -q '^hypothesis: "H-101"$' "$WP_FILE"
grep -q '^hypothesis_relation: "tests"$' "$WP_FILE"

if bash "$TEMPLATE_ROOT/scripts/create-wp.sh" \
  --title "Некорректная связь" --budget 1h --priority P4 --no-consent-check \
  --hypothesis-relation tests >"$TMPDIR/invalid.out" 2>&1; then
  echo "FAIL: tests without H-NNN was accepted" >&2
  exit 1
fi
grep -q "нужен --hypothesis H-NNN" "$TMPDIR/invalid.out"

echo "✓ hypothesis relation is written and inconsistent tests link is rejected"
