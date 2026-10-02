#!/usr/bin/env bash
# canon-reconcile-published-smoke.sh -- throwaway-repo scenarios for canon-reconcile-published.sh
# (WP-530 Ф38 / Ф5). Each scenario asserts an observable outcome, not just "did not crash".
set -uo pipefail
SCRIPT="${1:-$(dirname "$0")/../canon-reconcile-published.sh}"
[ -x "$SCRIPT" ] || SCRIPT="$(cd "$(dirname "$0")" && pwd)/../canon-reconcile-published.sh"
# shellcheck source=ancestry-hardening-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/ancestry-hardening-lib.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export IWE_WORKSPACE="$SANDBOX/no-workspace"   # ledger-append absent -> ledger_note is a no-op
export IWE_RUNTIME="$SANDBOX/runtime"; mkdir -p "$IWE_RUNTIME/sessions"   # no live writers unless a scenario adds one
fails=0
assert() { if [ "$1" = "$2" ]; then echo "  ok   $3"; else echo "  FAIL $3 (got '$1', want '$2')"; fails=$((fails+1)); fi; }
# `md5` is macOS-only (BSD coreutils); GitHub's ubuntu-latest runner has neither
# `md5` nor a `md5` alias. shasum ships on both macOS and ubuntu-latest, so it
# is the cross-platform default; sha256sum is the fallback for a bare Linux
# box that lacks shasum.
hash_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  else
    echo "FAIL: neither shasum nor sha256sum is available" >&2
    return 1
  fi
}
# Fail fast, not silently: without -e, a hash_stdin failure inside "$(git ... |
# hash_stdin)" would leave the caller comparing two empty strings and passing
# the assert -- checking the precondition once, up front, turns a missing tool
# into a loud failure here instead of a quiet false-green at scenario 13.
command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 || {
  echo "FAIL: neither shasum nor sha256sum is available in this environment" >&2
  exit 1
}

fresh() {  # <name> -- bare origin + canonical clone with one base commit; sets ORIGIN, CANON
  ORIGIN="$SANDBOX/$1-origin.git"; CANON="$SANDBOX/$1-canon"
  # -b main: a bare repo's HEAD symref defaults to whatever `init.defaultBranch`
  # resolves to on the host, not necessarily "main" (GitHub's ubuntu-latest
  # runner defaults to master; this Mac's git happens to default to main).
  # Every clone of $ORIGIN below relies on its HEAD resolving to "main" to
  # auto-checkout a local "main" branch -- an unresolvable HEAD symref instead
  # produces "remote HEAD refers to nonexistent ref, unable to checkout" and a
  # clone with no branch checked out at all, so every later `push origin main`
  # from that clone fails with "src refspec main does not match any". Found
  # live on the first real ubuntu-latest CI run (15 failed assertions), not
  # locally on macOS. ancestry-mutation-guards-smoke.sh already does this
  # correctly (`git init -q --template= -b main`) -- this file was the only
  # one of the 7 missing it.
  git init -q --bare -b main "$ORIGIN"
  git init -q "$CANON" && git -C "$CANON" -c user.name=t -c user.email=t@t checkout -q -b main
  echo base > "$CANON/a.txt"; git -C "$CANON" add a.txt; git -C "$CANON" -c user.name=t -c user.email=t@t commit -qm base
  git -C "$CANON" remote add origin "$ORIGIN"; git -C "$CANON" push -q origin main
}
commit_in() { git -C "$1" add -A; git -C "$1" -c user.name=t -c user.email=t@t commit -qm "$2"; }
# origin gets the same patch republished under a new SHA (what isolate-push does)
republish_on_origin() {  # <canon> <commit> -- cherry-pick onto a fresh clone of origin and push
  local pub="$SANDBOX/pub-$RANDOM"; git clone -q "$ORIGIN" "$pub"
  git -C "$pub" fetch -q "$1" "$2"; git -C "$pub" -c user.name=o -c user.email=o@o cherry-pick FETCH_HEAD >/dev/null
  git -C "$pub" push -q origin main
}

echo "scenario 1: diverged, patch-equivalent, clean -> replaced, untracked intact"
fresh s1; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"; echo keep > "$CANON/note.tmp"
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
git -C "$CANON" fetch -q origin
assert "$rc" "0" "exit 0"
assert "$(git -C "$CANON" rev-parse HEAD)" "$(git -C "$CANON" rev-parse origin/main)" "HEAD == origin/main"
assert "$(cat "$CANON/note.tmp")" "keep" "untracked file kept"
assert "$(git -C "$CANON" status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "0" "tracked tree clean"

