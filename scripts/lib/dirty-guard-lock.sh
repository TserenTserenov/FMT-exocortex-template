#!/usr/bin/env bash
# dirty-guard-lock.sh -- the repository lock of the guard scripts, in ONE place (WP-530 Ф81 remainder; peer session 2026-10-02-01
# with Kimi and Codex). SOURCED by git-dirty-guard.sh, canon-refresh.sh, canon-reconcile.sh, canon-reconcile-published.sh and
# sync-strategy-files.sh, never executed. The code is the lock section that Ф81 wrote inside canon-reconcile-published.sh, moved here
# so that the five scripts share it; the protocol is the same: $GIT_DIR/dirty-guard.lock is a directory and its file "owner" holds
# node=, pid=, epoch=, token= and script=. The name of the host is written as node=, NOT host=, on purpose (see "Old and new guards").
#
# Contract. The library sets no trap, never calls exit, never changes the working directory and writes nothing but its own lock and
# the lines named below (on stderr); WHAT to do when the lock is busy (exit status, channel, journal) stays with each script.
#   dglock_acquire <git-dir> <who>   0 = the lock is ours (the owner record is published)
#                                    1 = NOT taken: it is held, or it cannot be proven free, or it cannot be created (DGLOCK_STATE says which)
#                                    2 = our owner record could not be written: in a NEW lock directory (removed as far as possible; the
#                                        reason says when the directory is still there) or while a stale lock was being taken over (the
#                                        record of the dead owner is put back, or the reason names the file in which it is left)
#                                    3 = misuse or an environment that cannot serve the call, NOTHING was changed: this process already
#                                        holds the lock, the call was made from a subshell (bash 4 and newer; $(...), a pipeline or ( ) must
#                                        not take or release the lock), no git directory was given, or a command the library needs is not in PATH
#   dglock_release                   removes the lock only when its owner record carries OUR token; call it from the script's own EXIT
#                                    handler (a bash script has one EXIT trap: this library never sets it); safe to call twice or when
#                                    nothing is held; does nothing in a subshell (bash 4 and newer); always returns 0
#   dglock_instance                  prints the inode number of the lock directory (empty when ls cannot say)
# Variables, set by dglock_acquire on every call that changed something (code 3 changes none of them but DGLOCK_STATE and DGLOCK_REASON):
#   DGLOCK_DIR      the lock directory, an absolute physical path when the git directory could be resolved
#   DGLOCK_STATE    taken | held-alive | held-unproven | held-error | held-self
#   DGLOCK_REASON   one sentence without a prefix, for the caller's message: why the lock is not ours (the age of a live owner's lock is in it)
#   DGLOCK_ID       the lock INSTANCE as a short label for a series key: "pid 123 dir 456", "no owner file dir 456", "no lock directory"...
#   DGLOCK_INSTANCE the inode number of the lock directory as it was when DGLOCK_ID was made (empty when unknown): the caller compares it with
#                   dglock_instance before it writes a record about this skip, so that a record does not knowingly describe another lock (an
#                   inode number can be reused by a later lock directory: see the limits)
# Optional, read when a message is printed: DGLOCK_PREFIX (default "<who>:").
# The idiom of a guard (the call is on the left of ||, so it is safe under set -e; a bare call under set -e would end the script on a busy lock):
#   DGLOCK_LIB="$SCRIPT_DIR/lib/dirty-guard-lock.sh"        # SCRIPT_DIR is taken from BASH_SOURCE[0] BEFORE any cd
#   unset DGLOCK_LIB_READY                                   # a marker inherited from the environment must not vouch for a file that was cut short
#   if [ -r "$DGLOCK_LIB" ] && . "$DGLOCK_LIB" && [ "${DGLOCK_LIB_READY:-}" = 1 ]; then :; else echo "<who>: the lock library is missing or unusable: $DGLOCK_LIB ..." >&2; exit 1; fi
#   rc=0; dglock_acquire "$GIT_DIR" "<who>" || rc=$?
#   case $rc in 0) ;; 1) echo "<who>: lock busy -- $DGLOCK_REASON" >&2; exit <the script's own busy status> ;; *) echo "<who>: $DGLOCK_REASON" >&2; exit 1 ;; esac
#   trap '<own cleanup> || :; dglock_release' EXIT           # release LAST, and a failing cleanup step must not stop it (set -e, errexit in traps)
# DGLOCK_LIB_READY=1 is the last line of this file: a file that was cut short while it was being delivered does not set it (the guard unsets it
# BEFORE the source, so that a value left in the environment cannot vouch for a cut file).
#
# The takeover rule (WP-530 Ф81): a lock is taken over ONLY when its owner is PROVEN gone, that is when the builtin kill -0 answers
# "No such process" AND one successful listing of all processes (ps -A) holds this very run and pid 1 and not the pid. NOT proof: a
# missing, empty, unreadable or damaged owner file, another host name, a pid whose state cannot be established (ps fails, kill answers
# anything else), and a pid that is ALIVE (a number handed to another process looks exactly like that: the lock stays and the reason says
# how old the lock is). A zombie counts as alive. A lock directory that cannot be created, a dead owner's lock that cannot be changed,
# and a file or link in the place of the lock are named as such.
# The takeover is a CLAIM, not a read-then-delete. The lock DIRECTORY stays where it is, so there is no moment without a lock and no run can
# make a lock of its own meanwhile. The owner record is read once (pid, host, epoch, token together); our own record is written under a
# name of its own inside the directory; the dead owner's record is moved aside by ONE rename (of several runs that judged the same record
# only one rename succeeds); what was moved is compared with what was judged (not the same: it was the record of a live owner that took
# the lock meanwhile, and it is put back untouched); our record is linked into place by a hard link, which refuses a name that is taken,
# atomically (a rename would replace the record of another run, and there is no fallback by rename: "look first, then rename" is not one
# step). The record of a NEW lock directory is published the same way. A release removes only a
# lock whose record is ours, and it renames the directory away before it deletes it (a delete in place that fails half way would leave a
# lock without its owner record, which needs a human); a signal that arrives in the middle of a takeover puts the dead record back.
# Old and new guards (the delivery window, and a rollback). A guard from before this library reads host= and pid= and removes the lock of an
# owner it cannot signal (another user's process, pid 1) or whose pid is gone, after ONE failed kill -0: it would remove the LIVE lock of a
# guard that uses this library. A record with no host= key makes it stand aside (its host is not "this host": "lock busy"). Conversely this
# library never takes over a record in the old format (host= and no node=): an owner that is alive keeps the lock as always, but a lock of a
# dead owner is left to the old code (which removes it) or to a human, the reason says so. So an old and a new guard never judge the same
# stale lock, whatever the order of delivery; a stale lock of the old format that no old guard runs to clean up needs a human, loudly.
# SCOPE of the library: a file system that allows HARD LINKS (the owner record is published by a link) and keeps directory inode numbers
# stable (for DGLOCK_ID and dglock_instance): local APFS, HFS+, ext4, xfs, btrfs, zfs and tmpfs, where the guarded repositories live. Where
# links are refused the guards stop, loudly, with "cannot record the owner of the lock"; where the inode numbers wander, a series of skips
# built on DGLOCK_ID may fall apart into classes of different numbers: such file systems are outside the supported scope.
# Limits of this protocol (documented, not closable in a shell script): a record that was moved aside although it was not the judged one
# (the straddling run: it judged the same stale record, was slow, and its rename hit the record of the run that took the lock) is put
# back only where no record is there; the window is one read of the record, nobody can make a lock in it (the directory stays), and when the
# record cannot be put back the run says so and names the file in which the displaced record is left (the exit handler, after a signal,
# says so too); the owner whose record a straddling run holds aside at the moment of its release waits a few milliseconds, then leaves
# the lock in place and says so (the next run takes it over as stale); a run that is KILLED (not terminated: SIGKILL, power loss) between
# the move and its own record, or a creator that is KILLED between the mkdir and the publication of its record, leaves a lock without an
# owner file, which stays held, loudly, until a human removes it (a kernel lock would not; a signal that is terminated, also one that
# arrives while mkdir itself runs, is handled: the exit handler removes the empty directory or puts the dead record back); the
# release checks the owner record and removes the directory in two steps; an inode number can be reused by a later lock directory; a lock
# held by a live pid that is no guard run (a handed-over number) is removed by a human; without a working ps and without /proc nothing
# is ever taken over, and a system that hides other users' processes (hidepid in /proc, a restricted ps) gives no complete list, since
# pid 1 is missing from it: nothing is taken over there either; an old guard and a new one share no stale lock (see "Old and new guards"),
# and on a live lock they exclude each other as before, through the directory (mkdir) and the pid of the owner; two namespaces of process
# numbers under one host name are not told apart; after a failed
# publication (or in the exit handler, after a signal that arrived during a failed mkdir) the removal of the empty directory (rmdir) can
# remove an empty directory that another run made in the meantime (that run finds its directory gone, tries again and usually takes the
# lock; nothing is said); bash 3.2 has no BASHPID (and an inherited one is ignored there), so
# a release or an acquire made in a subshell is only refused on bash 4 and newer; a guard that is started through a SYMLINK to its file
# does not find its library (the directory is taken from the path of the script as it was called): start the real file; a signal that
# arrives while a foreground child (git) runs makes the exit handler release the lock at once, while the child may still run (as before
# this library). External commands (a minimal PATH must hold them): mkdir rmdir rm mv ln ls date awk, hostname only when $HOSTNAME is
# empty, and for the proof of a death ps (looked for in PATH, then in /run/current-system/sw/bin, /usr/bin and /bin; without any ps the
# kernel's list in /proc is read on Linux; where there is neither, nothing is ever taken over). Written for bash 3.2 (macOS /bin/bash)
# and newer; no shell arithmetic is done on a value that was not checked first (a failed arithmetic expansion discards the whole
# top-level command), ages are computed in awk.

