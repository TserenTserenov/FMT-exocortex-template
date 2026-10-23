#!/usr/bin/env bash
# pull-on-touch-ff-only-smoke.sh — regression coverage for .claude/hooks/pull-on-touch.sh
# (issue #1245, recurrence of bug-2026-07-17-kimi-queue-autostash-conflict-and-orphaned-semaphores.md).
# Real bare-origin sandboxes, real hook invocation via stdin JSON — no mocking of
# git-sync-status.sh or the hook itself.
set -uo pipefail

HOOK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$HOOK_ROOT/.claude/hooks/pull-on-touch.sh"
[ -f "$HOOK" ] || { echo "FAIL: $HOOK not found"; exit 1; }

TMP=$(mktemp -d)
SESSION_PREFIX="pull-ff-only-smoke-${TMP##*/}-$$"
STATE_FILES="$TMP/state-files"
: > "$STATE_FILES"
# shellcheck disable=SC2329  # Invoked through the EXIT trap.
cleanup() {
  local state_file
  while IFS= read -r state_file; do
    rm -f "$state_file"
  done < "$STATE_FILES"
  rm -rf "$TMP"
}
trap cleanup EXIT
REAL_GIT=$(command -v git)

FAILURES=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 -- ожидалось '$2', получено '$3'"
    FAILURES=$((FAILURES + 1))
  fi
}

setup_sandbox() {  # setup_sandbox <workspace-dir> <repo-name> -- real bare "origin" под IWE/<repo-name>
  local ws="$1" name="$2"
  local bare="$ws/${name}.origin.git"
  mkdir -p "$ws"
  git init -q --bare "$bare"
  git clone -q "$bare" "$ws/$name"
  git -C "$ws/$name" checkout -q -b main
  git -C "$ws/$name" config user.email test@test.local
  git -C "$ws/$name" config user.name test
  echo init > "$ws/$name/seed.md"
  git -C "$ws/$name" add seed.md
  git -C "$ws/$name" commit -q -m init
  git -C "$ws/$name" push -q origin main
  git -C "$bare" symbolic-ref HEAD refs/heads/main
}

advance_remote() {  # advance_remote <workspace-dir> <repo-name> -- push one commit from a second clone
  local ws="$1" name="$2"
  local pusher="$ws/${name}-pusher"
  git clone -q "$ws/${name}.origin.git" "$pusher" 2>/dev/null
  git -C "$pusher" checkout -q main
  git -C "$pusher" config user.email test@test.local
  git -C "$pusher" config user.name test
  echo remote-change >> "$pusher/seed.md"
  git -C "$pusher" add seed.md
  git -C "$pusher" commit -q -m remote-change
  git -C "$pusher" push -q origin main
}

run_hook() {  # run_hook <workspace-dir> <repo-name> <session-id> -- real stdin JSON, real env.
  # Decodes the hook's JSON reply to its plain-text additionalContext: the hook
  # emits Cyrillic through `json.dumps` (ensure_ascii, \uXXXX escapes), so a
  # literal grep for Cyrillic text on the raw reply would never match.
  local ws="$1" name="$2" session="$SESSION_PREFIX-$3"
  printf '%s\n' "$HOME/.claude/state/repo-pulled-$session.txt" >> "$STATE_FILES"
  IWE_WORKSPACE="$ws" python3 -c '
import json, sys
print(json.dumps({
    "tool_name": "Read",
    "tool_input": {"file_path": sys.argv[1] + "/" + sys.argv[2] + "/seed.md"},
    "session_id": sys.argv[3],
}))
' "$ws" "$name" "$session" | IWE_WORKSPACE="$ws" bash "$HOOK" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)
# A broken autostash path may prepend Git notices to the hooks final JSON.
# Preserve those notices while still checking its reported success/warning.
prefix, _, reply = raw.rpartition("\n")
if prefix:
    print(prefix)
print(json.loads(reply).get("hookSpecificOutput", {}).get("additionalContext", ""))
'
}

