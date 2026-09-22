#!/usr/bin/env bash
# session-guard-isolate-lib.sh — thin isolate helpers for FMT session-guard (WP-485 Ф14, а∩г)
# Sourced by scripts/session-guard.sh. Requires: fail(), IWE_ROOT, ISOLATE_LOCK_DIR, ISOLATE_LOCK_TTL_SEC.
# Do not hardcode personal governance repo names.

isolate_entropy_suffix() {
  # `... && return` on a zero-exit-but-empty-output pipe (e.g. xxd installed
  # but the read returns nothing) would return an EMPTY suffix here -- the
  # exact collision this function exists to prevent, only silent instead of
  # loud (cold-context review, WP-530 peer-session 2026-08-15-10). Capture
  # and check for non-empty output explicitly instead of trusting exit code.
  local suffix
  if [ -r /dev/urandom ]; then
    suffix=$(head -c 2 /dev/urandom 2>/dev/null | xxd -p 2>/dev/null)
    if [ -n "$suffix" ]; then
      printf '%s' "$suffix"
      return
    fi
  fi
  printf '%04x' "$RANDOM"
}


validate_isolate_slug() {
  local slug="$1"
  [[ "$slug" =~ ^[a-zA-Z0-9._-]+$ ]] \
    || fail "--isolate: slug '$slug' содержит недопустимые символы (разрешены: буквы, цифры, точка, подчёркивание, дефис) — не может использоваться в пути worktree или имени ветки" 1
}

with_isolate_lock() {
  local session_id="$1"; shift
  mkdir -p "$ISOLATE_LOCK_DIR"
  local lock_path="$ISOLATE_LOCK_DIR/${session_id}.lockdir"
  local attempt=0
  while ! mkdir "$lock_path" 2>/dev/null; do
    # cold-context review (2026-08-14, this same session): TTL-only reclaim
    # here had a real race -- a stale holder's `rm -rf` right before a THIRD
    # process wins a concurrent `mkdir` in that same window deletes the
    # third process's freshly-taken lock out from under it, leaving two
    # processes both convinced they hold the lock for one session_id
    # (exactly the invariant this primitive exists to prevent). Same fix
    # already proven for session semaphores (sweep_orphaned_semaphores()
    # above): PID liveness first, TTL only as fallback when no PID is
    # recorded -- age alone never triggers a deletion by itself anymore.
    if [ -f "$lock_path/pid" ]; then
      local held_pid
      held_pid=$(cat "$lock_path/pid" 2>/dev/null || echo "")
      if [[ "$held_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$held_pid" 2>/dev/null; then
        rm -rf "$lock_path"
        continue
      fi
    elif [ -f "$lock_path/locked_at" ]; then
      local held_at held_epoch age
      held_at=$(cat "$lock_path/locked_at" 2>/dev/null || echo "")
      held_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$held_at" +%s 2>/dev/null \
        || date -u -d "$held_at" +%s 2>/dev/null || echo 0)
      age=$(( $(date +%s) - held_epoch ))
      if [ "$age" -gt "$ISOLATE_LOCK_TTL_SEC" ]; then
        rm -rf "$lock_path"
        continue
      fi
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 30 ]; then
      fail "with_isolate_lock: сессия '$session_id' заблокирована другим параллельным open --isolate >30с — повтори позже" 1
    fi
    sleep 1
  done
  now_iso > "$lock_path/locked_at"
  echo $$ > "$lock_path/pid"
  # Both exits out of the critical section have to release the lock, and neither
  # did before (WP-530, peer session 2026-09-05-34 with Kimi):
  #   - a non-zero return from the callback killed the script right here under
  #     `set -euo pipefail` (line 63), before the release below ever ran;
  #   - `fail()` (line 149) is "message + exit", so a callback failing deep
  #     inside it leaves the function entirely -- which a RETURN trap would not
  #     catch either, the reason this is an EXIT trap and not that.
  # Nothing about waiting changes: a dead owner's lock is already reclaimed by
  # the PID-liveness branch above on the next contender's first pass, so what
  # leaked here was a stale directory on disk, not a window of protection.
  # The trap is installed for the critical section only and cleared right after
  # it -- this file's global EXIT trap belongs to another command
  # (wp-context-guarded-edit), and leaving ours armed would take it over.
  # The trap releases EVERY lock this process holds, not just this one. A
  # process has a single EXIT trap, so a nested call that armed its own would
  # disarm the outer one and leak the outer lock on an abort (cold review of
  # this change, Medium). Holding the paths in one stack keeps the trap correct
  # at any depth -- no call site nests today, and none has to remember not to.
  _ISOLATE_LOCKS_HELD+=("$lock_path")
  trap release_isolate_locks EXIT
  local rc=0
  "$@" || rc=$?
  # Normal path releases only this call's own lock; an outer holder's lock is
  # its own business and stays until that call returns.
  unset "_ISOLATE_LOCKS_HELD[$(( ${#_ISOLATE_LOCKS_HELD[@]} - 1 ))]"
  rm -rf "$lock_path"
  if [ "${#_ISOLATE_LOCKS_HELD[@]}" -eq 0 ]; then
    trap - EXIT
  fi
  return $rc
}

release_isolate_locks() {
  local held
  for held in ${_ISOLATE_LOCKS_HELD[@]+"${_ISOLATE_LOCKS_HELD[@]}"}; do
    [ -n "$held" ] && rm -rf "$held"
  done
  _ISOLATE_LOCKS_HELD=()
}