# shellcheck disable=SC2034  # the DGLOCK_* variables are the interface: they are read by the scripts that source this file

_dglock_oneline() { local v="$1"; v="${v//$'\t'/ }"; v="${v//$'\r'/ }"; v="${v//$'\n'/ }"; printf '%s' "$v"; }   # a message must stay one line: a path name with a newline must not forge a line
_dglock_num_ok() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 12 ]; }   # 1-12 digits: no sign, point or overflow reaches arithmetic
_dglock_now() { local n; n=$(date -u +%s) || return 1; _dglock_num_ok "$n" || return 1; printf '%s' "$((10#$n))"; }   # the clock as plain decimal digits; fails when unreadable
_dglock_in_subshell() { [ "${BASH_VERSINFO[0]:-0}" -ge 4 ] && [ -n "${BASHPID:-}" ] && [ "$BASHPID" != "$$" ]; }   # bash 4+: $$ is the pid of the script, BASHPID the pid of the (sub)shell that runs this (bash 3.2 has none: an inherited value is not believed)
_dglock_pause() { if command -v sleep >/dev/null 2>&1; then sleep 0.02 2>/dev/null || :; fi; }   # a pause of a few milliseconds when a lock is changing hands; no sleep in PATH: no pause

_dglock_listing() {  # prints the pid of every process, one per line; fails when there is no source of the list (a failing ps fails it too: that is NOT a list)
  local ps_bin p d
  ps_bin=$(command -v ps 2>/dev/null) || ps_bin=""
  if [ -z "$ps_bin" ]; then for p in /run/current-system/sw/bin/ps /usr/bin/ps /bin/ps; do if [ -x "$p" ]; then ps_bin="$p"; break; fi; done; fi
  if [ -n "$ps_bin" ]; then LC_ALL=C "$ps_bin" -A -o pid= 2>/dev/null; return; fi
  if [ -d /proc/self ] && [ -d /proc/1 ]; then for d in /proc/[0-9]*; do printf '%s\n' "${d#/proc/}"; done; return 0; fi
  return 1
}
_dglock_pid_state() {  # <pid> -> alive | gone | unknown. The answer of the builtin kill -0 (a function named kill cannot stand in for it; the builtin keyword itself can be shadowed by an exported function, which is outside the trust of one user) decides: "No such process" is absence, "not permitted" is a process that exists; any other message proves nothing. Absence also needs ONE successful listing of all processes that holds this very run and pid 1 and not the pid
  local err snap
  case "$1" in ''|0*|*[!0-9]*) echo unknown; return ;; esac
  if err=$(export LC_ALL=C; builtin kill -0 "$1" 2>&1); then echo alive; return; fi
  case "$err" in
    *"No such process"*) ;;
    *"not permitted"*) echo alive; return ;;
    *) echo unknown; return ;;
  esac
  snap=$(_dglock_listing) || { echo unknown; return; }
  printf '%s\n' "$snap" | awk -v me="$$" -v target="$1" '
    { gsub(/[ \t]/, "") }
    $0 == me { seen_me = 1 }
    $0 == "1" { seen_init = 1 }
    $0 == target { found = 1 }
    END { if (found) print "alive"; else if (seen_me && seen_init) print "gone"; else print "unknown" }'
}
_dglock_field() {  # <key> -> the value of a key of the owner file; empty when the key is missing; "doubled-key" when it appears twice (a damaged file)
  awk -F= -v k="$1" '$1 == k { n++; v = substr($0, length(k) + 2) } END { if (n == 1) print v; else if (n > 1) print "doubled-key" }' "$DGLOCK_DIR/owner" 2>/dev/null
}
_dglock_snap() {  # <owner file> -> its pid, node, host, epoch and token on five lines, read in ONE pass ("key=" when missing, "key=doubled-key" when it appears twice); nothing when the file cannot be read
  awk -F= '$1 == "pid" || $1 == "node" || $1 == "host" || $1 == "epoch" || $1 == "token" { n[$1]++; v[$1] = substr($0, length($1) + 2) }
    END { split("pid node host epoch token", ks, " "); for (i = 1; i <= 5; i++) { k = ks[i]; if (n[k] > 1) print k "=doubled-key"; else print k "=" v[k] } }' "$1" 2>/dev/null
}
dglock_instance() {  # the inode number of the lock directory: a new directory is a new instance, whatever its owner record says; empty when ls cannot say
  ls -di "$DGLOCK_DIR" 2>/dev/null | awk 'NR == 1 { print $1 }'
}
_dglock_age_min() {  # <epoch of the owner record> -> whole minutes since then; empty when a time is unusable (awk, not shell arithmetic: nothing here may abort the run)
  local now_s
  now_s=$(_dglock_now) || return 0
  awk -v n="$now_s" -v e="$1" 'BEGIN { if (n ~ /^[0-9]+$/ && e ~ /^[0-9]+$/ && e >= 1000000000 && n >= e) printf "%d", (n - e) / 60 }'
}
_dglock_judge() {  # -> _DGLOCK_VERDICT (takeover | held | vanished), DGLOCK_REASON (why, in words), _DGLOCK_LABEL (what the lock is), DGLOCK_STATE and _DGLOCK_SNAP (the record that was judged)
  local snap pid host epoch l_pid l_node l_host l_epoch l_token node old="" st age
  _DGLOCK_VERDICT=held; DGLOCK_STATE=held-unproven; _DGLOCK_LABEL="not a directory"; _DGLOCK_SNAP=""
  if [ -L "$DGLOCK_DIR" ] || [ ! -d "$DGLOCK_DIR" ]; then
    if [ ! -e "$DGLOCK_DIR" ] && [ ! -L "$DGLOCK_DIR" ]; then _DGLOCK_VERDICT=vanished; _DGLOCK_LABEL="vanished"; DGLOCK_REASON="the lock went away while it was being judged"; return; fi   # released between two looks: nothing stands in the place of the lock
    DGLOCK_REASON="$(_dglock_oneline "$DGLOCK_DIR") is not a directory (a file or a link stands in the place of the lock)"; return
  fi
  _DGLOCK_LABEL="no owner file"
  if [ ! -f "$DGLOCK_DIR/owner" ]; then
    if [ ! -d "$DGLOCK_DIR" ]; then _DGLOCK_VERDICT=vanished; _DGLOCK_LABEL="vanished"; DGLOCK_REASON="the lock went away while it was being judged"; return; fi   # the directory went away between two looks
    DGLOCK_REASON="the owner file is missing (its creator may have died before it wrote it)"; return
  fi
  snap=$(_dglock_snap "$DGLOCK_DIR/owner")
  if [ -z "$snap" ]; then
    if [ -e "$DGLOCK_DIR/owner" ] && [ ! -r "$DGLOCK_DIR/owner" ]; then _DGLOCK_LABEL="unreadable owner file"; DGLOCK_REASON="the owner file cannot be read"; return; fi   # there, but not readable: no proof, the lock stays
    _DGLOCK_VERDICT=vanished; _DGLOCK_LABEL="vanished"; DGLOCK_REASON="the owner file went away while it was being read"; return   # gone, or replaced by another record between the check and the read (the lock changed hands): judge again
  fi
  { IFS= read -r l_pid; IFS= read -r l_node; IFS= read -r l_host; IFS= read -r l_epoch; IFS= read -r l_token; } <<< "$snap"
  pid="${l_pid#pid=}"; node="${l_node#node=}"; host="${l_host#host=}"; epoch="${l_epoch#epoch=}"
  if [ -n "$node" ]; then host="$node"; elif [ -n "$host" ]; then old=1; fi   # node= is written by this library, host= by a guard from before it (the old format)
  _DGLOCK_LABEL="damaged owner file"
  case "$pid" in ''|0*|*[!0-9]*) DGLOCK_REASON="the owner file is damaged (pid '$(_dglock_oneline "$pid")')"; return ;; esac
  _DGLOCK_LABEL="pid $pid"
  case "$host" in ''|doubled-key) DGLOCK_REASON="the owner file is damaged (host '$(_dglock_oneline "$host")')"; return ;; esac
  if [ "$host" != "$_DGLOCK_HOST" ]; then DGLOCK_REASON="the owner host '$(_dglock_oneline "$host")' is not this host '$_DGLOCK_HOST'"; return; fi
  st=$(_dglock_pid_state "$pid")
  case "$st" in
    gone)
      if [ -n "$old" ]; then _DGLOCK_LABEL="old-format pid $pid"; DGLOCK_REASON="owner pid $pid is gone, but its record is in the old format (written by a guard from before this library): this version does not take such a lock over, an old guard or a human does (remove $(_dglock_oneline "$DGLOCK_DIR") by hand if no old guard is running)"
      else _DGLOCK_VERDICT=takeover; _DGLOCK_SNAP="$snap"; DGLOCK_REASON="owner pid $pid is gone"; fi ;;
    alive) DGLOCK_STATE=held-alive; age=$(_dglock_age_min "$epoch"); DGLOCK_REASON="owner pid $pid is alive${age:+, the lock was taken $age min ago}" ;;
    *) DGLOCK_REASON="it cannot be established whether owner pid $pid is alive" ;;
  esac
}
_dglock_verdict() {  # -> the verdict of _dglock_judge, DGLOCK_INSTANCE (the lock instance) and DGLOCK_ID (the instance as it goes into the class of a skip)
  DGLOCK_INSTANCE=$(dglock_instance)
  _dglock_judge
  DGLOCK_ID="$_DGLOCK_LABEL${DGLOCK_INSTANCE:+ dir $DGLOCK_INSTANCE}"
}
_dglock_write_tmp() {  # our record under a name of its own inside the lock directory: only a draft until it is linked into place
  { printf 'node=%s\npid=%s\nepoch=%s\ntoken=%s\nscript=%s\n' "$_DGLOCK_HOST" "$$" "$_DGLOCK_EPOCH" "$_DGLOCK_TOKEN" "$_DGLOCK_WHO" > "$DGLOCK_DIR/owner.tmp.$$"; } 2>/dev/null
}
_dglock_link_in() {  # <file>: the file becomes the owner record, whole, and never over a record that is there: a hard link refuses a name that is taken, atomically. There is NO fallback by rename: a rename replaces the record of another run, and "look first, then rename" is not one step. A file system without hard links is outside the supported scope: the take fails there, loudly
  { ln "$1" "$DGLOCK_DIR/owner"; } 2>/dev/null
}
_dglock_publish() {  # the record of a NEW lock directory goes in: whole or not at all
  local rc=0
  { _dglock_write_tmp && _dglock_link_in "$DGLOCK_DIR/owner.tmp.$$"; } || rc=$?   # no command is forked before the draft is written but the printf's redirection: the clock was read before the mkdir (a signal in this gap is the one that leaves an ownerless lock)
  rm -f "$DGLOCK_DIR/owner.tmp.$$" 2>/dev/null || :   # after the link the second name is not needed
  return "$rc"
}
_dglock_unclaim() {  # a takeover that is not finished: the record that was moved aside goes back (only where no record is there), our draft goes, the lock can be judged again. 0 = the record is back (or there was none to put back); 1 = it could not be put back and is left where it is (_DGLOCK_LEFT names the file)
  local rc=0
  _DGLOCK_LEFT=""
  if [ -n "${_DGLOCK_CLAIM:-}" ] && [ -e "$_DGLOCK_CLAIM" ]; then
    if _dglock_link_in "$_DGLOCK_CLAIM"; then rm -f "$_DGLOCK_CLAIM" 2>/dev/null || :; else rc=1; _DGLOCK_LEFT="$_DGLOCK_CLAIM"; fi
  fi
  rm -f "$DGLOCK_DIR/owner.tmp.$$" 2>/dev/null || :
  _DGLOCK_CLAIM=""
  return "$rc"
}
_dglock_try_make() {  # 0 = the directory was made and the owner record published (the lock is ours); 1 = mkdir said no, or the directory was taken from this run before its record was in; 2 = made but unpublished (cleaned up as far as possible)
  _DGLOCK_MADE=1   # set BEFORE the mkdir: a signal that arrives while mkdir runs reaches the exit handler before any later line could set the flag; the handler removes an EMPTY directory only (rmdir), never a lock that holds a record (an empty directory of another run can go: that run retries, see the limits)
  mkdir "$DGLOCK_DIR" 2>/dev/null || { _DGLOCK_MADE=""; return 1; }
  if _dglock_publish; then
    _DGLOCK_MADE=""; DGLOCK_STATE=taken; DGLOCK_ID=""; DGLOCK_REASON=""
    return 0
  fi
  _DGLOCK_MADE=""
  if [ -e "$DGLOCK_DIR/owner" ] || [ ! -d "$DGLOCK_DIR" ]; then return 1; fi   # the directory that this run made was taken from it (replaced by the lock of another run, or removed): not ours, not a failure to write: the caller judges what is there now
  DGLOCK_STATE=held-error; DGLOCK_ID="no owner record"; DGLOCK_REASON="cannot record the owner of the lock $(_dglock_oneline "$DGLOCK_DIR") (no write access, a full disk, or a file system without hard links?)"
  if ! rmdir "$DGLOCK_DIR" 2>/dev/null && [ -e "$DGLOCK_DIR" ]; then
    DGLOCK_REASON="$DGLOCK_REASON (the lock directory was not removed: another run holds it now, or the git directory is not writable)"
  fi
  _DGLOCK_TOKEN=""
  return 2
}
_dglock_claim() {  # <attempt number>: the lock was judged stale (a dead owner, the record _DGLOCK_SNAP). The lock DIRECTORY stays where it is (no moment without a lock, so no run can make a lock of its own meanwhile); the dead owner's record is moved aside by ONE rename (of several runs that judged the same record only one rename succeeds), compared with the record that was judged, and replaced by ours through a link that refuses a taken name. 0 = taken over, ours; 1 = it changed meanwhile, judge again; 3 = not taken (DGLOCK_STATE and DGLOCK_REASON say why); 4 = our record could not be written (the dead record is back)
  local dead="$DGLOCK_DIR/owner.dead.$_DGLOCK_TOKEN.$1" tmp="$DGLOCK_DIR/owner.tmp.$$" snap1 why
  if ! _dglock_write_tmp; then
    rm -f "$tmp" 2>/dev/null || :   # a draft that was written in part (a full disk)
    if [ -d "$DGLOCK_DIR" ]; then DGLOCK_STATE=held-error; DGLOCK_REASON="the lock could not be taken over ($DGLOCK_REASON): the lock directory cannot be written"; return 3; fi
    return 1   # the lock is gone (its directory was released): judge what is there now
  fi
  _DGLOCK_CLAIM="$dead"   # from here a release puts the dead record back (a signal in this window must not leave a lock without a record)
  if ! { mv "$DGLOCK_DIR/owner" "$dead"; } 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || :; _DGLOCK_CLAIM=""
    if [ "$(_dglock_snap "$DGLOCK_DIR/owner")" = "$_DGLOCK_SNAP" ]; then DGLOCK_STATE=held-error; DGLOCK_REASON="the lock could not be taken over ($DGLOCK_REASON)"; return 3; fi   # the dead owner's record is still there, whole, and cannot be moved away (no write access)
    return 1   # somebody else moved it first (and maybe wrote a record of their own already), or the lock is gone: judge what is there now
  fi
  snap1=$(_dglock_snap "$dead")
  if [ "$snap1" != "$_DGLOCK_SNAP" ]; then   # not the record that was judged: its owner released and another run took the lock meanwhile
    if _dglock_link_in "$dead"; then rm -f "$dead" "$tmp" 2>/dev/null || :; _DGLOCK_CLAIM=""; return 1; fi   # put back untouched: judge it
    rm -f "$tmp" 2>/dev/null || :; _DGLOCK_CLAIM=""
    if [ ! -d "$DGLOCK_DIR" ]; then return 1; fi   # the lock was released meanwhile (its directory, with the moved record in it, is gone): nothing is displaced, judge what is there now
    if [ -e "$DGLOCK_DIR/owner" ]; then why="another record is in its place"; else why="the link could not be made"; fi
    echo "$_DGLOCK_PREFIX warning: a record that was not the one judged was moved aside to $(_dglock_oneline "$dead") and could not be put back ($why); it is left as it is" >&2
    DGLOCK_STATE=held-error; DGLOCK_ID="displaced record"; DGLOCK_REASON="the lock changed hands while it was being taken over (a record that was moved aside by mistake is left in $(_dglock_oneline "$dead"))"
    return 3
  fi
  echo "$_DGLOCK_PREFIX reclaiming the lock: $DGLOCK_REASON" >&2
  if _dglock_link_in "$tmp"; then
    rm -f "$dead" "$tmp" 2>/dev/null || :; _DGLOCK_CLAIM=""
    DGLOCK_STATE=taken; DGLOCK_ID=""; DGLOCK_REASON=""
    return 0
  fi
  if [ -e "$DGLOCK_DIR/owner" ]; then rm -f "$dead" "$tmp" 2>/dev/null || :; _DGLOCK_CLAIM=""; return 1; fi   # the record of another run is there: it holds the lock, judge it
  if [ ! -d "$DGLOCK_DIR" ]; then rm -f "$tmp" 2>/dev/null || :; _DGLOCK_CLAIM=""; return 1; fi   # the lock directory is gone (released, or removed by somebody else, with the moved record in it): nothing to put back, judge what is there now
  if _dglock_unclaim; then
    DGLOCK_REASON="cannot record the owner of the lock $(_dglock_oneline "$DGLOCK_DIR") (the record of the dead owner was put back)"
  else
    echo "$_DGLOCK_PREFIX warning: the record of the dead owner was moved aside to $(_dglock_oneline "$_DGLOCK_LEFT") and could not be put back: the lock is left without an owner record (a human removes it)" >&2
    DGLOCK_REASON="cannot record the owner of the lock $(_dglock_oneline "$DGLOCK_DIR") (and the record of the dead owner could not be put back: it is left in $(_dglock_oneline "$_DGLOCK_LEFT"))"
  fi
  DGLOCK_STATE=held-error; DGLOCK_ID="no owner record"; _DGLOCK_TOKEN=""
  return 4
}

