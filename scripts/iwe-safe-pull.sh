#!/usr/bin/env bash
# iwe-safe-pull.sh -- non-mutating Pull-on-Touch freshness gate (AR.006).
#
# A shared checkout has no transaction that binds its symbolic HEAD, named branch,
# index and worktree against arbitrary concurrent checkout/edit/commit operations.
# Updating it automatically can therefore move the wrong branch or overwrite work
# created after a preflight check. This gate reads the exact remote branch OID,
# classifies the checked-out branch against that snapshot when the object is already
# local, and never fetches or changes refs, FETCH_HEAD, the index, worktree, or stash.
#
# Usage: iwe-safe-pull.sh <repo-path> [branch]
# Exit codes: 0 = the stable local snapshot equals or contains the queried remote.
#             1 = query/guard refused, local is behind/diverged, or the repo changed
#                 during inspection. The caller must mark its data potentially stale.
set -uo pipefail
# Read-only Git inspection must not refresh/write the shared index opportunistically.
export GIT_OPTIONAL_LOCKS=0
# Do not let rev-parse/merge-base hydrate promised objects outside the query timeout.
export GIT_NO_LAZY_FETCH=1
# Ignore repository-local graph rewrites when deciding real remote ancestry.
export GIT_NO_REPLACE_OBJECTS=1
export GIT_GRAFT_FILE=/dev/null/iwe-no-grafts

REPO="${1:?usage: iwe-safe-pull.sh <repo-path> [branch]}"
IWE="${IWE_ROOT:-$HOME/IWE}"
GUARD="${IWE_SAFE_PULL_GUARD:-$IWE/scripts/git-dirty-guard.sh}"
FETCH_TIMEOUT="${IWE_SAFE_PULL_FETCH_TIMEOUT:-20}"

cd "$REPO" 2>/dev/null || { echo "iwe-safe-pull: cannot cd to $REPO" >&2; exit 1; }
REPO="$(pwd)"

git_supports_no_lazy_fetch() {
  git --no-lazy-fetch --version >/dev/null 2>&1
}

if ! git_supports_no_lazy_fetch; then
  echo "iwe-safe-pull: Git 2.45+ is required to prevent implicit object downloads; refusing" >&2
  exit 1
fi

current_branch() {
  git symbolic-ref --quiet --short HEAD 2>/dev/null
}

repo_has_operation() {
  [ -d "$GIT_DIR/rebase-merge" ] || [ -d "$GIT_DIR/rebase-apply" ] \
    || [ -f "$GIT_DIR/MERGE_HEAD" ] || [ -f "$GIT_DIR/CHERRY_PICK_HEAD" ] \
    || [ -f "$GIT_DIR/REVERT_HEAD" ]
}

GIT_DIR=$(git rev-parse --absolute-git-dir 2>/dev/null) || {
  echo "iwe-safe-pull: cannot resolve git dir for $REPO" >&2
  exit 1
}
if repo_has_operation; then
  echo "iwe-safe-pull: repo is mid-operation -- refusing without cleanup" >&2
  exit 1
fi

BRANCH="${2:-}"
[ -n "$BRANCH" ] || BRANCH=$(current_branch)
if [ -z "$BRANCH" ] || ! git check-ref-format "refs/heads/$BRANCH" >/dev/null 2>&1; then
  echo "iwe-safe-pull: invalid or detached branch in $REPO, refusing" >&2
  exit 1
fi

INITIAL_BRANCH=$(current_branch) || {
  echo "iwe-safe-pull: detached HEAD in $REPO, refusing" >&2
  exit 1
}
if [ "$INITIAL_BRANCH" != "$BRANCH" ]; then
  echo "iwe-safe-pull: checked-out branch is $INITIAL_BRANCH (expected $BRANCH) -- refusing" >&2
  exit 1
fi

query_guard() {
  # This gate is read-only and its caller (pull-on-touch hook) already tells the
  # agent "potentially stale". A dirty shared checkout under parallel agent
  # sessions is normal work, not an incident for the pilot: 9 of 13 Telegram
  # alerts on 2026-09-02 were this path, one per dirty repo per new session
  # (WP-538 Ф4). Callers that do want the pilot told (e.g. a server-side git
  # sync job, day-open-pipeline) keep their own guard invocation and alert policy.
  GIT_DIRTY_GUARD_TG_ALERTS=false \
    GIT_DIRTY_GUARD_REQUIRE_FETCH=true \
    GIT_DIRTY_GUARD_FETCH_TIMEOUT="$FETCH_TIMEOUT" \
    GIT_DIRTY_GUARD_REMOTE_OID_OUTPUT=true \
    GIT_DIRTY_GUARD_FETCH_DEST_REF='' \
    GIT_DIRTY_GUARD_ALLOW_SELF_HEAL=false \
    bash "$GUARD" "$REPO" "$BRANCH"
}

is_valid_oid() {
  local oid="$1"
  case "$oid" in
    ''|*$'\n'*|*[!0-9a-fA-F]*) return 1 ;;
  esac
  case "${#oid}" in
    40|64) return 0 ;;
  esac
  return 1
}

REMOTE_HEAD=$(query_guard)
guard_status=$?
if [ "$guard_status" -ne 0 ]; then
  echo "iwe-safe-pull: remote query/guard refused -- checkout untouched, data potentially stale" >&2
  exit 1