snapshot_protected_state() {  # snapshot_protected_state <repo> <snapshot-dir>
  local repo="$1" snapshot="$2" file
  mkdir -p "$snapshot"
  for file in seed.md new-wp-draft.md; do
    if [ -f "$repo/$file" ]; then
      cp "$repo/$file" "$snapshot/$file"
    fi
  done
  cp "$repo/.git/index" "$snapshot/index"
  "$REAL_GIT" -C "$repo" ls-files --stage -z > "$snapshot/index-entries"
  "$REAL_GIT" -C "$repo" rev-parse HEAD > "$snapshot/head"
  "$REAL_GIT" -C "$repo" rev-parse --verify refs/stash > "$snapshot/stash" 2>/dev/null || :
}

check_protected_state() {  # check_protected_state <repo> <snapshot-dir>
  local repo="$1" snapshot="$2" file actual="$2/actual"
  snapshot_protected_state "$repo" "$actual"
  for file in seed.md new-wp-draft.md index index-entries head stash; do
    if [ -f "$snapshot/$file" ]; then
      check "$file preserved byte-for-byte" "1" \
        "$(cmp -s "$snapshot/$file" "$actual/$file" && echo 1 || echo 0)"
    fi
  done
}

check_stale_warning() {
  check "hook emits a stale warning" "1" "$(printf '%s' "$1" | grep -qF 'potentially stale' && echo 1 || echo 0)"
  check "hook does not claim an update succeeded" "0" "$(printf '%s' "$1" | grep -qF 'Подтянул свежее' && echo 1 || echo 0)"
}

# Only the race/failure is injected. All git operations, including the merge,
# still execute against real local repositories. No network services are used.
WRAPPER_BIN="$TMP/git-wrapper"
mkdir -p "$WRAPPER_BIN"
{
  printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  declare -f snapshot_protected_state
  cat <<'WRAPPER'
REAL_GIT="$IWE_TEST_REAL_GIT"
command_name=""
for arg in "$@"; do
  case "$arg" in
    fetch|merge|status) command_name="$arg"; break ;;
  esac
done

inject_local_work() {
  printf 'local staged change\n' > "$IWE_TEST_REPO/seed.md"
  "$REAL_GIT" -C "$IWE_TEST_REPO" add seed.md || exit 1
  printf 'local unstaged change\n' >> "$IWE_TEST_REPO/seed.md"
  printf 'untracked draft\000preserve trailing newlines\n\n' > "$IWE_TEST_REPO/new-wp-draft.md"
  snapshot_protected_state "$IWE_TEST_REPO" "$IWE_TEST_STATE/before"
  touch "$IWE_TEST_STATE/injected"
}

case "$command_name" in
  status)
    if [ "$IWE_TEST_MODE" = status-first ] \
      || { [ "$IWE_TEST_MODE" = status-after-fetch ] && [ -f "$IWE_TEST_STATE/fetched" ]; }; then
      touch "$IWE_TEST_STATE/status-failed"
      exit 70  # deliberately no stdout: failure must never mean "clean"
    fi
    ;;
  fetch)
    "$REAL_GIT" "$@"
    fetch_status=$?
    [ "$fetch_status" -eq 0 ] || exit "$fetch_status"
    touch "$IWE_TEST_STATE/fetched"
    [ "$IWE_TEST_MODE" != during-fetch ] || inject_local_work
    exit 0
    ;;
  merge)
    touch "$IWE_TEST_STATE/merge-called"
    [ "$IWE_TEST_MODE" != before-merge ] || inject_local_work
    ;;
esac
exec "$REAL_GIT" "$@"
WRAPPER
} > "$WRAPPER_BIN/git"
chmod +x "$WRAPPER_BIN/git"

