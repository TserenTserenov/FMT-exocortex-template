#!/bin/bash
# session-manifest-write.sh — writer attest-session manifest (F1, consensus
# peer-session 2026-08-21-02-day-close-anomaly-classes, WP-484).
#
# Purpose: a catch-up close of an already pushed session must not repeat
# commit/push. commit-push.sh received an early exit, which proves
# «everything on remote» via the immutable manifest, and not on the word of the caller.
# This script — the sole writer of this manifest.
#
# Two-phase semantics (consensus, step 6): is called AFTER payload-commits
# (report.md and all session artifacts are already committed in the branch), BEFORE isolate-push.
# Manifest = a separate attest-commit, containing ONLY session-manifest.json;
# its own OID in `commits` is not included (circularity eliminated by two-phase design).
#
# Usage: session-manifest-write.sh <session_worktree> <session_id> [target_branch=main]
# Exit: 0 — attest-commit created; 1 — precondition violated (diagnostics in stderr).

set -euo pipefail

WORKTREE="${1:-}"
SESSION_ID="${2:-}"
TARGET_BRANCH="${3:-main}"

usage() {
  echo "Usage: session-manifest-write.sh <session_worktree> <session_id> [target_branch]" >&2
  exit 1
}
[ -n "$WORKTREE" ] && [ -n "$SESSION_ID" ] || usage
[ -d "$WORKTREE" ] || { echo "session-manifest-write: directory not found $WORKTREE" >&2; exit 1; }

MONTH="${SESSION_ID:0:7}"
DAY="${SESSION_ID:8:2}"
# WP-526 Phase2: $WORKTREE is expected to be the MC-sessions checkout now,
# not a DS-strategy worktree -- session content lives at its root
# (the transfer stripped the old sessions/ prefix), not under sessions/.
SESSION_DIR="$WORKTREE/$MONTH/$DAY/$SESSION_ID"
META="$SESSION_DIR/meta.yaml"
REPORT="$SESSION_DIR/report.md"

[ -f "$META" ] || { echo "session-manifest-write: not found $META" >&2; exit 1; }
[ -f "$REPORT" ] || { echo "session-manifest-write: not found $REPORT — payload not ready yet" >&2; exit 1; }
grep -q "session_id: \"$SESSION_ID\"" "$META" || grep -q "session_id: $SESSION_ID" "$META" \
  || { echo "session-manifest-write: meta.yaml does not belong to this session ($SESSION_ID)" >&2; exit 1; }

# WP-530/537 Phase22 (05.09, ArchGate + cold review): $WORKTREE — shared checkout
# MC-sessions, shared by ALL parallel sessions (WP-526 Phase2), not
# an isolated copy for this session. An unconditional `git status --porcelain`
# applied to the entire tree sees dirt from ANY neighboring session and falsely refuses
# closing fully synchronized work — live symptom of WP-537
# «finding 02.09/05.09». Scope — only the directory of this session; path
# ($MONTH/$DAY/$SESSION_ID) unique by design (date+slug), therefore
# narrowing the pathspec pathspec cannot accidentally capture work belonging to another session.
SESSION_PATH="$MONTH/$DAY/$SESSION_ID"
if [ -n "$(git -C "$WORKTREE" status --porcelain -- "$SESSION_PATH")" ]; then
  echo "session-manifest-write: session directory is dirty — commit all session artifacts first" >&2
  git -C "$WORKTREE" status --short -- "$SESSION_PATH" >&2
  exit 1
fi

git -C "$WORKTREE" fetch origin "$TARGET_BRANCH" --quiet 2>/dev/null || true
PAYLOAD_COMMITS=$(git -C "$WORKTREE" rev-list --reverse "origin/$TARGET_BRANCH..HEAD" -- "$SESSION_PATH" 2>/dev/null || echo "")
[ -n "$PAYLOAD_COMMITS" ] || { echo "session-manifest-write: no payload-commits, touching the session directory (HEAD does not ahead of origin/$TARGET_BRANCH for $SESSION_PATH)" >&2; exit 1; }

# Cold review (05.09): HEAD may be ahead of origin with commits that origin commits, that
# $SESSION_PATH do not touch, -- the manifest silently ignores them, and
# downstream isolate-push delivers payload exactly via patch_ids from here.
# Not a failure (this may be a normal commit from another parallel session on the same
# shared branch, not our concern) -- but a visible warn, not silence.
ALL_AHEAD_COUNT=$(git -C "$WORKTREE" rev-list --count "origin/$TARGET_BRANCH..HEAD" 2>/dev/null || echo 0)
SCOPED_AHEAD_COUNT=$(wc -l <<< "$PAYLOAD_COMMITS" | tr -d ' ')
if [ "$ALL_AHEAD_COUNT" -gt "$SCOPED_AHEAD_COUNT" ]; then
  echo "session-manifest-write: WARN -- HEAD is ahead of origin/$TARGET_BRANCH by $ALL_AHEAD_COUNT commits, of which $SCOPED_AHEAD_COUNT touch $SESSION_PATH; the rest will not be included in the manifest (work from another session on the shared branch or an own commit outside the session directory)" >&2
fi

REPORT_BLOB=$(git -C "$WORKTREE" hash-object "$MONTH/$DAY/$SESSION_ID/report.md")
REPORT_REL="$MONTH/$DAY/$SESSION_ID/report.md"
MANIFEST_REL="$MONTH/$DAY/$SESSION_ID/session-manifest.json"

