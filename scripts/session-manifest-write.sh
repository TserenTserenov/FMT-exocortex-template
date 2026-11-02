#!/bin/bash
# session-manifest-write.sh — writer of the session attest manifest (F1, consensus
# of peer session 2026-08-21-02-day-close-anomaly-classes, WP-484).
#
# Why: a catch-up close of an already-pushed session must not commit/push
# again. commit-push.sh got an early exit that proves
# "everything is on remote" by an immutable manifest, not by the caller's word.
# This script is the only writer of such a manifest.
#
# Two-phase semantics (consensus, turn 6): called AFTER the payload commits
# (report.md and all session artifacts are already committed in the branch), BEFORE isolate-push.
# The manifest = a separate attest commit containing ONLY session-manifest.json;
# its own OID is not included in `commits` (circularity removed by the two-phase approach).
#
# Usage: session-manifest-write.sh <session_worktree> <session_id> [target_branch=main]
# Exit: 0 — attest commit created; 1 — precondition violated (diagnostics in stderr).

set -euo pipefail

WORKTREE="${1:-}"
SESSION_ID="${2:-}"
TARGET_BRANCH="${3:-main}"

usage() {
  echo "Использование: session-manifest-write.sh <session_worktree> <session_id> [target_branch]" >&2
  exit 1
}
[ -n "$WORKTREE" ] && [ -n "$SESSION_ID" ] || usage
[ -d "$WORKTREE" ] || { echo "session-manifest-write: нет каталога $WORKTREE" >&2; exit 1; }

MONTH="${SESSION_ID:0:7}"
DAY="${SESSION_ID:8:2}"
# WP-526 Phase 2: $WORKTREE is expected to be the MC-sessions checkout now,
# not a DS-strategy worktree -- session content lives at its root
# (the transfer stripped the old sessions/ prefix), not under sessions/.
SESSION_DIR="$WORKTREE/$MONTH/$DAY/$SESSION_ID"
META="$SESSION_DIR/meta.yaml"
REPORT="$SESSION_DIR/report.md"

[ -f "$META" ] || { echo "session-manifest-write: нет $META" >&2; exit 1; }
[ -f "$REPORT" ] || { echo "session-manifest-write: нет $REPORT — payload ещё не готов" >&2; exit 1; }
grep -q "session_id: \"$SESSION_ID\"" "$META" || grep -q "session_id: $SESSION_ID" "$META" \
  || { echo "session-manifest-write: meta.yaml не про эту сессию ($SESSION_ID)" >&2; exit 1; }

# WP-530/537 Phase 22 (05.09, ArchGate + cold review): $WORKTREE is a shared checkout of
# MC-sessions, shared by ALL parallel sessions (WP-526 Phase 2), not an
# isolated copy for this session. An unconditional `git status --porcelain`
# on the whole tree sees the dirt of ANY neighboring session and falsely refuses
# to close fully synchronized work — a live symptom of WP-537
# "finding 02.09/05.09". The scope is only this session's directory; the path
# ($MONTH/$DAY/$SESSION_ID) is unique by construction (date+slug), so
# narrowing the pathspec cannot accidentally capture someone else's work.
SESSION_PATH="$MONTH/$DAY/$SESSION_ID"
if [ -n "$(git -C "$WORKTREE" status --porcelain -- "$SESSION_PATH")" ]; then
  echo "session-manifest-write: каталог сессии грязный — сначала закоммить все артефакты сессии" >&2
  git -C "$WORKTREE" status --short -- "$SESSION_PATH" >&2
  exit 1
fi

git -C "$WORKTREE" fetch origin "$TARGET_BRANCH" --quiet 2>/dev/null || true
PAYLOAD_COMMITS=$(git -C "$WORKTREE" rev-list --reverse "origin/$TARGET_BRANCH..HEAD" -- "$SESSION_PATH" 2>/dev/null || echo "")
[ -n "$PAYLOAD_COMMITS" ] || { echo "session-manifest-write: нет payload-коммитов, трогающих каталог сессии (HEAD не опережает origin/$TARGET_BRANCH по $SESSION_PATH)" >&2; exit 1; }

# Cold review (05.09): HEAD may be ahead of origin by commits that
# do not touch $SESSION_PATH, -- the manifest quietly does not account for them, while
# downstream isolate-push delivers the payload exactly by the patch_ids from here.
# Not a refusal (it may be a regular commit of another parallel session on the
# same shared branch, not our concern) -- but a visible warn, not silence.
ALL_AHEAD_COUNT=$(git -C "$WORKTREE" rev-list --count "origin/$TARGET_BRANCH..HEAD" 2>/dev/null || echo 0)
SCOPED_AHEAD_COUNT=$(wc -l <<< "$PAYLOAD_COMMITS" | tr -d ' ')
if [ "$ALL_AHEAD_COUNT" -gt "$SCOPED_AHEAD_COUNT" ]; then
  echo "session-manifest-write: WARN -- HEAD опережает origin/$TARGET_BRANCH на $ALL_AHEAD_COUNT коммитов, из них $SCOPED_AHEAD_COUNT трогают $SESSION_PATH; остальные в манифест не войдут (чужая работа на общей ветке или собственный коммит вне каталога сессии)" >&2
