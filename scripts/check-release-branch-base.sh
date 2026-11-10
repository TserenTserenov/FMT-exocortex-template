#!/usr/bin/env bash
# WP-529 Ф261 (finding 2 of the 10.11 pipeline review): the identity "candidate = release"
# holds only while merging the release branch into main yields exactly the tree of the
# branch. That is true when the tip of main is already part of the branch history. If main
# moved after the cut, the merge commit adds main's changes, its tree differs from the latest
# rc, and release.yml stops the release at the very end (and the [Unreleased] section
# conflicts). Until now this rested on a spoken agreement "do not touch main"; this script
# makes it checkable. Run by release-candidate.yml (next-rc) and by the Release Lead right
# before merging the release PR.
#
# Usage: check-release-branch-base.sh <version> [remote] [--head]   # remote defaults to origin
# Exit 0: the tip of <remote>/main is an ancestor of (or equal to) <remote>/release/v<version>.
# Exit 1: main moved (recovery is printed) or the refs cannot be read.
# --head (the workflow passes it): HEAD of this checkout must also be the remote tip of the branch,
# so a candidate is never tagged on a tip other than the one that was checked.

set -euo pipefail

VERSION="${1:-}"
REMOTE="${2:-origin}"
PIN_HEAD=false
[ "${3:-}" = "--head" ] && PIN_HEAD=true

case "$VERSION" in
    *[!0-9.]*|"") echo "usage: check-release-branch-base.sh <numeric version> [remote]" >&2; exit 1 ;;
esac

BRANCH="release/v${VERSION}"
git fetch -q "$REMOTE" \
    "+refs/heads/main:refs/remotes/${REMOTE}/main" \
    "+refs/heads/${BRANCH}:refs/remotes/${REMOTE}/${BRANCH}" \
    || { echo "check-release-branch-base: cannot fetch main and ${BRANCH} from ${REMOTE}" >&2; exit 1; }

MAIN_TIP=$(git rev-parse "refs/remotes/${REMOTE}/main")
BRANCH_TIP=$(git rev-parse "refs/remotes/${REMOTE}/${BRANCH}")

if $PIN_HEAD && [ "$(git rev-parse HEAD)" != "$BRANCH_TIP" ]; then
    echo "check-release-branch-base: HEAD $(git rev-parse HEAD) is not the remote tip of ${BRANCH} ($BRANCH_TIP) — the branch moved after checkout, run again" >&2
    exit 1
fi

if git merge-base --is-ancestor "$MAIN_TIP" "$BRANCH_TIP"; then
    echo "check-release-branch-base: main ${MAIN_TIP} is part of ${BRANCH} — merging the PR gives the tree of the branch" >&2
    exit 0
fi

cat >&2 <<EOF
check-release-branch-base: main moved after the cut — its tip ${MAIN_TIP} is not part of ${BRANCH} (tip ${BRANCH_TIP}).
Merging the release PR now would give a tree different from the candidate, and release.yml would stop the release.
Recovery (the branch release/v${VERSION} already exists, so a second cut is refused): bring main into the branch
(git checkout ${BRANCH} && git merge origin/main, resolve [Unreleased] and the fields of the new entries, push),
then run Release Candidate with mode=next-rc: the new tree becomes the next rc and every row of the protocol runs again.
EOF
exit 1