run_injected_hook() {  # run_injected_hook <workspace> <repo-name> <mode> <state-dir>
  PATH="$WRAPPER_BIN:$PATH" IWE_TEST_REAL_GIT="$REAL_GIT" \
    IWE_TEST_REPO="$1/$2" IWE_TEST_MODE="$3" IWE_TEST_STATE="$4" \
    run_hook "$1" "$2" "$3"
}

echo "=== FF: clean tree, remote ahead -> fast-forwards, no stash ==="
WS="$TMP/ok-ff/IWE"; setup_sandbox "$WS" repo-ff
advance_remote "$WS" repo-ff
before_head=$(git -C "$WS/repo-ff" rev-parse HEAD)
out=$(run_hook "$WS" repo-ff pull-ff-only-smoke-ff)
after_head=$(git -C "$WS/repo-ff" rev-parse HEAD)
remote_head=$(git -C "$WS/repo-ff.origin.git" rev-parse main)
check "HEAD advanced to match origin" "$remote_head" "$after_head"
check "HEAD actually moved" "1" "$([ "$before_head" != "$after_head" ] && echo 1 || echo 0)"
check "no stash left behind" "" "$(git -C "$WS/repo-ff" stash list)"
check "hook reports a pull, not a stale warning" "1" "$(printf '%s' "$out" | grep -qF 'Подтянул свежее' && echo 1 || echo 0)"

echo "=== STALE-SAFE: dirty tracked tree, remote ahead -> no merge, no stash, no data loss ==="
WS="$TMP/dirty-tracked/IWE"; setup_sandbox "$WS" repo-dirty
advance_remote "$WS" repo-dirty
echo "uncommitted local work" >> "$WS/repo-dirty/seed.md"
before_head=$(git -C "$WS/repo-dirty" rev-parse HEAD)
out=$(run_hook "$WS" repo-dirty pull-ff-only-smoke-dirty)
after_head=$(git -C "$WS/repo-dirty" rev-parse HEAD)
check "HEAD did not move (merge was skipped)" "$before_head" "$after_head"
check "no autostash was created" "" "$(git -C "$WS/repo-dirty" stash list)"
check "local edit survived on disk" "1" "$(grep -qF 'uncommitted local work' "$WS/repo-dirty/seed.md" && echo 1 || echo 0)"
check "hook names it a stale-not-fetched case" "1" "$(printf '%s' "$out" | grep -qF 'не подтягиваю' && echo 1 || echo 0)"

echo "=== STALE-SAFE: untracked file present, remote ahead -> no merge, no stash (the exact #1245 class) ==="
WS="$TMP/dirty-untracked/IWE"; setup_sandbox "$WS" repo-untracked
advance_remote "$WS" repo-untracked
echo "new work product draft" > "$WS/repo-untracked/new-wp-draft.md"
before_head=$(git -C "$WS/repo-untracked" rev-parse HEAD)
run_hook "$WS" repo-untracked pull-ff-only-smoke-untracked >/dev/null
after_head=$(git -C "$WS/repo-untracked" rev-parse HEAD)
check "HEAD did not move with an untracked file present" "$before_head" "$after_head"
check "no autostash was created" "" "$(git -C "$WS/repo-untracked" stash list)"
check "untracked file survived on disk" "1" "$([ -f "$WS/repo-untracked/new-wp-draft.md" ] && echo 1 || echo 0)"

echo "=== DIVERGED: both sides advanced -> no merge attempted, no stash ==="
WS="$TMP/diverged/IWE"; setup_sandbox "$WS" repo-diverged
advance_remote "$WS" repo-diverged
echo local-side-commit >> "$WS/repo-diverged/seed.md"
git -C "$WS/repo-diverged" add seed.md
git -C "$WS/repo-diverged" commit -q -m local-side-commit
before_head=$(git -C "$WS/repo-diverged" rev-parse HEAD)
run_hook "$WS" repo-diverged pull-ff-only-smoke-diverged >/dev/null
after_head=$(git -C "$WS/repo-diverged" rev-parse HEAD)
check "HEAD did not move on diverged history" "$before_head" "$after_head"
check "no autostash was created" "" "$(git -C "$WS/repo-diverged" stash list)"

