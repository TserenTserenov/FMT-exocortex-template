#!/bin/bash
# Regression test (WP-530 F72): an isolated extractor run is published to origin
# as a cherry-pick (new SHA), so `git branch -d` never sees its branch as merged
# and every run left an `extractor/<label>-<id>` branch behind. The real
# cleanup_isolated_inbox_worktree() must now drop the branch when all its
# commits are patch-equivalent on the upstream, and keep it when any commit is
# not published.
#
# Extracts the real function from extractor.sh (same technique as
# test_mount_readonly_packs.sh) instead of a hand-rolled equivalent.
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/roles/extractor/scripts/extractor.sh"
CLEANUP_FN=$(awk '$0 ~ "^cleanup_isolated_inbox_worktree\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$SCRIPT")
if [ -z "$CLEANUP_FN" ]; then
    echo "FAIL: cleanup_isolated_inbox_worktree() not found in $SCRIPT"
    exit 1
fi
eval "$CLEANUP_FN"

TMP=$(mktemp -d)
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
LOG_FILE="$TMP/extractor.log"
log() { echo "$*" >> "$LOG_FILE"; }

GIT_ID=(-c user.email=test@example.invalid -c user.name="Branch cleanup regression")
FAIL=0

git init -q --bare -b main "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/canon" 2>/dev/null
git -C "$TMP/canon" "${GIT_ID[@]}" commit -q --allow-empty -m init
git -C "$TMP/canon" push -q origin main
git clone -q "$TMP/origin.git" "$TMP/publisher"

run_case() {  # <name> <published: yes|no>
    local name="$1" published="$2" branch="extractor/feed-$1" wt="$TMP/wt-$1" iso="$TMP/iso-$1"
    mkdir -p "$iso"
    git -C "$TMP/canon" worktree add -q -b "$branch" "$wt" origin/main
    echo "$name" > "$wt/feed-$name.md"
    git -C "$wt" add "feed-$name.md"
    git -C "$wt" "${GIT_ID[@]}" commit -q -m "feed $name"
    if [ "$published" = yes ]; then
        # Publish the way ds-publish does: cherry-pick onto fresh origin (new SHA).
        git -C "$TMP/publisher" pull -q origin main
        git -C "$TMP/publisher" fetch -q "$TMP/canon" "$branch"
        git -C "$TMP/publisher" "${GIT_ID[@]}" cherry-pick FETCH_HEAD >/dev/null
        git -C "$TMP/publisher" push -q origin main
    fi
    cleanup_isolated_inbox_worktree "$TMP/canon" "$wt" "$branch" "$iso" canon "$iso"
    if git -C "$TMP/canon" rev-parse --verify -q "refs/heads/$branch" >/dev/null; then
        echo present
    else
        echo absent
    fi
}

if [ "$(run_case published yes)" = absent ]; then
    echo "PASS: branch published by cherry-pick is deleted"
else
    echo "FAIL: branch published by cherry-pick was left behind"
    FAIL=1
fi

if [ "$(run_case unpublished no)" = present ]; then
    echo "PASS: branch with an unpublished commit is preserved"
else
    echo "FAIL: branch with an unpublished commit was deleted"
    FAIL=1
fi

if grep -q 'isolated-run branch was preserved for review: extractor/feed-unpublished' "$LOG_FILE"; then
    echo "PASS: preserved branch is reported"
else
    echo "FAIL: no preserve warning for the unpublished branch"
    FAIL=1
fi

exit "$FAIL"
