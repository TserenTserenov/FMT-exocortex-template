#!/usr/bin/env bash
# test_issue_1577_1578_isolate_root.sh — `open --isolate` started from the IWE
# root (its own git repo, the governance repo nested inside it), then `close`,
# on a stock template layout: isolate-push.sh only next to session-guard.sh.
#
# #1577: the open-log line went into <root copy>/inbox/open-sessions.log, an
#        untracked file in a copy that has no inbox/, instead of the
#        governance repo's log.
# #1578: close looked for isolate-push.sh only in $GOV_REPO/scripts and
#        $IWE_ROOT/scripts, printed "isolate-push.sh не найден" and left the
#        isolated copy behind with its commits unpushed. close also always
#        pushed to `main`, while open isolates from origin's default branch:
#        a root whose default branch is not `main` was never delivered.
# Run once with a `main` root and once with a `trunk` root.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SG="$ROOT/scripts/session-guard.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

SANDBOX=$(mktemp -d)
trap 'cd /; rm -rf "$SANDBOX"' EXIT

git_id() { git -C "$1" config user.email test@example.com; git -C "$1" config user.name test; }

run_case() { # <root default branch>
  local branch="$1" case_dir iwe gov sid out wt orz close_rc close_out
  echo "case: IWE root on '$branch'"
  case_dir="$SANDBOX/$branch"
  mkdir -p "$case_dir"

  # IWE root: its own repo with an origin; the governance repo and the
  # runtime directory are nested inside and ignored, as in a real install.
  iwe="$case_dir/iwe-root"
  git init -q --bare --initial-branch="$branch" "$case_dir/root-origin.git"
  git init -q --initial-branch="$branch" "$iwe"
  git_id "$iwe"
  printf 'DS-strategy/\n.iwe-runtime/\n' > "$iwe/.gitignore"
  echo "root" > "$iwe/README.md"
  git -C "$iwe" add .gitignore README.md
  git -C "$iwe" commit -qm "seed root"
  git -C "$iwe" remote add origin "$case_dir/root-origin.git"
  git -C "$iwe" push -qu origin "$branch" 2>/dev/null
  git -C "$iwe" remote set-head origin -a >/dev/null 2>&1

  gov="$iwe/DS-strategy"
  git init -q --bare --initial-branch=main "$case_dir/gov-origin.git"
  git init -q --initial-branch=main "$gov"
  git_id "$gov"
  mkdir -p "$gov/inbox/WP-485"
  echo "card" > "$gov/inbox/WP-485/WP-485.md"
  git -C "$gov" add inbox
  git -C "$gov" commit -qm "seed gov"
  git -C "$gov" remote add origin "$case_dir/gov-origin.git"
  git -C "$gov" push -qu origin main 2>/dev/null

  mkdir -p "$iwe/.iwe-runtime/sessions"
  sid="t1577-$branch-$$"

  [ ! -e "$iwe/scripts/isolate-push.sh" ] && [ ! -e "$gov/scripts/isolate-push.sh" ] \
    || { echo "fixture error: isolate-push.sh must exist only next to session-guard.sh"; exit 1; }

  out=$(cd "$iwe" && IWE_ROOT="$iwe" IWE_SESSION_ID="$sid" bash "$SG" open --wp WP-485 \
    --agent "$AGENT" --task "isolate root" --slug "$sid" --isolate 2>&1)
  wt=$(printf '%s\n' "$out" | grep -o '{.*}' | tail -1 \
    | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["worktree_path"])' 2>/dev/null)
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    fail "open --isolate from the root returned no worktree: $(printf '%s\n' "$out" | tail -3 | tr '\n' ' ')"
    return
  fi

  # --- #1577 ---
  if [ ! -e "$wt/inbox/open-sessions.log" ]; then
    pass "#1577 the root copy got no inbox/open-sessions.log"
  else
    fail "#1577 open-log line written into the root copy: $wt/inbox/open-sessions.log"
  fi
  if grep -q "| WP-485 | $AGENT | isolate root" "$gov/inbox/open-sessions.log" 2>/dev/null; then
    pass "#1577 the open-log line is in the governance repo's log"
  else
    fail "#1577 governance log has no line for this open"
  fi

  # --- #1578 ---
  echo "work" > "$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" commit -qm "session work"

  # The ORZ scaffold stays in the governance repo for a root isolate; close
  # wants it staged, and a completed Quick Close card for this slug.
  orz=$(find "$gov/sessions" -name "*-$sid.md" -type f 2>/dev/null | head -1)
  if [ -z "$orz" ]; then
    fail "ORZ scaffold not found under $gov/sessions"
    return
  fi
  printf '\n## Итог\n\nСделано.\n' >> "$orz"
  git -C "$gov" add -- "${orz#"$gov"/}"
  mkdir -p "$gov/inbox/agent/tasks"
  printf -- '---\nprocess_id: quick-close\nstatus: completed\n---\n' > "$gov/inbox/agent/tasks/RUN-quick-close-$sid.md"

  # Without IWE_GOVERNANCE_REPO in the environment (the shipped default name):
  # isolate-push.sh refuses to run without it, so close must pass its own value.
  close_rc=0
  close_out=$(cd "$iwe" && env -u IWE_GOVERNANCE_REPO IWE_ROOT="$iwe" IWE_SESSION_ID="$sid" \
    bash "$SG" close --wp WP-485 --agent "$AGENT" --slug "$sid" 2>&1) || close_rc=$?
  if printf '%s\n' "$close_out" | grep -q "isolate-push.sh не найден"; then
    fail "#1578 close did not find isolate-push.sh next to session-guard.sh"
  else
    pass "#1578 close found isolate-push.sh"
  fi
  if git -C "$case_dir/root-origin.git" cat-file -e "refs/heads/$branch:work.txt" 2>/dev/null; then
    pass "#1578 the session's commit reached origin/$branch"
  else
    fail "#1578 origin/$branch has no work.txt: $(printf '%s\n' "$close_out" | grep -i 'isolate' | tail -2 | tr '\n' ' ')"
  fi
  if git -C "$case_dir/root-origin.git" rev-parse -q --verify refs/heads/main >/dev/null && [ "$branch" != main ]; then
    fail "#1578 close created a stray 'main' on a '$branch' origin"
  fi
  if [ ! -d "$wt" ] && ! git -C "$iwe" worktree list --porcelain | grep -qxF "worktree $wt"; then
    pass "#1578 the isolated copy is removed after close"
  else
    fail "#1578 the isolated copy is left behind: $wt"
  fi
  if [ "$close_rc" -eq 0 ]; then
    pass "close exits 0"
  else
    fail "close rc=$close_rc: $(printf '%s\n' "$close_out" | tail -3 | tr '\n' ' ')"
  fi
}

export IWE_GOVERNANCE_REPO=DS-strategy IWE_FROZEN_CANONICAL_PATH=""
unset IWE_SESSIONS_ROOT
AGENT=claude-code
export IWE_AGENT="$AGENT"

run_case main
run_case trunk

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: issues #1577 #1578 isolate of the IWE root"
else
  echo "FAIL: issues #1577 #1578 have $FAIL violation(s)"
  exit 1
fi
