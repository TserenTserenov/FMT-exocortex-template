#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# git-dirty-guard.sh — protects a repo's periodic pull from a dirty working tree.
#
# WP-484 (2026-07-19). Root cause of the recurring tsekh-1 cleanup: sync-strategy-files.sh
# (and the fleeting-notes sync) write files straight from origin's blobs without ever
# committing, so ${IWE_GOVERNANCE_REPO:-DS-strategy}'s working tree on the server accumulates "dirty" entries
# whose content is byte-identical to origin — not real work, just a stale local HEAD.
# `git pull --rebase` refuses to run on a dirty tree, so local HEAD never catches up, and
# any guard relying on local git log (e.g. day-open-pipeline.sh step 1.1) goes blind to
# commits origin already has — the day this was written, the server was found 33 commits
# behind with 21 dirty tracked files, all 21 byte-identical to origin (verified live).
#
# This script tells the two cases apart before a caller attempts pull/rebase:
#   - every dirty TRACKED file byte-identical to origin/<branch>  → stale mirror, safe to
#     `git reset --hard origin/<branch>` (untracked files are never touched — reset --hard
#     doesn't remove them, and they're exactly the shape of real new work found live on
#     2026-07-18/19: WP-406 Ф22, WP-455 Ф11, WP-493 Ф7, none yet on origin).
#   - any dirty tracked file DIFFERS from origin/<branch>          → real uncommitted work,
#     never touched automatically — loud Telegram alert instead, caller must skip pull
#     this round rather than attempt a doomed rebase.
#
# Usage: git-dirty-guard.sh <repo-path> [branch]
# Exit codes: 0 = repo clean, or safely self-healed — caller may proceed with pull.
#             1 = real uncommitted work present, or repo mid-rebase/merge — caller must
#                 NOT pull/rebase this round.
#             2 = usage/repo error.

set -uo pipefail

REPO="${1:?usage: git-dirty-guard.sh <repo-path> [branch]}"
BRANCH="${2:-}"

AIST_ENV="$HOME/.config/aist/env"
[ -f "$AIST_ENV" ] && { set -a; source "$AIST_ENV"; set +a; }

tg_alert() {
  local msg="$1"
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] || return 0
  curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=$msg" > /dev/null || true
}

cd "$REPO" 2>/dev/null || { echo "git-dirty-guard: cannot cd to $REPO" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "git-dirty-guard: $REPO is not a git repo" >&2; exit 2; }

GIT_DIR=$(git rev-parse --git-dir)

# A repo mid-rebase/merge is a different, more serious class of problem (see
# lessons_stale_rebase_merge_recovery.md) — resetting through it would compound the
# mess, not clean it up. Bail out loudly and leave it for manual recovery.
if [ -d "$GIT_DIR/rebase-merge" ] || [ -d "$GIT_DIR/rebase-apply" ] || [ -f "$GIT_DIR/MERGE_HEAD" ]; then
  echo "git-dirty-guard: $REPO is mid-rebase/merge — refusing to touch, needs manual recovery" >&2
  tg_alert "🚨 git-dirty-guard: $REPO застрял в rebase/merge — не тронул, нужно ручное восстановление."
  exit 1
fi

[ -n "$BRANCH" ] || BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  echo "git-dirty-guard: detached HEAD in $REPO, refusing" >&2
  exit 2
fi

# Serialize against a concurrent guard run on the same repo. ${IWE_GOVERNANCE_REPO:-DS-strategy} is
# deliberately excluded from the shared .iwe-git-ops.lock (see systemd-timers.nix
# pullScript comment) so this gets its own lock, scoped to .git/. mkdir is used
# instead of flock — atomic on POSIX and, unlike flock, available on macOS out of
# the box (this guard runs on both the Mac and the Linux server).
LOCK_DIR="$GIT_DIR/dirty-guard.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "git-dirty-guard: lock busy, skipping" >&2
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

if ! git fetch origin "$BRANCH" --quiet 2>/dev/null; then
  echo "git-dirty-guard: fetch failed (offline?) — nothing to check"
  exit 0
fi

if ! git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  echo "git-dirty-guard: no origin/$BRANCH — nothing to check"
  exit 0
fi

# Collect tracked dirty paths (staged or unstaged). Untracked (`??`) is skipped on
# purpose — reset --hard never removes it, and treating it as dirty-to-heal would risk
# discarding genuinely new work.
TRACKED_DIRTY=()
while IFS= read -r -d '' entry; do
  status="${entry:0:2}"
  rest="${entry:3}"
  case "$status" in
    "??") continue ;;
    R*|C*)
      # -z emits "new\0old\0" for renames/copies — `rest` is already the current
      # (destination) path, the one worth diffing against origin. Consume and
      # discard the second field (the pre-rename source path).
      IFS= read -r -d '' _origpath
      TRACKED_DIRTY+=("$rest")
      ;;
    *)
      TRACKED_DIRTY+=("$rest")
      ;;
  esac
done < <(git status --porcelain -z)

if [ "${#TRACKED_DIRTY[@]}" -eq 0 ]; then
  echo "git-dirty-guard: clean (or untracked-only) — nothing to heal"
  exit 0
fi

DIFFERING=()
for f in "${TRACKED_DIRTY[@]}"; do
  if ! git diff --quiet "origin/$BRANCH" -- "$f" 2>/dev/null; then
    DIFFERING+=("$f")
  fi
done

# Cold-review finding (2026-07-19), confirmed live: dirty-file content matching origin is
# NOT sufficient to make `git reset --hard` safe. Reset also moves the branch ref itself,
# so an unpushed local commit — the exact call pattern strategist.sh routes through this
# guard for — gets silently orphaned (and any file unique to it deleted) even though every
# currently-dirty file happened to be a harmless stale mirror. Ancestry, not dirty-file
# content, is the real safety condition for a hard reset.
UNPUSHED=false
git merge-base --is-ancestor HEAD "origin/$BRANCH" 2>/dev/null || UNPUSHED=true

if [ "${#DIFFERING[@]}" -eq 0 ] && [ "$UNPUSHED" = "false" ]; then
  echo "git-dirty-guard: ${#TRACKED_DIRTY[@]} dirty file(s), all byte-identical to origin/$BRANCH — stale mirror, self-healing"
  git reset --hard "origin/$BRANCH" >/dev/null
  tg_alert "🩹 git-dirty-guard: $REPO самовосстановился (${#TRACKED_DIRTY[@]} устаревших файлов сброшено на origin/$BRANCH, содержимое не менялось)."
  exit 0
fi

if [ "$UNPUSHED" = "true" ]; then
  echo "git-dirty-guard: HEAD has commit(s) origin/$BRANCH doesn't have — self-heal would orphan them, not touching" >&2
  tg_alert "🚨 git-dirty-guard: $REPO — есть незапушенные коммиты, self-heal пропущен (не тронул). Нужен pull/push вручную."
  exit 1
fi

echo "git-dirty-guard: ${#DIFFERING[@]} file(s) genuinely differ from origin/$BRANCH — NOT touching, real work present:" >&2
printf '  %s\n' "${DIFFERING[@]}" >&2
LIST=$(printf '%s, ' "${DIFFERING[@]:0:5}")
LIST="${LIST%, }"
tg_alert "🚨 git-dirty-guard: $REPO — ${#DIFFERING[@]} файл(ов) с реальными несохранёнными правками (не тронул): $LIST. Pull пропущен, нужна ручная проверка."
exit 1