echo "scenario 2: unique local commit -> fail closed, nothing touched"
fresh s2; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"; echo two > "$CANON/c.txt"; commit_in "$CANON" "unique"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"

echo "scenario 3: tracked dirt -> fail closed"
fresh s3; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"; echo dirty >> "$CANON/a.txt"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"; assert "$(tail -1 "$CANON/a.txt")" "dirty" "dirt preserved"

echo "scenario 4a: untracked collides with target file, different content -> fail closed"
fresh s4a; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-extra"; git clone -q "$ORIGIN" "$pub"; echo origin-version > "$pub/new.txt"; commit_in "$pub" "origin adds new.txt"; git -C "$pub" push -q origin main
echo local-version > "$CANON/new.txt"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1"; assert "$(cat "$CANON/new.txt")" "local-version" "untracked not overwritten"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"

echo "scenario 4b: untracked collides with target file, identical content -> replaced, hash recorded == target blob"
fresh s4b; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-extra2"; git clone -q "$ORIGIN" "$pub"; echo same > "$pub/new.txt"; commit_in "$pub" "origin adds new.txt"; git -C "$pub" push -q origin main
echo same > "$CANON/new.txt"; BEFORE=$(git -C "$CANON" hash-object new.txt)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
git -C "$CANON" fetch -q origin
assert "$rc" "0" "exit 0"; assert "$(git -C "$CANON" rev-parse HEAD)" "$(git -C "$CANON" rev-parse origin/main)" "HEAD == origin/main"
assert "$(git -C "$CANON" rev-parse HEAD:new.txt)" "$BEFORE" "replaced file identical to the pre-replacement untracked content"

echo "scenario 4c: untracked directory where target has a file -> fail closed"
fresh s4c; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-extra3"; git clone -q "$ORIGIN" "$pub"; echo f > "$pub/thing"; commit_in "$pub" "origin adds file thing"; git -C "$pub" push -q origin main
mkdir -p "$CANON/thing"; echo x > "$CANON/thing/inner"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"; assert "$(cat "$CANON/thing/inner")" "x" "untracked dir intact"

echo "scenario 5: HEAD already ancestor of origin -> exit 0, no action (canon-refresh's job)"
fresh s5; pub="$SANDBOX/pub-ff"; git clone -q "$ORIGIN" "$pub"; echo z > "$pub/z.txt"; commit_in "$pub" "origin ahead"; git -C "$pub" push -q origin main
H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "0" "exit 0"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD untouched"

echo "scenario 6: lock busy -> exit 0, no action"
fresh s6; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
H=$(git -C "$CANON" rev-parse HEAD); mkdir "$CANON/.git/dirty-guard.lock"; printf 'host=%s\npid=%s\n' "$(hostname)" "$$" > "$CANON/.git/dirty-guard.lock/owner"
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "0" "exit 0"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD untouched while lock held"

echo "scenario 4d: untracked file where target has paths below it (file vs target directory) -> fail closed"
fresh s4d; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-extra4"; git clone -q "$ORIGIN" "$pub"; mkdir -p "$pub/dir"; echo f > "$pub/dir/inner"; commit_in "$pub" "origin adds dir/inner"; git -C "$pub" push -q origin main
echo plain > "$CANON/dir"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1"; assert "$(cat "$CANON/dir")" "plain" "untracked file intact"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"

echo "scenario 4e: untracked sibling next to a new tracked file in the same dir -> not a collision, replaced"
fresh s4e; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-extra5"; git clone -q "$ORIGIN" "$pub"; mkdir -p "$pub/inbox/WP-573"; echo card > "$pub/inbox/WP-573/WP-573.md"; commit_in "$pub" "origin adds card"; git -C "$pub" push -q origin main
mkdir -p "$CANON/inbox/WP-573"; echo mine > "$CANON/inbox/WP-573/x"
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
git -C "$CANON" fetch -q origin
assert "$rc" "0" "exit 0"; assert "$(cat "$CANON/inbox/WP-573/x")" "mine" "sibling untracked kept"; assert "$(cat "$CANON/inbox/WP-573/WP-573.md")" "card" "tracked file materialised"

