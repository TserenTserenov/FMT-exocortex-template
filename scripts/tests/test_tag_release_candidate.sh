#!/usr/bin/env bash
# WP-529 Phase 251: scripts/tag-release-candidate.sh against a local bare remote.
#
# Checks: first candidate is rc.1 and is published to the remote; the output
# carries rc_tag/rc_commit/rc_tree; the same content is refused; new content
# gets rc.2; a remote that already has rc.5 (taken by a parallel run) makes
# the next candidate rc.6, not a collision.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/tag-release-candidate.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAILS=0
check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "  ok: $1"
    else
        echo "  FAIL: $1 — expected '$2', got '$3'"
        FAILS=$((FAILS + 1))
    fi
}

git init -q --bare "$WORK/remote.git"
git clone -q "$WORK/remote.git" "$WORK/clone" 2>/dev/null
cd "$WORK/clone"
mkdir scripts
cp "$SCRIPT" "$REPO_ROOT/scripts/next-rc-tag.sh" scripts/
git config user.name test
git config user.email test@example.invalid
echo one > file.txt
git add . && git commit -q -m one
git push -q origin HEAD:refs/heads/release/v9.9.0

echo "1. first candidate"
OUT=$(bash scripts/tag-release-candidate.sh 9.9.0 origin 2>/dev/null)
check "rc_tag line" "rc_tag=v9.9.0-rc.1" "$(printf '%s\n' "$OUT" | grep '^rc_tag=')"
check "rc_commit line" "rc_commit=$(git rev-parse HEAD)" "$(printf '%s\n' "$OUT" | grep '^rc_commit=')"
check "rc_tree line" "rc_tree=$(git rev-parse 'HEAD^{tree}')" "$(printf '%s\n' "$OUT" | grep '^rc_tree=')"
check "tag is on the remote" "1" "$(git ls-remote --tags origin 'v9.9.0-rc.1' | grep -c 'refs/tags/v9.9.0-rc.1$')"

echo "2. same content is refused"
if bash scripts/tag-release-candidate.sh 9.9.0 origin >/dev/null 2>"$WORK/err"; then RC=0; else RC=$?; fi
check "exit code" "1" "$RC"
check "reason names the existing candidate" "1" "$(grep -c 'same content as v9.9.0-rc.1' "$WORK/err")"
check "no rc.2 on the remote" "0" "$(git ls-remote --tags origin 'v9.9.0-rc.2' | wc -l | tr -d ' ')"

echo "3. new content gets the next number"
echo two > file.txt && git commit -q -am two
OUT=$(bash scripts/tag-release-candidate.sh 9.9.0 origin 2>/dev/null)
check "rc_tag line" "rc_tag=v9.9.0-rc.2" "$(printf '%s\n' "$OUT" | grep '^rc_tag=')"

echo "4. number taken on the remote by a parallel run"
git tag -a v9.9.0-rc.5 -m parallel HEAD~1 && git push -q origin refs/tags/v9.9.0-rc.5 && git tag -d v9.9.0-rc.5 >/dev/null
echo three > file.txt && git commit -q -am three
OUT=$(bash scripts/tag-release-candidate.sh 9.9.0 origin 2>/dev/null)
check "rc_tag line" "rc_tag=v9.9.0-rc.6" "$(printf '%s\n' "$OUT" | grep '^rc_tag=')"

echo "5. bad version is rejected"
if bash scripts/tag-release-candidate.sh 'v9.9' origin >/dev/null 2>&1; then RC=0; else RC=$?; fi
check "exit code" "1" "$RC"

if [ "$FAILS" -gt 0 ]; then
    echo "test_tag_release_candidate: $FAILS failure(s)"
    exit 1
fi
echo "test_tag_release_candidate: all checks passed"
