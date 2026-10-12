#!/usr/bin/env bash
# Regression coverage for issue #1201: the router journal written by
# route-task.sh into <governance-repo>/logs/ must not appear in `git status`.
# Two layers:
#   1. the seed .gitignore of the governance repo lists logs/;
#   2. on an install whose .gitignore predates that entry, route-task.sh adds
#      the directory to the repo-local info/exclude the first time it writes.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SCRIPT="$ROOT/scripts/route-task.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

# --- 1. Seed .gitignore carries the entry.
if grep -qxF 'logs/' "$ROOT/seed/strategy/.gitignore"; then
    pass "seed/strategy/.gitignore ignores logs/"
else
    fail_test "seed/strategy/.gitignore does not list logs/"
fi

# --- 2. Existing install (no entry in .gitignore): run the real function.
GOV="$TMP/DS-strategy"
mkdir -p "$GOV"
git -C "$GOV" init -q
: > "$GOV/.gitignore"
git -C "$GOV" add .gitignore
git -C "$GOV" -c user.email=t@t -c user.name=t commit -q -m init

run_helper() {
    bash -c '
        set -euo pipefail
        '"$(sed -n '/^exclude_log_dir_from_git() {/,/^}/p' "$SCRIPT")"'
        mkdir -p "$1"
        exclude_log_dir_from_git "$1"
        printf "x\n" >> "$1/routing-path-distribution.tsv"
    ' _ "$1"
}

run_helper "$GOV/logs"
if [ -z "$(git -C "$GOV" status --porcelain)" ]; then
    pass "logs/ does not show up in git status after the router writes"
else
    fail_test "git status is not clean: $(git -C "$GOV" status --porcelain)"
fi

# Idempotent: a second run must not duplicate the pattern.
run_helper "$GOV/logs"
count=$(grep -cxF '/logs/' "$GOV/.git/info/exclude")
if [ "$count" = "1" ]; then pass "exclude entry added once (idempotent)"; else fail_test "exclude entry count = $count"; fi

# --- 3. A directory outside any git work tree is left alone, no failure.
mkdir -p "$TMP/plain/logs"
if run_helper "$TMP/plain/logs"; then pass "non-git directory: helper is a silent no-op"; else fail_test "helper failed outside git"; fi

# --- 4. The helper is wired into both log writers.
if [ "$(grep -c 'exclude_log_dir_from_git "\$' "$SCRIPT")" = "2" ]; then
    pass "helper called from emit_error and log_audit"
else
    fail_test "helper is not called from both log writers"
fi

exit $fail
