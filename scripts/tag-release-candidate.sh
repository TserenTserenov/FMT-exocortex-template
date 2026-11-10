#!/usr/bin/env bash
# WP-529 Phase 251: tag HEAD as the next release candidate vX.Y.Z-rc.N.
#
# Used by .github/workflows/release-candidate.yml in both modes (cut: rc.1 on
# the fresh bump commit; next-rc: the tip of release/vX.Y.Z after reverts or
# fixes). Testers install exactly this tag (IWE_UPDATE_CHANNEL=rc), and
# release.yml refuses a release whose tree differs from the latest rc.
#
# Refuses when HEAD's tree equals the tree of the latest existing rc of this
# version: that would be the same candidate under a new number, and testers
# would re-check content they already checked.
#
# The number comes from scripts/next-rc-tag.sh (remote tags, max N + 1). A
# push rejected because a parallel run took the number is retried with a
# recomputed number, three attempts in total.
#
# Usage: tag-release-candidate.sh <version> [remote]   # remote defaults to origin
# Stdout (GitHub output format): rc_tag=…, rc_commit=…, rc_tree=…
# Diagnostics go to stderr. Exit 1 on any failure.

set -euo pipefail

VERSION="${1:-}"
REMOTE="${2:-origin}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$VERSION" in
    *[!0-9.]*|"") echo "usage: tag-release-candidate.sh <numeric version> [remote]" >&2; exit 1 ;;
esac

git fetch -q --tags "$REMOTE" || { echo "tag-release-candidate: git fetch --tags $REMOTE failed" >&2; exit 1; }

HEAD_TREE=$(git rev-parse 'HEAD^{tree}')
LATEST_RC=$(git tag -l "v${VERSION}-rc.*" | sort -V | tail -1)
if [ -n "$LATEST_RC" ] && [ "$(git rev-parse "${LATEST_RC}^{tree}")" = "$HEAD_TREE" ]; then
    echo "tag-release-candidate: HEAD has the same content as $LATEST_RC — no new candidate to tag" >&2
    exit 1
fi

git config user.name >/dev/null || git config user.name "github-actions[bot]"
git config user.email >/dev/null || git config user.email "github-actions[bot]@users.noreply.github.com"

for _attempt in 1 2 3; do
    RC_TAG=$(bash "$SCRIPT_DIR/next-rc-tag.sh" "$VERSION" "$REMOTE")
    git tag -a "$RC_TAG" -m "Release candidate $RC_TAG" HEAD
    if git push -q "$REMOTE" "refs/tags/${RC_TAG}"; then
        echo "tag-release-candidate: published $RC_TAG" >&2
        echo "rc_tag=$RC_TAG"
        echo "rc_commit=$(git rev-parse HEAD)"
        echo "rc_tree=$HEAD_TREE"
        exit 0
    fi
    git tag -d "$RC_TAG" >/dev/null
    echo "tag-release-candidate: push of $RC_TAG rejected, recomputing the number" >&2
done

echo "tag-release-candidate: could not publish an rc tag after 3 attempts" >&2
exit 1
