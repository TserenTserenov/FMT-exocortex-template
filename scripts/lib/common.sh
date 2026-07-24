#!/usr/bin/env bash
# routing: library  deterministic=true
# lib/common.sh — shared shell helpers for IWE template scripts.
# Source, don't execute: `source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"`
#
# WP-5 Ubuntu-portability audit (2026-07-22, факт #5): 132 scripts, no shared
# library — IWE workspace root was resolved 5 different ways (IWE_WORKSPACE/
# IWE_ROOT/IWE_ROOT_ARG env vars, in varying precedence), governance-repo
# default duplicated with 4 variable names, and Telegram notification existed
# in 3 incompatible conventions (jq-built JSON vs hand-escaped, TG_TOKEN vs
# TELEGRAM_BOT_TOKEN directly) — some alert paths silently dropped messages
# because a caller used a convention no other caller tested. Pilot migration
# (this file) covers day-open-pipeline.sh + day-open-preflight.sh; the other
# ~40 call sites are backlog (WP-5 П4), not blind-swept in one pass.

# iwe_resolve_root [EXPLICIT] — canonical $IWE workspace root.
# Precedence: explicit arg > IWE_WORKSPACE > IWE_ROOT > $HOME/IWE.
# (IWE_ROOT_ARG, a third variant seen in some scripts, is intentionally NOT
# consulted here — callers that need a positional-arg override should pass
# it as EXPLICIT instead of adding a 4th env var to this precedence chain.)
iwe_resolve_root() {
  echo "${1:-${IWE_WORKSPACE:-${IWE_ROOT:-$HOME/IWE}}}"
}

# iwe_sha256 — sha256 of stdin, printed alone (no filename column).
# GNU-first (sha256sum, coreutils — on every Linux, absent on macOS by
# default) then shasum -a 256 (macOS default, also present on Linux only if
# perl's Digest::SHA happens to be installed — WP-5 Ubuntu-audit факт #4:
# 3 callers used bare `shasum -a 256` with no fallback, so a minimal Ubuntu
# install without it silently broke dedup/hash checks depending on it).
# lessons_stat_f_gnu_bsd_fallback_order.md: GNU-first is deliberate — the
# reverse order previously broke Linux checks the same way for `stat -f/-c`.
iwe_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# iwe_resolve_governance_repo [EXPLICIT] — canonical governance-repo name.
iwe_resolve_governance_repo() {
  echo "${1:-${IWE_GOVERNANCE_REPO:-DS-strategy}}"
}

# iwe_scheduler_active — is any IWE role scheduler (strategist/synchronizer/
# extractor) registered AND active with the launcher this OS actually uses?
# Returns 0 (active) / 1 (not active).
#
# WP-5 Ubuntu-audit факт #4: day-open-scaffold.sh checked `launchctl list`
# unconditionally — on Linux launchctl doesn't exist, so the check silently
# saw empty output and reported the scheduler as down (🔴) every single day
# even when the equivalent systemd --user timer was running fine. Two
# independent call sites had ALSO drifted from each other on macOS (one used
# the current per-role launchd labels post-issue-#261, the other still used
# the pre-#261 legacy iwe.scheduler/iwe.feedback labels that don't match any
# plist actually shipped) — this is now the single source of truth for both.
iwe_scheduler_active() {
  if command -v launchctl >/dev/null 2>&1; then
    launchctl list 2>/dev/null | grep -qE "com\.(exocortex\.scheduler|strategist\.morning|strategist\.weekreview|extractor\.inbox-check)"
  elif command -v systemctl >/dev/null 2>&1; then
    # No --all: list-timers without it already restricts to loaded+active
    # units. --all would also match a disabled/stopped timer, reporting a
    # dead scheduler as 🟢.
    systemctl --user list-timers --no-legend 2>/dev/null \
      | grep -qE "iwe-(exocortex-scheduler|strategist-morning|strategist-weekreview|extractor-inbox-check)\.timer"
  else
    return 1
  fi
}

# tg_notify MESSAGE — best-effort Telegram alert via TELEGRAM_BOT_TOKEN/
# TELEGRAM_CHAT_ID. No-op, not an error, when either is unset — most callers
# run in contexts (CI, smoke-tests, fresh installs) that never configure them.
# jq-built payload (not hand-escaped JSON) so a message containing a quote or
# newline can't produce malformed JSON that silently drops the alert.
tg_notify() {
  local msg="$1"
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    local payload
    payload=$(jq -n --arg chat "$TELEGRAM_CHAT_ID" --arg text "$msg" \
      '{chat_id: $chat, text: $text, parse_mode: "Markdown"}')
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" -d "$payload" > /dev/null
  fi
}