echo "scenario 4f: same content but type mismatch (symlink vs regular file) -> fail closed"
fresh s4f; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-extra6"; git clone -q "$ORIGIN" "$pub"; echo a.txt > "$pub/ln"; commit_in "$pub" "origin adds regular file ln"; git -C "$pub" push -q origin main
ln -s a.txt "$CANON/ln"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1"; assert "$([ -L "$CANON/ln" ] && echo link)" "link" "symlink intact"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"

echo "scenario 7: local merge commit (cherry cannot prove it) -> fail closed"
fresh s7; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
git -C "$CANON" checkout -q -b side; echo s > "$CANON/s.txt"; commit_in "$CANON" "side"; git -C "$CANON" checkout -q main
git -C "$CANON" -c user.name=t -c user.email=t@t merge -q --no-ff -m "local merge" side
republish_on_origin "$CANON" "$(git -C "$CANON" rev-parse side)"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"

echo "scenario 8: live canonical writer semaphore -> fail closed (strict barrier)"
fresh s8; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
printf 'agent: claude-code\npid: %s\n' "$$" > "$IWE_RUNTIME/sessions/claude-code-writer.open"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1 with live writer"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"
printf 'agent: codex\n' > "$IWE_RUNTIME/sessions/codex-nopid.open"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "semaphore without pid counts as a live writer"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"; rm -f "$IWE_RUNTIME/sessions/codex-nopid.open"
printf 'agent: claude-code\npid: %s\nisolated_worktree: /tmp/x\n' "$$" > "$IWE_RUNTIME/sessions/claude-code-writer.open"
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
git -C "$CANON" fetch -q origin
assert "$rc" "0" "isolated session does not block"; assert "$(git -C "$CANON" rev-parse HEAD)" "$(git -C "$CANON" rev-parse origin/main)" "replaced once only isolated sessions are live"
rm -f "$IWE_RUNTIME/sessions/claude-code-writer.open"

echo "scenario 9: origin advanced past the caller's pinned oid -> targets the live tip"
fresh s9; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
P1=$(git -C "$CANON" ls-remote origin refs/heads/main | cut -c1-40)
pub="$SANDBOX/pub-extra7"; git clone -q "$ORIGIN" "$pub"; echo later > "$pub/later.txt"; commit_in "$pub" "origin later"; git -C "$pub" push -q origin main
bash "$SCRIPT" "$CANON" main "$P1" >/dev/null 2>&1; rc=$?
git -C "$CANON" fetch -q origin
assert "$rc" "0" "exit 0"; assert "$(git -C "$CANON" rev-parse HEAD)" "$(git -C "$CANON" rev-parse origin/main)" "HEAD == live origin tip, not the stale pin"

echo "scenario 10: collision inside a nested directory (not repo root) -> fail closed"
fresh s10; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-nested"; git clone -q "$ORIGIN" "$pub"; mkdir -p "$pub/inbox/WP-9"; echo origin > "$pub/inbox/WP-9/WP-9.md"; commit_in "$pub" "origin adds nested card"; git -C "$pub" push -q origin main
mkdir -p "$CANON/inbox/WP-9"; echo local > "$CANON/inbox/WP-9/WP-9.md"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1"; assert "$(cat "$CANON/inbox/WP-9/WP-9.md")" "local" "nested untracked not overwritten"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"

echo "scenario 11: git-ignored local file where target adds a tracked file with other content -> fail closed"
fresh s11; echo '*.lock' > "$CANON/.gitignore"; commit_in "$CANON" "ignore"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-ignored"; git clone -q "$ORIGIN" "$pub"; echo origin > "$pub/run.lock"; git -C "$pub" add -f run.lock; git -C "$pub" -c user.name=o -c user.email=o@o commit -qm "origin tracks run.lock"; git -C "$pub" push -q origin main
echo local > "$CANON/run.lock"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1"; assert "$(cat "$CANON/run.lock")" "local" "ignored file not overwritten"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"

echo "scenario 12: a foreign live lock is left in place after our no-op exit"
fresh s12; mkdir "$CANON/.git/dirty-guard.lock"; printf 'host=%s\npid=%s\n' "$(hostname)" "$$" > "$CANON/.git/dirty-guard.lock/owner"
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1
assert "$([ -d "$CANON/.git/dirty-guard.lock" ] && echo present)" "present" "foreign lock still present"; rm -rf "$CANON/.git/dirty-guard.lock"

