#!/usr/bin/env bash
# Contract test for bug #338: create-wp.sh must guarantee atomic registry coherence.
# Inject a deterministic fault right AFTER the WeekPlan write (step 3/5: the writer
# has already put its row into the file, then fails) and verify full rollback
# (inbox + archive stub + REGISTRY + WeekPlan all back to pre-run state), not a
# partial WP left behind.
#
# The test proves its own premises (issue #956): since 2026-09-11 the Artifactor
# Gate refuses a call without --artifactor-result/--no-artifactor-check with exit
# 1 BEFORE anything is written, and an earlier version of this test stayed green
# on that early exit — the "rollback" was compared against files that had never
# changed. Now the call passes the gate (--no-artifactor-check), the fault shim
# records the working tree at the moment of injection, and the test asserts
#   (a) the injection point was reached (shim and create-wp.sh failure messages),
#   (b) steps 1-3 had already written their traces (REGISTRY row, inbox folder and
#       the WeekPlan row, so a rollback of each has work to do),
#   (c) everything is byte-identical to the pre-run state afterwards.
#
# Earlier version used `chmod 444` on WeekPlan — non-deterministic (root/ACLs can
# still write) and create-wp.sh never checked the WeekPlan step's exit code at all,
# so the injected failure was silently ignored and the script reported success
# regardless (found 03.08, running this for real produced a false "Exit code: 0").
# This version shadows `python3` on PATH so only the WeekPlan-writing invocation
# fails, with a distinctive exit code — deterministic regardless of permissions.
# The shim lets the real writer run first and fails afterwards: failing BEFORE the
# write would leave the WeekPlan untouched and make its rollback check vacuous.

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

# seed/ is a one-time bootstrap template, correctly excluded from update.sh's
# ongoing-sync manifest — a copy of this repo obtained any way other than a
# fresh git clone of the exact commit that added current/WeekPlan*.md won't
# have it (found by cold review 03.08). No-op when the real seed one is
# already present.
# shellcheck source=lib/seed_strategy_fixture.sh
source "$TEMPLATE_ROOT/scripts/tests/lib/seed_strategy_fixture.sh"
ensure_weekplan_fixture "$TMPDIR/strategy"

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

WEEKPLAN=$(find current -maxdepth 1 -name "WeekPlan*.md" | sed -n 1p)

# Fault injection: a python3 shim that fails ONLY when invoked with the
# WeekPlan path as an argument (create-wp.sh step 3/5) — after running the real
# writer —, passes through to the real interpreter for every other call (the
# REGISTRY step uses a plain heredoc, but the WP number lookup and slug
# transliteration also shell out to python3).
# `[[ == */"$WEEKPLAN" ]]`, not a `case` pattern: real WeekPlan filenames
# contain spaces (this repo's own convention — "WeekPlan W31 ....md"), and an
# unquoted case pattern splits on that space into two tokens, a syntax error
# in the generated shim (found running this test for real against the actual
# seed fixture — every python3 call failed, including unrelated ones, not
# just the one this was meant to intercept). Quoting the variable inside
# [[ == ]] forces a literal (non-glob) match for that segment.
REAL_PYTHON3=$(command -v python3)
FAKE_BIN="$TMPDIR/fake-bin"
mkdir -p "$FAKE_BIN"
# At the moment of injection the shim also records what steps 1-3 had already
# written (REGISTRY row, inbox folder, WeekPlan row): proof that the later
# rollback has something to undo, so "everything is back to the initial state"
# cannot be satisfied by a run that never wrote anything.
cat > "$FAKE_BIN/python3" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == */"$WEEKPLAN" ]]; then
    "$REAL_PYTHON3" "\$@" || exit 74
    echo "injected WeekPlan writer failure" >&2
    cp "$TMPDIR/strategy/docs/WP-REGISTRY.md" "$TMPDIR/registry.at-injection"
    cp "$TMPDIR/strategy/$WEEKPLAN" "$TMPDIR/weekplan.at-injection"
    (cd "$TMPDIR/strategy" && find inbox -mindepth 1 | sort) > "$TMPDIR/inbox.at-injection"
    exit 73
  fi
done
exec "$REAL_PYTHON3" "\$@"
EOF
chmod +x "$FAKE_BIN/python3"

