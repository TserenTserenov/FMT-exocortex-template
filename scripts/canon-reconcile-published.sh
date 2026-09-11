#!/usr/bin/env bash
# canon-reconcile-published.sh <repo-path> <branch> [<pinned-oid>] -- replace a
# canonical checkout's branch ref with the just-published origin tip when, and
# only when, the local history it would drop is provably already on origin.
#
# The gap this closes (WP-530 Ф38, peer-session 2026-09-11-07, Claude+Kimi+Codex):
# sessions commit straight into the canonical checkout, isolate-push.sh carries
# those commits to origin as cherry-picks (new SHAs), and nothing afterwards
# moves the canonical ref -- so the canon is never an ancestor of origin again.
# canon-refresh.sh (clean + purely behind) and canon-reconcile.sh (dirty +
# purely behind) both refuse a diverged history by design; without this step the
# divergence grows until a human merges by hand (74/230 on 11.09).
#
# Contract (fail closed -- any doubt means "touch nothing, say why"):
#   preflight  no live session is writing into this host's checkouts (semaphores
#              under $IWE_RUNTIME/sessions without isolated_worktree and with a
#              live pid -- Codex, round 3: a re-check right before reset shrinks
#              the race with a concurrent writer but cannot close it, and this
#              script takes no snapshot of tracked dirt; until a barrier every
#              writer honours exists (Ф5.1) the only safe answer is skip + retry
#              on the next publish) · branch as expected · index and tracked
#              tree clean · every local-only commit patch-equivalent to the
#              target (`git cherry` has no `+`, no local merge commits) · every
#              path `git reset --hard` would CREATE (added in target vs current
#              HEAD) is either absent on disk or identical in type, mode and
#              content -- checked on disk, so ignored files, case-folded names
#              and file-vs-directory clashes count too (cold review 11.09).
#   action     `git update-ref` with compare-and-swap on the old head, then
#              `git reset --hard` so index and tracked tree follow the ref.
#   postcheck  HEAD == pinned · tracked tree clean · the set of untracked paths
#              (mode, hash, path) is unchanged apart from paths the target now
#              tracks -- a changed hash, a missing path or a NEW path means
#              someone wrote during the window: reported, never called success.
# This script never writes inside the repository except through git itself:
# its own log goes to $IWE_RUNTIME/canon-reconcile-published.log (a ledger
# event inside the canon would dirty the very tree it is reconciling -- cold
# review 11.09 found the resulting 15-minute publish loop).
#
# Exit: 0 = replaced, or nothing to do (already ancestor -> canon-refresh's job)
#       1 = refused (canon untouched) or post-check failed (ref already replaced
#           -- the message says which; both are logged)
#       2 = usage / repo error
set -uo pipefail

