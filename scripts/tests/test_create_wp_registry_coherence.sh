#!/usr/bin/env bash
# Regression test for bug #338: create-wp.sh must record the WP in ALL local places.
# Check (5 items): inbox, WeekPlan, Strategy.md, WP-REGISTRY, build-active-wp.py.
# The external tracker is not included — it is a conditional post-step (issue #321), not a local record.

set -euo pipefail

# Fixture: a temporary repo skeleton
# Template root comes from this file's own location, never from $HOME (CI checks
# the repository out elsewhere); HOME and TMPDIR stay inside the test's temp dir.
TEMPLATE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
export TMPDIR
export HOME="$TMPDIR/home"
mkdir -p "$HOME"

cp -R "$TEMPLATE_ROOT/seed/strategy" "$TMPDIR/strategy"

# seed/ is a one-time bootstrap template, correctly excluded from update.sh's
# ongoing-sync manifest — a copy of this repo obtained any way other than a
# fresh git clone of the exact commit that added current/WeekPlan*.md won't
# have it (found by cold review 03.08). ensure_weekplan_fixture is a no-op
# when the real seed one is already present.
# shellcheck source=lib/seed_strategy_fixture.sh
source "$TEMPLATE_ROOT/scripts/tests/lib/seed_strategy_fixture.sh"
ensure_weekplan_fixture "$TMPDIR/strategy"

# IWE_GOVERNANCE_REPO — the name of a subfolder UNDER IWE_ROOT (create-wp.sh:26-30), not an
# arbitrary relative path. "." without IWE_ROOT set resolved
# to $HOME/IWE/. — the real home directory, not this sandbox (found 03.08,
# it created a junk inbox/WP-001/ in ~/IWE live). IWE_ROOT=$TMPDIR + the directory
# name make IWE/$GOV_REPO = $TMPDIR/strategy — exactly what was copied.
export IWE_TEMPLATE="$TEMPLATE_ROOT"
export IWE_ROOT="$TMPDIR"
export IWE_GOVERNANCE_REPO="strategy"

cd "$TMPDIR/strategy"

# $PWD (logical), not `pwd -P` (physical): on macOS $TMPDIR from mktemp is
# under /var, which is itself a symlink to /private/var — `pwd -P` resolves
# that symlink and would never match "$TMPDIR"/*, failing this guard on every
# single run regardless of whether the fixture actually escaped (found running
# this test for real, not by reading the code).
case "$PWD" in
  "$TMPDIR"/*) ;;
  *)
    echo "FAIL: fixture escaped TMPDIR: $PWD" >&2
    exit 1
    ;;
esac

# Run create-wp.sh
# --no-artifactor-check: the Artifactor Gate is covered by
# test_create_wp_artifactor_gate.sh; this test is about the five write targets.
TITLE="Тестовый РП"
bash "$IWE_TEMPLATE/scripts/create-wp.sh" \
  --title "$TITLE" \
  --budget "2h" \
  --priority "P3" \
  --verification-class closed-loop \
  --no-consent-check \
  --no-artifactor-check

# Extract the WP number from the created file
WP_NUM=""
for wp_dir in inbox/WP-*; do
  [ -d "$wp_dir" ] || continue
  WP_NUM=$(basename "$wp_dir" | sed 's/WP-//')
  break
done
[ -z "$WP_NUM" ] && { echo "FAIL: no WP created"; exit 1; }

WP_ID="WP-$(printf '%03d' "$WP_NUM")"

echo "Created: $WP_ID"

# Check the 5 places
echo "Checking 5 locations..."

# 1. inbox/WP-N/WP-N.md
[ -f "inbox/$WP_ID/$WP_ID.md" ] || { echo "FAIL: $WP_ID.md not found"; exit 1; }
grep -q "^title:" "inbox/$WP_ID/$WP_ID.md" || { echo "FAIL: title not in inbox"; exit 1; }
echo "✓ inbox/$WP_ID/$WP_ID.md"

# 2. WeekPlan W{N}.md (the anchor must be present)
# The anchor is the WP heading, not $WP_ID: create-wp.sh:166-168 documents that the
# "#" column in WeekPlan/REGISTRY deliberately holds a bare number (issue #338 item 4),
# padding only in paths/headings. A WeekPlan line contains no path, so
# "WP-001" never appears in it in principle — grep for $WP_ID was running idle
# until this fixture finally worked in full (03.08).
WEEKPLAN=$(ls -1 current/WeekPlan*.md | sed -n 1p)
[ -n "$WEEKPLAN" ] || { echo "FAIL: no WeekPlan found"; exit 1; }
grep -q "$TITLE" "$WEEKPLAN" || { echo "FAIL: $WP_ID (title: $TITLE) not in WeekPlan"; exit 1; }
echo "✓ WeekPlan ($WEEKPLAN)"

# 3. Strategy.md (the anchor in ## Current week)
[ -f "docs/Strategy.md" ] || { echo "FAIL: Strategy.md not found"; exit 1; }
grep -q "$WP_ID" "docs/Strategy.md" || { echo "WARN: $WP_ID not in Strategy.md (may be intentional)"; }
echo "✓ Strategy.md (checked)"

# 4. WP-REGISTRY.md (must be with WP-NNN padding)
[ -f "docs/WP-REGISTRY.md" ] || { echo "FAIL: WP-REGISTRY.md not found"; exit 1; }
grep -q "$WP_ID" "docs/WP-REGISTRY.md" || { echo "FAIL: $WP_ID not in WP-REGISTRY"; exit 1; }
echo "✓ WP-REGISTRY.md"

# 5. build-active-wp.py is available (path check)
# Resolved from the template root, not $HOME/IWE/scripts: that author layout does
# not exist in CI, and a WARN-only check could never fail.
BUILD_SCRIPT="$TEMPLATE_ROOT/scripts/build-active-wp.py"
[ -f "$BUILD_SCRIPT" ] || { echo "FAIL: build-active-wp.py not found at $BUILD_SCRIPT"; exit 1; }
echo "✓ build-active-wp.py path verified"

echo ""
echo "✓ All 5 locations populated correctly for $WP_ID"