# File copies + `cmp`, not `$(cat file)` + string `=`: command substitution
# strips every trailing newline, so a snapshot/restore bug that drops the
# final \n (the exact class create-wp.sh's own rollback was fixed for — see
# its comment on SNAPSHOT_DIR) would be invisible to a `$(cat A)` = `$(cat B)`
# comparison, since both sides get stripped the same way (found by cold
# review 03.08: reverted the rollback fix to its pre-`cp`-based form and this
# test still passed clean, despite the restored files being missing their
# final newline — a regression test that couldn't catch the regression it
# was written for).
INITIAL_REGISTRY_SNAPSHOT="$TMPDIR/registry.before"
INITIAL_WEEKPLAN_SNAPSHOT="$TMPDIR/weekplan.before"
cp docs/WP-REGISTRY.md "$INITIAL_REGISTRY_SNAPSHOT"
cp "$WEEKPLAN" "$INITIAL_WEEKPLAN_SNAPSHOT"
INITIAL_INBOX=$(find inbox -mindepth 1 | sort)
INITIAL_ARCHIVE=$(find archive/wp-contexts -mindepth 1 | sort)

# --no-artifactor-check: the Artifactor Gate is covered by
# test_create_wp_artifactor_gate.sh. It refuses before any write, so without the
# flag this run would exit 1 at the gate and never reach the injected fault.
set +e
PATH="$FAKE_BIN:$PATH" bash "$IWE_TEMPLATE/scripts/create-wp.sh" \
  --title "Contract Test WP" \
  --budget "1h" \
  --priority "P4" \
  --verification-class closed-loop \
  --no-consent-check \
  --no-artifactor-check \
  >"$TMPDIR/create.out" 2>&1
EXIT_CODE=$?
set -e

cat "$TMPDIR/create.out"
echo "Exit code: $EXIT_CODE"

if [ "$EXIT_CODE" -eq 0 ]; then
  echo "FAIL: injected WeekPlan failure was reported as success" >&2
  exit 1
fi

# (a) The failure must come from the injected WeekPlan fault, not from an early
# refusal: both the shim's marker and create-wp.sh's own step-3 message are required.
grep -q "injected WeekPlan writer failure" "$TMPDIR/create.out" ||
  { echo "FAIL: the fault injection point was never reached (exit $EXIT_CODE came from somewhere else)" >&2; exit 1; }
grep -q "WeekPlan write FAILED" "$TMPDIR/create.out" ||
  { echo "FAIL: create-wp.sh did not report the WeekPlan write failure" >&2; exit 1; }
grep -q "Откат:" "$TMPDIR/create.out" ||
  { echo "FAIL: create-wp.sh did not announce the rollback" >&2; exit 1; }

# (b) Steps 1-3 had written their traces by the time the fault fired.
[ -f "$TMPDIR/registry.at-injection" ] && [ -f "$TMPDIR/weekplan.at-injection" ] && [ -f "$TMPDIR/inbox.at-injection" ] ||
  { echo "FAIL: no working-tree record from the injection point" >&2; exit 1; }
cmp -s "$TMPDIR/registry.at-injection" "$INITIAL_REGISTRY_SNAPSHOT" &&
  { echo "FAIL: REGISTRY was unchanged at injection time — the rollback check below would be vacuous" >&2; exit 1; }
cmp -s "$TMPDIR/weekplan.at-injection" "$INITIAL_WEEKPLAN_SNAPSHOT" &&
  { echo "FAIL: WeekPlan was unchanged at injection time — the rollback check below would be vacuous" >&2; exit 1; }
[ "$(cat "$TMPDIR/inbox.at-injection")" = "$INITIAL_INBOX" ] &&
  { echo "FAIL: inbox/ was unchanged at injection time — the rollback check below would be vacuous" >&2; exit 1; }

FINAL_INBOX=$(find inbox -mindepth 1 | sort)
FINAL_ARCHIVE=$(find archive/wp-contexts -mindepth 1 | sort)

cmp -s docs/WP-REGISTRY.md "$INITIAL_REGISTRY_SNAPSHOT" ||
  { echo "FAIL: WP-REGISTRY.md was not rolled back (byte-exact compare, incl. trailing newline)" >&2; exit 1; }
cmp -s "$WEEKPLAN" "$INITIAL_WEEKPLAN_SNAPSHOT" ||
  { echo "FAIL: WeekPlan was not rolled back (byte-exact compare, incl. trailing newline)" >&2; exit 1; }
[ "$FINAL_INBOX" = "$INITIAL_INBOX" ] ||
  { echo "FAIL: inbox/ was not rolled back" >&2; exit 1; }
[ "$FINAL_ARCHIVE" = "$INITIAL_ARCHIVE" ] ||
  { echo "FAIL: archive/wp-contexts/ was not rolled back (orphaned stub left behind)" >&2; exit 1; }

echo "✓ Correctly rolled back after fault injection — no partial WP left behind"
