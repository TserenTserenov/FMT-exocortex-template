#!/usr/bin/env bash
# routing: helper  called-by=roles/strategist/scripts/strategist.sh  deterministic=true
# ds-publish.sh — publish ONE local commit to origin without touching this checkout.
#
# Why (issue #941): scheduled roles (strategist, extractor) commit into the
# governance repo while you may be working in the same checkout. A plain
# `git pull --rebase && git push` there once lost a week-review commit. This script
# leaves your checkout alone: it fetches origin, replays the commit in a throw-away
# worktree on top of the fresh branch tip, and pushes from there.
#
# Usage:
#   ds-publish.sh <repo-dir> <priority> [--reason TEXT] [--from-commit SHA]
#     <priority>      normal | high (kept for the callers' contract; not used to reorder anything)
#     --reason TEXT   shown in the output only
#     --from-commit   the single commit to publish (default: HEAD of <repo-dir>)
#
# Behaviour:
#   - target branch = the branch currently checked out in <repo-dir> (origin/HEAD, then
#     main, when HEAD is detached);
#   - a commit already on origin (same SHA or an equivalent patch) is a successful no-op;
#   - if origin moved between fetch and push, the commit is replayed on the new tip
#     (up to 3 attempts); never a force push;
#   - your working tree, index and HEAD are never modified.
#
# Exit codes: 0 published or already published | 1 usage / precondition / fetch failure |
#             2 the commit is a merge commit (only single commits are carried) |
#             3 cherry-pick conflict (the commit stays local) | 4 push refused after retries
#
# Not covered on purpose: the extractor publishes through scripts/lib/publish-gate.sh of
# the governance repo and falls back to a plain push when that library is missing.

set -uo pipefail

MAX_ATTEMPTS=3

die() { echo "ds-publish: $1" >&2; exit "${2:-1}"; }

usage() {
  echo "usage: ds-publish.sh <repo-dir> <priority: normal|high> [--reason TEXT] [--from-commit SHA]" >&2
  exit 1
}

[ "$#" -ge 2 ] || usage
REPO="$1"; PRIORITY="$2"; shift 2
case "$PRIORITY" in normal|high) ;; *) usage ;; esac

REASON=""; FROM_COMMIT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reason)      [ "$#" -ge 2 ] || usage; REASON="$2"; shift 2 ;;
    --from-commit) [ "$#" -ge 2 ] || usage; FROM_COMMIT="$2"; shift 2 ;;
    *) usage ;;
  esac
done

git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$REPO is not a git work tree"
git -C "$REPO" remote get-url origin >/dev/null 2>&1 || die "$REPO has no remote 'origin'"

SHA=$(git -C "$REPO" rev-parse --verify --quiet "${FROM_COMMIT:-HEAD}^{commit}") \
  || die "commit '${FROM_COMMIT:-HEAD}' not found in $REPO"

if [ "$(git -C "$REPO" rev-list --parents -n 1 "$SHA" | wc -w | tr -d ' ')" -gt 2 ]; then
  die "$SHA is a merge commit; only single commits are published" 2
fi

BRANCH=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null \
  || git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
BRANCH="${BRANCH:-main}"

echo "ds-publish: ${SHA:0:12} -> origin/$BRANCH${REASON:+ ($REASON)}"

WORK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ds-publish.XXXXXX" 2>/dev/null || mktemp -d) || die "cannot create a temp directory"
WORKTREE="$WORK_ROOT/wt"
# origin's tip is fetched into a private ref, not into refs/remotes/origin/<branch>: a
# single-branch clone (or any narrowed remote.origin.fetch) never updates the latter.
TIP_REF="refs/ds-publish/$$"

cleanup_worktree() {
  git -C "$REPO" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  git -C "$REPO" update-ref -d "$TIP_REF" >/dev/null 2>&1 || true
  rm -rf "$WORK_ROOT"
}
trap cleanup_worktree EXIT

# Committer identity for the replay: the repo's own, else the commit's author.
if [ -z "$(git -C "$REPO" config user.email 2>/dev/null)" ]; then
  GIT_COMMITTER_NAME=$(git -C "$REPO" log -1 --format=%an "$SHA")
  GIT_COMMITTER_EMAIL=$(git -C "$REPO" log -1 --format=%ae "$SHA")
  export GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
fi

already_published() {
  git -C "$REPO" merge-base --is-ancestor "$SHA" "$TIP" 2>/dev/null && return 0
  # `git cherry` marks an equivalent patch already upstream with "-".
  git -C "$REPO" rev-parse --verify --quiet "$SHA^" >/dev/null || return 1
  git -C "$REPO" cherry "$TIP" "$SHA" "$SHA^" 2>/dev/null | grep -q '^-'
}

attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  git -C "$REPO" fetch --quiet origin "+refs/heads/$BRANCH:$TIP_REF" 2>"$WORK_ROOT/fetch.err" \
    || die "fetch origin/$BRANCH failed: $(tail -n 1 "$WORK_ROOT/fetch.err")"
  TIP=$(git -C "$REPO" rev-parse --verify --quiet "$TIP_REF^{commit}") || die "origin/$BRANCH not found after fetch"

  if already_published; then
    echo "ds-publish: already on origin/$BRANCH, nothing to do"
    exit 0
  fi

  git -C "$REPO" worktree add --detach --quiet "$WORKTREE" "$TIP" 2>"$WORK_ROOT/wt.err" \
    || die "cannot create a temp worktree: $(tail -n 1 "$WORK_ROOT/wt.err")"

  if ! git -C "$WORKTREE" cherry-pick "$SHA" >"$WORK_ROOT/pick.out" 2>&1; then
    # Three different failures share this branch; only a PROVEN empty result may report success.
    picking=$(git -C "$WORKTREE" rev-parse --verify --quiet CHERRY_PICK_HEAD || true)
    conflicts=$(git -C "$WORKTREE" diff --name-only --diff-filter=U)
    if [ -n "$conflicts" ]; then
      git -C "$WORKTREE" cherry-pick --abort >/dev/null 2>&1 || true
      die "conflict replaying ${SHA:0:12} on origin/$BRANCH; the commit stays local. $(tail -n 1 "$WORK_ROOT/pick.out")" 3
    fi
    if [ -n "$picking" ] && git -C "$WORKTREE" diff --cached --quiet && [ "$(git -C "$WORKTREE" rev-parse HEAD)" = "$TIP" ]; then
      echo "ds-publish: the commit changes nothing on top of origin/$BRANCH, nothing to do"
      exit 0
    fi
    die "cherry-pick of ${SHA:0:12} failed for a reason other than a conflict; the commit stays local. $(tail -n 1 "$WORK_ROOT/pick.out")"
  fi

  if git -C "$WORKTREE" push --quiet origin "HEAD:refs/heads/$BRANCH" 2>"$WORK_ROOT/push.err"; then
    echo "ds-publish: published as $(git -C "$WORKTREE" rev-parse --short=12 HEAD)"
    exit 0
  fi
  echo "ds-publish: push attempt $attempt of $MAX_ATTEMPTS refused: $(tail -n 1 "$WORK_ROOT/push.err")" >&2
  git -C "$REPO" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  attempt=$((attempt + 1))
done

die "push to origin/$BRANCH refused $MAX_ATTEMPTS times; the commit stays local" 4
