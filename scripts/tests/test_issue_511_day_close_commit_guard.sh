#!/usr/bin/env bash
# Regression for issue #511: a stale-path `git add` after `git mv` must make
# the production Day Close guard return before commit, even though the rename
# already makes the index non-empty.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/.claude/skills/day-close/SKILL.md"
TEST_ROOT="$(mktemp -d /tmp/iwe-issue-511-commit-guard.XXXXXX)"
GUARD_SOURCE="$TEST_ROOT/guard.sh"
REPO="$TEST_ROOT/repo"

FAIL=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "  ✅ PASS: $*"; }
# Invoked indirectly by the trap below.
# shellcheck disable=SC2329
cleanup() { local rc=$?; rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM

awk '
  /<!-- issue-511-guard:start -->/ { capture=1; next }
  /<!-- issue-511-guard:end -->/ { capture=0 }
  capture && $0 !~ /^```/ { print }
' "$SKILL" > "$GUARD_SOURCE"

if ! grep -q '^stage_and_commit_or_stop()' "$GUARD_SOURCE"; then
    echo "❌ production guard could not be extracted from day-close/SKILL.md" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$GUARD_SOURCE"

git -C "$TEST_ROOT" init -q repo
git -C "$REPO" config user.name "Issue 511 regression"
git -C "$REPO" config user.email "issue-511@example.invalid"
printf 'original\n' > "$REPO/old-path.md"
printf 'unchanged\n' > "$REPO/unchanged.md"
mkdir -p "$REPO/docs"
printf 'doc-a\n' > "$REPO/docs/a.md"
printf 'doc-b\n' > "$REPO/docs/b.md"
git -C "$REPO" add -- old-path.md unchanged.md docs/a.md docs/b.md
git -C "$REPO" commit -qm "initial"
INITIAL_HEAD=$(git -C "$REPO" rev-parse HEAD)

# A directory path is syntactically explicit but semantically broad: `git add
# -- docs` can capture every file below it. Reject before touching the index.
printf 'directory-edit\n' >> "$REPO/docs/a.md"
if stage_and_commit_or_stop "$REPO" "must not accept a directory" docs \
    >"$TEST_ROOT/directory.out" 2>&1; then
    fail "directory path was accepted as an explicit file scope"
else
    pass "directory path is rejected as broad staging"
fi
if git -C "$REPO" diff --cached --quiet --exit-code; then
    pass "directory refusal leaves the index untouched"
else
    fail "directory refusal staged files recursively"
fi
if [ "$(git -C "$REPO" rev-parse HEAD)" = "$INITIAL_HEAD" ]; then
    pass "directory refusal leaves HEAD unchanged"
else
    fail "directory refusal changed HEAD"
fi
if grep -q 'explicit commit scope requires files, not a directory: docs' "$TEST_ROOT/directory.out"; then
    pass "guard explains that directory scope is forbidden"
else
    fail "guard did not identify the directory scope"
fi
git -C "$REPO" restore --worktree -- docs/a.md

# A removed directory is no longer visible to `[ -d ]`, but Git still resolves
# its pathspec recursively to every tracked descendant. Reject it before add so
# multiple deletions cannot be smuggled through a nominally explicit path.
rm "$REPO/docs/a.md" "$REPO/docs/b.md"
rmdir "$REPO/docs"
if stage_and_commit_or_stop "$REPO" "must not accept a deleted directory" docs \
    >"$TEST_ROOT/deleted-directory.out" 2>&1; then
    fail "deleted directory path was accepted as a single-file scope"
else
    pass "deleted directory with tracked descendants is rejected"
fi
if git -C "$REPO" diff --cached --quiet --exit-code; then
    pass "deleted-directory refusal leaves the index untouched"
else
    fail "deleted-directory refusal staged recursive deletions"
fi
if [ "$(git -C "$REPO" rev-parse HEAD)" = "$INITIAL_HEAD" ]; then
    pass "deleted-directory refusal leaves HEAD unchanged"
else
    fail "deleted-directory refusal changed HEAD"
fi
if grep -q 'resolves to tracked descendants, not one file: docs' \
    "$TEST_ROOT/deleted-directory.out"; then
    pass "guard explains the deleted-directory pathspec risk"
else
    fail "guard did not identify tracked descendants below the deleted path"
fi
git -C "$REPO" restore --worktree -- docs/a.md docs/b.md

# Exact 21.08 mechanism: rename is staged, the content edit is not, and the
# caller accidentally retains the old path for its next add.
git -C "$REPO" mv old-path.md new-path.md
printf 'edited-after-move\n' >> "$REPO/new-path.md"

if stage_and_commit_or_stop "$REPO" "must not be created" old-path.md \
    >"$TEST_ROOT/stale.out" 2>&1; then
    fail "stale old-path add returned success"
else
    pass "stale old-path add fails closed"
fi

if [ "$(git -C "$REPO" rev-parse HEAD)" = "$INITIAL_HEAD" ]; then
    pass "commit is unreachable after failed git add"
else
    fail "HEAD changed despite failed git add"
fi

if grep -q 'commit was not attempted' "$TEST_ROOT/stale.out"; then
    pass "guard reports the causal stop, not an empty-index approximation"
else
    fail "guard did not report that commit was skipped"
fi

# A merely non-empty index is not enough: an unchanged explicit path must not
# be allowed to ride on the already-staged rename and commit unrelated bytes.
if stage_and_commit_or_stop "$REPO" "must still not be created" unchanged.md \
    >"$TEST_ROOT/unchanged.out" 2>&1; then
    fail "unchanged explicit path rode on an unrelated staged rename"
else
    pass "every explicit path must have staged content of its own"
fi
if [ "$(git -C "$REPO" rev-parse HEAD)" = "$INITIAL_HEAD" ]; then
    pass "non-empty unrelated index still cannot bypass the path guard"
else
    fail "HEAD changed when the explicit path had no staged content"
fi
if grep -q 'explicit path has no pending or staged change: unchanged.md' "$TEST_ROOT/unchanged.out"; then
    pass "guard names the path whose intended content is absent"
else
    fail "guard did not identify the unstaged explicit path"
fi

# Positive control: the current path stages the post-move edit and commits the
# rename plus content. Without this control an always-failing guard could pass.
if stage_and_commit_or_stop "$REPO" "rename with edit" new-path.md \
    >"$TEST_ROOT/current.out" 2>&1; then
    pass "current path reaches commit"
else
    fail "current path was rejected (see $TEST_ROOT/current.out)"
fi

if git -C "$REPO" show HEAD:new-path.md | grep -q '^edited-after-move$'; then
    pass "committed blob contains the post-move edit"
else
    fail "post-move edit is absent from HEAD"
fi

if git -C "$REPO" diff --quiet HEAD -- new-path.md; then
    pass "post-commit content containment remains satisfied"
else
    fail "worktree still has uncommitted content after the positive control"
fi

# Multi-path partial-mutation control: one changed path plus one unchanged path
# must be rejected before git add, leaving a clean index and the worktree edit
# intact for correction. Automatically resetting an existing index would erase
# incident evidence, so the production invariant is "no new staging before
# preflight completes", not "reset every pre-existing staged byte".
CONTROL_HEAD=$(git -C "$REPO" rev-parse HEAD)
printf 'second-edit\n' >> "$REPO/new-path.md"
if stage_and_commit_or_stop "$REPO" "must not stage partially" new-path.md unchanged.md \
    >"$TEST_ROOT/multipath.out" 2>&1; then
    fail "multi-path call accepted an unchanged explicit path"
else
    pass "multi-path call rejects an unchanged path before commit"
fi
if [ "$(git -C "$REPO" rev-parse HEAD)" = "$CONTROL_HEAD" ]; then
    pass "multi-path preflight leaves HEAD unchanged"
else
    fail "multi-path preflight changed HEAD"
fi
if git -C "$REPO" diff --cached --quiet --exit-code; then
    pass "multi-path preflight creates no partial staged mutation"
else
    fail "changed path was staged before the unchanged path stopped the call"
fi
if grep -q 'explicit path has no pending or staged change: unchanged.md' "$TEST_ROOT/multipath.out"; then
    pass "multi-path preflight names the unchanged path"
else
    fail "multi-path preflight did not name the unchanged path"
fi

# Shared-index control: an unrelated staged file from another operation must
# make commit unreachable before this call stages its own intended edit. The
# pre-existing index is evidence and therefore remains intact for its owner.
git -C "$REPO" reset -q HEAD -- new-path.md unchanged.md
printf 'unrelated-agent-edit\n' >> "$REPO/unchanged.md"
git -C "$REPO" add -- unchanged.md
printf 'third-edit\n' >> "$REPO/new-path.md"
SHARED_HEAD=$(git -C "$REPO" rev-parse HEAD)
if stage_and_commit_or_stop "$REPO" "must not capture shared index" new-path.md \
    >"$TEST_ROOT/shared-index.out" 2>&1; then
    fail "explicit commit captured an unrelated staged path"
else
    pass "unrelated staged path blocks the whole commit"
fi
if [ "$(git -C "$REPO" rev-parse HEAD)" = "$SHARED_HEAD" ]; then
    pass "shared-index refusal leaves HEAD unchanged"
else
    fail "shared-index refusal changed HEAD"
fi
if git -C "$REPO" diff --cached --quiet --exit-code -- unchanged.md; then
    fail "shared-index refusal erased the pre-existing staged path"
else
    pass "pre-existing staged evidence remains intact"
fi
if git -C "$REPO" diff --cached --quiet --exit-code -- new-path.md; then
    pass "intended path was not partially staged before scope refusal"
else
    fail "scope refusal partially staged the intended path"
fi
if grep -q 'staged path is outside the explicit commit scope: unchanged.md' "$TEST_ROOT/shared-index.out"; then
    pass "guard names the unrelated staged path"
else
    fail "guard did not identify the unrelated staged path"
fi

if [ "$FAIL" -eq 0 ]; then
    echo "issue-511 commit guard: все сценарии прошли"
    exit 0
fi
echo "issue-511 commit guard: $FAIL сценариев провалено" >&2
exit 1
