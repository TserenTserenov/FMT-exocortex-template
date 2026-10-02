#!/usr/bin/env bash
# Issue #941: the template ships seed/strategy/scripts/ds-publish.sh. Real git,
# a local bare "origin", no network. Bash 3.2 compatible.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SELF_DIR")"
PUB="$REPO_ROOT/seed/strategy/scripts/ds-publish.sh"
[ -f "$PUB" ] || { echo "FATAL: $PUB missing" >&2; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

FAILS=0
ok()   { echo "  ✅ PASS: $1"; }
fail() { echo "  ❌ FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
g()    { git -C "$1" "${@:2}"; }

# new_scene NAME → sets ORIGIN (bare), WS (workspace with spaces), OTHER (a second clone)
new_scene() {
  local name="$1"
  ORIGIN="$TMP/$name/origin.git"; WS="$TMP/$name/my workspace/DS strategy"; OTHER="$TMP/$name/other"
  mkdir -p "$TMP/$name/my workspace"
  git init -q --bare -b main "$ORIGIN"
  git clone -q "$ORIGIN" "$WS" 2>/dev/null; g "$WS" checkout -q -b main 2>/dev/null
  g "$WS" config user.name t; g "$WS" config user.email t@example.invalid
  printf 'base\n' > "$WS/base.txt"; g "$WS" add base.txt; g "$WS" commit -q -m base
  g "$WS" push -q origin main 2>/dev/null
  git clone -q "$ORIGIN" "$OTHER" 2>/dev/null
  g "$OTHER" config user.name t; g "$OTHER" config user.email t@example.invalid
}
origin_log() { git --git-dir="$ORIGIN" log --format=%s main | tr '\n' '|'; }
origin_count() { git --git-dir="$ORIGIN" rev-list --count main; }
commit_in() {  # DIR FILE CONTENT MESSAGE → prints SHA
  printf '%s\n' "$3" > "$1/$2"; g "$1" add "$2"; g "$1" commit -q -m "$4"; g "$1" rev-parse HEAD
}
# A git shim that logs every invocation: the only way to prove that no push carries a
# force flag (a forced push still fails on a moved ref, so behaviour alone cannot tell).
REAL_GIT=$(command -v git)
mkdir -p "$TMP/shim"
cat > "$TMP/shim/git" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/git-calls.log"
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$TMP/shim/git"
run_pub() {  # runs from a foreign cwd, like a scheduled role would
  : > "$TMP/git-calls.log"
  ( cd "$TMP" && PATH="$TMP/shim:$PATH" bash "$PUB" "$@" ) > "$TMP/out.txt" 2> "$TMP/err.txt"; RC=$?
}
pushes_are_plain() {  # every logged push is without force flags or a forcing refspec
  grep -E ' push ' "$TMP/git-calls.log" | grep -qE -- ' (--force|-f|--force-with-lease|--mirror)( |$)| \+' && return 1
  grep -qE ' push ' "$TMP/git-calls.log"
}
temp_worktrees() { g "$WS" worktree list | wc -l | tr -d ' '; }

echo "== publishes exactly the given commit; the checkout is left alone"
new_scene s1
SHA1=$(commit_in "$WS" a.txt one "role: first")
commit_in "$WS" b.txt two "role: second" >/dev/null       # a later local commit must NOT be published
printf 'dirty\n' > "$WS/base.txt"; printf 'staged\n' > "$WS/staged.txt"; g "$WS" add staged.txt
HEAD_BEFORE=$(g "$WS" rev-parse HEAD)
run_pub "$WS" normal --reason "test" --from-commit "$SHA1"
[ "$RC" -eq 0 ] && ok "exit 0" || fail "exit $RC: $(cat "$TMP/err.txt")"
[ "$(origin_log)" = "role: first|base|" ] && ok "origin got only the requested commit" || fail "origin log: $(origin_log)"
[ "$(g "$WS" rev-parse HEAD)" = "$HEAD_BEFORE" ] && ok "local HEAD unchanged" || fail "local HEAD moved"
[ "$(cat "$WS/base.txt")" = dirty ] && [ -f "$WS/staged.txt" ] && [ -n "$(g "$WS" diff --cached --name-only)" ] && ok "uncommitted and staged changes preserved" || fail "working tree or index changed"
[ "$(temp_worktrees)" = 1 ] && ok "temp worktree removed" || fail "temp worktree left: $(g "$WS" worktree list)"
pushes_are_plain && ok "the push carried no force flag" || fail "a push used a force flag (or no push was made): $(grep ' push ' "$TMP/git-calls.log")"

echo "== already on origin: same SHA"
new_scene s2
SHA=$(commit_in "$WS" a.txt one "role: only"); g "$WS" push -q origin main 2>/dev/null
N=$(origin_count); run_pub "$WS" normal --from-commit "$SHA"
[ "$RC" -eq 0 ] && [ "$(origin_count)" = "$N" ] && ok "no-op, origin unchanged" || fail "same SHA (rc=$RC)"

echo "== already on origin: same patch, different SHA"
new_scene s3
SHA=$(commit_in "$WS" a.txt same "role: patch")
g "$OTHER" fetch -q origin 2>/dev/null; printf 'same\n' > "$OTHER/a.txt"; g "$OTHER" add a.txt; g "$OTHER" commit -q -m "role: patch (other SHA)"; g "$OTHER" push -q origin HEAD:main 2>/dev/null
N=$(origin_count); run_pub "$WS" normal --from-commit "$SHA"
[ "$RC" -eq 0 ] && [ "$(origin_count)" = "$N" ] && ok "equivalent patch recognised, no duplicate" || fail "equivalent patch (rc=$RC, n=$N→$(origin_count))"

echo "== conflict: exit 3, origin untouched, nothing left behind"
new_scene s4
SHA=$(commit_in "$WS" base.txt mine "role: mine")
g "$OTHER" pull -q origin main 2>/dev/null; commit_in "$OTHER" base.txt theirs "someone else" >/dev/null; g "$OTHER" push -q origin HEAD:main 2>/dev/null
BEFORE=$(origin_log); run_pub "$WS" normal --from-commit "$SHA"
[ "$RC" -eq 3 ] && ok "exit 3" || fail "exit $RC"
[ "$(origin_log)" = "$BEFORE" ] && ok "origin unchanged" || fail "origin changed"
[ "$(temp_worktrees)" = 1 ] && ok "no temp worktree left" || fail "temp worktree left"
[ "$(g "$WS" rev-parse "$SHA")" = "$SHA" ] && ok "the commit stays local" || fail "local commit lost"

echo "== origin moves between fetch and push: replayed on the new tip, nothing lost"
new_scene s5
SHA=$(commit_in "$WS" a.txt mine "role: mine")
mkdir -p "$WS/.git/hooks"
cat > "$WS/.git/hooks/pre-push" <<EOF
#!/bin/sh
# first push only: somebody else lands a commit on origin, so this push is non-fast-forward.
# git exports GIT_DIR & co. to hooks; they must not leak into the other clone's commands.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
[ -e "$TMP/raced" ] && exit 0
touch "$TMP/raced"
git -C "$OTHER" pull -q origin main 2>/dev/null
printf 'racer\n' > "$OTHER/racer.txt"; git -C "$OTHER" add racer.txt; git -C "$OTHER" commit -q -m "racer"
git -C "$OTHER" push -q origin HEAD:main 2>/dev/null
exit 0
EOF
chmod +x "$WS/.git/hooks/pre-push"
rm -f "$TMP/raced"; run_pub "$WS" normal --from-commit "$SHA"
[ "$RC" -eq 0 ] && ok "exit 0 after a retry" || fail "exit $RC: $(cat "$TMP/err.txt")"
case "$(origin_log)" in *"role: mine"*"racer"*|*"racer"*"role: mine"*) ok "both the racer's commit and ours are on origin" ;; *) fail "origin log: $(origin_log)" ;; esac
grep -q "refused" "$TMP/err.txt" && ok "the refused attempt is reported" || fail "no report of the refused attempt"

