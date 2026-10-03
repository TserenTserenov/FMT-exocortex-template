#!/usr/bin/env bash
# shellcheck disable=SC2034  # GIT_SYNC_* are the library's public output API, read by callers after sourcing
# git-sync-status.sh — read-only git-vs-origin sync classifier for gates that
# run on every WP session open and in the nightly cycle (WP-561 Ф20).
#
# Never fetches: a full `git fetch` writes refs/remotes/*/FETCH_HEAD into the
# shared .git that dozens of worktrees share on this machine (see
# git-dirty-guard.sh header for the same rationale). Uses `git ls-remote`
# (read-only network call) instead, same model as iwe-safe-pull.sh.
#
# Usage:
#   . git-sync-status.sh
#   check_git_sync_status "<repo_dir>" ["<branch>"] ["<timeout_seconds>"]
#   echo "$GIT_SYNC_STATUS"   # OK|STALE|DIVERGED|fetch_failed|NO_UPSTREAM|NOT_A_REPO|checker_unavailable
#
# Sets after every call: GIT_SYNC_STATUS, GIT_SYNC_BEHIND, GIT_SYNC_AHEAD,
# GIT_SYNC_REMOTE_OID, GIT_SYNC_HEAD_OID, GIT_SYNC_DETAIL (one-line, for
# GIT_SYNC_DETAIL: stdout).
#
# Every internal git call that can fail as a normal, expected outcome (no
# origin, branch never pushed, network down, ...) is the *condition* of an
# `if`, not a bare `var=$(cmd)` statement — bash's `set -e` does not abort on
# a failing command inside an if/while condition, but it does on a bare
# assignment, and this library is sourced into callers that run under
# `set -euo pipefail` (wp-sync-bundle.sh). A bare assignment here would silently
# kill the caller on the very failure paths this function exists to classify.
#
# Precomputed short-circuit (nightly batch — one check per run, not one per
# WP card): set GIT_SYNC_PRECOMPUTED_STATUS to a value from the table above
# before calling; an invalid value is treated as checker_unavailable (fail
# closed on a broken integration, not a silent re-check that defeats the
# point of precomputing once).
_GIT_SYNC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check_git_sync_status() {
  local repo_dir="$1"
  local branch="${2:-}"
  local timeout_seconds="${3:-15}"

  GIT_SYNC_STATUS=""
  GIT_SYNC_BEHIND=""
  GIT_SYNC_AHEAD=""
  GIT_SYNC_REMOTE_OID=""
  GIT_SYNC_HEAD_OID=""
  GIT_SYNC_DETAIL=""

  if [ -n "${GIT_SYNC_PRECOMPUTED_STATUS:-}" ]; then
    case "$GIT_SYNC_PRECOMPUTED_STATUS" in
      OK|STALE|DIVERGED|fetch_failed|NO_UPSTREAM|NOT_A_REPO|checker_unavailable)
        GIT_SYNC_STATUS="$GIT_SYNC_PRECOMPUTED_STATUS"
        GIT_SYNC_DETAIL="method=precomputed"
        return 0
        ;;
      *)
        GIT_SYNC_STATUS="checker_unavailable"
        GIT_SYNC_DETAIL="method=precomputed reason=invalid_value:$GIT_SYNC_PRECOMPUTED_STATUS"
        return 0
        ;;
    esac
  fi

  command -v git >/dev/null 2>&1 || {
    GIT_SYNC_STATUS="checker_unavailable"
    GIT_SYNC_DETAIL="reason=no_git"
    return 0
  }

  local toplevel=""
  if ! toplevel=$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null); then
    toplevel=""
  fi
  if [ -z "$toplevel" ]; then
    GIT_SYNC_STATUS="NOT_A_REPO"
    GIT_SYNC_DETAIL="reason=not_a_git_repo"
    return 0
  fi
  # Fixtures and probe copies often live *inside* a real repo (e.g. test
  # fixtures under <governance>/scripts/tests/) — rev-parse then silently
  # resolves to that outer repo instead of failing, and a fixture would get
  # judged against the outer repo's real origin. Physical-path compare
  # (matches the existing guard in wp-sync-bundle.sh:440-446) catches that.
  local repo_dir_real=""
  if ! repo_dir_real=$(cd "$repo_dir" 2>/dev/null && pwd -P); then
    repo_dir_real=""
  fi
  local toplevel_real=""
  if ! toplevel_real=$(cd "$toplevel" 2>/dev/null && pwd -P); then
    toplevel_real=""
  fi
  if [ -z "$repo_dir_real" ] || [ "$repo_dir_real" != "$toplevel_real" ]; then
    GIT_SYNC_STATUS="NOT_A_REPO"
    GIT_SYNC_DETAIL="reason=not_toplevel"
    return 0
  fi

  if [ -z "$branch" ]; then
    if ! branch=$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD 2>/dev/null); then
      branch=""
    fi
  fi
  if [ -z "$branch" ]; then
    GIT_SYNC_STATUS="NO_UPSTREAM"
    GIT_SYNC_DETAIL="reason=detached_head"
    return 0
  fi

  if ! git -C "$repo_dir" remote get-url origin >/dev/null 2>&1; then
    GIT_SYNC_STATUS="NO_UPSTREAM"
    GIT_SYNC_DETAIL="reason=no_origin_remote"
    return 0
  fi

  local head_oid=""
  if ! head_oid=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null); then
    head_oid=""
  fi
  if [ -z "$head_oid" ]; then
    GIT_SYNC_STATUS="checker_unavailable"
    GIT_SYNC_DETAIL="reason=head_unresolved"
    return 0
  fi
  GIT_SYNC_HEAD_OID="$head_oid"

  local ls_remote_output="" ls_remote_status=0
  if ls_remote_output=$(_git_sync_run_with_timeout "$timeout_seconds" \
      git -C "$repo_dir" ls-remote --exit-code --refs origin "refs/heads/$branch" 2>/dev/null); then
    ls_remote_status=0
  else
    ls_remote_status=$?
  fi

  if [ "$ls_remote_status" -eq 2 ]; then
    # --exit-code: no matching ref on origin at all — the branch was never
    # pushed, not that our data is stale.
    GIT_SYNC_STATUS="NO_UPSTREAM"
    GIT_SYNC_DETAIL="reason=branch_not_on_origin branch=$branch"
    return 0
  fi
  if [ "$ls_remote_status" -eq 124 ]; then
    GIT_SYNC_STATUS="fetch_failed"
    GIT_SYNC_DETAIL="reason=timeout_${timeout_seconds}s"
    return 0
  fi
  if [ "$ls_remote_status" -eq 125 ]; then
    GIT_SYNC_STATUS="fetch_failed"
    GIT_SYNC_DETAIL="reason=timeout_supervision_failed"
    return 0
  fi
  if [ "$ls_remote_status" -ne 0 ]; then
    GIT_SYNC_STATUS="fetch_failed"
    GIT_SYNC_DETAIL="reason=ls_remote_exit_$ls_remote_status"
    return 0
  fi

  local remote_oid=""
  if ! remote_oid=$(printf '%s\n' "$ls_remote_output" | awk -v expected="refs/heads/$branch" '
      NF != 2 || $2 != expected { exit 1 }
      { count += 1; oid = $1 }
      END { if (count != 1) exit 1; print oid }
    '); then
    remote_oid=""
  fi
  if [ -z "$remote_oid" ]; then
    GIT_SYNC_STATUS="fetch_failed"
    GIT_SYNC_DETAIL="reason=malformed_ls_remote_response"
    return 0
  fi
  case "$remote_oid" in
    *[!0-9a-fA-F]*)
      GIT_SYNC_STATUS="fetch_failed"
      GIT_SYNC_DETAIL="reason=invalid_remote_oid"
      return 0
      ;;
  esac
  GIT_SYNC_REMOTE_OID="$remote_oid"

  if [ "$remote_oid" = "$head_oid" ]; then
    GIT_SYNC_STATUS="OK"
    GIT_SYNC_BEHIND=0
    GIT_SYNC_AHEAD=0
    GIT_SYNC_DETAIL="behind=0 ahead=0 method=ls-remote"
    return 0
  fi

  if ! git -C "$repo_dir" cat-file -e "${remote_oid}^{commit}" 2>/dev/null; then
    # Remote moved to a commit we don't have locally at all. We cannot compute
    # an exact distance without fetching it, and refusing to fetch is the
    # whole point of this checker — report STALE with an unknown distance
    # rather than guess. Any state where origin has work we've never seen is
    # unsynced by definition, not a false positive.
    GIT_SYNC_STATUS="STALE"
    GIT_SYNC_BEHIND="unknown"
    GIT_SYNC_AHEAD="unknown"
    GIT_SYNC_DETAIL="behind=unknown ahead=unknown reason=remote_object_absent method=ls-remote"
    return 0
  fi

  if git -C "$repo_dir" merge-base --is-ancestor "$remote_oid" HEAD 2>/dev/null; then
    local ahead=""
    if ! ahead=$(git -C "$repo_dir" rev-list --count "${remote_oid}..HEAD" 2>/dev/null); then
      ahead=""
    fi
    GIT_SYNC_STATUS="OK"
    GIT_SYNC_BEHIND=0
    GIT_SYNC_AHEAD="${ahead:-unknown}"
    GIT_SYNC_DETAIL="behind=0 ahead=${GIT_SYNC_AHEAD} method=ls-remote"
    return 0
  fi

  if git -C "$repo_dir" merge-base --is-ancestor HEAD "$remote_oid" 2>/dev/null; then
    local behind=""
    if ! behind=$(git -C "$repo_dir" rev-list --count "HEAD..${remote_oid}" 2>/dev/null); then
      behind=""
    fi
    GIT_SYNC_STATUS="STALE"
    GIT_SYNC_BEHIND="${behind:-unknown}"
    GIT_SYNC_AHEAD=0
    GIT_SYNC_DETAIL="behind=${GIT_SYNC_BEHIND} ahead=0 method=ls-remote"
    return 0
  fi

  local behind="" ahead=""
  if ! behind=$(git -C "$repo_dir" rev-list --count "HEAD..${remote_oid}" 2>/dev/null); then
    behind=""
  fi
  if ! ahead=$(git -C "$repo_dir" rev-list --count "${remote_oid}..HEAD" 2>/dev/null); then
    ahead=""
  fi
  GIT_SYNC_STATUS="DIVERGED"
  GIT_SYNC_BEHIND="${behind:-unknown}"
  GIT_SYNC_AHEAD="${ahead:-unknown}"
  GIT_SYNC_DETAIL="behind=${GIT_SYNC_BEHIND} ahead=${GIT_SYNC_AHEAD} method=ls-remote"
  return 0
}

