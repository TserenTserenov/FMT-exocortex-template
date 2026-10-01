#!/usr/bin/env bash
# Contract: a new WP keeps its strategic basis explicit and rejects inconsistent links.
set -euo pipefail

# Template root comes from this file's own location, never from $HOME (CI checks
# the repository out elsewhere); HOME and TMPDIR stay inside the test's temp dir.
TEMPLATE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
export TMPDIR
export HOME="$TMPDIR/home"
mkdir -p "$HOME"

cp -R "$TEMPLATE_ROOT/seed/strategy" "$TMPDIR/strategy"
export IWE_ROOT="$TMPDIR"
export IWE_GOVERNANCE_REPO="strategy"

# --no-artifactor-check: the Artifactor Gate runs before every other check and is
# covered by test_create_wp_artifactor_gate.sh. Without the flag the negative case
# below would be refused by that gate and never reach the hypothesis check.
bash "$TEMPLATE_ROOT/scripts/create-wp.sh" \
  --title "Проверка связи РП" --budget 1h --priority P4 --verification-class closed-loop --no-consent-check --no-artifactor-check \
  --hypothesis H-101 --hypothesis-relation tests >"$TMPDIR/create.out"

WP_FILE=$(find "$TMPDIR/strategy/inbox" -type f -name 'WP-*.md' | sed -n 1p)
grep -q '^hypothesis: "H-101"$' "$WP_FILE"
grep -q '^hypothesis_relation: "tests"$' "$WP_FILE"

if bash "$TEMPLATE_ROOT/scripts/create-wp.sh" \
  --title "Некорректная связь" --budget 1h --priority P4 --verification-class closed-loop --no-consent-check --no-artifactor-check \
  --hypothesis-relation tests >"$TMPDIR/invalid.out" 2>&1; then
  echo "FAIL: tests without H-NNN was accepted" >&2
  exit 1
fi
grep -q "нужен --hypothesis H-NNN" "$TMPDIR/invalid.out" || {
  echo "FAIL: refused for the wrong reason (expected the hypothesis-link check):" >&2
  cat "$TMPDIR/invalid.out" >&2
  exit 1
}

echo "✓ hypothesis relation is written and inconsistent tests link is rejected"