echo "== push refused every time: exit 4, no force push, origin untouched"
new_scene s6
SHA=$(commit_in "$WS" a.txt mine "role: mine")
printf '#!/bin/sh\nexit 1\n' > "$WS/.git/hooks/pre-push"; chmod +x "$WS/.git/hooks/pre-push"
BEFORE=$(origin_log); run_pub "$WS" normal --from-commit "$SHA"
[ "$RC" -eq 4 ] && ok "exit 4" || fail "exit $RC"
[ "$(origin_log)" = "$BEFORE" ] && ok "origin unchanged" || fail "origin changed"
[ "$(grep -c 'push attempt' "$TMP/err.txt")" = 3 ] && ok "three attempts" || fail "attempts: $(grep -c 'push attempt' "$TMP/err.txt")"
[ "$(grep -c ' push ' "$TMP/git-calls.log")" = 3 ] && ok "exactly three push attempts" || fail "push calls: $(grep -c ' push ' "$TMP/git-calls.log")"
pushes_are_plain && ok "no force flag on any retry" || fail "a retry used a force flag"
[ "$(temp_worktrees)" = 1 ] && ok "no temp worktree left" || fail "temp worktree left"

echo "== preconditions fail cleanly (exit 1)"
new_scene s7
run_pub "$WS" normal --from-commit deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
[ "$RC" -eq 1 ] && ok "unknown commit" || fail "unknown commit rc=$RC"
run_pub "$TMP/not-a-repo" normal
[ "$RC" -eq 1 ] && ok "not a git repository" || fail "not a repo rc=$RC"
g "$WS" remote remove origin; run_pub "$WS" normal
[ "$RC" -eq 1 ] && ok "no origin" || fail "no origin rc=$RC"
run_pub "$WS" bogus
[ "$RC" -eq 1 ] && ok "bad priority" || fail "bad priority rc=$RC"
run_pub "$WS" normal --nope
[ "$RC" -eq 1 ] && ok "unknown option" || fail "unknown option rc=$RC"