# Self-contained deadline for the read-only Sync Gate remote query. A timeout
# is reported only after the process tree is stopped; incomplete cleanup has
# a distinct exit status so callers never mistake it for a handled timeout.
_git_sync_run_with_timeout() {
  local seconds="$1"
  shift
  case "$seconds" in
    0|'') "$@" ;;
    *[!0-9]*)
      echo "git-sync-status: invalid timeout: $seconds" >&2
      return 1
      ;;
    *)
      local py
      # The timeout wrapper below needs only the standard library.
      py="$("$_GIT_SYNC_LIB_DIR/find-python3.sh" --stdlib-only 2>/dev/null)" || {
        echo "git-sync-status: timeout requested but python3 is unavailable" >&2
        return 1
      }
      "$py" -c '
import os
import signal
import subprocess
import sys

seconds = int(sys.argv[1])
IS_WINDOWS = os.name == "nt"
HAS_PGROUP = hasattr(os, "killpg")
popen_kwargs = {"start_new_session": True} if HAS_PGROUP else {}
# Resolve the native system tool before launching git. A same-named program
# in the working directory or PATH must not replace process-tree cleanup.
TASKKILL = None
if IS_WINDOWS:
    system_root = os.environ.get("SystemRoot") or os.environ.get("WINDIR")
    if system_root:
        candidate = os.path.join(system_root, "System32", "taskkill.exe")
        if os.path.isfile(candidate):
            TASKKILL = candidate
    if not TASKKILL:
        raise SystemExit(125)