fi

REPORT_BLOB=$(git -C "$WORKTREE" hash-object "$MONTH/$DAY/$SESSION_ID/report.md")
REPORT_REL="$MONTH/$DAY/$SESSION_ID/report.md"
MANIFEST_REL="$MONTH/$DAY/$SESSION_ID/session-manifest.json"

# review-01 Critical-3: TOCTOU between the cleanliness check and the commit. The whole block
# "status → write → add → verify → commit" is under one lock file; before commit
# we prove that the only change is the manifest itself.
# review-01 Critical-3 + review-02: the whole block "status → write → add → verify →
# commit" is under a mandatory lock; without a working locking mechanism — fail
# closed (continuing without serialization would bring the whole TOCTOU window back).
# the lock file is from the absolute git-common-dir (rev-parse may return
# a relative path, otherwise opening would fail when run outside $WORKTREE).
GIT_COMMON=$(git -C "$WORKTREE" rev-parse --git-common-dir)
case "$GIT_COMMON" in
  /*) : ;;
  *) GIT_COMMON="$WORKTREE/$GIT_COMMON" ;;
esac
MANIFEST_LOCK="$GIT_COMMON/session-manifest-write.lock"
exec 8>"$MANIFEST_LOCK"
if command -v flock >/dev/null 2>&1; then
  flock 8 || { echo "session-manifest-write: lock $MANIFEST_LOCK не взят — отказ" >&2; exit 1; }
elif command -v shlock >/dev/null 2>&1; then
  shlock -f "$MANIFEST_LOCK.pid" -p $$ || { echo "session-manifest-write: shlock не взят — отказ" >&2; exit 1; }
  trap 'rm -f "$MANIFEST_LOCK.pid"' EXIT
else
  # The last portable mechanism: mkdir is atomic on all target OSes.
  if ! mkdir "$MANIFEST_LOCK.d" 2>/dev/null; then
    echo "session-manifest-write: ни flock, ни shlock, ни mkdir-lock недоступны — отказ (fail closed)" >&2
    exit 1
  fi
  trap 'rm -rf "$MANIFEST_LOCK.d"' EXIT
fi

# Re-check inside the critical section: during the lock wait window the tree
# may have changed. The same session scope as the first check above.
if [ -n "$(git -C "$WORKTREE" status --porcelain -- "$SESSION_PATH")" ]; then
  echo "session-manifest-write: каталог сессии стал грязным к моменту записи — отказ" >&2
  exit 1
fi

python3 - "$SESSION_DIR/session-manifest.json" "$SESSION_ID" "$REPORT_BLOB" "$REPORT_REL" "$WORKTREE" "$PAYLOAD_COMMITS" <<'PYEOF'
import json, sys, time, subprocess
path, session_id, blob, report_rel, worktree, commits = sys.argv[1:7]
oids = commits.split()
# Консенсус ход 7: isolate-push доставляет через cherry-pick, который
# переписывает OID — payload доказывается по стабильному patch-id (контентный
# адрес), OID-проверка остаётся для прямых push.
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

# Coverage proof: exactly one path is staged — the manifest; the worktree outside it
# is clean. Otherwise we delete the uncommitted manifest and fail.
STAGED=$(git -C "$WORKTREE" diff --cached --name-only)
REST=$(git -C "$WORKTREE" status --porcelain -- "$SESSION_PATH" ":!$MANIFEST_REL")
if [ "$STAGED" != "$MANIFEST_REL" ] || [ -n "$REST" ]; then
  git -C "$WORKTREE" reset -q -- "$MANIFEST_REL" 2>/dev/null || true
  rm -f "$SESSION_DIR/session-manifest.json"
  echo "session-manifest-write: к моменту коммита изменилось что-то кроме манифеста — манифест удалён, отказ" >&2
  exit 1
fi

git -C "$WORKTREE" commit -q -m "chore(session): attest manifest $SESSION_ID" -- "$MANIFEST_REL"

# This commit goes directly through git, not through Write/Edit, so the session-guard
# scope gate will not see the path without explicit registration. `--slug` without
# `--wp` is enough (select_semaphore resolves by slug). We do not fail the attest
# itself on a note-file refusal -- the commit is already made, a rollback is worse than a warning.
# The path is absolute ($SESSION_DIR, not the relative $MANIFEST_REL): note-file
# resolves the repository by cwd when the path is relative, and the cwd of the
# script's caller does not have to match $WORKTREE.
GUARD="${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh"
[ -x "$GUARD" ] || GUARD="$HOME/IWE/scripts/session-guard.sh"
if ! NOTE_ERR=$(bash "$GUARD" note-file "$SESSION_DIR/session-manifest.json" --slug "$SESSION_ID" 2>&1); then
  echo "session-manifest-write: WARN -- note-file для $MANIFEST_REL не прошёл ($NOTE_ERR); attest-коммит сделан, но close откажет без повторной регистрации" >&2
fi

echo "session-manifest-write: attest-коммит создан ($MANIFEST_REL, payload: $(echo "$PAYLOAD_COMMITS" | wc -l | tr -d ' ') коммитов) — дальше isolate-push"