echo "== a merge commit is refused (exit 2)"
new_scene s8
g "$WS" checkout -q -b side; SIDE=$(commit_in "$WS" side.txt s "side"); g "$WS" checkout -q main
commit_in "$WS" main.txt m "main work" >/dev/null; g "$WS" merge -q --no-ff side -m "merge side" 2>/dev/null
MERGE=$(g "$WS" rev-parse HEAD); N=$(origin_count); run_pub "$WS" normal --from-commit "$MERGE"
[ "$RC" -eq 2 ] && [ "$(origin_count)" = "$N" ] && ok "merge commit refused, origin untouched" || fail "merge commit rc=$RC"

echo "== a single-branch clone (remote.origin.fetch narrowed to another branch)"
new_scene s10
g "$WS" config remote.origin.fetch "+refs/heads/other:refs/remotes/origin/other"
g "$WS" update-ref -d refs/remotes/origin/main
SHA=$(commit_in "$WS" a.txt one "role: single-branch")
run_pub "$WS" normal --from-commit "$SHA"
[ "$RC" -eq 0 ] && [ "$(origin_log)" = "role: single-branch|base|" ] && ok "published although refs/remotes/origin/main does not exist" || fail "single-branch (rc=$RC): $(cat "$TMP/err.txt")"
[ -z "$(g "$WS" for-each-ref refs/ds-publish)" ] && ok "the private fetch ref is removed" || fail "private ref left behind"

echo "== a stale origin/<branch> tracking ref must not fake 'already published'"
new_scene s11
SHA=$(commit_in "$WS" a.txt one "role: stale")
g "$WS" push -q origin HEAD:main 2>/dev/null                         # published under this SHA ...
g "$OTHER" pull -q origin main 2>/dev/null; g "$OTHER" reset -q --hard HEAD~1; g "$OTHER" push -q --force origin HEAD:main 2>/dev/null   # ... then origin was rewritten without it
run_pub "$WS" normal --from-commit "$SHA"
[ "$RC" -eq 0 ] && [ "$(origin_log)" = "role: stale|base|" ] && ok "re-published after origin was rewritten (the stale tracking ref was not trusted)" || fail "stale tracking ref (rc=$RC, log=$(origin_log))"