echo "=== OK: already up to date -> no pull message ==="
WS="$TMP/already-ok/IWE"; setup_sandbox "$WS" repo-ok
out=$(run_hook "$WS" repo-ok pull-ff-only-smoke-ok)
check "no stash" "" "$(git -C "$WS/repo-ok" stash list)"
check "hook stays silent when already fresh" "" "$out"

echo "=== PRE-EXISTING STASH: unrelated stash from before this hook ran is left untouched ==="
# `stash push` itself cleans the working tree, so the hook sees a clean tree
# and (remote being ahead) does fast-forward -- the point of this case is that
# an unrelated, already-stashed entry must survive that untouched, not that
# the hook should skip the repo.
WS="$TMP/pre-existing-stash/IWE"; setup_sandbox "$WS" repo-prestash
advance_remote "$WS" repo-prestash
# A different file than seed.md (which advance_remote also changes) -- the
# point is an unrelated stash, not a stash that would collide on pop with
# the file the fast-forward itself touches.
echo "unrelated earlier work" > "$WS/repo-prestash/unrelated.md"
git -C "$WS/repo-prestash" stash push -q --include-untracked -m pre-existing
before_stash=$(git -C "$WS/repo-prestash" stash list)
run_hook "$WS" repo-prestash pull-ff-only-smoke-prestash >/dev/null
after_head=$(git -C "$WS/repo-prestash" rev-parse HEAD)
remote_head=$(git -C "$WS/repo-prestash.origin.git" rev-parse main)
check "HEAD still fast-forwards normally despite the unrelated stash" "$remote_head" "$after_head"
check "pre-existing stash entry is untouched (same ref, not popped/dropped/added to)" "$before_stash" "$(git -C "$WS/repo-prestash" stash list)"
check "pre-existing stash content still pops cleanly afterwards" "1" "$(git -C "$WS/repo-prestash" stash pop -q >/dev/null 2>&1 && grep -qF 'unrelated earlier work' "$WS/repo-prestash/unrelated.md" && echo 1 || echo 0)"

echo "=== DETACHED HEAD: no upstream branch to compare against -> no merge, no stash ==="
WS="$TMP/detached/IWE"; setup_sandbox "$WS" repo-detached
advance_remote "$WS" repo-detached
git -C "$WS/repo-detached" checkout -q --detach HEAD
before_head=$(git -C "$WS/repo-detached" rev-parse HEAD)
run_hook "$WS" repo-detached pull-ff-only-smoke-detached >/dev/null
after_head=$(git -C "$WS/repo-detached" rev-parse HEAD)
check "HEAD did not move on detached HEAD" "$before_head" "$after_head"
check "no autostash was created" "" "$(git -C "$WS/repo-detached" stash list)"

for race in during-fetch before-merge; do
  echo "=== RACE: $race, merge.autoStash=true -> local work and stash stay untouched ==="
  WS="$TMP/$race/IWE"; setup_sandbox "$WS" repo-race
  advance_remote "$WS" repo-race
  git -C "$WS/repo-race" config merge.autoStash true
  echo "unrelated earlier work" > "$WS/repo-race/unrelated.md"
  git -C "$WS/repo-race" stash push -q --include-untracked -m pre-existing
  race_state="$TMP/$race/injection"
  mkdir -p "$race_state"
  out=$(run_injected_hook "$WS" repo-race "$race" "$race_state")
  check "race injection actually ran" "1" "$([ -f "$race_state/injected" ] && echo 1 || echo 0)"
  if [ -f "$race_state/injected" ]; then
    check_protected_state "$WS/repo-race" "$race_state/before"
  fi
  if [ "$race" = during-fetch ]; then
    check "fetch-time edits prevent invoking merge" "0" "$([ -f "$race_state/merge-called" ] && echo 1 || echo 0)"
  else
    check "race occurs at the real merge boundary" "1" "$([ -f "$race_state/merge-called" ] && echo 1 || echo 0)"
  fi
  check_stale_warning "$out"