# review-01 Critical-3: TOCTOU between the cleanliness check and the commit. The entire block
# «status → write → add → verify → commit» under a single lock-file; before commit
# we prove, that the only change is — the manifest itself.
# review-01 Critical-3 + review-02: the entire block «status → write → add → verify →
# commit» under a mandatory lock lock; without a working locking mechanism — fail
# closed (continuing without serialization would have restored the TOCTOU-window entirely).
# lock-file — from the absolute git-common-dir (rev-parse may return
# relative path, otherwise opening will fail when run outside $WORKTREE).
GIT_COMMON=$(git -C "$WORKTREE" rev-parse --git-common-dir)
case "$GIT_COMMON" in
  /*) : ;;
  *) GIT_COMMON="$WORKTREE/$GIT_COMMON" ;;
esac
MANIFEST_LOCK="$GIT_COMMON/session-manifest-write.lock"
exec 8>"$MANIFEST_LOCK"
if command -v flock >/dev/null 2>&1; then
  flock 8 || { echo "session-manifest-write: lock $MANIFEST_LOCK not acquired — aborting" >&2; exit 1; }
elif command -v shlock >/dev/null 2>&1; then
  shlock -f "$MANIFEST_LOCK.pid" -p $$ || { echo "session-manifest-write: shlock not acquired — aborting" >&2; exit 1; }
  trap 'rm -f "$MANIFEST_LOCK.pid"' EXIT
else
  # Last portable mechanism: mkdir mkdir is atomic on all target operating systems.
  if ! mkdir "$MANIFEST_LOCK.d" 2>/dev/null; then
    echo "session-manifest-write: neither flock, nor shlock, nor mkdir-lock are available — aborting (fail closed)" >&2
    exit 1
  fi
  trap 'rm -rf "$MANIFEST_LOCK.d"' EXIT
fi

# Re-check inside the critical section: during the lock wait window lock the working tree
# may have changed. Same session scope as the first check above, as the first check above.
if [ -n "$(git -C "$WORKTREE" status --porcelain -- "$SESSION_PATH")" ]; then
  echo "session-manifest-write: session directory became dirty by the time of writing — aborting" >&2
  exit 1
fi

python3 - "$SESSION_DIR/session-manifest.json" "$SESSION_ID" "$REPORT_BLOB" "$REPORT_REL" "$WORKTREE" "$PAYLOAD_COMMITS" <<'PYEOF'
import json, sys, time, subprocess
path, session_id, blob, report_rel, worktree, commits = sys.argv[1:7]
oids = commits.split()
# Consensus step 7: isolate-push delivers via cherry-pick, which
# rewrites OID — payload is proven by stable patch-id (content-based
# address), OID-check remains for direct push.
patch_ids = []
for oid in oids:
    show = subprocess.run(["git", "-C", worktree, "show", oid], capture_output=True, check=True)
    pid = subprocess.run(["git", "-C", worktree, "patch-id", "--stable"], input=show.stdout,
                         capture_output=True, check=True)
    patch_ids.append(pid.stdout.decode().split()[0])
json.dump({
    "session_id": session_id,
    "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "commits": oids,
    "patch_ids": patch_ids,
    "report_path": report_rel,
    "report_blob_sha": blob,
}, open(path, "w"), indent=2, ensure_ascii=False)
PYEOF

git -C "$WORKTREE" add -- "$MANIFEST_REL"

# Coverage proof: staged exactly one path staged — manifest; worktree beyond it
# is clean. Otherwise remove the uncommitted manifest and fail.
STAGED=$(git -C "$WORKTREE" diff --cached --name-only)
REST=$(git -C "$WORKTREE" status --porcelain -- "$SESSION_PATH" ":!$MANIFEST_REL")
if [ "$STAGED" != "$MANIFEST_REL" ] || [ -n "$REST" ]; then
  git -C "$WORKTREE" reset -q -- "$MANIFEST_REL" 2>/dev/null || true
  rm -f "$SESSION_DIR/session-manifest.json"
  echo "session-manifest-write: by commit time something changed other than-the manifest — manifest removed, aborting" >&2
  exit 1
fi

git -C "$WORKTREE" commit -q -m "chore(session): attest manifest $SESSION_ID" -- "$MANIFEST_REL"

# This commit goes directly through git, not through Write/Edit, therefore scope
# gate session-guard will not see the path without explicit registration. `--slug` without
# `--wp` is sufficient (select_semaphore resolves by slug). Do not fail
# attest on note-file failure note-file -- commit is already made, rollback is worse than a warning.
# Path -- absolute ($SESSION_DIR, not relative $MANIFEST_REL): note-file
# resolves the repository by cwd, when the path is relative, and cwd of the calling
# script process is not required to match $WORKTREE.
GUARD="${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh"
[ -x "$GUARD" ] || GUARD="$HOME/IWE/scripts/session-guard.sh"
if ! NOTE_ERR=$(bash "$GUARD" note-file "$SESSION_DIR/session-manifest.json" --slug "$SESSION_ID" 2>&1); then
  echo "session-manifest-write: WARN -- note-file for $MANIFEST_REL did not pass ($NOTE_ERR); attest-commit made, but close close will fail without re-registration" >&2
fi

echo "session-manifest-write: attest-commit created ($MANIFEST_REL, payload: $(echo "$PAYLOAD_COMMITS" | wc -l | tr -d ' ') commits) — next isolate-push"