# iwe_safe_pull [-C REPO] — git pull --rebase that refuses to silently DROP a
# local commit whose patch is already upstream under a different hash (the
# case a plain `git rebase` mishandles: same change, different SHA, dropped
# without warning). Returns non-zero instead of exiting the calling script —
# callers keep their own `|| abort "..."` / cleanup-trap flow.
#
# Folded in from the formerly-standalone scripts/safe-pull.sh (found with
# zero callers in the same audit, факт #5) rather than deleted: this exact
# failure mode is a live, open risk this pilot's own sessions hit twice on
# 2026-07-23 (see feedback_parallel_agents_shared_workdir_git_race.md), and
# several callers were still doing a naive `git pull --rebase`.
#
# Scope: fast-forward and "only local ahead" cases are handled fully. A true
# two-sided divergence with NO same-patch collision rebases automatically
# (no tty/confirmation gate — day-open-pipeline.sh runs unattended from two
# machines by design, and gating on tty would turn every ordinary divergence
# into a hard pipeline failure; the git-cherry pre-check above IS the safety
# gate, not a human glancing at the output). A collision (the actual unsafe
# case) always returns 2 without touching the branch, tty or not.
iwe_safe_pull() {
  local repo="."
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) repo="$2"; shift 2 ;;
      *) echo "iwe_safe_pull: unknown argument: $1" >&2; return 1 ;;
    esac
  done

  ( set -eu
    cd "$repo"

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "iwe_safe_pull: not inside a git repository ($repo)" >&2
      exit 1
    fi

    branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$branch" = "HEAD" ]; then
      echo "iwe_safe_pull: detached HEAD; refusing to guess a branch" >&2
      exit 1
    fi

    if ! git diff --quiet --ignore-submodules || ! git diff --cached --quiet --ignore-submodules; then
      echo "iwe_safe_pull: working tree or index is dirty; commit or stash first" >&2
      exit 1
    fi

    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
    if [ -z "$upstream" ]; then
      if git show-ref --verify --quiet refs/remotes/origin/main; then
        upstream=origin/main
      elif git show-ref --verify --quiet refs/remotes/origin/master; then
        upstream=origin/master
      else
        echo "iwe_safe_pull: no tracked upstream and no origin/main or origin/master" >&2
        exit 1
      fi
    fi

    remote=${upstream%%/*}
    git fetch --quiet "$remote"

    ahead=$(git rev-list --count "$upstream"..HEAD 2>/dev/null || echo 0)
    behind=$(git rev-list --count HEAD.."$upstream" 2>/dev/null || echo 0)

    if [ "$ahead" -eq 0 ] && [ "$behind" -eq 0 ]; then
      echo "iwe_safe_pull: already up to date with $upstream"
      exit 0
    fi

    if [ "$ahead" -eq 0 ] && [ "$behind" -gt 0 ]; then
      echo "iwe_safe_pull: only upstream ahead ($behind) — fast-forwarding"
      git merge --ff-only "$upstream"
      exit 0
    fi

    if [ "$behind" -eq 0 ] && [ "$ahead" -gt 0 ]; then
      echo "iwe_safe_pull: only local ahead ($ahead) — nothing to pull"
      exit 0
    fi

    # Diverged: both sides have commits.
    already_upstream=$(git cherry "$upstream" HEAD | grep -c '^-' || true)
    if [ "$already_upstream" -gt 0 ]; then
      echo "iwe_safe_pull: $already_upstream local commit(s) already have an equivalent patch in $upstream." >&2
      echo "  A plain rebase would DROP them. Review: git log --cherry-mark --oneline --right-only $upstream...HEAD" >&2
      exit 2
    fi

    orig_pids=()
    while IFS= read -r sha; do
      [ -n "$sha" ] || continue
      orig_pids+=("$(git diff-tree -p "$sha" | git patch-id --stable | awk '{print $1}')")
    done < <(git rev-list --reverse "$upstream"..HEAD)

    echo "iwe_safe_pull: diverged ($ahead local / $behind upstream). Rebasing $branch onto $upstream..."
    if ! git rebase "$upstream"; then
      echo "iwe_safe_pull: rebase stopped (conflict) — resolve manually or 'git rebase --abort'" >&2
      exit 3
    fi

    # Defense-in-depth: the pre-check above catches same-patch-different-hash
    # drops before they happen; this re-check catches any OTHER way the
    # rebase could have lost a commit (e.g. a mid-rebase --skip) rather than
    # trusting a clean `git rebase` exit code alone.
    new_pids=()
    while IFS= read -r sha; do
      [ -n "$sha" ] || continue
      new_pids+=("$(git diff-tree -p "$sha" | git patch-id --stable | awk '{print $1}')")
    done < <(git rev-list --reverse "$upstream"..HEAD)

    # Multiset diff, not membership: two distinct local commits can share a
    # patch-id (identical diff, different message) — a naive "does opid
    # exist anywhere in new_pids" membership check would mark both as
    # present after only one survived. `comm -23` on two sorted streams
    # treats each line occurrence separately, so a genuinely dropped
    # duplicate still shows up as one missing line.
    missing=$(comm -23 <(printf '%s\n' "${orig_pids[@]}" | sort) <(printf '%s\n' "${new_pids[@]}" | sort))
    if [ -n "$missing" ]; then
      echo "iwe_safe_pull: ERROR — local patch(es) lost during rebase:" >&2
      echo "$missing" | sed 's/^/  /' >&2
      echo "iwe_safe_pull: rebase dropped local commit(s). Recover: git rebase --abort, or inspect: git reflog $branch" >&2
      exit 4
    fi

    echo "iwe_safe_pull: rebase complete, ${#orig_pids[@]} local patch(es) verified preserved"
  )
}