process = subprocess.Popen(sys.argv[2:], **popen_kwargs)
handled_signals = tuple(
    getattr(signal, name)
    for name in ("SIGTERM", "SIGINT", "SIGHUP")
    if hasattr(signal, name)
)

def stop_process_tree():
    if IS_WINDOWS:
        try:
            result = subprocess.run(
                [TASKKILL, "/F", "/T", "/PID", str(process.pid)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
                check=False,
            )
            if result.returncode == 0:
                process.wait(timeout=2)
                return True
        except (OSError, subprocess.TimeoutExpired):
            pass
        # A direct kill is only a fallback. It cannot prove that native git
        # helpers exited, so the wrapper returns 125 even if the root exits.
        try:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=2)
        except (OSError, subprocess.TimeoutExpired):
            pass
        return False

    try:
        if HAS_PGROUP:
            os.killpg(process.pid, signal.SIGTERM)
        else:
            process.terminate()
    except OSError:
        pass
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        try:
            if HAS_PGROUP:
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
        except OSError:
            pass
        process.wait()
    return True

def forward_signal(signum, _frame):
    for handled in handled_signals:
        signal.signal(handled, signal.SIG_IGN)
    raise SystemExit(128 + signum if stop_process_tree() else 125)

for handled in handled_signals:
    signal.signal(handled, forward_signal)

try:
    returncode = process.wait(timeout=seconds)
except subprocess.TimeoutExpired:
    raise SystemExit(124 if stop_process_tree() else 125)

raise SystemExit(returncode if returncode >= 0 else 128 - returncode)
' "$seconds" "$@"
      ;;
  esac
}
