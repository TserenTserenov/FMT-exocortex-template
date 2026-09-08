#!/usr/bin/env bash
# Проверяет WP-518: карточку без определённой связи с гипотезой нельзя начать.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/DS-strategy/inbox/WP-001"
printf '%s\n' 'hypothesis_relation: "unclassified"' \
  > "$TMP_DIR/DS-strategy/inbox/WP-001/WP-001.md"

if IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$ROOT_DIR/scripts/session-guard.sh" open --wp WP-001 --agent kimi \
  >/dev/null 2>&1; then
  echo "FAIL: unclassified WP opened a session" >&2
  exit 1
fi

printf '%s\n' 'hypothesis_relation: "tests"' \
  > "$TMP_DIR/DS-strategy/inbox/WP-001/WP-001.md"
IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$ROOT_DIR/scripts/session-guard.sh" open --wp WP-001 --agent kimi \
  >/dev/null

echo "PASS: session guard blocks unclassified WP and admits classified WP"
