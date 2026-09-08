#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

eval "$(awk '
  /^is_upstream_git_mirror\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$ROOT/update.sh")"
declare -F is_upstream_git_mirror >/dev/null

SCRIPT_DIR="$TMP/template"
mkdir -p "$SCRIPT_DIR"
git -C "$SCRIPT_DIR" init -q
git -C "$SCRIPT_DIR" config user.email test@example.invalid
git -C "$SCRIPT_DIR" config user.name 'Deprecated mirror guard test'

if is_upstream_git_mirror; then
    echo 'guard treated a regular template checkout as an upstream mirror' >&2
    exit 1
fi

git -C "$SCRIPT_DIR" remote add origin https://example.invalid/user/template.git
if is_upstream_git_mirror; then
    echo 'guard treated an origin-only checkout as an upstream mirror' >&2
    exit 1
fi

git -C "$SCRIPT_DIR" remote add upstream https://example.invalid/canonical/template.git
if ! is_upstream_git_mirror; then
    echo 'guard missed a template mirror with an upstream remote' >&2
    exit 1
fi

echo 'PASS: deprecated cleanup skips a template git mirror with upstream remote'
