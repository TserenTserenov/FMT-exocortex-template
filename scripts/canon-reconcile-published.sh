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
#              on the next publish; re-checked right before the swap) · branch
#              as expected · index clean · tracked-tree dirt only where the
#              on-disk entry already equals the target's (mode+blob) or the
#              path is deleted here and absent there (WP-561 Ф24: point-
#              installed published bytes must not freeze the canon forever) ·
#              every local-only commit patch-equivalent to the target (`git
#              cherry` has no `+`) OR content-superseded (every path it touched
#              has the same tree entry in HEAD and target; no local merge
#              commits either way) · every
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

# The delivery proof (git cherry) must not trust local replacement refs or legacy
# grafts: a forged object can make an undelivered commit look published (WP-7 Ф161).
export GIT_NO_REPLACE_OBJECTS=1
export GIT_GRAFT_FILE=/dev/null/iwe-no-grafts
# Every pathspec here is a literal path name, never a glob or ":(magic)" (WP-530 F72 review).
export GIT_LITERAL_PATHSPECS=1

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
live_canonical_writers() {  # prints " name name ..." or nothing
  local sem sem_pid out=""
  for sem in "$RUNTIME_DIR"/sessions/*.open; do
    [ -f "$sem" ] || continue
    grep -q '^isolated_worktree:' "$sem" && continue
    sem_pid=$(awk '$1=="pid:"{print $2; exit}' "$sem")
    # no pid (Kimi/Codex semaphores never carry one) = no proof of death -> treat as live, like session-guard's own sweep
    if [ -z "$sem_pid" ] || kill -0 "$sem_pid" 2>/dev/null; then out="$out $(basename "$sem" .open)"; fi
  done
  printf '%s' "$out"
}
LIVE_WRITERS=$(live_canonical_writers)
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

tracked_and_deleted_by_target() {  # <path> -- a blob in OLD_HEAD that the target removes (reset deletes it itself)
  [ -n "$(git ls-tree "$OLD_HEAD" -- "$1" | awk '$1!="040000"')" ] && [ -z "$(git ls-tree "$PINNED" -- "$1" | awk '$1!="040000"')" ]
}
ANCESTRAL_HISTORY_LIMIT=400
# ANCESTRAL_PATH criterion (WP-530 Ф72, next to "entry equals the target's"): the
# canon's version of <path> (`<mode> <oid>`) already occurred in the target's
# history of the SAME path, and the path is still alive on the target (a blob,
# not deleted, not renamed away, not a directory now). The canon then holds an
# older state of origin -- nothing of it is unique. A path missing on the target,
# a deletion on the canon side and any version origin never had all stay
# refusals. History-based evidence ("nothing is lost"), not a compatibility
# proof; no line-by-line subset mode (rejected in Ф71). Literal pathspecs: a
# name with glob characters must not match its neighbours.
ancestral_path() {  # <path> <"mode oid"> -- return 0 when the criterion holds
  local p="$1" want="$2" alive sha
  # Only regular files and symlinks count: a tree ("dir"), a gitlink (160000) or an
  # unknown mode is never accepted as an ancestral version.
  case "${want%% *}" in 100644|100755|120000) ;; *) return 1 ;; esac
  # Literal pathspecs on every ls-tree too: ":(top)x" or "a*" must name that path only.
  alive=$(GIT_LITERAL_PATHSPECS=1 git ls-tree "$PINNED" -- "$p" | awk 'NR==1 && $2=="blob" && $1!="160000"{print $1" "$3}')
  [ -n "$alive" ] || return 1
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    [ "$(GIT_LITERAL_PATHSPECS=1 git ls-tree "$sha" -- "$p" | awk 'NR==1 && $2=="blob"{print $1" "$3}')" = "$want" ] && return 0
  done < <(GIT_LITERAL_PATHSPECS=1 git log --full-history --max-count="$ANCESTRAL_HISTORY_LIMIT" --format=%H "$PINNED" -- "$p")
  return 1
}
disk_entry() {  # <path> -> "<mode> <hash>" of what is on disk, or "" if absent
  if [ -L "$1" ]; then printf '120000 %s' "$(printf '%s' "$(readlink "$1")" | git hash-object --stdin)"
  elif [ -d "$1" ]; then printf 'dir'
  elif [ -x "$1" ]; then printf '100755 %s' "$(git hash-object "$1")"
  elif [ -e "$1" ]; then printf '100644 %s' "$(git hash-object "$1")"
  fi
}

# 2. index must be clean. Tracked-tree dirt is tolerated ONLY when what is on
#    disk already equals the target's entry (mode + blob, or "deleted here and
#    absent on the target"): `git reset --hard` would write the very same bytes,
#    so nothing is lost. WP-561 Ф24 / WP-530 (peer-session 2026-09-27-09,
#    Claude+Kimi+Codex): published fixes were being point-installed into the
#    frozen canon, which then refused every reconcile as "tracked/staged changes
#    present" -- and stayed frozen precisely because it was dirty. Any other
#    dirt still refuses; staged changes always refuse (the index is intent, not
#    bytes on disk). Paths are NUL-delimited end to end (Codex: spaces, quotes,
#    newlines and rename records break line-based porcelain parsing).
STAGED=$(git diff --cached --name-only -z 2>/dev/null | tr '\0' ' ')
[ -z "$STAGED" ] || refuse "staged changes present in index:${STAGED:+ }$STAGED"
dirty_signature() {  # "<path>\t<disk entry>" per dirty tracked path, sorted -- compared again right before the swap
  git diff --name-only -z 2>/dev/null | while IFS= read -r -d '' p; do
    printf '%s\t%s\n' "$p" "$(disk_entry "$p")"
  done | LC_ALL=C sort
}
DIRTY_BLOCKING=""; DIRTY_TOLERATED=0; DIRTY_ANCESTRAL=0; COMMIT_ANCESTRAL=0
while IFS= read -r -d '' p; do
  [ -n "$p" ] || continue
  t_entry=$(git ls-tree "$PINNED" -- "$p" | awk 'NR==1{print $1" "$3}')
  on_disk=$(disk_entry "$p")
  if [ -z "$on_disk" ] && [ -z "$t_entry" ]; then DIRTY_TOLERATED=$((DIRTY_TOLERATED+1)); continue; fi   # deleted here, absent on target
  if [ -n "$on_disk" ] && [ "$on_disk" != "dir" ] && [ "$on_disk" = "$t_entry" ]; then DIRTY_TOLERATED=$((DIRTY_TOLERATED+1)); continue; fi
  if ancestral_path "$p" "$on_disk"; then DIRTY_ANCESTRAL=$((DIRTY_ANCESTRAL+1)); continue; fi
  DIRTY_BLOCKING="$DIRTY_BLOCKING $p"
done < <(git diff --name-only -z 2>/dev/null)
[ -z "$DIRTY_BLOCKING" ] || refuse "tracked changes differ from target:$DIRTY_BLOCKING"
DIRTY_SIG_BEFORE=$(dirty_signature)

# 3. every local-only commit must already be on the target as an equivalent patch.
UNIQUE=$(git cherry "$PINNED" "$OLD_HEAD" 2>/dev/null | awk '$1=="+"{print $2}')
CONTENT_SUPERSEDED=0
if [ -n "$UNIQUE" ]; then
  # Content-superseded proof (Codex, peer-session 2026-09-27-09): a local-only
  # commit whose EVERY touched path has the same full tree entry (mode type oid,
  # or absent on both sides) in OLD_HEAD and in the target changes nothing at
  # those paths when OLD_HEAD is replaced -- its end state is already on the
  # target under some other history (a later fix that landed with a different
  # diff, so patch-id cannot see it). Proves safety of the END STATE, not
  # preservation of the commit; the log line says which. Renames are seen as
  # delete+add (--no-renames), a root commit needs --root, paths are NUL-safe.
  DIFFERING=""
  for c in $UNIQUE; do
    while IFS= read -r -d '' p; do
      [ -n "$p" ] || continue
      old_e=$(git ls-tree "$OLD_HEAD" -- "$p" | awk 'NR==1{print $1" "$2" "$3}')
      new_e=$(git ls-tree "$PINNED" -- "$p" | awk 'NR==1{print $1" "$2" "$3}')
      if [ "$old_e" != "$new_e" ]; then
        # ANCESTRAL_PATH: the version this commit left at <p> occurred earlier on origin's <p>, and <p> is alive there
        if ancestral_path "$p" "$(printf '%s' "$old_e" | awk '{print $1" "$3}')"; then COMMIT_ANCESTRAL=$((COMMIT_ANCESTRAL+1)); continue; fi
        DIFFERING="$p (commit ${c:0:12})"; break 2
      fi
    done < <(git diff-tree -r -z --root --no-renames --no-commit-id --name-only "$c" 2>/dev/null)
  done
  [ -z "$DIFFERING" ] || refuse "local-only commits not on target: $(printf '%s ' $UNIQUE)-- first path whose end state differs from the target: $DIFFERING"
  CONTENT_SUPERSEDED=$(printf '%s\n' $UNIQUE | wc -l | tr -d ' ')
fi
# `git cherry` skips merge commits entirely -- an unexpected local merge is not proven delivered.
LOCAL_MERGES=$(git rev-list --merges "$PINNED..$OLD_HEAD")
[ -z "$LOCAL_MERGES" ] || refuse "local merge commit(s) not provable by patch-id: $(printf '%s ' $LOCAL_MERGES)"

# 4. everything `git reset --hard` would CREATE on disk must be absent or identical.
#    Checked on disk (not via git's untracked listing), so ignored files, names
#    that differ only by case on APFS, and file-vs-directory clashes are covered.
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
  # shellcheck disable=SC2010  # literal, exact-case name match by design (APFS case folding)
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

# Re-check right before the irreversible step (still under lock): index still
# clean, the tolerated dirt is byte-for-byte what it was, and no canonical
# writer opened meanwhile (Codex, 2026-09-27-09: the semaphore scan in step 1
# is TOCTOU; this re-check narrows the window, a shared open/reconcile lock
# in session-guard.sh is the follow-up that closes it -- WP-530).
[ -z "$(git diff --cached --name-only -z 2>/dev/null)" ] || refuse "index changed during preflight"
[ "$(dirty_signature)" = "$DIRTY_SIG_BEFORE" ] || refuse "tracked tree changed during preflight"
LIVE_WRITERS=$(live_canonical_writers)
[ -z "$LIVE_WRITERS" ] || refuse "live canonical writer(s) appeared during preflight:$LIVE_WRITERS"

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

echo "canon-reconcile-published: $REPO refs/heads/$BRANCH ${OLD_HEAD:0:12} -> ${PINNED:0:12} (dropped commits: patch-equivalent or content-superseded=$CONTENT_SUPERSEDED; tolerated identical dirty paths=$DIRTY_TOLERATED; ancestral-path dirty=$DIRTY_ANCESTRAL commit-paths=$COMMIT_ANCESTRAL; untracked intact)"
log_line replaced "$OLD_HEAD -> $PINNED content_superseded=$CONTENT_SUPERSEDED dirty_tolerated=$DIRTY_TOLERATED ancestral_dirty=$DIRTY_ANCESTRAL ancestral_commit_paths=$COMMIT_ANCESTRAL"
exit 0
