#!/usr/bin/env bash
# Regression coverage for issue #584: setup/build-runtime.sh always stamped
# the runtime version as "Unreleased" — grep -m1 took the FIRST '## [...]'
# heading in CHANGELOG.md, which under Keep a Changelog is always
# "## [Unreleased]" when that section is present.
#
# The exact parse command is extracted from build-runtime.sh at test time
# (not copy-pasted) so this test tracks the real shipped line instead of a
# duplicate that could silently drift from it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

pass_count=0
pass() { echo "  ✅ PASS: $*"; pass_count=$((pass_count + 1)); }
fail() { echo "  ❌ FAIL: $*" >&2; exit 1; }

PARSE_LINE=$(grep '^FMT_VERSION=' "$ROOT/setup/build-runtime.sh")
[ -n "$PARSE_LINE" ] || fail "could not find FMT_VERSION= line in setup/build-runtime.sh — has it moved?"

parse_version() {
  local template_dir="$1"
  ( TEMPLATE_DIR="$template_dir"; eval "$PARSE_LINE"; echo "$FMT_VERSION" )
}

echo "--- Unreleased section present above the latest real version (real repo shape) ---"
cat > "$TMP_ROOT/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [0.39.1] — 2026-08-30
- fix: something

## [0.39.0] — 2026-08-30
- feat: something else
EOF
got=$(parse_version "$TMP_ROOT")
if [ "$got" = "0.39.1" ]; then
  pass "parses the real latest version (0.39.1), not Unreleased"
else
  fail "expected 0.39.1, got '$got' — issue #584 not fixed"
fi

echo "--- No Unreleased section (older CHANGELOG shape, must still work) ---"
cat > "$TMP_ROOT/CHANGELOG.md" <<'EOF'
# Changelog

## [0.38.5] — 2026-08-18
- fix: older release
EOF
got=$(parse_version "$TMP_ROOT")
if [ "$got" = "0.38.5" ]; then
  pass "still parses the version when there is no Unreleased section at all"
else
  fail "expected 0.38.5, got '$got' — fix broke the no-Unreleased case"
fi

echo "--- Nothing released yet (Unreleased only) — must not crash, empty is acceptable ---"
cat > "$TMP_ROOT/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]
- feat: work in progress
EOF
got=$(parse_version "$TMP_ROOT")
if [ -z "$got" ]; then
  pass "no released version yet → empty FMT_VERSION, no crash (honest 'nothing shipped' state)"
else
  fail "expected empty FMT_VERSION with only Unreleased present, got '$got'"
fi

echo "issue-584 build-runtime.sh version fix: $pass_count checks passed"