echo "scenario 13: refusal writes nothing inside the repository (log goes to runtime dir)"
fresh s13; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
echo two > "$CANON/c.txt"; commit_in "$CANON" "unique"; BEFORE=$(git -C "$CANON" status --porcelain | hash_stdin); MARK=$(mktemp); sleep 1
LOG_BEFORE=$(grep -c ' refused ' "$IWE_RUNTIME/canon-reconcile-published.log" 2>/dev/null || echo 0)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1
assert "$(git -C "$CANON" status --porcelain | hash_stdin)" "$BEFORE" "repo status unchanged by the refusal"
assert "$(find "$CANON" -newer "$MARK" -type f -not -path "$CANON/.git/*" | wc -l | tr -d ' ')" "0" "no working-tree file written by the refusal (git's own fetch bookkeeping under .git is expected)"
assert "$(( $(grep -c ' refused ' "$IWE_RUNTIME/canon-reconcile-published.log") - LOG_BEFORE ))" "1" "refusal logged exactly once in the runtime log"

echo "scenario 14 (static): isolate-push.sh defines post_publish_reconcile before its first use"
IP="${ISOLATE_PUSH:-}"   # author-only static check; set ISOLATE_PUSH=<path> to run it
if [ -n "$IP" ] && [ -f "$IP" ]; then
  def=$(grep -n '^post_publish_reconcile()' "$IP" | head -1 | cut -d: -f1); use=$(grep -n '^ *post_publish_reconcile "' "$IP" | head -1 | cut -d: -f1)
  assert "$([ -n "$def" ] && [ -n "$use" ] && [ "$def" -lt "$use" ] && echo ok)" "ok" "definition (line $def) precedes first call (line $use)"
else
  echo "  skip isolate-push.sh (set ISOLATE_PUSH to enable)"
fi

echo "scenario 15: untracked symlink ancestor where target adds a path below it -> fail closed, symlink intact"
fresh s15; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-symanc"; git clone -q "$ORIGIN" "$pub"; mkdir -p "$pub/lnk"; echo f > "$pub/lnk/inner"; commit_in "$pub" "origin adds lnk/inner"; git -C "$pub" push -q origin main
mkdir -p "$CANON/realdir"; ln -s realdir "$CANON/lnk"; H=$(git -C "$CANON" rev-parse HEAD)
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
assert "$rc" "1" "exit 1"; assert "$([ -L "$CANON/lnk" ] && echo link)" "link" "symlink ancestor intact"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"

echo "scenario 16: tracked file -> directory conversion published on origin is not a collision"
fresh s16; echo conv > "$CANON/conv"; commit_in "$CANON" "add conv file"; C=$(git -C "$CANON" rev-parse HEAD); republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-conv"; git clone -q "$ORIGIN" "$pub"; git -C "$pub" rm -q conv; mkdir -p "$pub/conv"; echo inner > "$pub/conv/inner"; git -C "$pub" add conv/inner; git -C "$pub" -c user.name=o -c user.email=o@o commit -qm "conv file->dir"; git -C "$pub" push -q origin main
bash "$SCRIPT" "$CANON" main >/dev/null 2>&1; rc=$?
git -C "$CANON" fetch -q origin
assert "$rc" "0" "exit 0"; assert "$(cat "$CANON/conv/inner")" "inner" "directory materialised"; assert "$(git -C "$CANON" rev-parse HEAD)" "$(git -C "$CANON" rev-parse origin/main)" "HEAD == origin/main"

echo "scenario 17: refs/replace forgery makes an undelivered commit look patch-equivalent -> refused by the delivery proof itself"
# Origin holds BASE -> Q -> P. The local commit U is undelivered AND its end state
# differs from origin (x.txt says "different", origin says "pub"). The forgery
# replaces U with F (origin's tree, parent Q = exactly P's patch), so an unguarded
# `git cherry` says "-"; the guarded one says "+". WP-561 Ф24 added a second,
# content-based proof (same tree entries in HEAD and target) -- it must not be
# fooled either: it reads the REAL tree of U (GIT_NO_REPLACE_OBJECTS exported by
# the script), where x.txt differs, and refuses.
fresh s17
pub="$SANDBOX/pub-forge"; git clone -q "$ORIGIN" "$pub"
echo mine > "$pub/y.txt"; commit_in "$pub" "origin publishes y"; Q=$(git -C "$pub" rev-parse HEAD)
echo pub > "$pub/x.txt"; commit_in "$pub" "origin publishes x"; git -C "$pub" push -q origin main
echo mine > "$CANON/y.txt"; echo different > "$CANON/x.txt"; commit_in "$CANON" "undelivered local edit of x"; U=$(git -C "$CANON" rev-parse HEAD)
git -C "$CANON" fetch -q origin
FORGED=$(git -C "$CANON" -c user.name=t -c user.email=t@t commit-tree "$(git -C "$CANON" rev-parse 'origin/main^{tree}')" -p "$Q" -m forged)
git -C "$CANON" replace "$U" "$FORGED"
assert "$(GIT_NO_REPLACE_OBJECTS=1 git -C "$CANON" status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "0" "precondition: tracked tree clean in the real world"
assert "$(git -C "$CANON" cherry origin/main "$U" | cut -c1)" "-" "precondition: the forgery fools an unguarded git cherry"
assert "$(GIT_NO_REPLACE_OBJECTS=1 git -C "$CANON" cherry origin/main "$U" | cut -c1)" "+" "precondition: the real commit is not on the target"
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1: a forged equivalence is not proof of delivery"
assert "$(git -C "$CANON" rev-parse refs/heads/main)" "$U" "branch still points at the undelivered commit"
assert "$(printf '%s' "$out" | grep -c 'local-only commits not on target')" "1" "refused by the delivery proof, not by another preflight"
assert "$(printf '%s' "$out" | grep -c 'end state differs from the target: x.txt')" "1" "the content proof names the real differing path (forgery ignored)"

echo "scenario 18 (static): exact hardening exports precede the first ancestry-sensitive call"
assert "$(hardening_violations "$SCRIPT" 'is-ancestor|git cherry')" "" "canon-reconcile-published.sh is hardened against refs/replace and grafts"

echo "scenario 19 (WP-561 Ф24): honest squash with the SAME end state as origin -> content-superseded, replaced"
fresh s19
pub="$SANDBOX/pub-s19"; git clone -q "$ORIGIN" "$pub"
echo mine > "$pub/y.txt"; commit_in "$pub" "origin y"; echo pub > "$pub/x.txt"; commit_in "$pub" "origin x"; git -C "$pub" push -q origin main
echo mine > "$CANON/y.txt"; echo pub > "$CANON/x.txt"; commit_in "$CANON" "local squash of y and x"; U=$(git -C "$CANON" rev-parse HEAD)
git -C "$CANON" fetch -q origin
assert "$(GIT_NO_REPLACE_OBJECTS=1 git -C "$CANON" cherry origin/main "$U" | cut -c1)" "+" "precondition: patch-id cannot see the squash"
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "0" "exit 0: end state provably on the target"
assert "$(git -C "$CANON" rev-parse HEAD)" "$(git -C "$CANON" rev-parse origin/main)" "HEAD replaced by origin tip"
assert "$(printf '%s' "$out" | grep -c 'content-superseded=1')" "1" "report counts the superseded commit"
assert "$(git -C "$CANON" status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "0" "tree clean afterwards"

echo "scenario 20 (WP-561 Ф24): tracked dirt that already equals the target byte-for-byte (point-installed fix) -> replaced"
fresh s20; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-s20"; git clone -q "$ORIGIN" "$pub"; echo fixed > "$pub/a.txt"; commit_in "$pub" "origin fixes a"; git -C "$pub" push -q origin main
echo fixed > "$CANON/a.txt"                                   # someone copied the published bytes into the frozen canon
assert "$(git -C "$CANON" status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "1" "precondition: canon is dirty in git's eyes"
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "0" "exit 0: identical dirt is not a reason to stay frozen"
assert "$(git -C "$CANON" rev-parse HEAD)" "$(git -C "$CANON" rev-parse origin/main)" "HEAD replaced"
assert "$(cat "$CANON/a.txt")" "fixed" "bytes unchanged on disk"
assert "$(git -C "$CANON" status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "0" "tree clean afterwards"
assert "$(printf '%s' "$out" | grep -c 'tolerated identical dirty paths=1')" "1" "report counts the tolerated path"

echo "scenario 21 (WP-561 Ф24): tracked dirt that DIFFERS from the target -> still fail closed, named"
fresh s21; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"; echo mine > "$CANON/a.txt"; H=$(git -C "$CANON" rev-parse HEAD)
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"
assert "$(printf '%s' "$out" | grep -c 'tracked changes differ from target: a.txt')" "1" "refusal names the differing path"

echo "scenario 22 (WP-561 Ф24): STAGED change, even if identical to the target -> fail closed (index is intent, not bytes)"
fresh s22; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-s22"; git clone -q "$ORIGIN" "$pub"; echo fixed > "$pub/a.txt"; commit_in "$pub" "origin fixes a"; git -C "$pub" push -q origin main
echo fixed > "$CANON/a.txt"; git -C "$CANON" add a.txt; H=$(git -C "$CANON" rev-parse HEAD)
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"
assert "$(printf '%s' "$out" | grep -c 'staged changes present in index: a.txt')" "1" "refusal names the staged path"

echo "scenario 23 (WP-561 Ф24): same blob but executable bit differs from the target -> fail closed (mode is part of the entry)"
fresh s23; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-s23"; git clone -q "$ORIGIN" "$pub"; echo fixed > "$pub/a.txt"; commit_in "$pub" "origin fixes a"; git -C "$pub" push -q origin main
echo fixed > "$CANON/a.txt"; chmod +x "$CANON/a.txt"; H=$(git -C "$CANON" rev-parse HEAD)
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"
assert "$(printf '%s' "$out" | grep -c 'tracked changes differ from target: a.txt')" "1" "mode mismatch is a difference"

echo "scenario 24 (WP-561 Ф24): unique local commit only PARTIALLY superseded -> fail closed, first differing path named"
fresh s24
pub="$SANDBOX/pub-s24"; git clone -q "$ORIGIN" "$pub"; echo mine > "$pub/y.txt"; commit_in "$pub" "origin y"; git -C "$pub" push -q origin main
echo mine > "$CANON/y.txt"; echo extra > "$CANON/z.txt"; commit_in "$CANON" "local y plus z"; H=$(git -C "$CANON" rev-parse HEAD)
git -C "$CANON" fetch -q origin
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"
assert "$(printf '%s' "$out" | grep -c 'end state differs from the target: z.txt')" "1" "z.txt (not on origin) is the named difference"

echo "scenario 25 (WP-561 Ф24): tracked file deleted on disk and absent on the target -> tolerated, replaced"
fresh s25; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; C=$(git -C "$CANON" rev-parse HEAD)
republish_on_origin "$CANON" "$C"
pub="$SANDBOX/pub-s25"; git clone -q "$ORIGIN" "$pub"; git -C "$pub" rm -q b.txt; commit_in "$pub" "origin removes b"; git -C "$pub" push -q origin main
rm "$CANON/b.txt"
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "0" "exit 0"
assert "$(git -C "$CANON" rev-parse HEAD)" "$(git -C "$CANON" rev-parse origin/main)" "HEAD replaced"
assert "$(test -e "$CANON/b.txt" && echo present || echo absent)" "absent" "b.txt stays absent"

# --- WP-530 Ф72: ANCESTRAL_PATH criterion -------------------------------------
origin_edit() {  # <tag> <file> <content> -- one commit on origin editing <file> (removing it when content is __RM__)
  local pub="$SANDBOX/pub-$1-$RANDOM"; git clone -q "$ORIGIN" "$pub"
  if [ "$3" = "__RM__" ]; then git -C "$pub" rm -q "$2"; else echo "$3" > "$pub/$2"; fi
  commit_in "$pub" "origin $1 $2"; git -C "$pub" push -q origin main
}
diverged_base() {  # <name> -- canon with one local commit already republished on origin (diverged, otherwise clean)
  fresh "$1"; echo one > "$CANON/b.txt"; commit_in "$CANON" "local"; republish_on_origin "$CANON" "$(git -C "$CANON" rev-parse HEAD)"
}

echo "scenario 26 (Ф72): dirty path holds an EARLIER origin version of the same live path -> ANCESTRAL_PATH, replaced"
diverged_base s26; origin_edit s26a a.txt v2; origin_edit s26b a.txt v3
echo v2 > "$CANON/a.txt"
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
git -C "$CANON" fetch -q origin
assert "$rc" "0" "exit 0"; assert "$(git -C "$CANON" rev-parse HEAD)" "$(git -C "$CANON" rev-parse origin/main)" "HEAD replaced by origin tip"
assert "$(cat "$CANON/a.txt")" "v3" "a.txt now carries the origin tip content"
assert "$(printf '%s' "$out" | grep -c 'ancestral-path dirty=1 commit-paths=0')" "1" "report counts the ancestral dirty path"

echo "scenario 27 (Ф72): local-only commit whose path end state is an EARLIER origin version -> ANCESTRAL_PATH, replaced"
diverged_base s27
pub="$SANDBOX/pub-s27"; git clone -q "$ORIGIN" "$pub"; echo v2 > "$pub/a.txt"; echo extra > "$pub/c.txt"; commit_in "$pub" "origin a v2 plus c"; git -C "$pub" push -q origin main
origin_edit s27b a.txt v3
echo v2 > "$CANON/a.txt"; commit_in "$CANON" "local a v2 only"; U=$(git -C "$CANON" rev-parse HEAD); git -C "$CANON" fetch -q origin
assert "$(GIT_NO_REPLACE_OBJECTS=1 git -C "$CANON" cherry origin/main | grep -c "^+ $U")" "1" "precondition: patch-id cannot see it, so only the path proof can"
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "0" "exit 0"; assert "$(git -C "$CANON" rev-parse HEAD)" "$(git -C "$CANON" rev-parse origin/main)" "HEAD replaced by origin tip"
assert "$(printf '%s' "$out" | grep -c 'ancestral-path dirty=0 commit-paths=1')" "1" "report counts the ancestral commit path"

echo "scenario 28 (Ф72): the path was DELETED on origin -> the old version is not ancestral, fail closed (dirty)"
diverged_base s28; origin_edit s28a a.txt v2; origin_edit s28b a.txt __RM__
echo v2 > "$CANON/a.txt"; H=$(git -C "$CANON" rev-parse HEAD)
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"; assert "$(cat "$CANON/a.txt")" "v2" "dirt preserved"
assert "$(printf '%s' "$out" | grep -c 'tracked changes differ from target: a.txt')" "1" "refusal names the dead path"

echo "scenario 28b (Ф72): the path was deleted on origin -> fail closed (local-only commit)"
diverged_base s28b
pub="$SANDBOX/pub-s28b"; git clone -q "$ORIGIN" "$pub"; echo v2 > "$pub/a.txt"; echo extra > "$pub/c.txt"; commit_in "$pub" "origin a v2 plus c"; git -C "$pub" push -q origin main
origin_edit s28bb a.txt __RM__
echo v2 > "$CANON/a.txt"; commit_in "$CANON" "local a v2 only"; U=$(git -C "$CANON" rev-parse HEAD); H=$U; git -C "$CANON" fetch -q origin
assert "$(GIT_NO_REPLACE_OBJECTS=1 git -C "$CANON" cherry origin/main | grep -c "^+ $U")" "1" "precondition: the commit is not patch-equivalent"
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"
assert "$(printf '%s' "$out" | grep -c 'end state differs from the target: a.txt')" "1" "refusal names the dead path"

echo "scenario 29 (Ф72): canon version never occurred in origin's history of the path -> fail closed (dirty and commit)"
diverged_base s29; origin_edit s29a a.txt v2; origin_edit s29b a.txt v3
echo never > "$CANON/a.txt"; H=$(git -C "$CANON" rev-parse HEAD)
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1 (dirty)"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged (dirty)"
assert "$(printf '%s' "$out" | grep -c 'tracked changes differ from target: a.txt')" "1" "dirty refusal names a.txt"
commit_in "$CANON" "local a never"; H=$(git -C "$CANON" rev-parse HEAD)
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1 (commit)"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged (commit)"
assert "$(printf '%s' "$out" | grep -c 'end state differs from the target: a.txt')" "1" "commit refusal names a.txt"

echo "scenario 30 (Ф72): admissible ancestral path mixed with ONE unique dirty path -> refused as a whole, nothing touched"
diverged_base s30; origin_edit s30a a.txt v2; origin_edit s30b a.txt v3
echo v2 > "$CANON/a.txt"; echo novel >> "$CANON/b.txt"; H=$(git -C "$CANON" rev-parse HEAD)
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"
assert "$(cat "$CANON/a.txt")" "v2" "the admissible path was not rewritten either"
assert "$(tail -1 "$CANON/b.txt")" "novel" "the unique dirt is preserved"
assert "$(printf '%s' "$out" | grep -c 'tracked changes differ from target: b.txt')" "1" "refusal names exactly the unique path"

echo "scenario 31 (Ф72): staged change stays a refusal even when its content is an ancestral version"
diverged_base s31; origin_edit s31a a.txt v2; origin_edit s31b a.txt v3
echo v2 > "$CANON/a.txt"; git -C "$CANON" add a.txt; H=$(git -C "$CANON" rev-parse HEAD)
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"
assert "$(printf '%s' "$out" | grep -c 'staged changes present in index: a.txt')" "1" "staged refusal wins"

# --- WP-530 Ф72 cold review: gitlinks and pathspec magic never count as ancestral ---
GL1=1111111111111111111111111111111111111111; GL2=2222222222222222222222222222222222222222
origin_gitlink() {  # <tag> <path> <sha> [extra-file] -- one origin commit pointing <path> at gitlink <sha> (replacing whatever was there)
  local pub="$SANDBOX/pub-$1-$RANDOM"; git clone -q "$ORIGIN" "$pub"
  git -C "$pub" rm -q --cached --ignore-unmatch "$2"; rm -rf "${pub:?}/$2"
  git -C "$pub" update-index --add --cacheinfo "160000,$3,$2"
  if [ -n "${4:-}" ]; then echo extra > "$pub/$4"; git -C "$pub" add "$4"; fi
  git -C "$pub" -c user.name=o -c user.email=o@o commit -qm "origin gitlink $2 $1"; git -C "$pub" push -q origin main
}

echo "scenario 32a (Ф72): local commit moves a submodule pointer to a value origin once had -> gitlink is never ancestral, fail closed"
diverged_base s32a; origin_gitlink s32aa sub "$GL1" c.txt; origin_gitlink s32ab sub "$GL2"
mkdir "$CANON/sub"   # an empty directory is how git sees an unpopulated submodule: no dirt
git -C "$CANON" update-index --add --cacheinfo "160000,$GL1,sub"; git -C "$CANON" -c user.name=t -c user.email=t@t commit -qm "local sub -> GL1"
U=$(git -C "$CANON" rev-parse HEAD); git -C "$CANON" fetch -q origin
assert "$(GIT_NO_REPLACE_OBJECTS=1 git -C "$CANON" cherry origin/main | grep -c "^+ $U")" "1" "precondition: not patch-equivalent"
assert "$(GIT_NO_REPLACE_OBJECTS=1 git -C "$CANON" ls-tree origin/main sub | cut -c1-6)" "160000" "precondition: sub is a gitlink on the target"
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$U" "HEAD unchanged"
assert "$(printf '%s' "$out" | grep -c 'end state differs from the target: sub')" "1" "refusal names the gitlink path"

echo "scenario 32b (Ф72): path was a file with the canon's content, but is a gitlink on the target now -> fail closed"
diverged_base s32b; origin_edit s32ba a.txt v2; origin_gitlink s32bb a.txt "$GL1"
echo v2 > "$CANON/a.txt"; H=$(git -C "$CANON" rev-parse HEAD)
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$H" "HEAD unchanged"; assert "$(cat "$CANON/a.txt")" "v2" "dirt preserved"
assert "$(printf '%s' "$out" | grep -c 'tracked changes differ from target: a.txt')" "1" "refusal names the path"

echo "scenario 33 (Ф72): path named ':(top)victim' must not be resolved as pathspec magic onto the neighbour 'victim' -> fail closed"
fresh s33; echo v2 > "$CANON/victim"; echo one > "$CANON/b.txt"; commit_in "$CANON" "local victim v2"; republish_on_origin "$CANON" "$(git -C "$CANON" rev-parse HEAD)"
origin_edit s33b victim v3
echo x > "$CANON/:(top)victim"; commit_in "$CANON" "local file literally named :(top)victim"; U=$(git -C "$CANON" rev-parse HEAD); git -C "$CANON" fetch -q origin
assert "$(GIT_NO_REPLACE_OBJECTS=1 git -C "$CANON" ls-tree origin/main -- victim | wc -l | tr -d ' ')" "1" "precondition: the neighbour 'victim' exists on the target"
out=$(bash "$SCRIPT" "$CANON" main 2>&1); rc=$?
assert "$rc" "1" "exit 1"; assert "$(git -C "$CANON" rev-parse HEAD)" "$U" "HEAD unchanged"
assert "$(printf '%s' "$out" | grep -c 'end state differs from the target')" "1" "refused by the end-state proof"

[ "$fails" = 0 ] && echo "PASS: all scenarios" || { echo "FAIL: $fails assertion(s)"; exit 1; }
