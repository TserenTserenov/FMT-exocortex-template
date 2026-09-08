#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORKFLOW="$ROOT/.github/workflows/validate-template.yml"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

git -C "$TMP" init -q
git -C "$TMP" config user.email test@example.invalid
git -C "$TMP" config user.name "Upgrade cleanup test"
printf 'previous\n' > "$TMP/tracked.txt"
git -C "$TMP" add tracked.txt
git -C "$TMP" commit -qm previous
PREV_SHA=$(git -C "$TMP" rev-parse HEAD)
printf 'current\n' > "$TMP/tracked.txt"
git -C "$TMP" commit -qam current
CURRENT_SHA=$(git -C "$TMP" rev-parse HEAD)
CURRENT_REF=$(git -C "$TMP" symbolic-ref --quiet --short HEAD || true)

git -C "$TMP" checkout -q "$PREV_SHA"
printf 'dirty\n' > "$TMP/tracked.txt"
printf 'garbage\n' > "$TMP/untracked.txt"

# Дословный контракт cleanup-блока workflow.
git -C "$TMP" reset --hard -q
git -C "$TMP" clean -fdq
if [ -n "$CURRENT_REF" ]; then
  git -C "$TMP" checkout -q "$CURRENT_REF"
else
  git -C "$TMP" checkout -q "$CURRENT_SHA"
fi

[ "$(cat "$TMP/tracked.txt")" = "current" ]
[ ! -e "$TMP/untracked.txt" ]
[ -z "$(git -C "$TMP" status --porcelain)" ]
[ "$(git -C "$TMP" symbolic-ref --short HEAD)" = "$CURRENT_REF" ]

# shellcheck disable=SC2016 # literal workflow contract; expansion would invalidate the assertion
grep -qF 'CURRENT_SHA=$(git rev-parse HEAD)' "$WORKFLOW"
# shellcheck disable=SC2016 # literal workflow contract; expansion would invalidate the assertion
grep -qF 'CURRENT_REF=$(git symbolic-ref --quiet --short HEAD || true)' "$WORKFLOW"
grep -qF 'git reset --hard' "$WORKFLOW"
grep -qF 'git clean -fd' "$WORKFLOW"
# shellcheck disable=SC2016 # literal workflow contract; expansion would invalidate the assertion
grep -qF 'if [ -n "$CURRENT_REF" ]; then' "$WORKFLOW"

echo "PASS: upgrade cleanup discards previous-version mutations and restores current SHA"
