#!/usr/bin/env bash
# Regression for WP-7 Ф83: an unrecognized flag used to be silently `shift`ed
# away instead of failing -- any protective flag typo'd or not yet wired into
# the parser vanished with no diagnostic.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/DS-strategy/inbox/WP-001"
printf '%s\n' 'hypothesis_relation: "tests"' \
  > "$TMP_DIR/DS-strategy/inbox/WP-001/WP-001.md"

if out=$(IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$ROOT_DIR/scripts/session-guard.sh" open --wp WP-001 --agent kimi \
  --slug smoke --totally-unknown-flag value 2>&1); then
  echo "FAIL: unrecognized flag was silently accepted" >&2
  exit 1
fi
if ! grep -q "неизвестный флаг" <<<"$out"; then
  echo "FAIL: expected an explicit 'неизвестный флаг' diagnostic, got: $out" >&2
  exit 1
fi
if [ -n "$(find "$TMP_DIR/.iwe-runtime" -name '*.open' 2>/dev/null)" ]; then
  echo "FAIL: unknown flag left a semaphore behind" >&2
  exit 1
fi

# Positive control: only known flags still opens cleanly.
IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$ROOT_DIR/scripts/session-guard.sh" open --wp WP-001 --agent kimi \
  --slug smoke2 >/dev/null

echo "PASS: session guard rejects unrecognized flags instead of silently dropping them"