echo "== a cherry-pick that fails for a reason other than a conflict is NOT success"
new_scene s12
SHA=$(commit_in "$WS" a.txt one "role: tech")
mkdir -p "$TMP/shim2"
cat > "$TMP/shim2/git" <<EOF
#!/bin/sh
case " \$* " in *" cherry-pick "*) echo "fatal: Unable to create index.lock: File exists" >&2; exit 1 ;; esac
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$TMP/shim2/git"
BEFORE=$(origin_log)
( cd "$TMP" && PATH="$TMP/shim2:$PATH" bash "$PUB" "$WS" normal --from-commit "$SHA" ) > "$TMP/out.txt" 2> "$TMP/err.txt"; RC=$?
[ "$RC" -eq 1 ] && ok "exit 1, not a false success" || fail "technical failure gave exit $RC"
[ "$(origin_log)" = "$BEFORE" ] && ok "origin unchanged" || fail "origin changed"
grep -q "other than a conflict" "$TMP/err.txt" && ok "the reason is stated" || fail "no reason: $(cat "$TMP/err.txt")"

echo "== the strategist call shape from the template"
new_scene s9
SHA=$(commit_in "$WS" a.txt one "strategist: day plan")
( cd "$TMP" && bash "$PUB" "$WS" normal --reason "strategist morning" --from-commit "$SHA" ) >/dev/null 2>&1
[ "$(origin_log)" = "strategist: day plan|base|" ] && ok "strategist.sh's exact argument shape publishes" || fail "strategist call shape: $(origin_log)"

# Isolated copies (C1, WP-7): strategist.sh (isolated scenarios) and session-guard.sh --isolate create a
# worktree of origin/main on a branch that exists only locally (strategist/<scenario>-<run id>,
# session-isolate/<agent>-<session>). Their callers name the copy's base branch with --branch.
origin_branches() { git --git-dir="$ORIGIN" for-each-ref --format='%(refname:short)' refs/heads | tr '\n' ' ' | sed 's/ $//'; }
iso_copy() {  # LABEL BRANCH FILE CONTENT → WT (worktree of origin/main on the local-only BRANCH), ISO_SHA (its commit)
  WT="$(dirname "$WS")/iso $1"
  g "$WS" fetch -q origin 2>/dev/null
  g "$WS" worktree add -q -b "$2" "$WT" origin/main 2>/dev/null
  ISO_SHA=$(commit_in "$WT" "$3" "$4" "isolated: $1")
}

for kind in "strategist/note-review-20261001223000-4242" "session-isolate/claude-s1"; do
  echo "== isolated copy on $kind: --branch main publishes to origin/main"
  new_scene "s13-${kind%%/*}"
  iso_copy c "$kind" c.txt c
  N=$(origin_count)
  run_pub "$WT" normal --reason "strategist: cleanup" --from-commit "$ISO_SHA" --branch main
  [ "$RC" -eq 0 ] && ok "exit 0" || fail "exit $RC: $(cat "$TMP/err.txt")"
  [ "$(origin_count)" = "$((N + 1))" ] && [ "$(git --git-dir="$ORIGIN" log -1 --format=%s main)" = "isolated: c" ] \
    && ok "origin/main got the copy's commit" || fail "origin log: $(origin_log)"
  [ "$(origin_branches)" = main ] && ok "no branch named after the copy appeared on origin" || fail "origin branches: $(origin_branches)"
  [ "$(g "$WT" symbolic-ref --short HEAD)" = "$kind" ] && [ "$(g "$WT" rev-parse HEAD)" = "$ISO_SHA" ] \
    && ok "the copy keeps its named branch and HEAD" || fail "the copy's branch or HEAD changed"
  [ "$(temp_worktrees)" = 2 ] && ok "no temp worktree left (the checkout and the copy only)" || fail "worktrees: $(g "$WS" worktree list)"
  run_pub "$WT" normal --reason "again" --from-commit "$ISO_SHA" --branch main
  [ "$RC" -eq 0 ] && [ "$(origin_count)" = "$((N + 1))" ] && grep -q "already on origin/main" "$TMP/out.txt" \
    && ok "a repeated publication is a no-op (exit 0, no second commit)" || fail "repeat: rc=$RC n=$(origin_count) out=$(cat "$TMP/out.txt")"
done

