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
#        isolated copy behind with its commits unpushed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SG="$ROOT/scripts/session-guard.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

SANDBOX=$(mktemp -d)
trap 'cd /; rm -rf "$SANDBOX"' EXIT

git_id() { git -C "$1" config user.email test@example.com; git -C "$1" config user.name test; }

# IWE root: its own repo with an origin; the governance repo and the runtime
# directory are nested inside and ignored, as in a real installation.
IWE_ROOT="$SANDBOX/iwe-root"
git init -q --bare --initial-branch=main "$SANDBOX/root-origin.git"
git init -q --initial-branch=main "$IWE_ROOT"
git_id "$IWE_ROOT"
printf 'DS-strategy/\n.iwe-runtime/\n' > "$IWE_ROOT/.gitignore"
echo "root" > "$IWE_ROOT/README.md"
git -C "$IWE_ROOT" add .gitignore README.md
git -C "$IWE_ROOT" commit -qm "seed root"
git -C "$IWE_ROOT" remote add origin "$SANDBOX/root-origin.git"
git -C "$IWE_ROOT" push -qu origin main 2>/dev/null

GOV="$IWE_ROOT/DS-strategy"
git init -q --bare --initial-branch=main "$SANDBOX/gov-origin.git"
git init -q --initial-branch=main "$GOV"
git_id "$GOV"
mkdir -p "$GOV/inbox/WP-485"
echo "card" > "$GOV/inbox/WP-485/WP-485.md"
git -C "$GOV" add inbox
git -C "$GOV" commit -qm "seed gov"
git -C "$GOV" remote add origin "$SANDBOX/gov-origin.git"
git -C "$GOV" push -qu origin main 2>/dev/null

mkdir -p "$IWE_ROOT/.iwe-runtime/sessions"
export IWE_ROOT IWE_GOVERNANCE_REPO=DS-strategy IWE_FROZEN_CANONICAL_PATH=""
unset IWE_SESSIONS_ROOT
AGENT=claude-code
SID="t1577-$$"
export IWE_AGENT="$AGENT" IWE_SESSION_ID="$SID"

[ ! -e "$IWE_ROOT/scripts/isolate-push.sh" ] && [ ! -e "$GOV/scripts/isolate-push.sh" ] \
  || { echo "fixture error: isolate-push.sh must exist only next to session-guard.sh"; exit 1; }

OUT=$(cd "$IWE_ROOT" && bash "$SG" open --wp WP-485 --agent "$AGENT" \
  --task "isolate root" --slug "$SID" --isolate 2>&1)
WT=$(printf '%s\n' "$OUT" | grep -o '{.*}' | tail -1 \
  | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["worktree_path"])' 2>/dev/null)
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  echo "FAIL: open --isolate from the root returned no worktree: $(printf '%s\n' "$OUT" | tail -3 | tr '\n' ' ')"
  exit 1
fi

# --- #1577 ---
if [ ! -e "$WT/inbox/open-sessions.log" ]; then
  pass "#1577 the root copy got no inbox/open-sessions.log"
else
  fail "#1577 open-log line written into the root copy: $WT/inbox/open-sessions.log"
fi
if grep -q "| WP-485 | $AGENT | isolate root" "$GOV/inbox/open-sessions.log" 2>/dev/null; then
  pass "#1577 the open-log line is in the governance repo's log"
else
  fail "#1577 governance log has no line for this open"
fi

# --- #1578 ---
# The session's own work in the root copy.
echo "work" > "$WT/work.txt"
git -C "$WT" add work.txt
git -C "$WT" commit -qm "session work"
WORK_SHA=$(git -C "$WT" rev-parse HEAD)

# The ORZ scaffold stays in the governance repo for a root isolate; close
# wants it staged, and a completed Quick Close card for this slug.
ORZ=$(find "$GOV/sessions" -name "*-$SID.md" -type f 2>/dev/null | head -1)
[ -n "$ORZ" ] || { echo "FAIL: ORZ scaffold not found under $GOV/sessions"; exit 1; }
printf '\n## Итог\n\nСделано.\n' >> "$ORZ"
git -C "$GOV" add -- "${ORZ#"$GOV"/}"
mkdir -p "$GOV/inbox/agent/tasks"
printf -- '---\nprocess_id: quick-close\nstatus: completed\n---\n' > "$GOV/inbox/agent/tasks/RUN-quick-close-$SID.md"

CLOSE_RC=0
# Without IWE_GOVERNANCE_REPO in the environment (the shipped default name):
# isolate-push.sh refuses to run without it, so close must pass its own value.
CLOSE_OUT=$(cd "$IWE_ROOT" && env -u IWE_GOVERNANCE_REPO bash "$SG" close --wp WP-485 --agent "$AGENT" --slug "$SID" 2>&1) || CLOSE_RC=$?
if printf '%s\n' "$CLOSE_OUT" | grep -q "isolate-push.sh не найден"; then
  fail "#1578 close did not find isolate-push.sh next to session-guard.sh"
else
  pass "#1578 close found isolate-push.sh"
fi
if git -C "$SANDBOX/root-origin.git" cat-file -e "$(git -C "$SANDBOX/root-origin.git" rev-parse main 2>/dev/null):work.txt" 2>/dev/null; then
  pass "#1578 the session's commit reached the root's origin"
else
  fail "#1578 origin/main has no work.txt (session commit $WORK_SHA not pushed)"
fi
if [ ! -d "$WT" ] && ! git -C "$IWE_ROOT" worktree list --porcelain | grep -qxF "worktree $WT"; then
  pass "#1578 the isolated copy is removed after close"
else
  fail "#1578 the isolated copy is left behind: $WT"
fi
if [ "$CLOSE_RC" -eq 0 ]; then
  pass "close exits 0"
else
  fail "close rc=$CLOSE_RC: $(printf '%s\n' "$CLOSE_OUT" | tail -3 | tr '\n' ' ')"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: issues #1577 #1578 isolate of the IWE root"
else
  echo "FAIL: issues #1577 #1578 have $FAIL violation(s)"
  exit 1
fi
