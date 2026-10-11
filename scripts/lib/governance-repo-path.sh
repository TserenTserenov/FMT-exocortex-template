# shellcheck shell=bash
# governance-repo-path.sh — single point of truth for resolving which working
# copy of the governance repo (DS-strategy) a script should read/write.
# (WP-537, peer-session 2026-08-17-06-wp530-parallel-session-architecture,
# consensus with Kimi: two functions with different semantics, not one —
# a future tip-snapshot audit (WP-535 "осталось") needs both paths at once,
# a single resolver would have to be reworked or bypassed for that case.)
# Source, don't execute: `. "$(dirname "${BASH_SOURCE[0]}")/lib/governance-repo-path.sh"`
# Sourced, not executed: declares functions only, no shebang needed
# (smoke-clean-env.sh exemption, issue #1013 — same marker as peer-adapter-common.sh).
#
# Root cause this replaces: 15+ scripts building "$IWE_ROOT/DS-strategy" or
# "$IWE_ROOT/$GOV_REPO" by hand, none of them asking whether the calling
# process is actually inside an isolated git worktree. session-guard.sh itself
# already carries a comment (line ~1779) acknowledging the pattern as known,
# unfixed debt. Confirmed live: session-index.sh writing sessions/00-index.md
# into the canonical checkout while the calling session ran from a worktree
# (WP-537 Находка 1) and close_obligation.py's cards_dir walking upward past
# the intended repo into {{WORKSPACE_DIR}} itself (WP-484, bug-2026-08-14... cd-restores-
# to-parent class).

# resolve_active_worktree — prints the governance repo path a MUTATING
# operation should write to: the worktree the calling process is actually
# running in, if any; the canonical checkout otherwise. Never walks upward
# past the immediate git root (that upward walk is what caused the {{WORKSPACE_DIR}}
# false-positive above) — it only ever trusts `git rev-parse --show-toplevel`
# run from $PWD, nothing more.
resolve_active_worktree() {
  local root
  if root=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$root" ]; then
    echo "$root"
    return 0
  fi
  # $PWD isn't inside any git tree (e.g. a cron job launched from $HOME) —
  # fall back to the canonical path, same rule the individual scripts used
  # before extraction.
  resolve_canonical_checkout
}

# resolve_canonical_checkout — prints the ONE canonical governance repo path,
# ignoring cwd entirely. For read-side operations that must compare against
# or aggregate the authoritative copy regardless of which worktree the caller
# happens to be sitting in (day/week/month-close preconditions, drift checks,
# the not-yet-built WP-535 tip-snapshot audit). Do not call this from a
# mutating write path — it will happily point a worktree-based session at the
# canonical checkout and reintroduce the exact class of bug this file exists
# to close.
resolve_canonical_checkout() {
  local root="${IWE_ROOT:-$HOME/IWE}"
  local repo="${IWE_GOVERNANCE_REPO:-DS-strategy}"
  echo "$root/$repo"
}

# iwe_sessions_root — prints the local checkout path for session content
# (peer-conversation / quick-close transcripts). WP-526 Ф2: this content
# moved out of DS-strategy into its own repo (MC-sessions) so the
# governance repo stops growing on every agent session. No longer takes
# a repo_dir argument -- MC-sessions isn't a subfolder of any governance
# checkout, its path doesn't depend on which worktree the caller runs in.
# Fails closed (non-zero exit, nothing on stdout) if the checkout is
# missing -- callers running under `set -e` abort instead of silently
# falling back to writing inside DS-strategy again (that fallback is
# exactly the split-brain this move exists to close).
iwe_sessions_root() {
  local root="${IWE_SESSIONS_ROOT:-${IWE_ROOT:-$HOME/IWE}/MC-sessions}"
  [ -d "$root" ] || { echo "iwe_sessions_root: $root не найден (MC-sessions не клонирован?)" >&2; return 1; }
  echo "$root"
}