echo "== isolated copy, conflict on --branch main: exit 3, the commit stays local, origin untouched"
new_scene s14
iso_copy f "session-isolate/claude-s2" base.txt mine
g "$OTHER" pull -q origin main 2>/dev/null; commit_in "$OTHER" base.txt theirs "someone else" >/dev/null; g "$OTHER" push -q origin HEAD:main 2>/dev/null
BEFORE=$(origin_log); run_pub "$WT" normal --from-commit "$ISO_SHA" --branch main
[ "$RC" -eq 3 ] && ok "exit 3" || fail "exit $RC: $(cat "$TMP/err.txt")"
[ "$(origin_log)" = "$BEFORE" ] && [ "$(origin_branches)" = main ] && ok "origin unchanged" || fail "origin changed: $(origin_log) / $(origin_branches)"
[ "$(g "$WT" rev-parse HEAD)" = "$ISO_SHA" ] && [ "$(g "$WT" symbolic-ref --short HEAD)" = "session-isolate/claude-s2" ] \
  && ok "the commit stays local on the copy's branch" || fail "the copy lost its commit or branch"
[ "$(temp_worktrees)" = 2 ] && ok "no temp worktree left" || fail "temp worktree left"

echo "== default unchanged: without --branch an isolated copy targets its own branch, absent on origin"
new_scene s15
iso_copy d "strategist/note-review-1" d.txt d
BEFORE=$(origin_log); run_pub "$WT" normal --from-commit "$ISO_SHA"
[ "$RC" -eq 1 ] && [ "$(origin_log)" = "$BEFORE" ] && [ "$(origin_branches)" = main ] \
  && ok "exit 1, origin untouched, no branch created" || fail "rc=$RC origin=$(origin_log) branches=$(origin_branches)"
grep -q "origin/strategist/note-review-1" "$TMP/err.txt" && ok "the error names the branch it tried" || fail "error: $(cat "$TMP/err.txt")"

echo "== the old call shape from a detached copy still publishes (origin/HEAD, then main)"
new_scene s16
WT="$(dirname "$WS")/iso detached"
g "$WS" worktree add -q --detach "$WT" origin/main 2>/dev/null
ISO_SHA=$(commit_in "$WT" e.txt e "isolated: detached")
run_pub "$WT" normal --reason "strategist: cleanup" --from-commit "$ISO_SHA"
[ "$RC" -eq 0 ] && [ "$(git --git-dir="$ORIGIN" log -1 --format=%s main)" = "isolated: detached" ] \
  && ok "detached HEAD without --branch publishes to main" || fail "detached: rc=$RC $(cat "$TMP/err.txt")"

echo "== --branch takes a branch name only: garbage gives usage (exit 1) before any fetch or push"
new_scene s17
SHA=$(commit_in "$WS" a.txt one "role: x")
for bad in "" "-main" "ma in" "main..x" "ma:in" "ma~in" "refs/heads/../x"; do
  run_pub "$WS" normal --from-commit "$SHA" --branch "$bad"
  if [ "$RC" -eq 1 ] && grep -q -- '--branch NAME' "$TMP/err.txt" && ! grep -qE ' (fetch|push) ' "$TMP/git-calls.log"; then
    ok "--branch '$bad' refused with usage"
  else
    fail "--branch '$bad': rc=$RC err=$(cat "$TMP/err.txt")"
  fi
done
run_pub "$WS" normal --from-commit "$SHA" --branch
[ "$RC" -eq 1 ] && grep -q -- '--branch NAME' "$TMP/err.txt" && ok "--branch without a value refused with usage" || fail "no value: rc=$RC err=$(cat "$TMP/err.txt")"
[ "$(origin_log)" = "base|" ] && ok "origin untouched by the refused calls" || fail "origin log: $(origin_log)"
run_pub "$WS" normal --from-commit "$SHA" --branch no-such-branch
[ "$RC" -eq 1 ] && [ "$(origin_branches)" = main ] && grep -q "fetch origin/no-such-branch failed" "$TMP/err.txt" \
  && ok "a valid name absent on origin: exit 1, nothing created on origin" || fail "absent branch: rc=$RC err=$(cat "$TMP/err.txt") branches=$(origin_branches)"

echo
if [ "$FAILS" -eq 0 ]; then echo "PASS: ds-publish (#941)"; else echo "FAILED: $FAILS check(s)"; exit 1; fi
