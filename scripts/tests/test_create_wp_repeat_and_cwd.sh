#!/usr/bin/env bash
# Idempotency + arbitrary-directory contract for create-wp.sh (Ф-script-contract-gate,
# Этап 2). create-wp.sh has no idempotency key or retry token — two calls with
# the same title are two distinct, intentional WPs by design, not a duplicate
# to collapse. The contract that actually matters: (1) it works when invoked
# from a directory that is not the governance repo itself, and (2) repeated
# invocation stays coherent — each call creates exactly one new WP, no
# collisions, no orphaned/partial entries.

set -euo pipefail

TEMPLATE_ROOT="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cp -R "$TEMPLATE_ROOT/seed/strategy" "$TMPDIR/strategy"
mkdir -p "$TMPDIR/unrelated/cwd"

export IWE_TEMPLATE="$TEMPLATE_ROOT"
export IWE_ROOT="$TMPDIR"
export IWE_GOVERNANCE_REPO="strategy"

run_create() {
  (
    cd "$TMPDIR/unrelated/cwd"
    bash "$TEMPLATE_ROOT/scripts/create-wp.sh" \
      --title "Retry Contract" \
      --budget 1h \
      --priority P4 \
      --no-consent-check
  )
}

count_wps() {
  find "$TMPDIR/strategy/inbox" -mindepth 1 -maxdepth 1 -type d -name 'WP-*' | wc -l | tr -d ' '
}

before=$(count_wps)
run_create >"$TMPDIR/run1.out" 2>&1 || { echo "FAIL: first call from unrelated cwd failed" >&2; cat "$TMPDIR/run1.out" >&2; exit 1; }
middle=$(count_wps)
run_create >"$TMPDIR/run2.out" 2>&1 || { echo "FAIL: second call from unrelated cwd failed" >&2; cat "$TMPDIR/run2.out" >&2; exit 1; }
after=$(count_wps)

[ "$middle" -eq $((before + 1)) ] ||
  { echo "FAIL: first invocation did not create exactly one WP ($before -> $middle)" >&2; exit 1; }
[ "$after" -eq $((middle + 1)) ] ||
  { echo "FAIL: second invocation did not create exactly one WP ($middle -> $after)" >&2; exit 1; }

ids=$(find "$TMPDIR/strategy/inbox" -mindepth 1 -maxdepth 1 -type d -name 'WP-*' \
  -exec basename {} \; | sort)

[ "$(printf '%s\n' "$ids" | uniq -d | wc -l | tr -d ' ')" -eq 0 ] ||
  { echo "FAIL: duplicate WP id across two invocations" >&2; exit 1; }

while IFS= read -r id; do
  [ -f "$TMPDIR/strategy/inbox/$id/$id.md" ] ||
    { echo "FAIL: missing context file for $id" >&2; exit 1; }
  grep -q "$id" "$TMPDIR/strategy/docs/WP-REGISTRY.md" ||
    { echo "FAIL: $id missing from WP-REGISTRY.md" >&2; exit 1; }
done <<EOF
$ids
EOF

echo "✓ Two invocations from an unrelated cwd each created exactly one coherent, non-colliding WP"
