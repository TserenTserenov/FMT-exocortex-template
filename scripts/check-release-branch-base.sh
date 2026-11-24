#!/usr/bin/env bash
# Base check of a release branch before a release candidate is tagged.
#
# WP-529 Ф268 (release from the release branch, main never stops): the release tag goes on
# the checked candidate on release/vX.Y.Z, and the branch is merged into main only after the
# release. So main moving after the cut no longer changes what is released and is NOT a
# refusal any more (it was, under Ф261, when the release tag went on the merge commit in main).
# What is still required:
#   1. the branch was cut from main: it shares history with main;
#   2. the branch contains the previous release tag (the highest vA.B.C below <version>):
#      otherwise it was cut before the previous release PR came back to main, and the version
#      number, the CHANGELOG sections and the release notes on the branch are stale;
#   3. with --head: HEAD of this checkout is the remote tip of the branch, so a candidate is
#      never tagged on a tip other than the one that was checked.
# Run by release-candidate.yml (next-rc).
#
# Usage: check-release-branch-base.sh <version> [remote] [--head]   # remote defaults to origin
# Exit 0: the branch is a valid base for a candidate (a moved main is only reported).
# Exit 1: one of the checks above failed, or the refs cannot be read.

set -euo pipefail

VERSION="${1:-}"
REMOTE="${2:-origin}"
PIN_HEAD=false
[ "${3:-}" = "--head" ] && PIN_HEAD=true

case "$VERSION" in
    *[!0-9.]*|"") echo "usage: check-release-branch-base.sh <numeric version> [remote] [--head]" >&2; exit 1 ;;
esac

BRANCH="release/v${VERSION}"
git fetch -q --tags "$REMOTE" \
    "+refs/heads/main:refs/remotes/${REMOTE}/main" \
    "+refs/heads/${BRANCH}:refs/remotes/${REMOTE}/${BRANCH}" \
    || { echo "check-release-branch-base: cannot fetch main and ${BRANCH} from ${REMOTE}" >&2; exit 1; }

MAIN_TIP=$(git rev-parse "refs/remotes/${REMOTE}/main")
BRANCH_TIP=$(git rev-parse "refs/remotes/${REMOTE}/${BRANCH}")

if $PIN_HEAD && [ "$(git rev-parse HEAD)" != "$BRANCH_TIP" ]; then
    echo "check-release-branch-base: HEAD $(git rev-parse HEAD) is not the remote tip of ${BRANCH} ($BRANCH_TIP) — the branch moved after checkout, run again" >&2
    exit 1
fi

if ! CUT_BASE=$(git merge-base "$MAIN_TIP" "$BRANCH_TIP"); then
    echo "check-release-branch-base: ${BRANCH} shares no history with main — it was not cut from main" >&2
    exit 1
fi

# The previous release: the highest stable tag vA.B.C strictly below this version.
PREV_TAG=$( { git tag -l 'v[0-9]*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | grep -vxF "v${VERSION}" || true
              echo "v${VERSION}"; } | sort -V | grep -B1 -xF "v${VERSION}" | head -1)
[ "$PREV_TAG" = "v${VERSION}" ] && PREV_TAG=""

if [ -n "$PREV_TAG" ] && ! git merge-base --is-ancestor "$PREV_TAG" "$BRANCH_TIP"; then
    cat >&2 <<EOF
check-release-branch-base: ${BRANCH} does not contain the previous release ${PREV_TAG}.
The branch was cut before the release PR of ${PREV_TAG} came back to main: its version number,
CHANGELOG sections and release notes are stale. Merge the release PR of ${PREV_TAG} into main,
then bring main into ${BRANCH} (git merge origin/main) or cut the release again.
EOF
    exit 1
fi

if git merge-base --is-ancestor "$MAIN_TIP" "$BRANCH_TIP"; then
    echo "check-release-branch-base: ${BRANCH} contains the tip of main ${MAIN_TIP}" >&2
else
    echo "check-release-branch-base: main moved after the cut (cut base ${CUT_BASE}, main ${MAIN_TIP}) — not part of this release, no action needed (WP-529 Ф268)" >&2
fi
echo "check-release-branch-base: ${BRANCH} is a valid base for a candidate${PREV_TAG:+ (contains ${PREV_TAG})}" >&2
exit 0
