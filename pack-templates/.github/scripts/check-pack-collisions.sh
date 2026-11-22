#!/usr/bin/env bash
# check-pack-collisions.sh — global detector ID-collisions in Pack-repo.
#
# Purpose: for CI and local pre-commit hooks. Self-contained (no dependencies
# beyond bash + standard unix-utilities).
#
# Every base ID (DP.M.NNN, DP.D.NNN, DP.SC.NNN, AR.NNN etc..) must be unique
# in the repo. When a duplicate basename is detected basename → exit 1 with the paths listed.
#
# Source: WP-7 Phase-PACK-COLLISIONS (18 May 2026) — detected 14 collisions, caused by
# parallel development without checking for a free number.
#
# Usage:
#   check-pack-collisions.sh          # run from the repo root
#   REPO_ROOT=/path check-pack-collisions.sh  # explicit path

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# `|| true` at the end — guard against grep/awk exit 1 on empty result with set -e/pipefail
COLLISIONS=$(find "$REPO_ROOT" -name "*.md" -type f 2>/dev/null \
  | grep -v '/\.git/' \
  | grep -v '/archive/' \
  | grep -v '/inbox/' \
  | xargs -n1 basename 2>/dev/null \
  | grep -oE '^[A-Z]+\.[A-Z]+\.[0-9]+' \
  | sort | uniq -c | awk '$1>1{print $2}' || true)

if [ -n "$COLLISIONS" ]; then
  echo ""
  echo "❌ pack-lint [R4]: detected ID-collisions (two files with the same base ID):"
  echo ""
  echo "$COLLISIONS" | while read -r coll_id; do
    echo "  [$coll_id]:"
    find "$REPO_ROOT" -name "${coll_id}*.md" -type f 2>/dev/null \
      | grep -v '/\.git/' | grep -v '/archive/' | grep -v '/inbox/' \
      | sed "s|^${REPO_ROOT}/|    |"
  done
  echo ""
  echo "Every ID must be unique in the repo (links break on duplicates)."
  echo "Fix: rename one of the files to the next free ID of the same type,"
  echo "         update 'id:' inside the file + slug-slug references to it throughout the entire IWE IWE."
  echo ""
  exit 1
fi

echo "✅ pack-lint [R4]: ID-no collisions detected"
exit 0