usage() { echo "usage: canon-reconcile-published.sh <repo-path> <branch> [<pinned-oid>]" >&2; exit 2; }
[ $# -ge 2 ] || usage
REPO="$1"; BRANCH="$2"; PINNED_ARG="${3:-}"
cd "$REPO" 2>/dev/null || { echo "canon-reconcile-published: cannot cd to $REPO" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "canon-reconcile-published: $REPO is not a git repo" >&2; exit 2; }
GIT_DIR=$(git rev-parse --git-dir)
RUNTIME_DIR="${IWE_RUNTIME:-${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime}"
LOG_FILE="$RUNTIME_DIR/canon-reconcile-published.log"
TMP_FILES=()
cleanup() { rm -f "${TMP_FILES[@]+"${TMP_FILES[@]}"}"; }
trap cleanup EXIT

log_line() {  # <status> <text> -- append-only log outside the repository
  mkdir -p "$RUNTIME_DIR" 2>/dev/null || return 0
  printf '%s %s repo=%s branch=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$REPO" "$BRANCH" "$2" >> "$LOG_FILE" 2>/dev/null || true
}

refuse() {  # <reason> -- nothing was changed
  echo "canon-reconcile-published: refused -- $1 (canon untouched, publish not rolled back)" >&2
  log_line refused "$1"
  exit 1
}

fail_after_swap() {  # <reason> -- the ref is already replaced; say so honestly
  echo "canon-reconcile-published: post-check FAILED after the ref was replaced -- $1. HEAD=$(git rev-parse HEAD); inspect the tree before trusting it" >&2
  log_line post-check-failed "$1"
  exit 1
}

if [ -d "$GIT_DIR/rebase-merge" ] || [ -d "$GIT_DIR/rebase-apply" ] || [ -f "$GIT_DIR/MERGE_HEAD" ] || [ -f "$GIT_DIR/CHERRY_PICK_HEAD" ]; then
  refuse "repo is mid-rebase/merge/cherry-pick"
fi
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
[ "$CURRENT_BRANCH" = "$BRANCH" ] || refuse "checked-out branch is '$CURRENT_BRANCH', expected '$BRANCH'"

# Same lock as git-dirty-guard.sh / canon-refresh.sh / canon-reconcile.sh /
# sync-strategy-files.sh: whoever holds it runs to completion first.
LOCK_DIR="$GIT_DIR/dirty-guard.lock"
LOCK_META="$LOCK_DIR/owner"
HOST_NOW="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [ -f "$LOCK_META" ]; then
    OTHER_HOST=$(awk -F= '$1=="host"{print $2}' "$LOCK_META" 2>/dev/null)
    OTHER_PID=$(awk -F= '$1=="pid"{print $2}' "$LOCK_META" 2>/dev/null)
    if [ "$OTHER_HOST" = "$HOST_NOW" ] && [ -n "$OTHER_PID" ] && ! kill -0 "$OTHER_PID" 2>/dev/null; then
      echo "canon-reconcile-published: reclaiming stale lock (pid=$OTHER_PID gone)" >&2
      rm -rf "$LOCK_DIR" 2>/dev/null
    fi
  fi
  mkdir "$LOCK_DIR" 2>/dev/null || { echo "canon-reconcile-published: lock busy, skipping this cycle"; exit 0; }
fi
trap 'cleanup; rm -rf "$LOCK_DIR" 2>/dev/null' EXIT
printf 'host=%s\npid=%s\n' "$HOST_NOW" "$$" > "$LOCK_META"

# 1. no live canonical writer (strict, Codex round 3). Isolated sessions never
#    touch this tree; only semaphores without isolated_worktree count.
LIVE_WRITERS=""
for sem in "$RUNTIME_DIR"/sessions/*.open; do
  [ -f "$sem" ] || continue
  grep -q '^isolated_worktree:' "$sem" && continue
  sem_pid=$(awk '$1=="pid:"{print $2; exit}' "$sem")
  # no pid (Kimi/Codex semaphores never carry one) = no proof of death -> treat as live, like session-guard's own sweep
  if [ -z "$sem_pid" ] || kill -0 "$sem_pid" 2>/dev/null; then LIVE_WRITERS="$LIVE_WRITERS $(basename "$sem" .open)"; fi
done
[ -z "$LIVE_WRITERS" ] || refuse "live canonical writer(s):$LIVE_WRITERS -- skipped, will retry on the next publish"

# explicit refspec: `git fetch origin <branch>` alone is not guaranteed to move origin/<branch>
git fetch origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" --quiet 2>/dev/null || refuse "git fetch origin $BRANCH failed"
OLD_HEAD=$(git rev-parse HEAD)
REMOTE_TIP=$(git rev-parse "origin/$BRANCH")
if [ -n "$PINNED_ARG" ]; then
  PINNED=$(git rev-parse --verify "${PINNED_ARG}^{commit}" 2>/dev/null) || refuse "pinned oid $PINNED_ARG is not a commit here"
  git merge-base --is-ancestor "$PINNED" "$REMOTE_TIP" || refuse "pinned oid is not on origin/$BRANCH"
  # origin moved past the caller's pin: re-evaluate against the live tip, never replace with a stale one
  [ "$PINNED" = "$REMOTE_TIP" ] || echo "canon-reconcile-published: origin/$BRANCH advanced past pinned ${PINNED:0:12}, targeting live tip ${REMOTE_TIP:0:12}"
fi
PINNED="$REMOTE_TIP"

if [ "$OLD_HEAD" = "$PINNED" ]; then echo "canon-reconcile-published: already at $PINNED"; exit 0; fi
if git merge-base --is-ancestor "$OLD_HEAD" "$PINNED"; then
  echo "canon-reconcile-published: HEAD is a plain ancestor of the target -- canon-refresh.sh owns that shape, nothing to do"
  exit 0
fi

# 2. index + tracked tree must be clean (untracked/ignored files are allowed, see 4).
TRACKED_DIRTY=$(git status --porcelain --untracked-files=no 2>/dev/null)
[ -z "$TRACKED_DIRTY" ] || refuse "tracked/staged changes present ($(printf '%s\n' "$TRACKED_DIRTY" | wc -l | tr -d ' ') paths)"

# 3. every local-only commit must already be on the target as an equivalent patch.
UNIQUE=$(git cherry "$PINNED" "$OLD_HEAD" 2>/dev/null | awk '$1=="+"{print $2}')
[ -z "$UNIQUE" ] || refuse "local-only commits not on target: $(printf '%s ' $UNIQUE)"
# `git cherry` skips merge commits entirely -- an unexpected local merge is not proven delivered.
LOCAL_MERGES=$(git rev-list --merges "$PINNED..$OLD_HEAD")
[ -z "$LOCAL_MERGES" ] || refuse "local merge commit(s) not provable by patch-id: $(printf '%s ' $LOCAL_MERGES)"

# 4. everything `git reset --hard` would CREATE on disk must be absent or identical.
#    Checked on disk (not via git's untracked listing), so ignored files, names
#    that differ only by case on APFS, and file-vs-directory clashes are covered.
tracked_and_deleted_by_target() {  # <path> -- a blob in OLD_HEAD that the target removes (reset deletes it itself)
  [ -n "$(git ls-tree "$OLD_HEAD" -- "$1" | awk '$1!="040000"')" ] && [ -z "$(git ls-tree "$PINNED" -- "$1" | awk '$1!="040000"')" ]
}
disk_entry() {  # <path> -> "<mode> <hash>" of what is on disk, or "" if absent
  if [ -L "$1" ]; then printf '120000 %s' "$(printf '%s' "$(readlink "$1")" | git hash-object --stdin)"
  elif [ -d "$1" ]; then printf 'dir'
  elif [ -x "$1" ]; then printf '100755 %s' "$(git hash-object "$1")"
  elif [ -e "$1" ]; then printf '100644 %s' "$(git hash-object "$1")"
  fi
}
COLLISION=""
while IFS= read -r -d '' status && IFS= read -r -d '' p; do
  [ "$status" = "A" ] || continue
  entry=$(git ls-tree "$PINNED" -- "$p" | head -1)
  t_mode=$(printf '%s' "$entry" | awk '{print $1}'); t_hash=$(printf '%s' "$entry" | awk '{print $3}')
  on_disk=$(disk_entry "$p")
  if [ "$on_disk" = "dir" ] && [ -n "$(git ls-tree "$OLD_HEAD" -- "$p/")" ] && [ -z "$(git ls-files --others -- "$p/")" ]; then
    on_disk=""   # tracked directory with nothing untracked inside: dir->file conversion, reset handles it
  fi
  if [ -n "$on_disk" ] && [ "$on_disk" != "$t_mode $t_hash" ]; then COLLISION="$p (on disk: ${on_disk%% *}, target wants $t_mode $t_hash)"; break; fi
  # case-insensitive filesystem: `-e` matched a differently-cased name; git would write into that inode
  # under the target's spelling and the post-check could only report it afterwards -- refuse up front
  if [ -n "$on_disk" ] && ! ls -a "$(dirname "$p")" 2>/dev/null | grep -qFx "$(basename "$p")"; then COLLISION="$p (a differently-cased name occupies this path on disk)"; break; fi
  # an ancestor of the new path exists on disk as a symlink (reset would destroy it and create a real
  # directory) or as a plain file that the target does not itself delete (file->dir conversion of a
  # tracked file is reset's normal job; an untracked/ignored file in the way is a collision)
  d=$(dirname "$p")
  while [ "$d" != "." ]; do
    if [ -L "$d" ]; then COLLISION="$d (on disk a symlink, target needs a directory for $p)"; break 2; fi
    if [ -e "$d" ] && [ ! -d "$d" ] && ! tracked_and_deleted_by_target "$d"; then COLLISION="$d (on disk a file, target needs a directory for $p)"; break 2; fi
    d=$(dirname "$d")
  done
done < <(git diff-tree -r -z --name-status --no-renames "$OLD_HEAD" "$PINNED")
[ -z "$COLLISION" ] || refuse "collision with what reset would write: $COLLISION"

untracked_inventory() {  # "<mode> <hash> <path>" per untracked (non-ignored) file, sorted
  git ls-files --others --exclude-standard -z | while IFS= read -r -d '' p; do
    printf '%s %s\n' "$(disk_entry "$p")" "$p"
  done | LC_ALL=C sort -k3
}
UNTRACKED_BEFORE=$(mktemp); TMP_FILES+=("$UNTRACKED_BEFORE")
untracked_inventory > "$UNTRACKED_BEFORE"

# Re-check the tracked tree right before the irreversible step (still under lock).
[ -z "$(git status --porcelain --untracked-files=no)" ] || refuse "tracked tree changed during preflight"

# 5. compare-and-swap on the ref, then bring index + tracked tree along.
git update-ref -m "canon-reconcile-published: $OLD_HEAD -> $PINNED" "refs/heads/$BRANCH" "$PINNED" "$OLD_HEAD" \
  || refuse "compare-and-swap on refs/heads/$BRANCH lost (HEAD moved)"
git reset --hard --quiet || fail_after_swap "git reset --hard failed -- index/tree need manual sync to $PINNED"

# 6. post-check.
[ "$(git rev-parse HEAD)" = "$PINNED" ] || fail_after_swap "HEAD is not the pinned oid"
[ -z "$(git status --porcelain --untracked-files=no)" ] || fail_after_swap "tracked tree not clean"
UNTRACKED_AFTER=$(mktemp); TMP_FILES+=("$UNTRACKED_AFTER"); untracked_inventory > "$UNTRACKED_AFTER"
# expected after-set = before-set minus paths the target now tracks (proven identical in 4)
EXPECTED=$(mktemp); TMP_FILES+=("$EXPECTED")
while IFS= read -r line; do
  p="${line#* * }"
  t=$(git ls-tree "$PINNED" -- "$p" 2>/dev/null | awk 'NR==1{print $1" "$3}')
  [ "$t" = "${line% "$p"}" ] || printf '%s\n' "$line"
done < "$UNTRACKED_BEFORE" > "$EXPECTED"
DIFF=$(diff "$EXPECTED" "$UNTRACKED_AFTER" | grep '^[<>]' | head -3)
[ -z "$DIFF" ] || fail_after_swap "untracked set changed during the operation (< expected / > actual): $(printf '%s' "$DIFF" | tr '\n' ';')"

echo "canon-reconcile-published: $REPO refs/heads/$BRANCH ${OLD_HEAD:0:12} -> ${PINNED:0:12} (all dropped commits were patch-equivalent on target; untracked intact)"
log_line replaced "$OLD_HEAD -> $PINNED"
exit 0
