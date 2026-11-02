#!/usr/bin/env bash
# check-pack-collisions.sh — global detector of ID collisions in a Pack repo.
#
# Purpose: for CI and local pre-commit hooks. Self-contained (no dependencies
# beyond bash + standard unix utilities).
#
# Every base ID (DP.M.NNN, DP.D.NNN, DP.SC.NNN, AR.NNN, etc.) must be unique
# in the repo. On finding a duplicate basename → exit 1 listing the paths.
#
# Source: WP-7 Phase PACK-COLLISIONS (18 May 2026) — 14 collisions found, caused by
# parallel development without checking for a free number.
#
# Usage:
#   check-pack-collisions.sh          # run from the repo root
#   REPO_ROOT=/path check-pack-collisions.sh  # explicit path

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# `|| true` at the end — protection against grep/awk exit 1 on an empty result under set -e/pipefail
COLLISIONS=$(find "$REPO_ROOT" -name "*.md" -type f 2>/dev/null \
  | grep -v '/\.git/' \
  | grep -v '/archive/' \
  | grep -v '/inbox/' \
  | xargs -n1 basename 2>/dev/null \
  | grep -oE '^[A-Z]+\.[A-Z]+\.[0-9]+' \
  | sort | uniq -c | awk '$1>1{print $2}' || true)

if [ -n "$COLLISIONS" ]; then
  echo ""
  echo "❌ pack-lint [R4]: обнаружены ID-коллизии (два файла с одинаковым базовым ID):"
  echo ""
  echo "$COLLISIONS" | while read -r coll_id; do
    echo "  [$coll_id]:"
    find "$REPO_ROOT" -name "${coll_id}*.md" -type f 2>/dev/null \
      | grep -v '/\.git/' | grep -v '/archive/' | grep -v '/inbox/' \
      | sed "s|^${REPO_ROOT}/|    |"
  done
  echo ""
  echo "Каждый ID должен быть уникален в репо (ссылки ломаются при дублях)."
  echo "Решение: переименовать один из файлов на следующий свободный ID того же типа,"
  echo "         обновить 'id:' внутри файла + slug-ссылки на него во всём IWE."
  echo ""
  exit 1
fi

echo "✅ pack-lint [R4]: ID-коллизий не обнаружено"
exit 0