done

for failure in status-first status-after-fetch; do
  echo "=== STATUS FAILURE: $failure, empty stdout -> fail closed ==="
  WS="$TMP/$failure/IWE"; setup_sandbox "$WS" repo-status
  advance_remote "$WS" repo-status
  git -C "$WS/repo-status" config merge.autoStash true
  failure_state="$TMP/$failure/injection"
  mkdir -p "$failure_state"
  snapshot_protected_state "$WS/repo-status" "$failure_state/before"
  out=$(run_injected_hook "$WS" repo-status "$failure" "$failure_state")
  check "failing status was reached" "1" "$([ -f "$failure_state/status-failed" ] && echo 1 || echo 0)"
  check_protected_state "$WS/repo-status" "$failure_state/before"
  check "merge was never invoked after a status failure" "0" "$([ -f "$failure_state/merge-called" ] && echo 1 || echo 0)"
  if [ "$failure" = status-first ]; then
    check "initial status failure prevents fetch" "0" "$([ -f "$failure_state/fetched" ] && echo 1 || echo 0)"
  fi
  check_stale_warning "$out"
done

echo "=== HIDDEN UNTRACKED: status.showUntrackedFiles=no cannot permit an update ==="
WS="$TMP/hidden-untracked/IWE"; setup_sandbox "$WS" repo-hidden
advance_remote "$WS" repo-hidden
git -C "$WS/repo-hidden" config status.showUntrackedFiles no
git -C "$WS/repo-hidden" config merge.autoStash true
# A different path from the remote edit: Git would happily update HEAD while
# this draft exists if the hook trusted the user's hidden-untracked setting.
printf 'hidden local draft\000keep bytes\n\n' > "$WS/repo-hidden/new-wp-draft.md"
hidden_state="$TMP/hidden-untracked/snapshot"
snapshot_protected_state "$WS/repo-hidden" "$hidden_state"
out=$(run_hook "$WS" repo-hidden hidden-untracked)
check_protected_state "$WS/repo-hidden" "$hidden_state"
check_stale_warning "$out"

echo "=== IGNORED COLLISION: upstream starts tracking a local ignored draft -> preserve it ==="
WS="$TMP/ignored-collision/IWE"; setup_sandbox "$WS" repo-ignored
printf 'new-wp-draft.md\n' > "$WS/repo-ignored/.gitignore"
git -C "$WS/repo-ignored" add .gitignore
git -C "$WS/repo-ignored" commit -q -m ignore-local-draft
git -C "$WS/repo-ignored" push -q origin main
advance_remote "$WS" repo-ignored
printf 'upstream starts tracking this path\n' > "$WS/repo-ignored-pusher/new-wp-draft.md"
git -C "$WS/repo-ignored-pusher" add -f new-wp-draft.md
git -C "$WS/repo-ignored-pusher" commit -q -m track-draft
git -C "$WS/repo-ignored-pusher" push -q origin main
printf 'local ignored draft\000preserve these bytes\n\n' > "$WS/repo-ignored/new-wp-draft.md"
check "fixture draft is ignored" "1" "$(git -C "$WS/repo-ignored" check-ignore -q new-wp-draft.md && echo 1 || echo 0)"
ignored_state="$TMP/ignored-collision/snapshot"
snapshot_protected_state "$WS/repo-ignored" "$ignored_state"
out=$(run_hook "$WS" repo-ignored ignored-collision)
check_protected_state "$WS/repo-ignored" "$ignored_state"
check_stale_warning "$out"

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: все проверки pull-on-touch.sh (ff-only, без autostash) прошли"
  exit 0
else
  echo "FAIL: $FAILURES проверок не прошли"
  exit 1
fi