_dglock_need() {  # prints the first command of the library that is not in PATH and fails; succeeds, printing nothing, when all are there (a missing ln would silently turn the link into the rename that the link replaces)
  local c
  for c in mkdir rmdir rm mv ln ls date awk; do command -v "$c" >/dev/null 2>&1 || { printf '%s' "$c"; return 1; }; done
  return 0
}
dglock_acquire() {  # <git-dir> <who> -- see the contract in the header
  local gd="${1-}" rc tries=0 absent=0 noowner=0 lost="" miss
  if _dglock_in_subshell; then DGLOCK_STATE=held-error; DGLOCK_REASON="dglock_acquire was called from a subshell: the lock must be taken in the shell of the guard"; return 3; fi
  if [ -n "${_DGLOCK_TOKEN:-}" ]; then   # a second call must not forget the token of the first: the lock stays releasable
    if [ "$(_dglock_field token)" = "$_DGLOCK_TOKEN" ]; then DGLOCK_STATE=held-self; DGLOCK_REASON="this process already holds the lock $(_dglock_oneline "$DGLOCK_DIR")"; return 3; fi
    _DGLOCK_TOKEN=""   # the lock of the earlier call was taken over or removed meanwhile: it is not ours any more
  fi
  _DGLOCK_WHO="${2:-guard}"
  _DGLOCK_PREFIX="${DGLOCK_PREFIX:-$_DGLOCK_WHO:}"
  if [ -z "$gd" ]; then DGLOCK_STATE=held-error; DGLOCK_REASON="dglock_acquire was called without a git directory"; return 3; fi
  if ! miss=$(_dglock_need); then DGLOCK_STATE=held-error; DGLOCK_REASON="the command $miss is not in PATH (the lock library needs mkdir rmdir rm mv ln ls date awk); nothing was done"; return 3; fi
  case "$gd" in /*|./*|../*) ;; *) gd="./$gd" ;; esac   # a relative name never consults CDPATH (it could lead to another directory)
  if gd=$(cd "$gd" >/dev/null 2>&1 && pwd -P && printf x); then gd="${gd%x}"; gd="${gd%$'\n'}"; else case "$1" in /*) gd="$1" ;; *) gd="$PWD/$1" ;; esac; fi   # a physical absolute path (a later cd of the guard must not move the lock it releases); cd prints nothing into the captured text (CDPATH makes it print); the marker x keeps a newline at the end of a directory name, which a command substitution would strip
  DGLOCK_DIR="$gd/dirty-guard.lock"
  _DGLOCK_HOST="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
  _DGLOCK_EPOCH=$(_dglock_now) || _DGLOCK_EPOCH=0   # read BEFORE any mkdir: nothing is forked between the mkdir and the publication of the record
  _DGLOCK_TOKEN="$$.$RANDOM.$RANDOM"
  _DGLOCK_MADE=""; _DGLOCK_CLAIM=""
  DGLOCK_STATE=held-unproven; DGLOCK_ID=""; DGLOCK_REASON=""; DGLOCK_INSTANCE=""
  while [ "$tries" -lt 8 ]; do
    tries=$((tries + 1))   # a counter of this loop: the only shell arithmetic here
    if _dglock_try_make; then rc=0; else rc=$?; fi
    [ "$rc" -eq 1 ] || return "$rc"
    if [ ! -e "$DGLOCK_DIR" ] && [ ! -L "$DGLOCK_DIR" ]; then   # mkdir said no but nothing is there: the lock was released a moment ago (try again), or the directory itself cannot be made (the second try says no again)
      absent=$((absent + 1))
      if [ "$absent" -ge 2 ]; then   # twice in a row: a probe of a private name tells a directory that cannot be made from a lock that changes hands quickly (a release between the mkdir and the look, under contention)
        if mkdir "$DGLOCK_DIR.probe.$_DGLOCK_TOKEN" 2>/dev/null; then rmdir "$DGLOCK_DIR.probe.$_DGLOCK_TOKEN" 2>/dev/null || :; _dglock_pause; continue; fi
        DGLOCK_STATE=held-error; DGLOCK_INSTANCE=""; DGLOCK_ID="no lock directory"; DGLOCK_REASON="the lock directory cannot be created (no write access to the git directory, a read-only or a full disk, a path too long?)"; _DGLOCK_TOKEN=""; return 1
      fi
      continue
    fi
    _dglock_verdict
    case "$_DGLOCK_VERDICT" in
      vanished) continue ;;   # it went away while it was judged: take it, or judge what is there now
      takeover) ;;
      *)
        if [ "$_DGLOCK_LABEL" = "no owner file" ] && [ "$noowner" -lt 3 ]; then noowner=$((noowner + 1)); _dglock_pause; continue; fi   # a run that has made the directory (or is taking the lock over) is about to write its record: a few milliseconds are given before the lock is called ownerless
        break ;;
    esac
    rc=0; _dglock_claim "$tries" || rc=$?
    case "$rc" in
      0) return 0 ;;
      1) lost=1; continue ;;
      3) _DGLOCK_TOKEN=""; return 1 ;;
      *) return 2 ;;
    esac
  done
  _DGLOCK_TOKEN=""   # not taken: there is nothing of ours to release
  if [ -n "$lost" ] && [ "$_DGLOCK_VERDICT" = takeover ]; then DGLOCK_STATE=held-error; DGLOCK_REASON="the lock kept changing hands while it was being taken over"; fi   # eight claims lost in a row: said as that (the last judgment, a dead owner, would contradict the busy answer)
  [ "$DGLOCK_STATE" != held-unproven ] || [ -n "$DGLOCK_REASON" ] || DGLOCK_REASON="the lock kept changing hands while it was being taken"
  return 1
}
dglock_release() {  # only a lock whose owner record is OURS is removed: a lock that was taken over while this run was still going belongs to somebody else
  local t n=0
  _dglock_in_subshell && return 0
  [ -z "${DGLOCK_DIR:-}" ] || rm -f "$DGLOCK_DIR/owner.tmp.$$" 2>/dev/null || :   # a draft of ours that a signal left behind (before a claim was marked) goes in any case
  if [ "${_DGLOCK_MADE:-}" = 1 ]; then rmdir "$DGLOCK_DIR" 2>/dev/null || :; _DGLOCK_MADE=""; fi   # a signal came between our mkdir and the record: the EMPTY directory of this run goes
  if [ -n "${_DGLOCK_CLAIM:-}" ]; then _dglock_unclaim || echo "$_DGLOCK_PREFIX warning: the record of the dead owner was moved aside to $(_dglock_oneline "$_DGLOCK_LEFT") and could not be put back: the lock is left without an owner record (a human removes it)" >&2; fi   # a signal came after the dead record was moved aside and before ours was in: the dead record goes back, so that the lock can be judged (and taken over) again
  [ -n "${_DGLOCK_TOKEN:-}" ] || return 0
  rmdir "$DGLOCK_DIR.probe.$_DGLOCK_TOKEN" 2>/dev/null || :   # a probe directory that a signal left behind goes
  t=$(_dglock_field token) || :   # || : on each read: awk fails on an absent file, and under set -e (the guard's errexit is active in its EXIT trap) a failing assignment would end the shell inside the handler
  while [ -z "$t" ] && [ -d "$DGLOCK_DIR" ] && [ ! -e "$DGLOCK_DIR/owner" ] && [ "$n" -lt 3 ]; do n=$((n + 1)); _dglock_pause; t=$(_dglock_field token) || :; done   # no record in the directory: a straddling run may hold ours aside for one read (the limits): a few milliseconds are given before the lock is left as it is
  if [ "$t" = "$_DGLOCK_TOKEN" ]; then   # the directory is renamed away first (the lock is gone at once) and then deleted: a delete in place that fails half way would leave a lock without its owner record, which needs a human; under set -e a failing command here must not end the shell before the token is forgotten
    if mv "$DGLOCK_DIR" "$DGLOCK_DIR.released.$_DGLOCK_TOKEN" 2>/dev/null; then
      rm -rf "$DGLOCK_DIR.released.$_DGLOCK_TOKEN" 2>/dev/null || echo "$_DGLOCK_PREFIX warning: the released lock was moved to $(_dglock_oneline "$DGLOCK_DIR.released.$_DGLOCK_TOKEN") and could not be deleted there (a human may delete it)" >&2
    else
      echo "$_DGLOCK_PREFIX warning: the lock $(_dglock_oneline "$DGLOCK_DIR") could not be released (no write access to its directory?); the next run takes it over as a stale lock" >&2
    fi
  elif [ -d "$DGLOCK_DIR" ] && [ ! -e "$DGLOCK_DIR/owner" ]; then
    echo "$_DGLOCK_PREFIX warning: the lock $(_dglock_oneline "$DGLOCK_DIR") was not released: its owner record is not there (a run that was taking it over may hold it aside); the next run judges it" >&2
  fi
  _DGLOCK_TOKEN=""
  return 0
}

DGLOCK_LIB_READY=1