fi
if repo_has_operation; then
  echo "iwe-safe-pull: repo entered a git operation during guard -- refusing without cleanup" >&2
  exit 1
fi
if [ "$(current_branch)" != "$BRANCH" ]; then
  echo "iwe-safe-pull: checked-out branch changed during guard -- refusing" >&2
  exit 1
fi
if ! is_valid_oid "$REMOTE_HEAD"; then
  echo "iwe-safe-pull: guard returned an invalid remote object id" >&2
  exit 1
fi

LOCAL_HEAD=$(git rev-parse HEAD 2>/dev/null) || {
  echo "iwe-safe-pull: cannot resolve local HEAD" >&2
  exit 1
}

clean_status_round() {
  local snapshot line snapshot_oid="" snapshot_branch=""
  local seen_oid=0 seen_branch=0
  ! repo_has_operation || return 1
  snapshot=$(git status --porcelain=v2 --branch --untracked-files=no) || return 1
  ! repo_has_operation || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "# branch.oid "*)
        [ "$seen_oid" -eq 0 ] || return 1
        snapshot_oid="${line#\# branch.oid }"
        seen_oid=1
        ;;
      "# branch.head "*)
        [ "$seen_branch" -eq 0 ] || return 1
        snapshot_branch="${line#\# branch.head }"
        seen_branch=1
        ;;
      "# "*) ;;
      '') ;;
      *) return 1 ;;
    esac
  done <<< "$snapshot"
  # Porcelain can resolve symbolic HEAD more than once while it builds one
  # report. Independently bind the observed index to the pinned commit; unlike
  # a worktree diff, this comparison neither refreshes nor rewrites the index.
  [ "$seen_oid" -eq 1 ] \
    && [ "$seen_branch" -eq 1 ] \
    && [ "$snapshot_oid" = "$LOCAL_HEAD" ] \
    && [ "$snapshot_branch" = "$BRANCH" ] \
    && git diff --cached --quiet "$LOCAL_HEAD" --
}

snapshot_is_stable() {
  # This is a repeated fail-closed observation, not a transaction. The second
  # complete status round detects a worktree change that lands after the first
  # status; the pinned index check rejects a clean report assembled across a
  # HEAD/index ABA transition.
  clean_status_round \
    && clean_status_round \
    && [ "$(current_branch)" = "$BRANCH" ] \
    && [ "$(git rev-parse HEAD 2>/dev/null)" = "$LOCAL_HEAD" ] \
    && ! repo_has_operation
}

confirm_remote_snapshot() {
  local confirmed_head confirm_status
  confirmed_head=$(query_guard)
  confirm_status=$?
  if [ "$confirm_status" -ne 0 ]; then
    echo "iwe-safe-pull: final remote query/guard refused -- data potentially stale" >&2
    return 1
  fi
  if ! is_valid_oid "$confirmed_head"; then
    echo "iwe-safe-pull: final guard returned an invalid remote object id" >&2
    return 1
  fi
  if [ "$confirmed_head" != "$REMOTE_HEAD" ]; then
    echo "iwe-safe-pull: origin/$BRANCH changed during inspection -- refusing, data potentially stale" >&2
    return 1
  fi
  if ! snapshot_is_stable; then
    echo "iwe-safe-pull: repo changed during final remote confirmation -- refusing" >&2
    return 1
  fi
  return 0
}

if ! snapshot_is_stable; then
  echo "iwe-safe-pull: repo changed during inspection -- refusing without cleanup" >&2
  exit 1
fi

if [ "$LOCAL_HEAD" = "$REMOTE_HEAD" ]; then
  if confirm_remote_snapshot; then
    printf 'iwe-safe-pull: stable checkout already matches queried origin/%s (%.10s)\n' "$BRANCH" "$LOCAL_HEAD"
    exit 0
  fi
  exit 1
fi

if ! git rev-parse --verify "$REMOTE_HEAD^{commit}" >/dev/null 2>&1; then
  echo "iwe-safe-pull: origin/$BRANCH points to an object absent locally -- shared checkout not auto-mutated, data potentially stale" >&2
  exit 1
fi

if git merge-base --is-ancestor "$REMOTE_HEAD" "$LOCAL_HEAD" 2>/dev/null; then
  if ! snapshot_is_stable; then
    echo "iwe-safe-pull: repo changed during ancestry check -- refusing" >&2
    exit 1
  fi
  if confirm_remote_snapshot; then
    printf 'iwe-safe-pull: stable local HEAD contains queried origin/%s (%.10s)\n' "$BRANCH" "$LOCAL_HEAD"
    exit 0
  fi
  exit 1
fi

if git merge-base --is-ancestor "$LOCAL_HEAD" "$REMOTE_HEAD" 2>/dev/null; then
  echo "iwe-safe-pull: origin/$BRANCH is ahead -- shared checkout not auto-mutated, data potentially stale" >&2
  echo "IWE_COMMITS_BEHIND: $(git rev-list --count "$LOCAL_HEAD..$REMOTE_HEAD" 2>/dev/null || echo unknown)" >&2
  exit 1
fi

echo "iwe-safe-pull: local and origin/$BRANCH histories diverged -- refusing without rebase" >&2
echo "IWE_COMMITS_BEHIND: $(git rev-list --count "$LOCAL_HEAD..$REMOTE_HEAD" 2>/dev/null || echo unknown)" >&2
exit 1
