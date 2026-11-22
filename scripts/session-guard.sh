#!/usr/bin/env bash
# session-guard.sh — unified gate open/close/audit for all agents (Claude, Kimi, Hermes)
# see WP-398 Phase5, AGENTS.md (WP Gate — CRITICAL), protocol-open.md
#
# Invariant: every session with file changes must go through open → ORZ → commit → close.
# Mechanical enforcement: git pre-commit hook checks for the presence of an active semaphore.
#
# Commands:
#   open --wp WP-N [--task "..."] [--files "a,b"] [--slug "..."] [--agent claude-code|kimi|hermes|grok] [--personality <unassigned|UUID>] [--isolate]
#   open --housekeeping <reason> [--agent ...]        # background housekeeping-session without ORZ
#   close [--wp WP-N] [--slug "..."] [--agent ...]
#   close ... --force-no-reflection "<reason>"       # close without answering the reflection —
#                                                      # only if the runner is set exactly to
#                                                      # blocked-witness-unavailable AND push already
#                                                      # confirmed (all_pushed: true)
#   close --housekeeping <reason> [--agent ...]       # close housekeeping-session
#   audit [--since YYYY-MM-DD] [--cleanup-orphans]
#   renew [--wp WP-N] [--slug "..."] [--agent ...]    # extend the right to commit
#   heartbeat --agent <agent> --session-id <id> --owner-pid <pid>
#   pre-commit-check
#   note-file <path> [--agent ...] [--session-id <id>]
#   lock-hot-file <path> [--agent ...]    # WP-7 SessionGitRaceIsolation: short
#   unlock-hot-file <path>                # mkdir-mkdir lock on a file that frequently, that frequently
#                                          # collides between parallel sessions
#                                          # (DayPlan, active WP card, hypotheses-log,
#                                          # MEMORY.md) — not on the entire working tree
#   freeze-canonical <path> [--force]     # WP-485 Phase14 / WP-520: chflags -R uchg
#   unfreeze-canonical <path>             # fail-closed: does not remove chflags
#   request-unfreeze-canonical <path> --reason "..."  # request log + nonce
#
# Lease (WP-484 Phase49): the existence of a session and its right to authorize a commit — are different
# things. Age revokes only the right (default 4h, `IWE_SESSION_LEASE_SEC`);
# existence is removed only by close or proven death of the owner process-owner.
#
# Exit codes:
#   0 — OK
#   1 — general error
#   2 — open without wp
#   3 — close without a preceding open
#   4 — git pre-commit block (semaphore not found)
#   5 — ORZ did not pass validation
#   6 — scope gate block (staged file outside active sessions)

set -euo pipefail

# The transition lock below uses Unix fcntl, inode ownership and /bin/bash.
# Git Bash with native Windows Python cannot uphold that contract. Refuse every
# command before creating the session directory or touching the canonical repo.
case "$(uname -s)" in
  MINGW*|MSYS*)
    echo 'session-guard: Git Bash on Windows with native Python is not supported: Unix-lock fcntl unavailable. Start the working session in WSL2.' >&2
    exit 1
    ;;
esac

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SESSION_GUARD_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
# issue #266: hardcoded "DS-strategy" broke every template user whose
# governance repo is named "DS-strategy" (the shipped default — see create-wp.sh).
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
# WP-485 Phase14 / WP-520: logical freeze paths (default-on). Empty override disables.
if [ -z "${IWE_FROZEN_CANONICAL_PATH+x}" ]; then
  FROZEN_CANONICAL_PATHS=("$IWE_ROOT/$GOV_REPO" "$IWE_ROOT")
elif [ -n "$IWE_FROZEN_CANONICAL_PATH" ]; then
  FROZEN_CANONICAL_PATHS=("$IWE_FROZEN_CANONICAL_PATH")
else
  FROZEN_CANONICAL_PATHS=()
fi
OPEN_LOG="$IWE_ROOT/$GOV_REPO/inbox/open-sessions.log"
AGENT_STATUS_SCRIPT="$IWE_ROOT/scripts/agent-status-report.sh"
# ORZ_DIR resolved further down by resolve_orz_sessions_dir(), once fail()
# exists -- not created here, see that function's docstring for why.
mkdir -p "$SESSION_DIR" "$(dirname "$OPEN_LOG")"

CMD="${1:-}"
shift || true
SESSION_GUARD_ARGS=("$@")

# --- helpers ---
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_date() { date +"%Y-%m-%d"; }
now_month() { date +"%Y-%m"; }
fail() { echo "session-guard: $1" >&2; exit "${2:-1}"; }

# WP-485 Phase14 (a∩g): thin isolate helpers
ISOLATE_LOCK_DIR="$IWE_ROOT/.iwe-runtime/isolate-locks"
ISOLATE_LOCK_TTL_SEC="${IWE_ISOLATE_LOCK_TTL_SEC:-120}"
_ISOLATE_LOCKS_HELD=()
_SG_ISOLATE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/session-guard-isolate-lib.sh"
if [ -f "$_SG_ISOLATE_LIB" ]; then
  # shellcheck source=lib/session-guard-isolate-lib.sh
  . "$_SG_ISOLATE_LIB"
fi
# issue #954: shared reader of WP numbers; the hypothesis gate in `open` finds the card by
# the normalised number. The same lookup block as in the other consumers, but OPTIONAL here
# (_WPN_OPTIONAL=1): a session must still open on an installation without the library, the
# gate then warns and checks only the exact card names (see wp_card_candidates).
_WPN_ROOT_UP=".."
_WPN_OPTIONAL=1
# >>> wp-num locate
# Find scripts/lib/wp-num.sh (issue #954) from THIS file's own location with symlinks
# resolved, never from IWE_WORKSPACE / IWE_ROOT / STRATEGY_DIR: callers point those at
# fixtures. Candidates, in order: lib/ next to the file, <root>/scripts/lib, the template
# clone next to a delivered workspace (<root>/IWE), the explicit
# IWE_TEMPLATE. <root> is _WPN_ROOT_UP above the file's directory (set by each consumer
# just above this block: the only per-file difference, checked by test_issue_954_locate.sh).
# The library is mandatory: not finding it is an installation error, not "WP not found",
# hence exit 4 and not 1 (memory/protocol-open.md reads exit 1 as "WP not found").
# A consumer that must keep working without the library (session-guard: its hypothesis gate
# warns and checks the exact card names, it never blocks a session over a missing library)
# sets _WPN_OPTIONAL=1 next to _WPN_ROOT_UP: WP_NUM_LIB then stays empty and nothing is sourced.
_wpn_src="${BASH_SOURCE[0]}"
_wpn_hops=0
while [ -L "$_wpn_src" ] && [ "$_wpn_hops" -lt 40 ]; do
  _wpn_link="$(readlink "$_wpn_src")"
  case "$_wpn_link" in
    /*) _wpn_src="$_wpn_link" ;;
    *) _wpn_src="$(dirname "$_wpn_src")/$_wpn_link" ;;
  esac
  _wpn_hops=$((_wpn_hops + 1))
done
_wpn_dir="$(cd -P "$(dirname "$_wpn_src")" && pwd)"
_wpn_root="$(cd -P "$_wpn_dir/$_WPN_ROOT_UP" && pwd)"
WP_NUM_LIB=""
for _wpn_cand in "$_wpn_dir/lib/wp-num.sh" \
                 "$_wpn_root/scripts/lib/wp-num.sh" \
                 "$_wpn_root/IWE/scripts/lib/wp-num.sh" \
                 ${IWE_TEMPLATE:+"$IWE_TEMPLATE/scripts/lib/wp-num.sh"}; do
  if [ -r "$_wpn_cand" ]; then
    WP_NUM_LIB="$_wpn_cand"
    break
  fi
done
if [ -z "$WP_NUM_LIB" ] && [ -z "${_WPN_OPTIONAL:-}" ]; then
  echo "❌ wp-num.sh not found (installation error, this is not «WP not found»): required scripts/lib/wp-num.sh. Searched: ${_wpn_dir}/lib, ${_wpn_root}/scripts/lib, ${_wpn_root}/IWE/scripts/lib, IWE_TEMPLATE=${IWE_TEMPLATE:-not set}. Update the template: bash update.sh" >&2
  exit 4
fi
if [ -n "$WP_NUM_LIB" ]; then
  # shellcheck source=/dev/null
  . "$WP_NUM_LIB"
fi
# <<< wp-num locate

# Every path where the card of `--wp <id>` may be written, one per line: the id as typed
# (inbox/<id>/<id>.md and inbox/<id>.md -- what the hypothesis gate always read) and, when
# the id is a WP number and the shared reader is loaded, the folder card in both spellings
# (WP-044/, legacy WP-44/) and every flat card of the number, with or without a slug
# (WP-044.md, WP-44-task.md: wp_num_flat_cards, the lookup wp-list.py and the bundle use).
# Without the reader only the typed paths are listed. Notes are not listed.
wp_card_candidates() {
  local inbox="$1" id="$2" n pad
  printf '%s\n' "$inbox/$id/$id.md" "$inbox/$id.md"
  if type wp_num_normalize >/dev/null 2>&1 && n=$(wp_num_normalize "$id"); then
    pad=$(printf '%03d' "$n")
    printf '%s\n' "$inbox/WP-$pad/WP-$pad.md" "$inbox/WP-$n/WP-$n.md"
    wp_num_flat_cards "$inbox" "$id" || true
  fi
}

# Succeeds when the top-level `hypothesis_relation` of the card is `unclassified`.
#
# Where the field is looked for: one rule, decided by the first NON-EMPTY line of the file
# (leading blank lines, a UTF-8 BOM and CRLF are ignored).
#   * It is `---`: the card has a frontmatter, up to the next `---` line, and only the first
#     such field in it counts. The body is never read, so a YAML example in it (a fenced block
#     included) is not the card's field.
#   * It is anything else: the card has no frontmatter, and only its initial block of metadata
#     is read, the run of `key: value` lines at the top of the file, up to the first blank line,
#     Markdown heading, fence or any other line; any `hypothesis_relation` in that block counts.
#     This keeps the one-line fixtures of the WP-518 test (and cards that are bare `key: value`
#     lines) working without reading the rest of the document: a field after a heading, after
#     a blank line or inside a ``` / ~~~ fence is an example, not metadata.
#
# What the value is: a SUBSET of YAML, on purpose. Supported: single-line plain and quoted
# values. Not supported: escape sequences and multi-line scalars. A quoted value is taken whole
# (a `#` inside the quotes belongs to it, so "unclassified # example" is not `unclassified`) and
# only whitespace and a `# comment` may follow the closing quote; a plain value ends at a ` #`
# comment. No quote is stripped on its own: an unterminated "unclassified is not `unclassified`
# either. Where this differs from a YAML parser: an escape is read literally ("unclassifi\x65d"
# is not `unclassified`, although YAML decodes it to that), and a plain `unclassified` continued
# on the next line is judged by its first line only (so it still blocks, although YAML reads
# the two lines as one value).
card_is_unclassified() {
  local bom
  bom=$'\xEF\xBB\xBF'
  awk -v bom="$bom" -v sq="'" -v dq='"' '
    function scalar(text,   q, i, n, c, out, closed, tail) {
      sub(/^[[:space:]]+/, "", text)
      sub(/[[:space:]]+$/, "", text)
      q = substr(text, 1, 1)
      if (q == dq || q == sq) {
        n = length(text); out = ""; closed = 0
        for (i = 2; i <= n; i++) {
          c = substr(text, i, 1)
          if (q == dq && c == "\\") { out = out substr(text, i, 2); i++; continue }
          if (c == q) {
            if (q == sq && substr(text, i + 1, 1) == sq) { out = out sq; i++; continue }
            closed = 1
            break
          }
          out = out c
        }
        if (closed) {
          tail = substr(text, i + 1)
          if (tail == "" || tail ~ /^[[:space:]]+#/) return out
        }
        return text
      }
      sub(/[[:space:]]+#.*$/, "", text)
      return text
    }
    NR == 1 && index($0, bom) == 1 { $0 = substr($0, length(bom) + 1) }
    state == "" {
      if ($0 ~ /^[[:space:]]*$/) next
      first = $0
      sub(/[[:space:]]+$/, "", first)
      if (first == "---") { state = "frontmatter"; next }
      state = "head"
    }
    state == "frontmatter" && /^---[[:space:]]*$/ { exit }
    state == "head" && $0 !~ /^[A-Za-z_][A-Za-z0-9_-]*:/ { exit }
    /^hypothesis_relation:/ {
      v = $0
      sub(/^hypothesis_relation:/, "", v)
      if (scalar(v) == "unclassified") found = 1
      if (found || state == "frontmatter") exit
    }
    END { exit found ? 0 : 1 }
  ' "$1" 2>/dev/null
}

# Prints frozen checkout cwd sits in, or empty. FMT has no gov_repo_dir();
# check git toplevel only (sufficient for open freeze + tests).
frozen_checkout_match() {
  [ "${#FROZEN_CANONICAL_PATHS[@]}" -gt 0 ] || return 0
  local cwd_toplevel real frozen frozen_real
  cwd_toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$cwd_toplevel" ] || return 0
  real=$(realpath "$cwd_toplevel" 2>/dev/null || echo "$cwd_toplevel")
  for frozen in "${FROZEN_CANONICAL_PATHS[@]}"; do
    frozen_real=$(realpath "$frozen" 2>/dev/null || echo "$frozen")
    if [ "$real" = "$frozen_real" ]; then
      printf '%s\n' "$cwd_toplevel"
      return 0
    fi
  done
  return 0
}

resolve_isolate_push_script() {
  local candidates=(
    "$IWE_ROOT/$GOV_REPO/scripts/isolate-push.sh"
    "$IWE_ROOT/scripts/isolate-push.sh"
  )
  local c
  for c in "${candidates[@]}"; do
    [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}


# Session mutations share one permanent lock inode derived from the canonical
# `.open` path.  Python's fcntl is available on the same POSIX platforms this
# Bash script supports, unlike the external `flock` utility (absent on stock
# macOS).  The lock file is never removed or reclaimed: kernel lock lifetime is
# the authority, while a stable inode prevents unlink/recreate split-brain.
# This FMT layer is deliberately single-host: advisory locks and inode/fsync
# proofs coordinate processes sharing one local filesystem namespace.  It does
# not claim cross-host consensus or the root workspace's delivery/isolation
# guarantees; installed workspaces need an external coordinator for those.
_safe_session_token() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}$ ]]
}

_canonical_session_path() { # <path>
  python3 - "$1" "$SESSION_DIR" <<'PY'
import os
import sys

path, session_dir = sys.argv[1:]
session_dir = os.path.realpath(session_dir)
parent = os.path.realpath(os.path.dirname(os.path.abspath(path)))
name = os.path.basename(path)
if parent != session_dir or name in {"", ".", ".."} or not name.endswith(".open"):
    raise SystemExit("session path is outside the canonical session directory")
print(os.path.join(session_dir, name))
PY
}

_validate_inherited_session_lock() { # <canonical .open path>
  python3 - "$1" "$SESSION_DIR" <<'PY'
import fcntl
import hashlib
import os
import stat
import sys

target, session_dir = sys.argv[1:]
fd_text = os.environ.get("IWE_SESSION_TRANSITION_FD", "")
lock_path = os.environ.get("IWE_SESSION_TRANSITION_LOCK_PATH", "")
locked_target = os.environ.get("IWE_SESSION_TRANSITION_TARGET", "")
token = os.environ.get("IWE_SESSION_TRANSITION_TOKEN", "")
if not fd_text.isdigit() or locked_target != target:
    raise SystemExit(1)
fd = int(fd_text)
session_dir = os.path.realpath(session_dir)
expected_dir = os.path.join(os.path.dirname(session_dir), "session-transition-locks")
expected_name = hashlib.sha256(target.encode("utf-8")).hexdigest() + ".lock"
expected_path = os.path.join(expected_dir, expected_name)
if lock_path != expected_path:
    raise SystemExit(1)
info = os.fstat(fd)
named = os.lstat(lock_path)
if (
    not stat.S_ISREG(info.st_mode)
    or (info.st_dev, info.st_ino) != (named.st_dev, named.st_ino)
    or info.st_uid != os.getuid()
    or info.st_nlink != 1
    or stat.S_IMODE(info.st_mode) != 0o600
    or token != "%d:%d" % (info.st_dev, info.st_ino)
):
    raise SystemExit(1)
# Acquires the lock if a caller forged only the environment/descriptor; on a
# legitimately inherited open-file description this is an idempotent check.
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
PY
}

_ensure_session_transition_lock() { # <original .open path> [session-id]
  local semaphore="$1" session_id="${2:-}" canonical
  canonical=$(_canonical_session_path "$semaphore") \
    || fail "session-transition: unsafe semaphore path '$semaphore'" 1

  if [ -n "${IWE_SESSION_TRANSITION_FD:-}" ] || \
     [ -n "${IWE_SESSION_TRANSITION_TARGET:-}" ]; then
    _validate_inherited_session_lock "$canonical" \
      || fail "session-transition: inherited lock failed validation" 1
    return 0
  fi

  python3 - "$canonical" "$SESSION_DIR" "$0" "$CMD" "$session_id" "${SESSION_GUARD_ARGS[@]}" <<'PY'
import errno
import fcntl
import hashlib
import os
import stat
import sys
import time

target, session_dir, script, command, session_id, *original = sys.argv[1:]
session_dir = os.path.realpath(session_dir)
if os.path.realpath(os.path.dirname(target)) != session_dir:
    raise SystemExit("session-transition target escaped session directory")

lock_dir = os.path.join(os.path.dirname(session_dir), "session-transition-locks")
os.makedirs(lock_dir, mode=0o700, exist_ok=True)
directory = os.lstat(lock_dir)
if (
    not stat.S_ISDIR(directory.st_mode)
    or directory.st_uid != os.getuid()
    or stat.S_IMODE(directory.st_mode) & 0o077
):
    raise SystemExit("session-transition lock directory is not private")

lock_name = hashlib.sha256(target.encode("utf-8")).hexdigest() + ".lock"
lock_path = os.path.join(lock_dir, lock_name)
flags = os.O_RDWR | os.O_CREAT
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
fd = os.open(lock_path, flags, 0o600)
try:
    info = os.fstat(fd)
    named = os.lstat(lock_path)
    if (
        not stat.S_ISREG(info.st_mode)
        or (info.st_dev, info.st_ino) != (named.st_dev, named.st_ino)
        or info.st_uid != os.getuid()
        or info.st_nlink != 1
        or stat.S_IMODE(info.st_mode) != 0o600
    ):
        raise SystemExit("session-transition lock inode is not trusted")

    deadline = time.monotonic() + 30.0
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise SystemExit("session-transition lock busy for more than 30 seconds")
            time.sleep(0.05)

    # Revalidate the permanent name after acquisition; an unlink/recreate by
    # an untrusted peer cannot silently create a second lock domain.
    info = os.fstat(fd)
    named = os.lstat(lock_path)
    if (info.st_dev, info.st_ino) != (named.st_dev, named.st_ino):
        raise SystemExit("session-transition lock name changed during acquire")

    fixed_fd = 196
    if fd != fixed_fd:
        os.dup2(fd, fixed_fd, inheritable=True)
        os.close(fd)
        fd = fixed_fd
    else:
        os.set_inheritable(fd, True)

    env = os.environ.copy()
    env["IWE_SESSION_TRANSITION_FD"] = str(fd)
    env["IWE_SESSION_TRANSITION_LOCK_PATH"] = lock_path
    env["IWE_SESSION_TRANSITION_TARGET"] = target
    env["IWE_SESSION_TRANSITION_TOKEN"] = "%d:%d" % (info.st_dev, info.st_ino)
    if session_id:
        env["IWE_SESSION_LOCKED_SESSION_ID"] = session_id
    script = os.path.realpath(script)
    os.execve("/bin/bash", ["/bin/bash", script, command, *original], env)
finally:
    try:
        os.close(fd)
    except OSError:
        pass
PY
  exit $?
}

_locked_open_identity() { # <path> <agent> <session-id> [allow-staged-close]
  python3 - "$1" "$2" "$3" "${4:-0}" <<'PY'
import os
import stat
import sys

path, expected_agent, expected_session, allow_staged = sys.argv[1:]
flags = os.O_RDONLY
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
fd = os.open(path, flags)
try:
    info = os.fstat(fd)
    named = os.lstat(path)
    closed = path + ".closed"
    try:
        closed_info = os.lstat(closed)
    except FileNotFoundError:
        closed_info = None
    terminal_pair = (
        closed_info is not None
        and stat.S_ISREG(closed_info.st_mode)
        and (info.st_dev, info.st_ino) == (closed_info.st_dev, closed_info.st_ino)
    )
    allowed_links = (1, 2) if allow_staged == "1" and terminal_pair else (1,)
    if (
        not stat.S_ISREG(info.st_mode)
        or (info.st_dev, info.st_ino) != (named.st_dev, named.st_ino)
        or info.st_uid != os.getuid()
        or info.st_nlink not in allowed_links
        or stat.S_IMODE(info.st_mode) & 0o022
        or (closed_info is not None and not terminal_pair)
    ):
        raise SystemExit(1)
    content = os.read(fd, max(info.st_size + 1, 1)).decode("utf-8")
finally:
    os.close(fd)

lines = content.splitlines()
agents = [line[7:] for line in lines if line.startswith("agent: ")]
sessions = [line[12:] for line in lines if line.startswith("session_id: ")]
if agents != [expected_agent] or sessions != [expected_session]:
    raise SystemExit(1)
closing = [
    line
    for line in lines
    if line.startswith((
        "close_protocol: ",
        "close_attempt_id: ",
        "close_destination: ",
        "close_terminal_inode: ",
        "closed_at: ",
    ))
]
if closing and allow_staged != "1":
    raise SystemExit(1)
PY
}

_atomic_append_open() { # <path> <agent> <session-id> <heartbeat|note|close-stage> <line...>
  python3 - "$@" <<'PY'
import os
import re
import stat
import sys
import tempfile
import uuid

path, expected_agent, expected_session, mode, *records = sys.argv[1:]
if any("\n" in record or "\0" in record for record in records):
    raise SystemExit("session record contains a line break")
flags = os.O_RDONLY
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
source = os.open(path, flags)
temp_path = ""
try:
    before = os.fstat(source)
    named = os.lstat(path)
    terminal_pair = False
    if mode == "close-stage":
        try:
            terminal = os.lstat(path + ".closed")
            terminal_pair = (
                stat.S_ISREG(terminal.st_mode)
                and (before.st_dev, before.st_ino) == (terminal.st_dev, terminal.st_ino)
            )
        except FileNotFoundError:
            terminal_pair = False
    allowed_links = (1, 2) if mode == "close-stage" and terminal_pair else (1,)
    if (
        not stat.S_ISREG(before.st_mode)
        or (before.st_dev, before.st_ino) != (named.st_dev, named.st_ino)
        or before.st_uid != os.getuid()
        or before.st_nlink not in allowed_links
        or stat.S_IMODE(before.st_mode) & 0o022
    ):
        raise SystemExit("open semaphore inode is not trusted")
    data = b""
    while True:
        chunk = os.read(source, 1024 * 1024)
        if not chunk:
            break
        data += chunk
    text = data.decode("utf-8")
    lines = text.splitlines()
    if [line[7:] for line in lines if line.startswith("agent: ")] != [expected_agent]:
        raise SystemExit("semaphore agent identity changed")
    if [line[12:] for line in lines if line.startswith("session_id: ")] != [expected_session]:
        raise SystemExit("semaphore session identity changed")

    close_keys = (
        "close_protocol",
        "close_attempt_id",
        "close_destination",
        "close_terminal_inode",
        "closed_at",
    )

    def values(key):
        prefix = key + ": "
        return [line[len(prefix):] for line in lines if line.startswith(prefix)]

    close_present = any(values(key) for key in close_keys)
    expected_destination = os.path.join(
        os.path.realpath(os.path.dirname(path)),
        os.path.basename(path) + ".closed",
    )

    def validate_staged_receipt():
        fields = {}
        for key in close_keys:
            found = values(key)
            if len(found) != 1 or not found[0]:
                raise SystemExit("malformed staged close receipt")
            fields[key] = found[0]
        if fields["close_protocol"] != "durable-v2":
            raise SystemExit("unsupported staged close receipt")
        try:
            attempt = uuid.UUID(fields["close_attempt_id"])
        except (AttributeError, ValueError):
            raise SystemExit("malformed close attempt id")
        if attempt.version != 4 or str(attempt) != fields["close_attempt_id"]:
            raise SystemExit("non-canonical close attempt id")
        if fields["close_destination"] != expected_destination:
            raise SystemExit("close receipt destination does not match its exact name")
        inode = "%d:%d" % (before.st_dev, before.st_ino)
        if not re.fullmatch(r"[0-9]+:[0-9]+", fields["close_terminal_inode"]):
            raise SystemExit("malformed close terminal inode")
        if fields["close_terminal_inode"] != inode:
            raise SystemExit("close receipt was replayed onto another inode")
        return fields["close_attempt_id"]

    close_attempt_id = ""
    if mode == "close-stage":
        if close_present:
            close_attempt_id = validate_staged_receipt()
            print(close_attempt_id)
            raise SystemExit(0)
        if terminal_pair:
            raise SystemExit("terminal hardlink exists without a staged close receipt")
        if len(records) != 1 or not records[0]:
            raise SystemExit("close-stage requires one closed_at value")
        close_attempt_id = str(uuid.uuid4())
    elif close_present:
        raise SystemExit("session is already closing")

    if mode == "note" and records and records[0] in lines:
        raise SystemExit(0)

    temp_fd, temp_path = tempfile.mkstemp(prefix=".session-mutate-", dir=os.path.dirname(path))
    try:
        os.fchmod(temp_fd, stat.S_IMODE(before.st_mode))
        if mode == "close-stage":
            temp_info = os.fstat(temp_fd)
            records = [
                "close_protocol: durable-v2",
                "close_attempt_id: " + close_attempt_id,
                "close_destination: " + expected_destination,
                "close_terminal_inode: %d:%d" % (temp_info.st_dev, temp_info.st_ino),
                "closed_at: " + records[0],
            ]
        suffix = "" if not records else "\n".join(records) + "\n"
        if suffix and text and not text.endswith("\n"):
            text += "\n"
        updated = (text + suffix).encode("utf-8")
        with os.fdopen(temp_fd, "wb", closefd=True) as out:
            out.write(updated)
            out.flush()
            os.fsync(out.fileno())
        current = os.lstat(path)
        immutable = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns", "st_nlink")
        if any(getattr(current, key) != getattr(before, key) for key in immutable):
            raise SystemExit("open semaphore changed outside transition lock")
        os.replace(temp_path, path)
        temp_path = ""
        directory = os.open(os.path.dirname(path), os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        if mode == "close-stage":
            print(close_attempt_id)
    finally:
        if temp_path:
            try:
                os.unlink(temp_path)
            except FileNotFoundError:
                pass
finally:
    os.close(source)
PY
}

_publish_open_no_clobber() { # <prepared temp file> <new .open path>
  python3 - "$1" "$2" <<'PY'
import os
import stat
import sys

prepared, target = sys.argv[1:]
source = os.open(prepared, os.O_RDONLY)
try:
    info = os.fstat(source)
    named = os.lstat(prepared)
    if (
        not stat.S_ISREG(info.st_mode)
        or (info.st_dev, info.st_ino) != (named.st_dev, named.st_ino)
        or info.st_uid != os.getuid()
        or info.st_nlink != 1
        or stat.S_IMODE(info.st_mode) != 0o600
        or os.path.dirname(prepared) != os.path.dirname(target)
    ):
        raise SystemExit("prepared semaphore is not trusted")
    os.fsync(source)
    os.link(prepared, target, follow_symlinks=False)
    directory = os.open(os.path.dirname(target), os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    os.unlink(prepared)
    directory = os.open(os.path.dirname(target), os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
finally:
    os.close(source)
PY
}

_terminal_close_no_clobber() { # <open path> <agent> <session-id> <close-attempt-id>
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import os
import re
import stat
import sys
import uuid

source_path, expected_agent, expected_session, expected_attempt = sys.argv[1:]
target_path = source_path + ".closed"
flags = os.O_RDONLY
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
source = os.open(source_path, flags)
try:
    info = os.fstat(source)
    named = os.lstat(source_path)
    if (
        not stat.S_ISREG(info.st_mode)
        or (info.st_dev, info.st_ino) != (named.st_dev, named.st_ino)
        or info.st_uid != os.getuid()
        or info.st_nlink not in (1, 2)
        or stat.S_IMODE(info.st_mode) & 0o022
    ):
        raise SystemExit("close source inode is not trusted")
    content = b""
    while True:
        chunk = os.read(source, 1024 * 1024)
        if not chunk:
            break
        content += chunk
    lines = content.decode("utf-8").splitlines()
    if [line[7:] for line in lines if line.startswith("agent: ")] != [expected_agent]:
        raise SystemExit("close source agent identity changed")
    if [line[12:] for line in lines if line.startswith("session_id: ")] != [expected_session]:
        raise SystemExit("close source session identity changed")
    close_keys = (
        "close_protocol",
        "close_attempt_id",
        "close_destination",
        "close_terminal_inode",
        "closed_at",
    )
    fields = {}
    for key in close_keys:
        prefix = key + ": "
        found = [line[len(prefix):] for line in lines if line.startswith(prefix)]
        if len(found) != 1 or not found[0]:
            raise SystemExit("close source has an incomplete durable receipt")
        fields[key] = found[0]
    if fields["close_protocol"] != "durable-v2":
        raise SystemExit("close source has no durable-v2 staged receipt")
    try:
        attempt = uuid.UUID(fields["close_attempt_id"])
    except (AttributeError, ValueError):
        raise SystemExit("close source has a malformed attempt id")
    if (
        attempt.version != 4
        or str(attempt) != fields["close_attempt_id"]
        or fields["close_attempt_id"] != expected_attempt
    ):
        raise SystemExit("close attempt does not match the staged receipt")
    expected_destination = os.path.join(
        os.path.realpath(os.path.dirname(source_path)),
        os.path.basename(target_path),
    )
    if fields["close_destination"] != expected_destination:
        raise SystemExit("close destination does not match the staged receipt")
    expected_inode = "%d:%d" % (info.st_dev, info.st_ino)
    if (
        not re.fullmatch(r"[0-9]+:[0-9]+", fields["close_terminal_inode"])
        or fields["close_terminal_inode"] != expected_inode
    ):
        raise SystemExit("close source inode does not match the staged receipt")

    try:
        terminal = os.lstat(target_path)
    except FileNotFoundError:
        os.link(source_path, target_path, follow_symlinks=False)
        directory = os.open(os.path.dirname(source_path), os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        terminal = os.lstat(target_path)
    if (
        not stat.S_ISREG(terminal.st_mode)
        or (terminal.st_dev, terminal.st_ino) != (info.st_dev, info.st_ino)
    ):
        raise SystemExit("close destination already exists with different content")
    current = os.lstat(source_path)
    if (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
        raise SystemExit("close source name changed before unlink")
    os.unlink(source_path)
    directory = os.open(os.path.dirname(source_path), os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
finally:
    os.close(source)
PY
}

_terminal_move_no_clobber() { # <source> <terminal destination>
  python3 - "$1" "$2" <<'PY'
import os
import stat
import sys

source_path, target_path = sys.argv[1:]
if os.path.dirname(source_path) != os.path.dirname(target_path):
    raise SystemExit("terminal destination escaped semaphore directory")
flags = os.O_RDONLY
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
source = os.open(source_path, flags)
try:
    info = os.fstat(source)
    named = os.lstat(source_path)
    if (
        not stat.S_ISREG(info.st_mode)
        or (info.st_dev, info.st_ino) != (named.st_dev, named.st_ino)
        or info.st_uid != os.getuid()
        or info.st_nlink not in (1, 2)
        or stat.S_IMODE(info.st_mode) & 0o022
    ):
        raise SystemExit("terminal source inode is not trusted")
    try:
        terminal = os.lstat(target_path)
    except FileNotFoundError:
        os.link(source_path, target_path, follow_symlinks=False)
        directory = os.open(os.path.dirname(source_path), os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        terminal = os.lstat(target_path)
    if (
        not stat.S_ISREG(terminal.st_mode)
        or (terminal.st_dev, terminal.st_ino) != (info.st_dev, info.st_ino)
    ):
        raise SystemExit("terminal destination already belongs to another inode")
    current = os.lstat(source_path)
    if (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
        raise SystemExit("terminal source name changed before unlink")
    os.unlink(source_path)
    directory = os.open(os.path.dirname(source_path), os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
finally:
    os.close(source)
PY
}

_closed_receipt_identity() { # <closed path> <agent> <session-id>
  python3 - "$1" "$2" "$3" <<'PY'
import os
import re
import stat
import sys
import uuid

path, expected_agent, expected_session = sys.argv[1:]
flags = os.O_RDONLY
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
fd = os.open(path, flags)
try:
    info = os.fstat(fd)
    named = os.lstat(path)
    if (
        not stat.S_ISREG(info.st_mode)
        or (info.st_dev, info.st_ino) != (named.st_dev, named.st_ino)
        or info.st_uid != os.getuid()
        or info.st_nlink != 1
        or stat.S_IMODE(info.st_mode) & 0o022
    ):
        raise SystemExit(1)
    content = b""
    while True:
        chunk = os.read(fd, 1024 * 1024)
        if not chunk:
            break
        content += chunk
finally:
    os.close(fd)
lines = content.decode("utf-8").splitlines()
if [line[7:] for line in lines if line.startswith("agent: ")] != [expected_agent]:
    raise SystemExit(1)
if [line[12:] for line in lines if line.startswith("session_id: ")] != [expected_session]:
    raise SystemExit(1)
close_keys = (
    "close_protocol",
    "close_attempt_id",
    "close_destination",
    "close_terminal_inode",
    "closed_at",
)
fields = {}
for key in close_keys:
    prefix = key + ": "
    found = [line[len(prefix):] for line in lines if line.startswith(prefix)]
    if len(found) != 1 or not found[0]:
        raise SystemExit(1)
    fields[key] = found[0]
if fields["close_protocol"] != "durable-v2":
    raise SystemExit(1)
try:
    attempt = uuid.UUID(fields["close_attempt_id"])
except (AttributeError, ValueError):
    raise SystemExit(1)
if attempt.version != 4 or str(attempt) != fields["close_attempt_id"]:
    raise SystemExit(1)
expected_destination = os.path.join(
    os.path.realpath(os.path.dirname(path)),
    os.path.basename(path),
)
if fields["close_destination"] != expected_destination:
    raise SystemExit(1)
expected_inode = "%d:%d" % (info.st_dev, info.st_ino)
if (
    not re.fullmatch(r"[0-9]+:[0-9]+", fields["close_terminal_inode"])
    or fields["close_terminal_inode"] != expected_inode
):
    raise SystemExit(1)
PY
}

# yaml_task_line <value> -- render a "task: <value>" YAML line, quoting the
# value only when PyYAML's own writer decides it needs quoting. session-guard
# used to write this field with a bare `echo "task: $TASK"`: a value
# containing a literal ": " (a real one arrived 2026-09-09, "WP170: R15-triage
# ...") produced a line no strict YAML parser can read back as a mapping,
# leaving the semaphore ambiguous to any such reader -- see
# bug-2026-09-09-git-wrapper-blocked-by-corrupt-semaphore.md. Delegates to
# PyYAML rather than reimplementing the plain-scalar grammar in bash, and
# falls back to the old bare form if PyYAML is unavailable -- a missing
# dependency degrades to previous behaviour instead of failing `open`. Not
# reused for other semaphore fields (e.g. `housekeeping:`/`slug:`, see the
# comment at their write site) -- those are matched elsewhere by exact
# raw-string equality and doubling as filename components, so quoting them
# would trade this bug for a different one, not just extend the same fix.
# width=10**7 disables PyYAML's default 80-column wrapping (cold review of
# this same fix, 2026-09-10): ordinary prose long enough to exceed 80
# columns -- not an edge case -- was folded onto a continuation line that
# every raw `grep '^task: ' | cut` reader then silently truncated away,
# reintroducing the same corruption class by length instead of by ": ".
# Embedded newlines fold the scalar the same way regardless of width, so
# they are collapsed to spaces first -- this field is documented as
# single-line, not free-form multi-line text.
yaml_task_line() {
  python3 -c '
import sys
value = " ".join(sys.argv[1].splitlines())
try:
    import yaml
except ImportError:
    # #1006: the bare fallback used to print the raw value unescaped,
    # reintroducing the exact ": "-in-value corruption this function exists
    # to fix (bug-2026-09-09-...), just only when PyYAML happens to be
    # missing. A double-quoted YAML scalar accepts the same range of values
    # that PyYAML would reach for quoting on, without needing the full
    # plain-scalar grammar.
    escaped = value.replace("\\", "\\\\").replace("\"", "\\\"")
    print("task: \"%s\"" % escaped)
    raise SystemExit(0)
sys.stdout.write(yaml.safe_dump({"task": value}, allow_unicode=True, default_flow_style=False, width=10**7).rstrip("\n"))
' "$1"
}

# resolve_orz_sessions_dir -- forward-port from ~/IWE/scripts/session-guard.sh
# (WP-526 Phase2, 29.08; this FMT copy stays on the reduced/freeze-canonical
# variant per WP-546, so only this one function is ported, not the file).
# Three-way resolver for the sessions-content root: MC-sessions is created
# "on demand", not by setup.sh (pilot decision 18.08), so an install that
# never adopted it must keep working exactly as before this function existed.
#   1. IWE_SESSIONS_ROOT set explicitly -- always fail-closed if broken,
#      never falls back: an explicit override is a deliberate choice, a
#      silent bypass of it would hide a real misconfiguration.
#   2. Default path ($IWE_ROOT/MC-sessions) exists and is a valid git repo
#      -- the normal case for an already-migrated checkout.
#   3. Default path exists but ISN'T a valid git repo -- looks like a
#      broken migration, not a fresh install. Fail-closed: falling back
#      here would create a second, undetected source of truth for an
#      already-migrated user.
#   4. Default path doesn't exist at all -- genuinely unmigrated. Legacy
#      fallback to "$GOV_REPO/sessions" with a visible WARN, same
#      behaviour as before this function existed.
resolve_orz_sessions_dir() {
  if [ -n "${IWE_SESSIONS_ROOT:-}" ]; then
    if [ -d "$IWE_SESSIONS_ROOT" ] && git -C "$IWE_SESSIONS_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
      echo "$IWE_SESSIONS_ROOT"
      return 0
    fi
    fail "IWE_SESSIONS_ROOT=$IWE_SESSIONS_ROOT set explicitly, but is inaccessible or is not a git-repository"
  fi

  local default_mc="$IWE_ROOT/MC-sessions"
  if [ -d "$default_mc" ]; then
    if git -C "$default_mc" rev-parse --git-dir >/dev/null 2>&1; then
      echo "$default_mc"
      return 0
    fi
    fail "MC-sessions exists ($default_mc), but does not look like a git-repository -- looks like a broken migrated installation, not falling back to legacy-path silently"
  fi

  echo "WARN: MC-sessions not found ($default_mc) -- using legacy-path \$GOV_REPO/sessions (normal behavior of a non-migrated template installation)" >&2
  local legacy="$IWE_ROOT/$GOV_REPO/sessions"
  mkdir -p "$legacy"
  echo "$legacy"
}
# Passive default here (no resolver call, no side effect) -- this line runs
# for EVERY subcommand, including ones unrelated to sessions storage
# (pre-commit-check fires on every git commit as a hook; note-file,
# lock-hot-file don't touch ORZ_DIR at all). Calling the strict resolver
# unconditionally would print its WARN on every commit for an unmigrated
# install, and hard-fail unrelated git operations for a broken migration.
# `open` (the only writer) calls resolve_orz_sessions_dir() itself, below.
ORZ_DIR="$IWE_ROOT/$GOV_REPO/sessions"

semaphore_epoch() {
  local semaphore="$1" timestamp=""
  timestamp=$(grep -E '^(opened_at|created_at): ' "$semaphore" | head -1 | cut -d' ' -f2- || true)
  [ -n "$timestamp" ] || return 1
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null \
    || date -u -d "$timestamp" +%s 2>/dev/null
}

# --- Lease: the semaphore right to authorize a commit (WP-484 Phase49, 04.08, peer-session with Codex) ---
#
# The semaphore carries two DISTINCT functions, which until now have been merged into one
# state `.open`:
#   A — «a session exists, do not touch it»;
#   B — «files of this session are authorized for commit» (scope gate below).
# WP-507 (30.07) — abandoned semaphore 4.5h was granting function B to unrelated files for 4.5h.
# This was addressed with auto-age-based quarantine in `open`, but it takes away feature A:
# any session older than TTL was moved into `.orphaned-*`, as soon as the same agent
# opened a second one, and after that could not complete Quick Close (`close`
# selects only `*.open`). On disk 155 such files versus 293 closed
# normally. Separating responsibilities removes the conflict: age-based revocation applies only to B.
#
# The lease lives in a SEPARATE file `<semaphore>.lease`, not as a line inside the semaphore:
#   1. append into the semaphore advances its mtime, and scope gate compares mtime of files
#      against mtime of the semaphore — renewing the lease would silently revoke permission from files,
#      edited before the renewal;
#   2. repeated append introduce ambiguity between «first or last entry»
#      (sweep_orphaned_semaphores above reads `head -1`);
#   3. the lease filename is derived from the semaphore filename — the binding to a specific
#      session is structural, extending someone elses lease «incidentally» is not possible.
LEASE_SEC="${IWE_SESSION_LEASE_SEC:-14400}"  # 4h; renewal — `renew`

lease_deadline_epoch() {
  local semaphore="$1" base_epoch renewed_at renewed_epoch=""
  base_epoch=$(semaphore_epoch "$semaphore") || return 1
  if [ -f "${semaphore}.lease" ]; then
    renewed_at=$(grep '^renewed_at: ' "${semaphore}.lease" | tail -1 | cut -d' ' -f2- || true)
    if [ -n "$renewed_at" ]; then
      renewed_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$renewed_at" +%s 2>/dev/null \
        || date -u -d "$renewed_at" +%s 2>/dev/null || echo "")
    fi
  fi
  if [ -n "$renewed_epoch" ] && [ "$renewed_epoch" -gt "$base_epoch" ]; then
    base_epoch="$renewed_epoch"
  fi
  echo $(( base_epoch + LEASE_SEC ))
}

# A semaphore without a parseable timestamp (pre-WP-484 or corrupted) does NOT receive
# permissions: this exact case was flagged by independent review: this exact case the independent review 01.08 flagged as a risk
# of scope gate weakening scope gate, and the auto-quarantine does not cover it by design.
lease_valid() {
  local semaphore="$1" deadline
  deadline=$(lease_deadline_epoch "$semaphore") || return 1
  [ "$(date +%s)" -lt "$deadline" ]
}

sweep_orphaned_semaphores() {
  local semaphore pid age epoch quarantined=0 ambiguous=0
  while IFS= read -r semaphore; do
    [ -f "$semaphore" ] || continue
    pid=$(grep '^pid: ' "$semaphore" | head -1 | cut -d' ' -f2- || true)
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      if ! kill -0 "$pid" 2>/dev/null; then
        if bash "$SESSION_GUARD_SELF" __quarantine-dead "$semaphore" "$pid" >/dev/null; then
          echo "WARNING: orphaned semaphore $(basename "$semaphore") quarantined: pid $pid is dead" >&2
          quarantined=$((quarantined + 1))
        else
          echo "WARNING: dead-pid semaphore $(basename "$semaphore") changed or could not be locked; kept for review" >&2
          ambiguous=$((ambiguous + 1))
        fi
      fi
      continue
    fi

    epoch=$(semaphore_epoch "$semaphore" || true)
    [ -n "$epoch" ] || {
      echo "WARNING: semaphore $(basename "$semaphore") has no live pid or parseable timestamp; manual review required" >&2
      ambiguous=$((ambiguous + 1))
      continue
    }
    age=$(( $(date +%s) - epoch ))
    if [ "$age" -gt 1800 ]; then
      echo "WARNING: semaphore $(basename "$semaphore") is ${age}s old without pid proof; kept for manual review" >&2
      ambiguous=$((ambiguous + 1))
    fi
  done < <(find "$SESSION_DIR" -name '*.open' -type f 2>/dev/null)
  echo "Semaphore sweep: quarantined=$quarantined ambiguous=$ambiguous"
}
orz_agent_name() {
  case "$1" in
    kimi) echo "kimi-headless" ;;
    *)    echo "$1" ;;
  esac
}

# WP-464: pick the semaphore matching --wp/--slug among an agent's open
# semaphores. Ambiguous only when 2+ are open and none match — fails loudly
# with the candidate list instead of guessing "newest" (bug-2026-06-23,
# bug-2026-07-03-close-ignores-wp-arg, bug-2026-07-04-ptr-collision).
#
# Return codes (caller must check — this function never calls `exit`: inside
# a `$(...)` substitution `exit` only kills the subshell, not the script,
# code review a8fe9ded caught this):
#   0 — printed the selected semaphore path to stdout
#   1 — no open semaphore at all for this agent
#   2 — ambiguous or requested --wp/--slug matched nothing; candidate list
#       already printed to stderr, caller should just propagate a failure
list_candidates() { # list_candidates <agent> — one path per line, newest first
  ls -t "$SESSION_DIR/${1}"-*.open 2>/dev/null || true
}

print_candidates() { # print_candidates <candidates> — human-readable list to stderr
  local cand
  while IFS= read -r cand; do
    [ -z "$cand" ] && continue
    echo "  $(basename "$cand")  wp=$(grep "^wp: " "$cand" | cut -d' ' -f2-)  slug=$(grep "^slug: " "$cand" | cut -d' ' -f2-)" >&2
  done <<< "$1"
}

select_semaphore() {
  local agent="$1" want_wp="$2" want_slug="$3"
  local candidates cand cand_wp cand_slug count
  local matches=()

  candidates=$(list_candidates "$agent")
  [ -z "$candidates" ] && return 1

  if [ -n "$want_wp" ] || [ -n "$want_slug" ]; then
    while IFS= read -r cand; do
      [ -z "$cand" ] && continue
      cand_wp=$(grep "^wp: " "$cand" | cut -d' ' -f2- || true)
      cand_slug=$(grep "^slug: " "$cand" | cut -d' ' -f2- || true)
      # WP-530 Phase12 (20.08, peer-session with Codex): with both selectors given, this
      # must be an intersection -- a plain OR (as this copy had until now)
      # matches a stale sibling session sharing only the wp, causing false
      # ambiguity. Synced from the canonical ~/IWE/scripts/session-guard.sh
      # (WP-484 Phase49, 04.08) -- same fix, this copy just hadn't received it.
      if { [ -n "$want_wp" ] && [ -n "$want_slug" ] &&
           [ "$cand_wp" = "$want_wp" ] && [ "$cand_slug" = "$want_slug" ]; } || \
         { [ -z "$want_slug" ] && [ -n "$want_wp" ] && [ "$cand_wp" = "$want_wp" ]; } || \
         { [ -z "$want_wp" ] && [ -n "$want_slug" ] && [ "$cand_slug" = "$want_slug" ]; }; then
        matches+=("$cand")
      fi
    done <<< "$candidates"

    if [ "${#matches[@]}" -eq 1 ]; then
      echo "${matches[0]}"
      return 0
    fi

    # WP-484 Phase49 (04.08, Codex): there used to be `break` on the first match,
    # that is, when two open sessions of the same WP existed, simply the newest one by
    # mtime — and `close` closed the wrong session, while `note-file` gave commit rights to
    # someone elses work. Multiple matches. Multiple matched — this is a rejection, not a guess: clarify
    # --slug or --session-id.
    if [ "${#matches[@]}" -gt 1 ]; then
      echo "session-guard: matching wp='$want_wp' slug='$want_slug' multiple sessions of agent match '$agent' — clarify:" >&2
      print_candidates "$(printf '%s\n' "${matches[@]}")"
      return 2
    fi

    # Explicit --wp/--slug was given and matched nothing — never silently
    # fall back to "the only open one", even when there's exactly one.
    # Falling back here would close/note-file the WRONG session under the
    # operator's own explicit (but mistyped/stale) --wp, defeating the
    # entire point of this fix.
    echo "session-guard: none of the open semaphores of agent '$agent' matched wp='$want_wp' slug='$want_slug':" >&2
    print_candidates "$candidates"
    return 2
  fi

  count=$(echo "$candidates" | grep -c . || true)
  if [ "$count" -eq 1 ]; then
    echo "$candidates"
    return 0
  fi

  echo "session-guard: multiple open semaphores for agent '$agent' — specify --wp/--slug:" >&2
  while IFS= read -r cand; do
    [ -z "$cand" ] && continue
    cand_wp=$(grep "^wp: " "$cand" | cut -d' ' -f2- || true)
    cand_slug=$(grep "^slug: " "$cand" | cut -d' ' -f2- || true)
    echo "  $(basename "$cand")  wp=$cand_wp  slug=$cand_slug" >&2
  done <<< "$candidates"
  return 2
}

resolve_semaphore_by_session_id() { # <agent> <session-id> [wp] [slug]
  local agent="$1" session_id="$2" want_wp="${3:-}" want_slug="${4:-}"
  local semaphore sem_wp sem_slug
  _safe_session_token "$agent" || {
    echo "unsafe agent '$agent'" >&2
    return 2
  }
  _safe_session_token "$session_id" || {
    echo "unsafe --session-id '$session_id'" >&2
    return 2
  }
  semaphore="$SESSION_DIR/${agent}-${session_id}.open"
  [ -f "$semaphore" ] || return 1
  sem_wp=$(grep '^wp: ' "$semaphore" | cut -d' ' -f2- || true)
  sem_slug=$(grep '^slug: ' "$semaphore" | cut -d' ' -f2- || true)
  if [ -n "$want_wp" ] && [ "$sem_wp" != "$want_wp" ]; then
    echo "--session-id $session_id points to wp='$sem_wp', but received --wp='$want_wp'" >&2
    return 2
  fi
  if [ -n "$want_slug" ] && [ "$sem_slug" != "$want_slug" ]; then
    echo "--session-id $session_id points to slug='$sem_slug', but received --slug='$want_slug'" >&2
    return 2
  fi
  echo "$semaphore"
}

_owner_pid_is_live_ancestor() { # <pid>; call-shape guard, not authentication
  local owner_pid="$1" current="$PPID" hops=0
  [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$owner_pid" 2>/dev/null || return 1
  # Bash may tail-exec the final `bash session-guard.sh ...` in a wrapper; in
  # that legitimate shape the wrapper's $$ becomes this process's $$ rather
  # than appearing in the PPID chain.
  [ "$owner_pid" = "$$" ] && return 0
  while [[ "$current" =~ ^[1-9][0-9]*$ ]] && [ "$hops" -lt 16 ]; do
    [ "$current" = "$owner_pid" ] && return 0
    [ "$current" = "1" ] && break
    current=$(ps -o ppid= -p "$current" 2>/dev/null | tr -d '[:space:]')
    hops=$((hops + 1))
  done
  return 1
}

# --- parse args ---
WP=""
TASK=""
FILES=""
SLUG=""
AGENT="${IWE_AGENT:-}"
HOUSEKEEPING=""
PERSONALITY=""
SESSION_ID_ARG=""
OWNER_PID=""
CLEANUP_ORPHANS=0
FORCE_NO_REFLECTION=""
CLOSE_PATH=""
ISOLATE_FLAG=0
BASE_SHA=""
ISOLATED_WORKTREE_PATH=""
ISOLATED_WORKTREE_BRANCH=""
FORCE_FLAG=0
UNFREEZE_REASON=""
CANONICAL_OWNER=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wp)     WP="$2"; shift 2 ;;
    --task)   TASK="$2"; shift 2 ;;
    --files)  FILES="$2"; shift 2 ;;
    --slug|--topic) SLUG="$2"; shift 2 ;;
    --agent)  AGENT="$2"; shift 2 ;;
    --isolate) ISOLATE_FLAG=1; shift ;;
    --base-sha) BASE_SHA="$2"; shift 2 ;;
    --force) FORCE_FLAG=1; shift ;;
    --reason) UNFREEZE_REASON="$2"; shift 2 ;;
    --canonical-owner) CANONICAL_OWNER="$2"; shift 2 ;;
    --housekeeping) HOUSEKEEPING="$2"; shift 2 ;;
    --personality) PERSONALITY="$2"; shift 2 ;;
    --session-id) SESSION_ID_ARG="$2"; shift 2 ;;
    --owner-pid) OWNER_PID="$2"; shift 2 ;;
    --since)  SINCE="$2"; shift 2 ;;
    --cleanup-orphans) CLEANUP_ORPHANS=1; shift ;;
    --force-no-reflection) FORCE_NO_REFLECTION="$2"; shift 2 ;;
    --close-path) CLOSE_PATH="$2"; shift 2 ;;
    --)       shift; POSITIONAL+=("$@"); break ;;
    # WP-7 Phase83: was a silent `shift` -- unrecognized flags vanished with no diagnostic.
    -*)       fail "unknown flag: $1" 1 ;;
    *)        POSITIONAL+=("$1"); shift ;;
  esac
done

if [ -z "$AGENT" ] && { [ "$CMD" = "open" ] || [ "$CMD" = "close" ]; }; then
  fail "--agent is required for open/close (or the variable IWE_AGENT)" 1
fi

# Internal one-semaphore sweep worker.  Running it as a child lets every
# candidate use the same exec-held per-session lock without nesting locks for
# unrelated sessions in the parent audit process.
if [ "$CMD" = "__quarantine-dead" ]; then
  [ "${#POSITIONAL[@]}" -eq 2 ] || fail "internal quarantine: expected semaphore and pid" 1
  QUARANTINE_SEM=$(_canonical_session_path "${POSITIONAL[0]}") \
    || fail "internal quarantine: path outside session directory" 1
  QUARANTINE_PID="${POSITIONAL[1]}"
  [[ "$QUARANTINE_PID" =~ ^[1-9][0-9]*$ ]] || fail "internal quarantine: invalid pid" 1
  [ -f "$QUARANTINE_SEM" ] || fail "internal quarantine: open semaphore disappeared" 1
  QUARANTINE_AGENT=$(grep '^agent: ' "$QUARANTINE_SEM" | cut -d' ' -f2- || true)
  QUARANTINE_SESSION=$(grep '^session_id: ' "$QUARANTINE_SEM" | cut -d' ' -f2- || true)
  _safe_session_token "$QUARANTINE_AGENT" || fail "internal quarantine: invalid agent identity" 1
  _safe_session_token "$QUARANTINE_SESSION" || fail "internal quarantine: no exact session identity" 1
  _ensure_session_transition_lock "$QUARANTINE_SEM" "$QUARANTINE_SESSION"
  _locked_open_identity "$QUARANTINE_SEM" "$QUARANTINE_AGENT" "$QUARANTINE_SESSION" 0 \
    || fail "internal quarantine: identity changed or close already staged" 1
  [ "$(grep '^pid: ' "$QUARANTINE_SEM" | head -1 | cut -d' ' -f2- || true)" = "$QUARANTINE_PID" ] \
    || fail "internal quarantine: owner pid changed" 1
  ! kill -0 "$QUARANTINE_PID" 2>/dev/null \
    || fail "internal quarantine: owner pid is alive again" 1
  _terminal_move_no_clobber "$QUARANTINE_SEM" "${QUARANTINE_SEM}.orphaned-dead-pid" \
    || fail "internal quarantine: terminal destination collision" 1
  rm -f "${QUARANTINE_SEM}.lease"
  exit 0
fi

# --- OPEN ---
if [ "$CMD" = "open" ]; then
  [ "${#POSITIONAL[@]}" -eq 0 ] || fail "open does not accept positional arguments" 1
  if [ -n "${BASE_SHA:-}" ] && [ "${ISOLATE_FLAG:-0}" != "1" ]; then
    fail "--base-sha is allowed only together with --isolate" 1
  fi
  _safe_session_token "$AGENT" || fail "open: unsafe --agent '$AGENT'" 1
  if [ -n "$SESSION_ID_ARG" ]; then
    _safe_session_token "$SESSION_ID_ARG" || fail "open: unsafe --session-id '$SESSION_ID_ARG'" 1
  fi
  if [ -n "$OWNER_PID" ]; then
    [[ "$OWNER_PID" =~ ^[1-9][0-9]*$ ]] || fail "open: --owner-pid must be a positive PID" 1
    kill -0 "$OWNER_PID" 2>/dev/null || fail "open: --owner-pid $OWNER_PID does not exist" 1
  fi
  # WP-510 Patch 4: personality — a routing label "which AI-personality conducted
  # the session, not an access grant to memory", not an access grant to memory (PIPE-14 handles the transfer separately). Empty flag =
  # unassigned — the same outcome, as an explicit `--personality unassigned`, the difference
  # explicit/default is not stored (consensus 2026-08-04-11-codex-wp510-patch4-proposed).
  PERSONALITY="${PERSONALITY:-unassigned}"
  if [ "$PERSONALITY" != "unassigned" ] && ! [[ "$PERSONALITY" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    fail "--personality: expected 'unassigned' or UUID of the form 8-4-4-4-12 (received: '$PERSONALITY')" 1
  fi

  if [ -n "$HOUSEKEEPING" ]; then
    # Housekeeping session: no ORZ, no WP, one semaphore per (agent, reason).
    _safe_session_token "$HOUSEKEEPING" || fail "open --housekeeping: reason must be a safe slug" 1
    HK_FILE="$SESSION_DIR/${AGENT}-housekeeping-${HOUSEKEEPING}.open"
    HK_SESSION_ID="housekeeping-${HOUSEKEEPING}"
    _safe_session_token "$HK_SESSION_ID" || fail "open --housekeeping: identifier is too long" 1
    _ensure_session_transition_lock "$HK_FILE" "$HK_SESSION_ID"
    HK_MAX_AGE=1800  # 30 minutes default TTL for housekeeping semaphores
    NOW_EPOCH=$(date +%s)
    if [ -f "$HK_FILE" ]; then
      HK_CREATED=$(grep "^created_at: " "$HK_FILE" | cut -d' ' -f2- || echo "")
      if [ -n "$HK_CREATED" ]; then
        HK_CREATED_EPOCH=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$HK_CREATED" +%s 2>/dev/null || date -d "$HK_CREATED" +%s 2>/dev/null || echo "")
        if [ -n "$HK_CREATED_EPOCH" ]; then
          HK_AGE=$(( NOW_EPOCH - HK_CREATED_EPOCH ))
          if [ "$HK_AGE" -gt "$HK_MAX_AGE" ]; then
            _terminal_move_no_clobber "$HK_FILE" "${HK_FILE}.stale" \
              || fail "open --housekeeping: .stale destination collision; existing open preserved" 1
            rm -f "${HK_FILE}.lease"
            echo "WARNING: housekeeping semaphore '${HOUSEKEEPING}' stale (${HK_AGE}s), renamed to .stale" >&2
          else
            fail "open --housekeeping: an active housekeeping-session '${HOUSEKEEPING}' (age ${HK_AGE}s). Close it or wait for TTL ${HK_MAX_AGE}s" 1
          fi
        fi
      fi
    fi
    HK_TMP=$(mktemp "$SESSION_DIR/.session-open.XXXXXX")
    chmod 600 "$HK_TMP"
    {
      echo "---"
      echo "agent: $AGENT"
      echo "personality: $PERSONALITY"
      # NOT run through yaml_task_line, unlike `task:` in the main open path
      # below: $HOUSEKEEPING is also interpolated straight into a filename
      # (HK_FILE, above) and matched elsewhere by exact raw-string equality
      # (select_semaphore, close, note-file, orphan audit all grep
      # '^slug: ' | cut and compare to the CLI argument verbatim) -- it is a
      # path-safe slug token by convention, not free-form prose like `task`.
      # Quoting only this line would not even close the YAML-parseability
      # gap it shares with `slug:` below (same raw value, same document)
      # without also quoting `slug:` -- and quoting `slug:` breaks every
      # exact-match consumer. A colon here already produces an unparseable
      # document for a strict reader regardless; the real fix is
      # validating/restricting `--housekeeping` to a path-safe token, a
      # separate, larger decision than this bug's scope (bug-2026-09-09-
      # git-wrapper-blocked-by-corrupt-semaphore.md, "Resolution", 2026-09-10).
      echo "housekeeping: $HOUSEKEEPING"
      # bug-2026-07-10 (Day Close): select_semaphore() only matches on `wp:`/`slug:`
      # lines. Without this, 2+ open housekeeping semaphores are permanently
      # ambiguous for note-file/close — --slug has nothing to match against.
      echo "slug: $HOUSEKEEPING"
      echo "session_id: $HK_SESSION_ID"
      echo "created_at: $(now_iso)"
      # $$ here is session-guard.sh's own transient process — already dead by
      # the time anyone checks it (verified live 08.08: recorded pid was dead
      # within the same second). $CLAUDE_PID is the actual long-lived Claude
      # Code process that stays alive for the whole session; other agents keep
      # today's behavior (transient $$, harmless — dead-pid check just never
      # fires for them, same as before this fix).
      echo "pid: ${OWNER_PID:-${CLAUDE_PID:-$$}}"
      echo "---"
    } > "$HK_TMP"
    _publish_open_no_clobber "$HK_TMP" "$HK_FILE" \
      || { rm -f "$HK_TMP"; fail "open --housekeeping: semaphore appeared concurrently; existing file not modified" 1; }
    echo "Housekeeping OPEN: $HK_FILE (reason: $HOUSEKEEPING)"
    exit 0
  fi

  [ -z "$WP" ] && fail "--wp is required for open" 2

  # WP-518: WP creation and starting work — are separate decisions. A new creator
  # of cards writes `hypothesis_relation: unclassified`, until the pilot has chosen
  # the purpose of the work within the bets loop. Such a WP can be registered and
  # discussed, but cannot be opened for file modification: otherwise the value of the
  # required field becomes an optional annotation.
  #
  # The missing field is intentionally not blocked: this is a card, created before
  # the contract was introduced, and bulk back-filling of historical WPs is not
  # a safe side effect of opening a single session.
  # issue #954: --wp 44, 044, WP-44 and WP-044 name one card (folder WP-044/), so every
  # place the card can be written is checked and ANY of them still marked unclassified
  # blocks the open (see wp_card_candidates). A note that merely carries `wp: N` is not a card.
  # The field is read by card_is_unclassified (where it is looked for -- the frontmatter, or
  # the initial block of metadata of a card without one -- and which values it understands
  # are described there), not grepped from the whole file: a trailing `# comment` does not
  # hide it and an example in the body does not fake it. A session is never refused for the
  # lack of the shared reader (the gate degrades instead), but checking less than it promises
  # must not be silent: one warning, and the exact card names are still checked. `open`
  # re-executes itself under the transition lock (_ensure_session_transition_lock), which runs
  # this gate a second time: warn on the first pass only.
  if ! type wp_num_normalize >/dev/null 2>&1 \
     && [ -z "${IWE_SESSION_TRANSITION_FD:-}" ] && [ -z "${IWE_SESSION_TRANSITION_TARGET:-}" ]; then
    echo "session-guard: wp-num.sh not found: hypothesis gate checks only exact card names" >&2
  fi
  WP_CARD=""
  while IFS= read -r _sg_card; do
    if [ -f "$_sg_card" ] && card_is_unclassified "$_sg_card"; then
      WP_CARD="$_sg_card"
      break
    fi
  done < <(wp_card_candidates "$IWE_ROOT/$GOV_REPO/inbox" "$WP")
  if [ -n "$WP_CARD" ]; then
    fail "WP $WP is not classified by hypothesis. Before opening choose tests, enables, responds, researches or operational in $WP_CARD" 1
  fi

  # Report stale semaphores of the same agent — WITHOUT quarantining them.
  #
  # WP-484 Phase49 (04.08): this loop used to `mv` every semaphore older than the
  # TTL into `.orphaned-*`. Age alone proves nothing about liveness, so it kept
  # killing sessions that were actively working — live case that triggered the
  # fix: a WP-7 session whose semaphore had been written to one minute earlier
  # was quarantined because `opened_at` was 43 minutes old. Once renamed, the
  # session can no longer close (`close` only selects `*.open`) — that is the
  # mechanism behind Phase49's "delivered work, no formal Quick Close".
  # Liveness is now decided where it matters (scope gate, via `lease_valid`),
  # and quarantine stays only where a real death signal exists: a dead pid in
  # `sweep_orphaned_semaphores` above.
  # WP-464: check EVERY open semaphore of this agent, not only the newest —
  # `head -1` used to leave older-but-still-stale siblings undetected whenever
  # a younger one existed for the same agent_id.
  while IFS= read -r STALE; do
    [ -z "$STALE" ] && continue
    [ -f "$STALE" ] || continue
    # Age by `opened_at:` (when the session actually started), not mtime —
    # WP-484 Thread1 (peer-session 2026-07-31-14-wp484-session-close-discipline):
    # any unrelated append (note-file, a stray write into the wrong semaphore)
    # bumps mtime and resets the TTL clock, which is exactly how a truly
    # abandoned semaphore (WP-507, 30.07) survived auto-orphan for 4.5h while
    # collecting other sessions' files. Falls back to created_at, then to a
    # loud WARN (no more silent mtime fallback — see WP-484 Phase31 below).
    STALE_OPENED_AT=$(grep "^opened_at: " "$STALE" | cut -d' ' -f2- || true)
    STALE_EPOCH=""
    if [ -n "$STALE_OPENED_AT" ]; then
      STALE_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$STALE_OPENED_AT" +%s 2>/dev/null \
        || date -u -d "$STALE_OPENED_AT" +%s 2>/dev/null || echo "")
    fi
    # Fallback to mtime is REMOVED to prevent WP-507-style orphan resurrection
    # (append-operations updating mtime restart the TTL clock).
    # If opened_at failed, try created_at (immutable backup added in WP-484 Phase31).
    if [ -z "$STALE_EPOCH" ]; then
      STALE_CREATED_AT=$(grep "^created_at: " "$STALE" | cut -d' ' -f2- || true)
      if [ -n "$STALE_CREATED_AT" ]; then
        STALE_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$STALE_CREATED_AT" +%s 2>/dev/null \
          || date -u -d "$STALE_CREATED_AT" +%s 2>/dev/null || echo "")
      fi
    fi
    # Neither timestamp present/parseable (pre-WP-484 semaphore, or corrupt
    # file): this semaphore can NEVER be auto-orphaned now that mtime fallback
    # is gone. Independent code review (01.08) flagged the silent version of
    # this as a scope-gate weakening risk — loud WARN so it surfaces in `audit`
    # and in whatever log captures open's stderr, instead of vanishing.
    if [ -z "$STALE_EPOCH" ]; then
      echo "WARNING: semaphore ($(basename "$STALE")) has no opened_at/created_at — cannot auto-orphan, needs manual cleanup or 'audit' review" >&2
      continue
    fi
    STALE_AGE=$(( $(date +%s) - STALE_EPOCH ))
    if [ "$STALE_AGE" -gt 1800 ]; then
      STALE_WP=$(grep "^wp: " "$STALE" | cut -d' ' -f2- || echo "unknown")
      if lease_valid "$STALE"; then
        echo "NOTE: agent has a long-running session open $(basename "$STALE") (WP: $STALE_WP, age ${STALE_AGE}s) — commit rights are active, leaving it untouched" >&2
      else
        echo "WARNING: session $(basename "$STALE") (WP: $STALE_WP, age ${STALE_AGE}s) has lost commit rights." >&2
        echo "         Close it (close --wp $STALE_WP) or renew: renew --wp $STALE_WP" >&2
      fi
    fi
  done < <(ls -t "$SESSION_DIR/${AGENT}"-*.open 2>/dev/null || true)

  if [ "${ISOLATE_FLAG:-0}" = "1" ] && type isolate_entropy_suffix >/dev/null 2>&1; then
    SESSION_ID="${SESSION_ID_ARG:-${IWE_SESSION_LOCKED_SESSION_ID:-${IWE_SESSION_ID:-$(date +%s)-$(isolate_entropy_suffix)}}}"
  else
    SESSION_ID="${SESSION_ID_ARG:-${IWE_SESSION_LOCKED_SESSION_ID:-${IWE_SESSION_ID:-$(date +%s)-$$-$RANDOM}}}"
  fi
  _safe_session_token "$SESSION_ID" || fail "open: unsafe session_id '$SESSION_ID'" 1
  SEM_FILE="$SESSION_DIR/${AGENT}-${SESSION_ID}.open"
  _ensure_session_transition_lock "$SEM_FILE" "$SESSION_ID"
  if [ -e "$SEM_FILE" ] || [ -L "$SEM_FILE" ]; then
    if [ "${ISOLATE_FLAG:-0}" = "1" ]; then
      : # re-entry: isolate block verifies worktree identity and allowlist
    else
      fail "open: exact session_id '$SESSION_ID' already open; existing semaphore not modified" 1
    fi
  fi
  if find "$SESSION_DIR" -maxdepth 1 \( -type f -o -type l \) \
      -name "$(basename "$SEM_FILE").*" -print -quit 2>/dev/null | grep -q .; then
    fail "open: for exact session_id '$SESSION_ID' already has terminal/lease state; choose a new identifier" 1
  fi
  # WP-484 (31.07, data-pipeline-audit-2026-07-30.md §3.3): a caller-supplied slug
  # sometimes already carries today's date (Kimi free-text `--slug`, human habit) —
  # confirmed live on real files, e.g. sessions/2026-07/2026-07-31-2026-07-31-wp510-*.md.
  # This is the ONE place that assembles the path, so it's the one place that can
  # enforce "date appears exactly once" regardless of what any caller passes.
  CLEAN_SLUG="${SLUG:-$WP}"
  CLEAN_SLUG="${CLEAN_SLUG#"$(now_date)"-}"
  ORZ_BASENAME="$(now_month)/$(now_date)-${CLEAN_SLUG}.md"
  # WP-526 Phase2 (29.08): `open` is the only writer, so it's the only place that
  # needs the strict (fail-closed-if-broken) resolution -- overrides the
  # passive default set at the top of the script for read-only commands.
  ORZ_DIR="$(resolve_orz_sessions_dir)"
  ORZ_FILE="$ORZ_DIR/$ORZ_BASENAME"
  mkdir -p "$(dirname "$ORZ_FILE")"
  # --- WP-485 Phase14: logical freeze on open (carve-outs: --isolate, --canonical-owner, exact-slug re-entry) ---
  if [ "${#FROZEN_CANONICAL_PATHS[@]}" -gt 0 ] && [ -z "${CANONICAL_OWNER:-}" ] && [ "${ISOLATE_FLAG:-0}" != "1" ]; then
    ACTUAL_CWD_TOPLEVEL=$(frozen_checkout_match)
    if [ -n "$ACTUAL_CWD_TOPLEVEL" ]; then
      REENTRY_OK=false
      if [ -n "${SLUG:-}" ]; then
        while IFS= read -r EXISTING_SEM; do
          [ -z "$EXISTING_SEM" ] && continue
          [ -f "$EXISTING_SEM" ] || continue
          [ "$(grep "^wp: " "$EXISTING_SEM" | cut -d' ' -f2-)" = "$WP" ] || continue
          [ "$(grep "^slug: " "$EXISTING_SEM" | cut -d' ' -f2-)" = "$SLUG" ] || continue
          lease_valid "$EXISTING_SEM" || continue
          REENTRY_OK=true
          break
        done < <(find "$SESSION_DIR" -name "${AGENT}-*.open" -type f 2>/dev/null)
      fi
      if ! $REENTRY_OK; then
        fail "this checkout ($ACTUAL_CWD_TOPLEVEL) is under freeze — direct writes are not allowed. Use --isolate or --canonical-owner <reason>." 1
      fi
    fi
  fi

  # --- WP-485 Phase14: open --isolate (happy-path + re-entry) ---
  if [ "${ISOLATE_FLAG:-0}" = "1" ]; then
    type with_isolate_lock >/dev/null 2>&1 || fail "--isolate: session-guard-isolate-lib.sh not loaded" 1
    [ -z "${CANONICAL_OWNER:-}" ] || fail "--isolate and --canonical-owner are mutually exclusive" 1
    [ -n "$SLUG" ] && validate_isolate_slug "$SLUG"
    ISOLATE_BASE_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$ISOLATE_BASE_DIR" ] || fail "--isolate: current directory is not a git-repository" 1
    # issue #1209: fetch/worktree add below used to target the literal "origin/main",
    # so an install whose governance repo defaults to e.g. "master" could never open
    # an isolated worktree. Same resolution as strategist.sh resolve_default_branch()
    # (issue #1097/#1195): read the already-cloned repo's remote HEAD symref, no
    # network call; "main" only as fallback when that symref is missing.
    ISOLATE_DEFAULT_BRANCH="$(git -C "$ISOLATE_BASE_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/origin/##' || true)"
    ISOLATE_DEFAULT_BRANCH="${ISOLATE_DEFAULT_BRANCH:-main}"
    if [ -n "${BASE_SHA:-}" ]; then
      GIT_NO_LAZY_FETCH=1 git -C "$ISOLATE_BASE_DIR" cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null \
        || fail "--isolate: --base-sha '$BASE_SHA' is not a commit in ($ISOLATE_BASE_DIR)" 1
      # A partial clone can have the commit but not its blobs. worktree add
      # otherwise fetches them implicitly from the promisor remote. Probe all
      # reachable objects without lazy fetch before creating a branch.
      if ! ISOLATE_LOCAL_OBJECTS=$(GIT_NO_LAZY_FETCH=1 git -C "$ISOLATE_BASE_DIR" rev-list --objects --missing=print "$BASE_SHA" 2>/dev/null); then
        fail "--isolate: failed to verify local objects for --base-sha '$BASE_SHA'; canon not modified" 1
      fi
      if printf '%s\n' "$ISOLATE_LOCAL_OBJECTS" | grep -q '^?'; then
        fail "--isolate: --base-sha '$BASE_SHA' is incomplete locally (missing objects from partial clone); connect to origin and fetch the missing objects or choose a fully local commit. Canon not modified" 1
      fi
    fi
    # A remote URL can carry credentials in userinfo, path, query or fragment.
    printf 'session-guard: --isolate: isolating %q (remote: origin)\n' "$ISOLATE_BASE_DIR" >&2
    ISOLATE_STORE_DIR="$IWE_ROOT/.iwe-runtime/isolated-worktrees"
    mkdir -p "$ISOLATE_STORE_DIR"
    ISOLATE_STORE_DIR_REAL="$(realpath "$ISOLATE_STORE_DIR")"
    ISOLATED_WORKTREE_PATH="$ISOLATE_STORE_DIR/${AGENT}-${SESSION_ID}"
    ISOLATED_WORKTREE_BRANCH="session-isolate/${AGENT}-${SESSION_ID}"
    ISOLATE_EXISTING_SEM="$SEM_FILE"
    [ -f "$ISOLATE_EXISTING_SEM" ] && ISOLATE_SEM_EXISTS=1 || ISOLATE_SEM_EXISTS=0

    # Dirty policy: first open on frozen path = advisory; re-entry = allowlist only
    ISOLATE_DIRTY_ENTRIES=()
    while IFS= read -r -d '' isolate_status_entry; do
      [ -n "$isolate_status_entry" ] || continue
      ISOLATE_DIRTY_ENTRIES+=("$isolate_status_entry")
    done < <(git -C "$ISOLATE_BASE_DIR" status --porcelain -z --untracked-files=all 2>/dev/null)
    if [ "${#ISOLATE_DIRTY_ENTRIES[@]}" -gt 0 ]; then
      if [ "$ISOLATE_SEM_EXISTS" = "1" ]; then
        ISOLATE_ALLOWLIST=$(grep '^file: ' "$ISOLATE_EXISTING_SEM" | sed 's/^file: //' | sort -u)
        ISOLATE_UNEXPECTED_DIRTY=""
        for isolate_status_entry in "${ISOLATE_DIRTY_ENTRIES[@]}"; do
          isolate_path="${isolate_status_entry:3}"
          isolate_path="${isolate_path# }"
          if ! printf '%s\n' "$ISOLATE_ALLOWLIST" | grep -Fxq -- "$isolate_path"; then
            ISOLATE_UNEXPECTED_DIRTY="$ISOLATE_UNEXPECTED_DIRTY"$'\n'"  $isolate_status_entry"
          fi
        done
        if [ -n "$ISOLATE_UNEXPECTED_DIRTY" ]; then
          fail "--isolate: re-entry session $SESSION_ID — dirty paths outside the allowlist of allowlist this session:$ISOLATE_UNEXPECTED_DIRTY" 1
        fi
      else
        ISOLATE_BASE_REAL="$(realpath "$ISOLATE_BASE_DIR" 2>/dev/null || echo "$ISOLATE_BASE_DIR")"
        ISOLATE_ON_FROZEN_PATH=0
        for isolate_frozen_path in "${FROZEN_CANONICAL_PATHS[@]+"${FROZEN_CANONICAL_PATHS[@]}"}"; do
          if [ "$ISOLATE_BASE_REAL" = "$(realpath "$isolate_frozen_path" 2>/dev/null || echo "$isolate_frozen_path")" ]; then
            ISOLATE_ON_FROZEN_PATH=1
            break
          fi
        done
        if [ "$ISOLATE_ON_FROZEN_PATH" -eq 0 ]; then
          fail "--isolate: in ($ISOLATE_BASE_DIR) has uncommitted changes — it is no longer the canon under freeze; commit or stash/before the nested isolate" 1
        fi
        echo "⚠️  --isolate: canonical checkout is dirty (${#ISOLATE_DIRTY_ENTRIES[@]} paths) — new worktree will not inherit them (expected)." >&2
      fi
    fi

    _fmt_isolate_create() {
      if [ -d "$ISOLATED_WORKTREE_PATH" ]; then
        if [ "$ISOLATE_SEM_EXISTS" != "1" ]; then
          fail "COLLISION_RETRY: --isolate: worktree $ISOLATED_WORKTREE_PATH exists, semaphore not found — fail closed" 1
        fi
        wt_path_real=$(realpath "$ISOLATED_WORKTREE_PATH" 2>/dev/null || echo "$ISOLATED_WORKTREE_PATH")
        registered_branch=$(git -C "$ISOLATE_BASE_DIR" worktree list --porcelain \
          | awk -v p="$wt_path_real" '$1=="worktree" && $2==p {found=1} found && /^branch / {print $2; exit}')
        registered_branch="${registered_branch#refs/heads/}"
        if [ "$registered_branch" != "$ISOLATED_WORKTREE_BRANCH" ]; then
          fail "--isolate: path $ISOLATED_WORKTREE_PATH is registered to '$registered_branch', expected '$ISOLATED_WORKTREE_BRANCH'" 1
        fi
        return 0
      fi
      if [ -z "${BASE_SHA:-}" ]; then
        local fetch_error fetch_reason fetch_rc local_sha offline_command
        local offline_args
        if fetch_error=$(LC_ALL=C GIT_TERMINAL_PROMPT=0 git -C "$ISOLATE_BASE_DIR" fetch origin "$ISOLATE_DEFAULT_BRANCH" 2>&1); then
          :
        else
          fetch_rc=$?
          # Git may echo credentials embedded in a remote URL. Report only a
          # classified cause; the pilot can inspect the raw error locally.
          case "$fetch_error" in
            *"Could not resolve host"*|*"Name or service not known"*) fetch_reason="hostname does not resolve" ;;
            *"Failed to connect"*|*"Connection refused"*|*"Network is unreachable"*|*"Could not connect"*) fetch_reason="no connection to origin origin" ;;
            *"Authentication failed"*|*"Permission denied (publickey)"*|*"could not read Username"*) fetch_reason="authorization error for origin origin" ;;
            *"couldn't find remote ref"*) fetch_reason="on origin branch does not exist on $ISOLATE_DEFAULT_BRANCH" ;;
            *) fetch_reason="reason not classified; check git fetch origin $ISOLATE_DEFAULT_BRANCH locally" ;;
          esac
          echo "session-guard: --isolate: origin/$ISOLATE_DEFAULT_BRANCH is not reachable: $fetch_reason (git fetch, exit code $fetch_rc)." >&2
          local_sha=$(git -C "$ISOLATE_BASE_DIR" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)
          if [ -n "$local_sha" ]; then
            printf 'session-guard: Check local revision: git -C %q show -s --format=%%H\\ %%s %q\n' "$ISOLATE_BASE_DIR" "$local_sha" >&2
            offline_args=(bash "$SESSION_GUARD_SELF" open --isolate --wp "$WP" --task "$TASK" --slug "$SLUG" --agent "$AGENT" --base-sha "$local_sha")
            [ -n "$SESSION_ID_ARG" ] && offline_args+=(--session-id "$SESSION_ID_ARG")
            printf -v offline_command '%q ' "${offline_args[@]}"
            printf 'session-guard: Offline after revision check: (cd -- %q && %s)\n' "$ISOLATE_BASE_DIR" "$offline_command" >&2
          fi
          return 1
        fi
        git -C "$ISOLATE_BASE_DIR" worktree add -b "$ISOLATED_WORKTREE_BRANCH" "$ISOLATED_WORKTREE_PATH" "origin/$ISOLATE_DEFAULT_BRANCH" \
          || fail "--isolate: git worktree add failed" 1
      else
        # An explicit local commit is the offline path: no remote query here.
        GIT_NO_LAZY_FETCH=1 git -C "$ISOLATE_BASE_DIR" worktree add -b "$ISOLATED_WORKTREE_BRANCH" "$ISOLATED_WORKTREE_PATH" "$BASE_SHA" \
          || fail "--isolate: git worktree add from --base-sha failed" 1
      fi
      real=$(realpath "$ISOLATED_WORKTREE_PATH" 2>/dev/null || echo "$ISOLATED_WORKTREE_PATH")
      case "$real" in
        "$ISOLATE_STORE_DIR_REAL"/*) : ;;
        *)
          git -C "$ISOLATE_BASE_DIR" worktree remove --force "$ISOLATED_WORKTREE_PATH" 2>/dev/null || rm -rf "$ISOLATED_WORKTREE_PATH"
          fail "--isolate: worktree outside store — removed" 1
          ;;
      esac
    }
    with_isolate_lock "$SESSION_ID" _fmt_isolate_create
    ISOLATED_WORKTREE_PATH=$(realpath "$ISOLATED_WORKTREE_PATH" 2>/dev/null) \
      || fail "--isolate: could not canonicalize path worktree" 1
  fi

  if [ "${ISOLATE_FLAG:-0}" = "1" ] && [ -f "$SEM_FILE" ]; then
    echo "Session OPEN (re-entry): $SEM_FILE (WP: $WP, agent: $AGENT, slug: ${SLUG:-$WP})"
    printf '{"worktree_path": "%s", "branch": "%s", "session_id": "%s"}\n' \
      "$ISOLATED_WORKTREE_PATH" "$ISOLATED_WORKTREE_BRANCH" "$SESSION_ID"
    echo "⚠️  cd \"$ISOLATED_WORKTREE_PATH\" before the next action -- working directory is not switched automatically." >&2
    exit 0
  fi

  SEM_TMP=$(mktemp "$SESSION_DIR/.session-open.XXXXXX")
  chmod 600 "$SEM_TMP"
  {
    echo "---"
    echo "agent: $AGENT"
    echo "personality: $PERSONALITY"
    echo "wp: $WP"
    echo "$(yaml_task_line "${TASK:-}")"
    echo "slug: ${SLUG:-$WP}"
    echo "opened_at: $(now_iso)"
    echo "created_at: $(now_iso)"
    echo "session_id: $SESSION_ID"
    [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && echo "harness_session_id: $CLAUDE_CODE_SESSION_ID"
    echo "close_path: ${CLOSE_PATH:-unknown}"
    # WP-484 point-patch + WP-485 Phase14: without isolate, governance_worktree is
    # the canonical $IWE_ROOT/$GOV_REPO (helps root readers on close). With
    # --isolate, fields above already point at the isolated worktree.
    if [ "${ISOLATE_FLAG:-0}" = "1" ] && [ -n "${ISOLATED_WORKTREE_PATH:-}" ]; then
      echo "governance_worktree: $ISOLATED_WORKTREE_PATH"
      echo "isolated_worktree: $ISOLATED_WORKTREE_PATH"
      echo "isolated_branch: $ISOLATED_WORKTREE_BRANCH"
    else
      echo "governance_worktree: $IWE_ROOT/$GOV_REPO"
    fi
    echo "orz_sessions_dir: $ORZ_DIR"
    echo "orz_file: $ORZ_BASENAME"
    # WP-484 (08.08, Kimi diagnosis + pilot report): regular sessions never
    # recorded a pid at all, so sweep_orphaned_semaphores()'s dead-pid check —
    # the only auto-detection left since age-based quarantine was retired
    # 04.08 — had nothing to grab onto; abandoned semaphores just hung open
    # forever (48 found live 08.08). $CLAUDE_PID is the long-lived Claude Code
    # process (stable for the whole session, verified live) — NOT $$, which
    # is session-guard.sh's own transient subprocess, already dead the moment
    # this script returns (verified live: recorded pid was dead within the
    # same second). Other agents get no pid line, same as before this fix —
    # strictly not worse, dead-pid check simply still can't fire for them.
    if [ -n "$OWNER_PID" ]; then
      echo "pid: $OWNER_PID"
    elif [ -n "${CLAUDE_PID:-}" ]; then
      echo "pid: $CLAUDE_PID"
    fi
    echo "---"
    # initial --files CSV → append-log entries (git-root-relative expected from caller)
    if [ -n "${FILES:-}" ]; then
      IFS=',' read -ra INITIAL_FILES <<< "$FILES"
      for init_file in "${INITIAL_FILES[@]}"; do
        init_file="$(echo "$init_file" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$init_file" ] && echo "file: $init_file"
      done
    fi
    # Phase32 pt.5 (WP-484, 31.07): `open` creates the ORZ scaffold itself below — its
    # first commit is a brand-new git path (status A), which the scope gate never
    # mtime-bypasses. Without this line every session's OWN report needed a
    # separate `note-file` call just to survive the gate it forgot about — live-
    # reproduced (mktemp sandbox: open → edit ORZ → git add → pre-commit-check
    # → BLOCK) and matches orphaned untracked ORZ files found sitting in this
    # session's own `git status` from a prior, unrelated WP. Path is relative to
    # $ORZ_DIR's PARENT (governance-repo root — sessions/<...>), same convention
    # every other `file:` line already uses.
    echo "file: $(basename "$ORZ_DIR")/$ORZ_BASENAME"
    # WP-485 Phase14: open appends OPEN_LOG under governance inbox — register for re-entry allowlist
    if [ -n "${OPEN_LOG:-}" ]; then
      case "$OPEN_LOG" in
        "$IWE_ROOT/$GOV_REPO"/*)
          echo "file: ${OPEN_LOG#"$IWE_ROOT/$GOV_REPO/"}"
          ;;
      esac
    fi
  } > "$SEM_TMP"
  _publish_open_no_clobber "$SEM_TMP" "$SEM_FILE" \
    || { rm -f "$SEM_TMP"; fail "open: exact session_id '$SESSION_ID' appeared concurrently; existing file was not modified" 1; }
  # Pointer to active semaphore for PostToolUse hooks
  PTR_FILE="$SESSION_DIR/current-${AGENT}.ptr"
  echo "$SEM_FILE" > "$PTR_FILE"
  # ORZ scaffold (paths already computed above for the semaphore)
  if [ ! -f "$ORZ_FILE" ]; then
    cat > "$ORZ_FILE" <<EOF
---
date: $(now_date)
type: work
wp: ${WP}
duration_h: ~
agent: $(orz_agent_name "$AGENT")
personality: ${PERSONALITY}
artifacts: []
---

# Session $(now_date) — ${TASK:-$WP}

## Key Insight

## Context

## Accomplished

| Artifact | Description |
|----------|----------|

## Key Decisions

## Next Step

EOF
    echo "ORZ scaffold created: $ORZ_FILE"
  fi
  # open-sessions.log
  printf "%s | %s | %s | %s\n" "$(date '+%Y-%m-%d %H:%M')" "$WP" "$AGENT" "${TASK:-standalone}" >> "$OPEN_LOG"
  # agent status (fail-safe)
  if [ -x "$AGENT_STATUS_SCRIPT" ]; then
    "$AGENT_STATUS_SCRIPT" --session-id "$SESSION_ID" --personality "$PERSONALITY" \
      "$AGENT" working "${WP}: ${TASK:-standalone}" "${FILES:-}" 2>/dev/null || true
  fi
  echo "Session OPEN: $SEM_FILE (WP: $WP, agent: $AGENT, slug: ${SLUG:-$WP})"
  if [ "${ISOLATE_FLAG:-0}" = "1" ] && [ -n "${ISOLATED_WORKTREE_PATH:-}" ]; then
    printf '{"worktree_path": "%s", "branch": "%s", "session_id": "%s"}\n' \
      "$ISOLATED_WORKTREE_PATH" "$ISOLATED_WORKTREE_BRANCH" "$SESSION_ID"
    echo "⚠️  cd \"$ISOLATED_WORKTREE_PATH\" before the next action -- working directory is not switched automatically." >&2
  fi
  exit 0
fi

# --- HEARTBEAT ---
# Exact-id only and no shell redirection: a delayed heartbeat can neither jump
# to a newer pointer nor recreate `.open` after close.  The caller PID must be
# a live ancestor of this guard process, which catches stale/replayed command
# shapes without pretending that a PID is an authentication credential.
if [ "$CMD" = "heartbeat" ]; then
  [ -n "$AGENT" ] || fail "heartbeat requires --agent" 1
  _safe_session_token "$AGENT" || fail "heartbeat: unsafe --agent '$AGENT'" 1
  [ -n "$SESSION_ID_ARG" ] || fail "heartbeat requires --session-id" 1
  _safe_session_token "$SESSION_ID_ARG" || fail "heartbeat: unsafe --session-id '$SESSION_ID_ARG'" 1
  if [ -n "${IWE_SESSION_TRANSITION_FD:-}" ]; then
    [ "${IWE_HEARTBEAT_OWNER_VALIDATED:-}" = "$OWNER_PID" ] \
      || fail "heartbeat: owner proof did not survive lock re-entry" 1
  else
    _owner_pid_is_live_ancestor "$OWNER_PID" \
      || fail "heartbeat: --owner-pid must be a live ancestor process-ancestor" 1
    # The Python lock wrapper adds one process hop before exec. Preserve the
    # already-checked call shape across that re-entry rather than depending on
    # `ps`, which is unavailable in some sandboxed installations.
    export IWE_HEARTBEAT_OWNER_VALIDATED="$OWNER_PID"
  fi
  [ "${#POSITIONAL[@]}" -eq 0 ] || fail "heartbeat does not accept positional arguments" 1
  [ -z "$WP$TASK$FILES$SLUG$HOUSEKEEPING$PERSONALITY$FORCE_NO_REFLECTION$CLOSE_PATH" ] \
    || fail "heartbeat accepts only --agent/--session-id/--owner-pid" 1

  SEM_FILE="$SESSION_DIR/${AGENT}-${SESSION_ID_ARG}.open"
  [ -f "$SEM_FILE" ] || fail "heartbeat: exact session ${AGENT}-${SESSION_ID_ARG} is not open" 3
  _ensure_session_transition_lock "$SEM_FILE" "$SESSION_ID_ARG"
  _locked_open_identity "$SEM_FILE" "$AGENT" "$SESSION_ID_ARG" 0 \
    || fail "heartbeat: open-semaphore did not pass exact identity/no-terminal check" 1
  _atomic_append_open "$SEM_FILE" "$AGENT" "$SESSION_ID_ARG" heartbeat \
    "heartbeat_at: $(now_iso)" "heartbeat_pid: $OWNER_PID" \
    || fail "heartbeat: atomic write rejected; session may have started close" 1
  echo "Heartbeat: ${AGENT}-${SESSION_ID_ARG}"
  exit 0
fi

# --- helpers for ORZ validation ---
# Ported from ~/IWE/scripts/session-guard.sh (root commit 2779845553, WP-484
# line AC, 31.08): batches the git-tracked lookup for `audit` (one
# `git ls-files` instead of one per file) and reads each file once with
# bash builtin pattern matching instead of ~13 grep/sed/head subprocesses.
# Root's function already carried the WP-520 case-8 remote-refs fallback
# below (published-but-unstaged ORZ files) before this batching commit --
# ported together since it is the same function body, not a separate
# addition to this session's scope.
validate_orz() { # <orz-path> <agent> [orz-base-dir, default $ORZ_DIR] [tracked-set-file, optional]
  local orz="$1"
  local agent="$2"
  local orz_base_dir="${3:-$ORZ_DIR}"
  orz_base_dir="${orz_base_dir%/}"
  local tracked_set_file="${4:-}"
  local errors=0

  # 1. file exists
  if [ ! -f "$orz" ]; then
    echo "  ❌ ORZ-file not found: $orz" >&2
    return 1
  fi

  # Checks 2-4 read the file once into a bash variable and use builtin
  # pattern matching instead of one grep/sed/head subprocess per check.
  # `$'\n'` is prepended so "key at the very start of the file" and "key
  # after a newline" are the same substring match, matching what the old
  # `grep -qE "^key:"` anchor covered without needing multiline `^`.
  local nl=$'\n'
  local content
  content="$(<"$orz")" 2>/dev/null || content=""
  local content_nl="${nl}${content}"

  # 2. frontmatter keys
  local keys=("date:" "type:" "wp:" "duration_h:" "artifacts:" "agent:")
  for key in "${keys[@]}"; do
    case "$content_nl" in
      *"${nl}${key}"*) : ;;
      *)
        echo "  ❌ in frontmatter key is missing '$key'" >&2
        errors=$((errors + 1))
        ;;
    esac
  done

  # 3. agent value
  # `[ -n "$agent" ]` guard: a caller that doesn't care about agent identity
  # (the archival `audit` scan) passes "" and skips this comparison outright,
  # instead of re-deriving the file's own value and comparing it to itself
  # (a self-match that could never fail -- the bug this port also fixes).
  local orz_agent="" agent_re="${nl}agent:[[:space:]]*([^${nl}]*)"
  if [[ "$content_nl" =~ $agent_re ]]; then
    orz_agent="${BASH_REMATCH[1]}"
  fi
  if [ -n "$agent" ] && [ -n "$orz_agent" ]; then
    if [ "$orz_agent" != "$agent" ] && \
       ! { [ "$agent" = "kimi" ] && [ "$orz_agent" = "kimi-headless" ]; }; then
      echo "  ❌ agent in ORZ ('$orz_agent') does not match the session agent ('$agent')" >&2
      errors=$((errors + 1))
    fi
  fi

  # 4. required sections
  local sections=("## Main Insight" "## Context" "## Accomplished" "## Key Decisions")
  for sec in "${sections[@]}"; do
    case "$content" in
      *"$sec"*) : ;;
      *)
        echo "  ❌ section is missing '$sec'" >&2
        errors=$((errors + 1))
        ;;
    esac
  done

  # 5. git tracked
  local rel
  local is_tracked=1
  if [ -n "$tracked_set_file" ] && [ -s "$tracked_set_file" ]; then
    # Batch path (audit call site): one `git ls-files` snapshot up front
    # instead of one `git ls-files --error-unmatch` + python3 relpath per
    # file. Safe to inline the relpath here because this call site's `orz`
    # always comes from `find "$ORZ_DIR" ...`, so it is always a literal
    # `$orz_base_dir/...` path; the fallback below (other callers) keeps
    # os.path.relpath for the non-prefixed cases it covers.
    rel="${orz#"$orz_base_dir"/}"
    grep -qxF "$rel" "$tracked_set_file" && is_tracked=0
  else
    rel="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[2], sys.argv[3]))" -- "$orz" "$orz_base_dir")"
    git -C "$orz_base_dir" ls-files --error-unmatch "$rel" >/dev/null 2>&1 && is_tracked=0
  fi
  if [ "$is_tracked" -ne 0 ]; then
    # A file whose commit went to main through an isolated worktree cannot
    # be staged in the live checkout (busy on a foreign branch). A file
    # present in ANY published remote-tracking ref is a strictly stronger
    # proof than a staged-only file: accept it as the index-equivalent.
    local published_ref=""
    local remote_ref
    while IFS= read -r remote_ref; do
      [ -z "$remote_ref" ] && continue
      # Content must match too -- path-only acceptance would let a locally
      # edited copy pass on legacy semaphores with no registered `file:`
      # line for the scope gate's cmp to catch.
      if git -C "$orz_base_dir" cat-file -e "$remote_ref:./$rel" 2>/dev/null &&
         git -C "$orz_base_dir" cat-file blob "$remote_ref:./$rel" 2>/dev/null | cmp -s - "$orz"; then
        published_ref="$remote_ref"
        break
      fi
    done <<< "$(git -C "$orz_base_dir" for-each-ref --format='%(refname)' refs/remotes 2>/dev/null)"
    if [ -n "$published_ref" ]; then
      echo "  ✓ ORZ-file is not in git index, but matches byte-for-byte the published blob in '$published_ref' — accepted as equivalent" >&2
    else
      echo "  ❌ ORZ-file is not added to git index (git add $rel) and does not match any blob in refs/remotes/*" >&2
      errors=$((errors + 1))
    fi
  fi

  return $errors
}

_append_direct_close_ledger() { # <validated terminal receipt>
  local receipt="$1" writer="$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh"
  local metadata period payload
  if [ ! -f "$writer" ]; then
    echo "  ⚠️  ledger session_closed_direct not recorded: ledger-append.sh is missing" >&2
    return 0
  fi
  # Only receipt fields are projected: a retry has no live close variables,
  # and its date must stay in the original close's ledger partition.
  if ! metadata=$(python3 - "$receipt" <<'PY'
from datetime import datetime
import json
from pathlib import Path
import sys

keys = {"wp", "slug", "agent", "close_path", "session_id", "close_attempt_id", "closed_at"}
fields = {}
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    key, separator, value = line.partition(": ")
    if separator and key in keys:
        if key in fields:
            raise ValueError(f"duplicate receipt field: {key}")
        fields[key] = value
closed_at = datetime.fromisoformat(fields.pop("closed_at").replace("Z", "+00:00"))
print(closed_at.astimezone().date().isoformat())
print(json.dumps(fields))
PY
  ); then
    echo "  ⚠️  ledger session_closed_direct not recorded: closure metadata is corrupted" >&2
    return 0
  fi
  period="${metadata%%$'\n'*}"
  payload="${metadata#*$'\n'}"
  IWE_LEDGER_DIR="${IWE_LEDGER_DIR:-$IWE_ROOT/$GOV_REPO/machine/ledger}" \
    bash "$writer" day "$period" session_closed_direct "$payload" session-guard \
    >/dev/null 2>&1 \
    || echo "  ⚠️  ledger session_closed_direct not recorded (best-effort, does not block close)" >&2
}

# --- CLOSE ---
if [ "$CMD" = "close" ]; then
  [ "${#POSITIONAL[@]}" -eq 0 ] || fail "close does not accept positional arguments" 1
  _safe_session_token "$AGENT" || fail "close: unsafe --agent '$AGENT'" 1
  if [ -n "$HOUSEKEEPING" ]; then
    _safe_session_token "$HOUSEKEEPING" || fail "close --housekeeping: reason must be a safe slug" 1
    HK_FILE="$SESSION_DIR/${AGENT}-housekeeping-${HOUSEKEEPING}.open"
    HK_SESSION_ID="housekeeping-${HOUSEKEEPING}"
    if [ ! -f "$HK_FILE" ]; then
      fail "close --housekeeping: no active housekeeping-session '${HOUSEKEEPING}' for $AGENT" 3
    fi
    _ensure_session_transition_lock "$HK_FILE" "$HK_SESSION_ID"
    _locked_open_identity "$HK_FILE" "$AGENT" "$HK_SESSION_ID" 1 \
      || fail "close --housekeeping: exact identity/terminal state did not pass verification" 1
    HK_CLOSE_ATTEMPT=$(_atomic_append_open "$HK_FILE" "$AGENT" "$HK_SESSION_ID" \
      close-stage "$(now_iso)") \
      || fail "close --housekeeping: failed to prepare durable receipt" 1
    [ -n "$HK_CLOSE_ATTEMPT" ] \
      || fail "close --housekeeping: durable receipt did not return attempt id" 1
    _terminal_close_no_clobber "$HK_FILE" "$AGENT" "$HK_SESSION_ID" "$HK_CLOSE_ATTEMPT" \
      || fail "close --housekeeping: terminal destination occupied by another inode; open preserved" 1
    rm -f "${HK_FILE}.lease"
    echo "Housekeeping CLOSE: ${HOUSEKEEPING} ✅"
    exit 0
  fi

  if [ -n "$SESSION_ID_ARG" ]; then
    _safe_session_token "$SESSION_ID_ARG" || fail "close: unsafe --session-id '$SESSION_ID_ARG'" 1
    EXACT_OPEN="$SESSION_DIR/${AGENT}-${SESSION_ID_ARG}.open"
    EXACT_CLOSED="$EXACT_OPEN.closed"
    if [ ! -e "$EXACT_OPEN" ] && [ -f "$EXACT_CLOSED" ]; then
      _ensure_session_transition_lock "$EXACT_OPEN" "$SESSION_ID_ARG"
      _closed_receipt_identity "$EXACT_CLOSED" "$AGENT" "$SESSION_ID_ARG" \
        || fail "close: existing .closed is not a trusted durable receipt this exact session" 1
      CLOSED_WP=$(grep '^wp: ' "$EXACT_CLOSED" | cut -d' ' -f2- || true)
      CLOSED_SLUG=$(grep '^slug: ' "$EXACT_CLOSED" | cut -d' ' -f2- || true)
      [ -z "$WP" ] || [ "$WP" = "$CLOSED_WP" ] \
        || fail "close: durable receipt belongs to wp='$CLOSED_WP', but received --wp='$WP'" 1
      [ -z "$SLUG" ] || [ "$SLUG" = "$CLOSED_SLUG" ] \
        || fail "close: durable receipt belongs to slug='$CLOSED_SLUG', but received --slug='$SLUG'" 1
      rm -f "$EXACT_OPEN.lease"
      PTR_FILE="$SESSION_DIR/current-${AGENT}.ptr"
      if [ -f "$PTR_FILE" ] && [ "$(cat "$PTR_FILE" 2>/dev/null || true)" = "$EXACT_OPEN" ]; then
        rm -f "$PTR_FILE"
      fi
      CLOSED_PERSONALITY=$(grep '^personality: ' "$EXACT_CLOSED" | cut -d' ' -f2- || true)
      CLOSED_PERSONALITY="${CLOSED_PERSONALITY:-unassigned}"
      if [ -x "$AGENT_STATUS_SCRIPT" ]; then
        "$AGENT_STATUS_SCRIPT" --session-id "$SESSION_ID_ARG" --personality "$CLOSED_PERSONALITY" \
          "$AGENT" idle "" "" 2>/dev/null || true
      fi
      if grep -q '^close_path: peer-session$' "$EXACT_CLOSED"; then
        _append_direct_close_ledger "$EXACT_CLOSED"
      fi
      echo "Session CLOSE: ${CLOSED_WP:-unknown} — closure confirmed by existing receipt ✅"
      exit 0
    fi
  fi

  if [ -n "$SESSION_ID_ARG" ]; then
    SEM_FILE=$(resolve_semaphore_by_session_id "$AGENT" "$SESSION_ID_ARG" "${WP:-}" "${SLUG:-}") && SG_RC=0 || SG_RC=$?
  else
    SEM_FILE=$(select_semaphore "$AGENT" "${WP:-}" "${SLUG:-}") && SG_RC=0 || SG_RC=$?
  fi
  [ "$SG_RC" -eq 2 ] && exit 3
  if [ "$SG_RC" -ne 0 ] || [ -z "$SEM_FILE" ] || [ ! -f "$SEM_FILE" ]; then
    fail "close without open: semaphore not found for $AGENT. Run first session-guard.sh open --wp WP-N" 3
  fi
  SESSION_ID_FROM_NAME="${SEM_FILE#"$SESSION_DIR/${AGENT}-"}"
  SESSION_ID_FROM_NAME="${SESSION_ID_FROM_NAME%.open}"
  _safe_session_token "$SESSION_ID_FROM_NAME" \
    || fail "close: semaphore name does not contain a safe exact session_id" 1
  _ensure_session_transition_lock "$SEM_FILE" "$SESSION_ID_FROM_NAME"
  _locked_open_identity "$SEM_FILE" "$AGENT" "$SESSION_ID_FROM_NAME" 1 \
    || fail "close: open-semaphore did not pass exact identity/no-clobber verification" 1

  WP_FROM_SEM=$(grep "^wp: " "$SEM_FILE" | cut -d' ' -f2- || true)
  WP="${WP:-$WP_FROM_SEM}"
  SLUG_FROM_SEM=$(grep "^slug: " "$SEM_FILE" | cut -d' ' -f2- || true)
  SLUG="${SLUG:-$SLUG_FROM_SEM}"
  TASK_FROM_SEM=$(grep "^task: " "$SEM_FILE" | cut -d' ' -f2- || true)
  TASK="${TASK:-$TASK_FROM_SEM}"
  SESSION_ID=$(grep "^session_id: " "$SEM_FILE" | cut -d' ' -f2- || echo "unknown")
  [ "$SESSION_ID" = "$SESSION_ID_FROM_NAME" ] \
    || fail "close: session_id inside the semaphore does not match the exact name" 1
  PERSONALITY_FROM_SEM=$(grep "^personality: " "$SEM_FILE" | cut -d' ' -f2- || true)
  PERSONALITY_FROM_SEM="${PERSONALITY_FROM_SEM:-unassigned}"

  ORZ_BASENAME=$(grep "^orz_file: " "$SEM_FILE" | cut -d' ' -f2- || true)
  if [ -z "$ORZ_BASENAME" ]; then
    # Fallback fallback for old semaphores without the field orz_file
    OPENED_DATE=$(grep "^opened_at: " "$SEM_FILE" | cut -d' ' -f2- | cut -dT -f1 || true)
    OPENED_DATE="${OPENED_DATE:-$(now_date)}"
    ORZ_BASENAME="${OPENED_DATE:0:7}/${OPENED_DATE}-${SLUG:-$WP}.md"
  fi
  # WP-526 Phase2 (29.08): must resolve the same way `open` did, or `close` looks
  # for the ORZ file at the passive legacy default while `open` actually
  # wrote it under MC-sessions -- validate_orz below would then fail on an
  # existing, correctly-written file. This semaphore has no orz_sessions_dir
  # field (root's more evolved variant does) to read the resolved dir back
  # from, but the resolver is a pure function of current filesystem state,
  # so recomputing it here agrees with what `open` computed moments earlier.
  ORZ_DIR="$(resolve_orz_sessions_dir)"
  ORZ_FILE="$ORZ_DIR/$ORZ_BASENAME"

  echo "Session CLOSE: checking ORZ $ORZ_FILE ..."
  if ! validate_orz "$ORZ_FILE" "$AGENT"; then
    fail "ORZ did not pass validation. Fix the issues above and repeat close. Semaphore remains active." 5
  fi

  # issue #356: runner map — capability-aware gate. A fresh user
  # template installation may not have process-runner.py/quick-close.yaml at all —
  # in that case Quick Close continues manually (runner_check=not_applicable), apparently
  # for the pilot, and is not blocked forever by a nonexistent runner. The check
  # was lost during delivery of the author copy 09-11.08 (the author always has the runner)
  # — restored in WP-7 Phase71, guarded by test T22.
  RUNNER_BIN="$IWE_ROOT/$GOV_REPO/scripts/process-runner.py"
  RUNNER_GRAPH="$IWE_ROOT/$GOV_REPO/scripts/processes/quick-close.yaml"
  if [ ! -f "$RUNNER_BIN" ] || [ ! -f "$RUNNER_GRAPH" ]; then
    echo "Session CLOSE: runner_check=not_applicable — process-runner not installed, manual Quick Close"
    # Peer-close still needs its ledger projection on a fresh installation.
    if grep -q '^close_path: peer-session$' "${SEM_FILE:-}" 2>/dev/null; then
      FORCED_CARD="declared-peer-session:$SLUG"
    fi
  else
  # Quick Close — not a textual declaration: specifically the terminal runner card
  # proves, that this session has completed the required process. Matching by slug
  # prevents a parallel card from another session from closing the current session.
  RUNNER_CARD="$IWE_ROOT/$GOV_REPO/inbox/agent/tasks/RUN-quick-close-${SLUG}"'*.md'
  RUNNER_OK=""
  for card in $RUNNER_CARD; do
    [ -f "$card" ] || continue
    grep -q '^process_id: quick-close$' "$card" || continue
    grep -q '^status: completed$' "$card" || continue
    RUNNER_OK="$card"
    break
  done

  # WP-484 Phase118 / WP-530 Phase18 (port from the author source source, 30.08.2026): session,
  # opened with "open --close-path peer-session", by definition never
  # creates RUN-quick-close-*.md — its closing protocol (DP.SC.154 Step
  # 4.5.1/4.5.2) direct git commit, not the runner. Without this workaround close required
  # from the peer-session a card from a foreign ritual (live failure 30.08). close_path
  # written by this same script at open — sufficient evidence.
  # ${SEM_FILE:-}: T22 sources this window standalone under set -u with no
  # semaphore stub; empty path -> grep fails -> bypass correctly not taken.
  if [ -z "$RUNNER_OK" ] && grep -q '^close_path: peer-session$' "${SEM_FILE:-}" 2>/dev/null; then
    RUNNER_OK="declared-peer-session:$SLUG"
    # WP-484 Phase133 (port from the author source source, found 04.09.2026, peer-session
    # 2026-09-04-23-wp561-peer-session-closed-ledger-gap): without FORCED_CARD
    # block ledger session_closed_direct does not trigger for this branch —
    # peer-sessions were silently left without a close entry in the daily log.
    FORCED_CARD="declared-peer-session:$SLUG"
    echo "Session CLOSE: close_path=peer-session declared at open — runner is not required (WP-484 Phase118)." >&2
  fi

  # --force-no-reflection (WP-484, 08.08, pilot): reflection on the mood of the day
  # blocks close, even when the substantive work (commit+push) already
  # confirmed by the runner card — live review showed, that the reflection prompt
  # is often rendered AFTER the command «close it», the pilot does not physically see it.
  # Bypass narrow and specific, not a general «skip the runner card»: requires
  # SPECIFICALLY the block at this step and a confirmed push — another runner failure
  # (failed push, cancelled before commit-push run) cannot be hidden with this flag.
  if [ -z "$RUNNER_OK" ] && [ -n "${FORCE_NO_REFLECTION:-}" ]; then
    for card in $RUNNER_CARD; do
      [ -f "$card" ] || continue
      grep -q '^process_id: quick-close$' "$card" || continue
      grep -q '^current_step: blocked-witness-unavailable$' "$card" || continue
      grep -qE '^[[:space:]]*all_pushed: true$' "$card" || continue
      RUNNER_OK="$card"
      FORCED_CARD="$card"
      break
    done
    if [ -z "$RUNNER_OK" ]; then
      fail "force-no-reflection: could not find RUN-quick-close-${SLUG}*.md with current_step=blocked-witness-unavailable and all_pushed=true — this flag bypasses only this specific block, not every runner failure." 7
    fi
    FORCE_EVENT=$(python3 -c '
import json, sys
print(json.dumps({"wp": sys.argv[1], "slug": sys.argv[2], "agent": sys.argv[3], "card": sys.argv[4], "reason": sys.argv[5]}))
' "$WP" "$SLUG" "$AGENT" "$FORCED_CARD" "$FORCE_NO_REFLECTION")
    echo "force-no-reflection: proof accepted ($FORCED_CARD); ledger will be updated after terminal transition" >&2
  fi

  if [ -z "$RUNNER_OK" ]; then
    fail "Quick Close not completed for slug '$SLUG': no terminal RUN-quick-close-${SLUG}*.md. First run process-runner.py start quick-close with the same --slug." 7
  fi
  fi

  # agent status idle boundary for T22; the projection remains after the terminal receipt below.
  # Authoritative transition first.  A complete, fsync'd `.closed` receipt is
  # published with hard-link no-clobber semantics before status, pointer,
  # lease, warnings or ledger projections.  If the process dies between link
  # and unlink, retry recognizes the same inode and completes the unlink.
  CLOSE_ATTEMPT=$(_atomic_append_open "$SEM_FILE" "$AGENT" "$SESSION_ID" \
    close-stage "$(now_iso)") \
    || fail "close: failed to prepare durable receipt; open preserved" 1
  [ -n "$CLOSE_ATTEMPT" ] \
    || fail "close: durable receipt did not return attempt id; open preserved" 1

  # WP-485 Phase14: happy-path isolate publish (full isolate-push/v2 journal deferred)
  ISOLATE_WT=$(grep "^isolated_worktree: " "$SEM_FILE" 2>/dev/null | head -1 | cut -d" " -f2- || true)
  if [ -n "$ISOLATE_WT" ] && [ -d "$ISOLATE_WT" ]; then
    if PUSH_BIN=$(resolve_isolate_push_script); then
      echo "session-guard: close: isolate-push via $PUSH_BIN" >&2
      if ! bash "$PUSH_BIN" "$ISOLATE_WT" main; then
        echo "⚠️  isolate-push did not complete successfully — worktree left: $ISOLATE_WT" >&2
      else
        git -C "$(git -C "$ISOLATE_WT" rev-parse --git-common-dir 2>/dev/null | sed "s|/.git$||;s|/$||" || true)" worktree remove --force "$ISOLATE_WT" 2>/dev/null           || git worktree remove --force "$ISOLATE_WT" 2>/dev/null           || echo "⚠️  could not remove isolate worktree $ISOLATE_WT" >&2
      fi
    else
      echo "⚠️  isolate-push.sh not found ($GOV_REPO/scripts or $IWE_ROOT/scripts) — worktree left: $ISOLATE_WT" >&2
    fi
  fi

  _terminal_close_no_clobber "$SEM_FILE" "$AGENT" "$SESSION_ID" "$CLOSE_ATTEMPT" \
    || fail "close: terminal destination occupied by another inode; open not removed" 1
  _sem_read="$SEM_FILE.closed"

  rm -f "$SEM_FILE.lease"
  # Remove only this session's pointer. A newer same-agent open must not lose
  # its pointer merely because an older close reached its projection phase.
  PTR_FILE="$SESSION_DIR/current-${AGENT}.ptr"
  if [ -f "$PTR_FILE" ] && [ "$(cat "$PTR_FILE" 2>/dev/null || true)" = "$SEM_FILE" ]; then
    rm -f "$PTR_FILE"
  fi

  # agent status idle (projection, deliberately after terminal receipt)
  if [ -x "$AGENT_STATUS_SCRIPT" ]; then
    "$AGENT_STATUS_SCRIPT" --session-id "$SESSION_ID" --personality "$PERSONALITY_FROM_SEM" \
      "$AGENT" idle "" "" 2>/dev/null || true
  fi
  echo "Session CLOSE: $WP → $ORZ_FILE ✅"

  if [ -n "${FORCE_EVENT:-}" ]; then
    if [ -f "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" ]; then
      bash "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" day "$(now_date)" \
        session_closed_no_reflection "$FORCE_EVENT" session-guard >/dev/null 2>&1 \
        || echo "  ⚠️  ledger session_closed_no_reflection not written (terminal receipt already durable)" >&2
    else
      echo "  ⚠️  ledger-append.sh absent; reason force-close saved only by the calling side" >&2
    fi
  fi

  # Warn if local commits are not pushed in repos touched by this session
  _warn_unpushed() {
    local repo="$1"
    local ahead default_branch
    # issue #1209: same class as the --isolate fetch/worktree-add fix above — a
    # repo whose default branch isn't "main" always compared against a
    # nonexistent origin/main here (silently empty $ahead, no warning ever
    # fired, but the comparison itself was still wrong for such installs).
    default_branch="$(git -C "$repo" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/origin/##' || true)"
    default_branch="${default_branch:-main}"
    ahead=$(git -C "$repo" rev-list --left-only --count "HEAD...origin/$default_branch" 2>/dev/null || echo "")
    if [ -n "$ahead" ] && [ "$ahead" -gt 0 ]; then
      echo "⚠️  $ahead unpushed commits in $(basename "$repo"). Run: git -C $repo push" >&2
    fi
  }
  # Always check the ORZ repo (governance repo, $GOV_REPO)
  _warn_unpushed "$ORZ_DIR"
  # Also check repos inferred from file: entries in the semaphore
  # The semaphore has already been published as durable .closed receipt.
  _seen_repos="$ORZ_DIR"
  while IFS= read -r _line; do
    [[ "$_line" =~ ^file:\ (.*) ]] || continue
    _repo=$(git -C "$IWE_ROOT/$(dirname "${BASH_REMATCH[1]}")" rev-parse --show-toplevel 2>/dev/null || true)
    [ -z "$_repo" ] && continue
    echo "$_seen_repos" | grep -qxF "$_repo" && continue
    _seen_repos="$_seen_repos
$_repo"
    _warn_unpushed "$_repo"
  done < <(cat "$_sem_read" 2>/dev/null || true)

  # Best-effort attribution ONLY for closures, that bypassed process-runner.py
  # (port from the original source, WP-484 Phase133 — found 04.09.2026, peer-session
  # 2026-09-04-23-wp561-peer-session-closed-ledger-gap: this block in FMT-copy
  # was absent entirely, due to-which peer-sessions were silently not appearing in the daily
  # log). FORCED_CARD non-empty on bypass-paths above (peer-session,
  # force-no-reflection). The condition is mandatory: without it the event would be written also
  # for a normally completed runner, duplicating r23_verdict with the same
  # meaning under a different name. Never fails close close.
  if [ -n "${FORCED_CARD:-}" ]; then
    _append_direct_close_ledger "$_sem_read"
  fi

  exit 0
fi

# --- NOTE-FILE (manual scope registration for Bash-created/deleted files) ---
if [ "$CMD" = "note-file" ]; then
  FILE_PATH="${POSITIONAL[0]:-}"
  [ -z "$FILE_PATH" ] && fail "note-file: missing path argument" 1
  [ "${#POSITIONAL[@]}" -eq 1 ] || fail "note-file: exactly one path argument is expected path argument" 1
  NOTE_AGENT="${AGENT:-${IWE_AGENT:-claude-code}}"
  _safe_session_token "$NOTE_AGENT" || fail "note-file: unsafe --agent '$NOTE_AGENT'" 1
  # WP-464: resolve via select_semaphore, not the singleton current-<agent>.ptr —
  # the ptr gets clobbered by a second concurrent `open` of the same agent
  # (bug-2026-07-04-ptr-collision), silently writing scope into the wrong session.
  if [ -n "$SESSION_ID_ARG" ]; then
    SEM_FILE=$(resolve_semaphore_by_session_id "$NOTE_AGENT" "$SESSION_ID_ARG" "${WP:-}" "${SLUG:-}") && SG_RC=0 || SG_RC=$?
  else
    SEM_FILE=$(select_semaphore "$NOTE_AGENT" "${WP:-}" "${SLUG:-}") && SG_RC=0 || SG_RC=$?
  fi
  [ "$SG_RC" -eq 2 ] && exit 1
  if [ "$SG_RC" -ne 0 ] || [ -z "$SEM_FILE" ] || [ ! -f "$SEM_FILE" ]; then
    fail "note-file: no open session for agent '$NOTE_AGENT'. For a one-off operation open a housekeeping-session:\n  session-guard.sh open --housekeeping note-file --agent $NOTE_AGENT\n  session-guard.sh note-file <path> --agent $NOTE_AGENT\n  session-guard.sh close --housekeeping note-file --agent $NOTE_AGENT" 1
  fi
  NOTE_SESSION_ID="${SEM_FILE#"$SESSION_DIR/${NOTE_AGENT}-"}"
  NOTE_SESSION_ID="${NOTE_SESSION_ID%.open}"
  _safe_session_token "$NOTE_SESSION_ID" \
    || fail "note-file: semaphore name does not contain a safe exact session_id" 1
  _ensure_session_transition_lock "$SEM_FILE" "$NOTE_SESSION_ID"
  _locked_open_identity "$SEM_FILE" "$NOTE_AGENT" "$NOTE_SESSION_ID" 0 \
    || fail "note-file: open-semaphore did not pass exact identity/no-terminal check" 1
  # Normalize to git-root-relative (resolve symlinks/macOS /tmp vs /private/tmp)
  if [ -f "$FILE_PATH" ] || [ -d "$FILE_PATH" ]; then
    REPO_ROOT=$(git -C "$(dirname "$FILE_PATH")" rev-parse --show-toplevel 2>/dev/null || true)
  else
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  fi
  if [ -n "$REPO_ROOT" ]; then
    REL_PATH=$(python3 -c "
import os,sys
f = os.path.realpath(sys.argv[2])
r = os.path.realpath(sys.argv[3])
print(os.path.relpath(f, r))
" -- "$FILE_PATH" "$REPO_ROOT")
  else
    REL_PATH="$FILE_PATH"
  fi
  [ -n "$REL_PATH" ] || fail "note-file: cannot determine relative path for '$FILE_PATH'" 1
  case "$REL_PATH" in
    *$'\n'*|*$'\r'*) fail "note-file: path containing a newline is not allowed" 1 ;;
  esac
  # A noted path only protects a commit if it byte-matches what `git diff --cached`
  # reports later (repo-relative, no repo-name prefix). A repo-name-prefixed path
  # silently recorded here is bug-2026-07-31-runner-commit-push-stale-retry (gate
  # keeps blocking after an honest-looking registration). Future files (noted
  # BEFORE creation — day-close-mechanical pre-notes archive dest, sessions note
  # files they are about to Write) are legitimate: record verbatim, warn loudly.
  path_known_to_repo() {
    [ -e "$1/$2" ] && return 0
    git -C "$1" ls-files --cached --error-unmatch -- "$2" >/dev/null 2>&1 && return 0
    git -C "$1" cat-file -e "HEAD:$2" 2>/dev/null && return 0
    return 1
  }
  if [ -n "$REPO_ROOT" ] && ! path_known_to_repo "$REPO_ROOT" "$REL_PATH"; then
    REPO_NAME=$(basename "$REPO_ROOT")
    STRIPPED="${REL_PATH#"$REPO_NAME"/}"
    if [ "$STRIPPED" != "$REL_PATH" ] && path_known_to_repo "$REPO_ROOT" "$STRIPPED"; then
      echo "note-file: path '$REL_PATH' normalized to repo-relative-relative '$STRIPPED' (repository name prefix stripped)" >&2
      REL_PATH="$STRIPPED"
    elif [ "$STRIPPED" != "$REL_PATH" ]; then
      # Prefix textually matches the repo name but neither form exists yet —
      # overwhelmingly the prefix mistake, not a self-named future subdir.
      echo "note-file: WARNING — '$REL_PATH' starts with the repository name '$REPO_NAME/'; writing without prefix as '$STRIPPED' (scope gate scope gate compares repo-relative paths)" >&2
      REL_PATH="$STRIPPED"
    else
      echo "note-file: WARNING — '$REL_PATH' does not yet exist in the repo '$REPO_NAME' (not on disk, not in the index, nor in HEAD); recorded as a future file. If this is a typo — scope gate will not pass staged-file." >&2
    fi
  fi
  # A directory is registered as a directory (QUICKCLOSE-GAPS1 p.2): the trailing
  # slash is what tells the scope gate to cover everything underneath, including
  # files this session has not written yet. Without it a peer session had to
  # re-register each of its own files by hand right before committing.
  if [ -d "$FILE_PATH" ]; then
    case "$REL_PATH" in
      */) ;;
      *) REL_PATH="${REL_PATH}/" ;;
    esac
  fi
  _atomic_append_open "$SEM_FILE" "$NOTE_AGENT" "$NOTE_SESSION_ID" note "file: $REL_PATH" \
    || fail "note-file: atomic write rejected; session may have started closing close" 1
  echo "Noted in scope: $REL_PATH"
  exit 0
fi

# --- HOT-FILE LOCK (WP-7 SessionGitRaceIsolation, 09.08) ---
#
# ArchGate verdict (09.08.2026): a git worktree per session was proposed to stop
# the repeated collisions on the SAME small set of files (DayPlan, an active WP
# card, hypotheses-log.md, MEMORY.md — 18+ documented cases in July, 5 more in
# this single session today, including this very WP-7 card getting clobbered
# mid-edit). Measured live: worktree creation on this repo (21000+ files) costs
# several seconds of "Updating files" AND requires updating every script that
# hardcodes a single $IWE_ROOT/$GOV_REPO path — too much cost for a class of
# collision confined to ~4 files, not the whole tree. This is the cheaper fix
# the ArchGate recommended instead: lock only the files that actually keep
# colliding, not the working tree they live in.
#
# Deliberately a session-guard.sh command, not a Claude-Code-only hook: Kimi and
# Codex peer sessions call this same script for open/close/note-file already
# (its own header: "unified gate ... for all agents"), so a lock here is the
# one place that can actually be cross-agent. A PreToolUse:Edit hook would only
# ever see Claude Code's own edits -- today's collisions came from a mix of
# agent types, so a Claude-only mechanism would have caught a fraction of them.
# Enforcement is cognitive for Kimi/Codex until their own instructions call it
# (same class as several findings in GateEnforcement-Audit) -- the FMT hook
# below is defense-in-depth for the one agent type that supports it, not the
# whole fix.
HOT_LOCK_DIR="$IWE_ROOT/.iwe-runtime/hot-file-locks"
HOT_LOCK_TTL_SEC="${IWE_HOT_LOCK_TTL_SEC:-600}"  # 10 min -- long enough for a real edit+commit, short enough that a crashed holder doesn't block the file for a whole session

_hot_lock_slug() {  # _hot_lock_slug <repo-relative-path> -- filesystem-safe lock dirname
  echo "$1" | tr '/' '_'
}

if [ "$CMD" = "lock-hot-file" ]; then
  HOT_PATH="${POSITIONAL[0]:-}"
  [ -z "$HOT_PATH" ] && fail "lock-hot-file: missing path argument" 1
  LOCK_HOLDER_AGENT="${AGENT:-${IWE_AGENT:-claude-code}}"
  mkdir -p "$HOT_LOCK_DIR"
  LOCK_PATH="$HOT_LOCK_DIR/$(_hot_lock_slug "$HOT_PATH").lockdir"
  ATTEMPT=0
  while ! mkdir "$LOCK_PATH" 2>/dev/null; do
    if [ -f "$LOCK_PATH/meta" ]; then
      HELD_AT=$(grep '^locked_at: ' "$LOCK_PATH/meta" 2>/dev/null | cut -d' ' -f2-)
      HELD_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$HELD_AT" +%s 2>/dev/null \
        || date -u -d "$HELD_AT" +%s 2>/dev/null || echo 0)
      AGE=$(( $(date +%s) - HELD_EPOCH ))
      if [ "$AGE" -gt "$HOT_LOCK_TTL_SEC" ]; then
        echo "lock-hot-file: stale lock on '$HOT_PATH' (age ${AGE}s > ttl ${HOT_LOCK_TTL_SEC}s) — reclaiming" >&2
        rm -rf "$LOCK_PATH"
        continue
      fi
    fi
    ATTEMPT=$((ATTEMPT + 1))
    if [ "$ATTEMPT" -gt 30 ]; then
      HOLDER=$(cat "$LOCK_PATH/agent" 2>/dev/null || echo "unknown")
      fail "lock-hot-file: '$HOT_PATH' held by '$HOLDER' for >30s, giving up — retry shortly" 1
    fi
    sleep 1
  done
  {
    echo "locked_at: $(now_iso)"
    echo "agent: $LOCK_HOLDER_AGENT"
  } > "$LOCK_PATH/meta"
  echo "$LOCK_HOLDER_AGENT" > "$LOCK_PATH/agent"
  echo "Locked: $HOT_PATH"
  exit 0
fi

if [ "$CMD" = "unlock-hot-file" ]; then
  HOT_PATH="${POSITIONAL[0]:-}"
  [ -z "$HOT_PATH" ] && fail "unlock-hot-file: missing path argument" 1
  LOCK_PATH="$HOT_LOCK_DIR/$(_hot_lock_slug "$HOT_PATH").lockdir"
  rm -rf "$LOCK_PATH"
  echo "Unlocked: $HOT_PATH"
  exit 0
fi

# --- AUDIT ---
# --- RENEW (WP-484 Phase49) ---
# Extends the semaphore right to permit a commit. A separate command, and not a side
# effect note-file: renewal — an intentional signal «session is alive», and it is tied
# to a specific semaphore via the lease file name, so that the activity of one session
# does not renew a neighboring one.
if [ "$CMD" = "renew" ]; then
  [ "${#POSITIONAL[@]}" -eq 0 ] || fail "renew does not accept positional arguments" 1
  RENEW_AGENT="${AGENT:-${IWE_AGENT:-claude-code}}"
  _safe_session_token "$RENEW_AGENT" || fail "renew: unsafe --agent '$RENEW_AGENT'" 1
  if [ -n "$SESSION_ID_ARG" ]; then
    SEM_FILE=$(resolve_semaphore_by_session_id "$RENEW_AGENT" "$SESSION_ID_ARG" "${WP:-}" "${SLUG:-}") && SG_RC=0 || SG_RC=$?
    [ "$SG_RC" -eq 2 ] && exit 1
    [ "$SG_RC" -eq 0 ] || fail "renew: no open session ${RENEW_AGENT}-${SESSION_ID_ARG}" 3
  else
    # Failure on ambiguity now lives inside select_semaphore itself select_semaphore (the same
    # finding Codex also applied to close/note-file), therefore renew does not keep its own
    # copy of the iteration logic — it is sufficient to forward the return code.
    SEM_FILE=$(select_semaphore "$RENEW_AGENT" "${WP:-}" "${SLUG:-}") && SG_RC=0 || SG_RC=$?
    [ "$SG_RC" -eq 2 ] && exit 1
    if [ "$SG_RC" -ne 0 ] || [ -z "$SEM_FILE" ] || [ ! -f "$SEM_FILE" ]; then
      fail "renew: no open session for agent '$RENEW_AGENT' (specify --wp/--slug/--session-id)" 3
    fi
  fi
  RENEW_SESSION_ID="${SEM_FILE#"$SESSION_DIR/${RENEW_AGENT}-"}"
  RENEW_SESSION_ID="${RENEW_SESSION_ID%.open}"
  _safe_session_token "$RENEW_SESSION_ID" \
    || fail "renew: semaphore name does not contain a safe exact session_id" 1
  _ensure_session_transition_lock "$SEM_FILE" "$RENEW_SESSION_ID"
  _locked_open_identity "$SEM_FILE" "$RENEW_AGENT" "$RENEW_SESSION_ID" 0 \
    || fail "renew: open-semaphore did not pass exact identity/no-terminal check" 1
  LEASE_TMP="${SEM_FILE}.lease.tmp.$$"
  {
    echo "renewed_at: $(now_iso)"
    echo "session_id: $RENEW_SESSION_ID"
  } > "$LEASE_TMP"
  chmod 600 "$LEASE_TMP"
  # A concurrent close may have renamed the semaphore, while we were assembling the lease —
  # in that case publishing would have created an orphaned .lease and reported a renewal
  # of an already closed session (Codex, cold review 04.08).
  if [ ! -f "$SEM_FILE" ]; then
    rm -f "$LEASE_TMP"
    fail "renew: session $(basename "$SEM_FILE") closed during renewal — nothing to renew" 3
  fi
  # Full replacement, not appending: the lease file always stores a single value,
  # so the reader has no choice «first or last entry».
  mv "$LEASE_TMP" "${SEM_FILE}.lease"
  echo "Lease RENEW: $(basename "$SEM_FILE") — commit rights renewed for $((LEASE_SEC / 60)) min"
  exit 0
fi

if [ "$CMD" = "audit" ]; then
  # WP-526 Phase2 fix (29.08, peer-session 2026-08-29-06-wp526-worktree-guard-continue):
  # open (line ~482) and close (line ~668) already re-resolve ORZ_DIR through
  # resolve_orz_sessions_dir() before using it -- audit never did, so it kept
  # reading the top-level legacy default (line 110) even on an install that
  # already migrated to MC-sessions. Same one-line fix, same place in the
  # command, as the other two commands.
  ORZ_DIR="$(resolve_orz_sessions_dir)"
  if [ "$CLEANUP_ORPHANS" -eq 1 ]; then
    sweep_orphaned_semaphores
    echo
  fi
  SINCE="${SINCE:-$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d)}"
  echo "=== Session Guard Audit (since $SINCE) ==="
  echo

  # 1. Active semaphores (open without close)
  ACTIVE=$(find "$SESSION_DIR" -name "*.open" -type f 2>/dev/null)
  if [ -n "$ACTIVE" ]; then
    echo "⚠️ Active sessions without close:"
    for f in $ACTIVE; do
      if lease_valid "$f"; then
        echo "  $(basename "$f")"
      else
        # WP-484 Phase49: expired lease — not the death of the session, but loss of the right to
        # allow commit. Displayed separately, so that the debt is visible to the operator
        # in the normal reporting cycle (Day Opening reads this same output), rather than surfacing
        # as a surprise block on commit.
        echo "  $(basename "$f")  ⏳ commit rights have expired (renew or close)"
      fi
      sed 's/^/    /' "$f"
    done
    echo
  fi

  # 2. Sessions in open-sessions.log without ORZ-file
  if [ -f "$OPEN_LOG" ]; then
    echo "Sessions in open-sessions.log without ORZ (after $SINCE):"
    awk -v since="$SINCE" '
      $1 >= since {
        wp=$3; gsub(/\|/,"",wp); print $1, wp
      }
    ' "$OPEN_LOG" | sort -u | while read -r dt wp; do
      ORZ=$(ls "$ORZ_DIR/${dt:0:7}/$dt"-*"$wp"*.md 2>/dev/null | head -1 || true)
      if [ -z "$ORZ" ]; then
        echo "  $dt | $wp | ORZ missing"
      fi
    done
    echo
  fi

  # 3. ORZ-files with invalid frontmatter/sections
  echo "ORZ-files with defects (after $SINCE):"
  # Ported alongside validate_orz() (root commit 2779845553): one `git
  # ls-files` snapshot for the whole tree instead of one per file inside
  # validate_orz. No agent extraction here either -- validate_orz's own
  # "agent value" check always re-derived the value from this same file
  # and compared it against whatever was passed, so a self-fed value could
  # never fail; passing "" skips that no-op comparison instead of redoing
  # the extraction to feed it.
  AUDIT_TRACKED_SET=$(mktemp)
  git -C "$ORZ_DIR" ls-files > "$AUDIT_TRACKED_SET" 2>/dev/null
  find "$ORZ_DIR" -maxdepth 2 -mindepth 2 -name '*.md' -type f ! -name '00-index.md' -newermt "$SINCE" 2>/dev/null | while read -r orz; do
    tmp_errors=$(mktemp)
    if ! validate_orz "$orz" "" "$ORZ_DIR" "$AUDIT_TRACKED_SET" >"$tmp_errors" 2>&1 && [ -s "$tmp_errors" ]; then
      echo "  $(basename "$orz"):"
      sed 's/^/    /' "$tmp_errors"
    fi
    rm -f "$tmp_errors"
  done
  rm -f "$AUDIT_TRACKED_SET"
  echo

  # 4. Untracked ORZ-files
  echo "Uncommitted ORZ-files:"
  git -C "$ORZ_DIR" status --short . 2>/dev/null | grep '^??' || echo "  (none)"
  echo

  # 5. Stale semaphores older than 7 days
  echo "Stale-semaphores older than 7 days:"
  find "$SESSION_DIR" -name "*.open" -type f -mtime +7 2>/dev/null | while read -r f; do
    echo "  $(basename "$f")"
  done

  echo "=== Audit done ==="
  exit 0
fi

# --- RECOVER-ORPHANED (WP-484 Phase49, contract designed 04.08 peer-session
# 2026-08-04-13-session-ttl-f47-draft, step 1: Codex B4) ---
# Quarantine file — already an honest terminal record of the location, where the session
# got stuck; renaming back to `.open` would simulate a normal
# closure, that did not occur (explicitly prohibited in record Phase49). recover-orphaned
# instead writes a separate ledger-event and marks the file — the file itself
# the quarantine file stays on disk as is, we do not rewrite history.
if [ "$CMD" = "recover-orphaned" ]; then
  ORPHAN_ARG="${POSITIONAL[0]:-}"
  [ -z "$ORPHAN_ARG" ] && fail "recover-orphaned: missing path argument" 1
  case "$ORPHAN_ARG" in
    /*) ORPHAN_FILE="$ORPHAN_ARG" ;;
    *)  ORPHAN_FILE="$SESSION_DIR/$ORPHAN_ARG" ;;
  esac
  [ -f "$ORPHAN_FILE" ] || fail "recover-orphaned: file not found: $ORPHAN_FILE" 1
  # Review post-consensus (one-time verification-request Codex, 04.08): the command
  # accepted any path on disk with a matching name — does not weaken Scope gate
  # (.recovered does not grant commit rights), but the extra ability to rename files
  # outside the semaphore directory. Canonicalize and confine to $SESSION_DIR, reject
  # symlink and repeated invocation on an already-recovered file.
  CANON_FILE=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$ORPHAN_FILE")
  CANON_DIR=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$SESSION_DIR")
  case "$CANON_FILE" in
    "$CANON_DIR"/*) : ;;
    *) fail "recover-orphaned: '$ORPHAN_FILE' outside the semaphore directory ($SESSION_DIR)" 1 ;;
  esac
  [ -L "$ORPHAN_FILE" ] && fail "recover-orphaned: '$ORPHAN_FILE' — symbolic link, not a quarantine file" 1
  case "$(basename "$CANON_FILE")" in
    *.recovered) fail "recover-orphaned: '$(basename "$CANON_FILE")' already recovered" 1 ;;
    *.orphaned-*) : ;;
    *) fail "recover-orphaned: '$(basename "$CANON_FILE")' does not look like a quarantine semaphore (expected suffix .orphaned-*)" 1 ;;
  esac
  REC_OPEN_KEY="${CANON_FILE%%.orphaned-*}"
  case "$REC_OPEN_KEY" in
    *.open) : ;;
    *) fail "recover-orphaned: failed to recover canonical .open key" 1 ;;
  esac
  _ensure_session_transition_lock "$REC_OPEN_KEY" ""
  [ -f "$CANON_FILE" ] || fail "recover-orphaned: quarantine file disappeared under lock" 1
  ORPHAN_FILE="$CANON_FILE"
  grep -qE '^(agent|opened_at|session_id): ' "$ORPHAN_FILE" || \
    fail "recover-orphaned: '$(basename "$CANON_FILE")' does not look like a semaphore session-guard (missing fields agent:/opened_at:/session_id:)" 1

  REASON=$(basename "$ORPHAN_FILE" | sed -n 's/.*\.orphaned-//p')
  REC_WP=$(grep "^wp: " "$ORPHAN_FILE" | cut -d' ' -f2- || true)
  REC_SLUG=$(grep "^slug: " "$ORPHAN_FILE" | cut -d' ' -f2- || true)
  REC_SID=$(grep "^session_id: " "$ORPHAN_FILE" | cut -d' ' -f2- || echo unknown)
  REC_PATH=$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$ORPHAN_FILE" "$IWE_ROOT")

  EVENT_JSON=$(python3 -c '
import json, sys
print(json.dumps({
    "original_path": sys.argv[1],
    "quarantine_reason": sys.argv[2],
    "wp": sys.argv[3] or "unknown",
    "slug": sys.argv[4] or "unknown",
    "session_id": sys.argv[5],
}))
' "$REC_PATH" "$REASON" "${REC_WP:-}" "${REC_SLUG:-}" "$REC_SID")

  # Terminal state is published first with no-clobber + directory fsync.
  # Ledger is a projection: its outage cannot roll terminal state back or
  # justify recreating the quarantine source on retry.
  _terminal_move_no_clobber "$ORPHAN_FILE" "${ORPHAN_FILE}.recovered" \
    || fail "recover-orphaned: destination .recovered already belongs to a different inode" 1
  if [ -f "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" ]; then
    bash "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" day "$(now_date)" \
      session_recovered_closed "$EVENT_JSON" session-guard >/dev/null 2>&1 \
      || echo "  ⚠️  ledger session_recovered_closed not written (terminal state already durable)" >&2
  else
    echo "  ⚠️  ledger-append.sh absent (terminal state already durable)" >&2
  fi

  echo "Recovered: $(basename "$ORPHAN_FILE") — file marked .recovered, session_recovered_closed written to ledger ($REC_PATH, wp=${REC_WP:-unknown}, session_id=$REC_SID). The original quarantine file has NOT been returned to .open — this is an honest terminal record, not a simulation of a normal closure."
  exit 0
fi

# A registered directory covers everything under it (QUICKCLOSE-GAPS1 item.2, found
# live 04.08): a peer-conversation opens ONE session directory and then writes a
# dozen files into it as the run goes on. Before this, every one of those files
# needed its own note-file call right before the commit -- 13 calls for a single
# session, and the gate blocked whatever was forgotten, even though `open` had
# already claimed that exact directory. A directory entry is stored with a
# trailing slash, so it can never be confused with a file of the same name.
scope_has_path() {  # scope_has_path <semaphore> <repo-relative-path>
  local sem="$1" path="$2" entry
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    [ "$entry" = "$path" ] && return 0
    case "$entry" in
      */) case "$path" in "$entry"*) return 0 ;; esac ;;
    esac
  done < <(sed -n 's/^file: //p' "$sem")
  return 1
}

# --- GIT PRE-COMMIT CHECK ---
if [ "$CMD" = "pre-commit-check" ]; then
  # WP-484 Phase49: the right to approve a commit expires on lease and is revoked for the ENTIRE
  # set of semaphore files at once. Partial revocation (block only new
  # `file:`) hole WP-507 does not close: already listed paths would continue to
  # let through foreign edits, made after, the session had effectively
  # ended. This is also why the removal of the mtime-mtime bypass of an expired semaphore —
  # the older it is, the more unrelated files passed through «by freshness».
  # Known limitation of the mechanism (intentional, not an oversight): the expiry is checked once per
  # hook, therefore a commit, started an instant before the lease expires, will pass.
  # A repeat check before exit does not close the window — between the end of the hook and
  # writing the git object git time passes regardless, — and it would look like a
  # guarantee of atomicity. With a lease duration of 4 hours «expired by a fraction of a second» and
  # «valid» describe the same session state.
  ALL_OPEN=$(find "$SESSION_DIR" -name "*.open" -type f 2>/dev/null)
  ACTIVE=""
  EXPIRED=""
  for sem in $ALL_OPEN; do
    if lease_valid "$sem"; then
      ACTIVE="${ACTIVE}${sem}"$'\n'
    else
      EXPIRED="${EXPIRED}${sem}"$'\n'
    fi
  done
  ACTIVE="${ACTIVE%$'\n'}"
  EXPIRED="${EXPIRED%$'\n'}"

  if [ -z "$ACTIVE" ]; then
    if [ -n "$EXPIRED" ]; then
      echo "🚫 SESSION-GUARD: commit blocked — the open sessions have an expired authorization period." >&2
      echo "" >&2
      for sem in $EXPIRED; do
        sem_wp=$(grep "^wp: " "$sem" | cut -d' ' -f2- || echo "?")
        echo "  · $(basename "$sem") (WP: $sem_wp)" >&2
      done
      echo "" >&2
      echo "The session-still exists and is being closed normally. Choose:" >&2
      echo "  renew:  bash {{WORKSPACE_DIR}}/scripts/session-guard.sh renew --wp WP-N" >&2
      echo "  close:   bash {{WORKSPACE_DIR}}/scripts/session-guard.sh close --wp WP-N" >&2
      exit 4
    fi
    cat >&2 <<'EOF'
🚫 SESSION-GUARD: commit blocked.

No session opened via the protocol. Before working with files:
  bash {{WORKSPACE_DIR}}/scripts/session-guard.sh open --wp WP-N --task "..."

Or, if this is an emergency-emergency fix without a WP:
  GIT_OPTIONAL_LOCKS=0 git commit --no-verify -m "..."
EOF
    exit 4
  fi

  # Scope gate: every staged file must be touched in at least one active session.
  # Existing/new files: mtime > semaphore mtime.
  # Deleted files: path must be listed in at least one semaphore append-log.
  BLOCKED=0
  SEMAPHORE_MTIMES=()
  for sem in $ACTIVE; do
    SEMAPHORE_MTIMES+=("$(python3 -c "import sys,os; print(os.stat(sys.argv[2]).st_mtime_ns)" -- "$sem")")
  done

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    status="${line%%$'\t'*}"
    f="${line##*$'\t'}"
    status_char="${status:0:1}"

    if [ "$status_char" = "D" ]; then
      # Deleted file: check append-log across all active semaphores
      FOUND=0
      for sem in $ACTIVE; do
        if scope_has_path "$sem" "$f"; then
          FOUND=1
          break
        fi
      done
      if [ "$FOUND" -eq 0 ]; then
        echo "🚫 BLOCK: $f deleted, but is not listed in scope active sessions" >&2
        BLOCKED=1
      fi
      continue
    fi

    if [ "$status_char" = "A" ] || [ "$status_char" = "R" ] || [ "$status_char" = "C" ]; then
      # New path (added/renamed/copied): no mtime bypass. A semaphore's mtime
      # is refreshed by every heartbeat, so a long-open session (bug-2026-07-07:
      # Kimi session open 42h) makes "mtime > semaphore" pass for ANY file any
      # OTHER agent happens to touch near commit time — mtime says nothing
      # about whether the file is actually this session's work. New paths must
      # be explicitly declared via note-file.
      FOUND=0
      for sem in $ACTIVE; do
        if scope_has_path "$sem" "$f"; then
          FOUND=1
          break
        fi
      done
      if [ "$FOUND" -eq 0 ]; then
        echo "🚫 BLOCK: $f — new file outside scope active sessions (a note-file is required note-file, mtime does not count)" >&2
        BLOCKED=1
      fi
      continue
    fi

    # Modified existing (already-tracked) file: mtime > semaphore, or explicit
    # note-file append-log entry (needed for files edited before `open` was
    # called — e.g. peer-conversation-skill sessions whose own meta.yaml/
    # report.md already document the session).
    FILE_MTIME=$(python3 -c "import sys,os; print(os.stat(sys.argv[2]).st_mtime_ns)" -- "$f")
    PASS=0
    for sem_mtime in "${SEMAPHORE_MTIMES[@]}"; do
      if [ "$FILE_MTIME" -gt "$sem_mtime" ]; then
        PASS=1
        break
      fi
    done
    if [ "$PASS" -eq 0 ]; then
      for sem in $ACTIVE; do
        if scope_has_path "$sem" "$f"; then
          PASS=1
          break
        fi
      done
    fi
    if [ "$PASS" -eq 0 ]; then
      echo "🚫 BLOCK: $f not touched in active sessions (mtime <= all semaphores, not in note-file)" >&2
      BLOCKED=1
    fi
  done < <(git -c core.quotepath=false diff --cached --name-status)

  if [ "$BLOCKED" -ne 0 ]; then
    echo "" >&2
    echo "Scope gate: staged-files outside current sessions." >&2
    echo "If the file belongs to a session, add it manually:" >&2
    echo "  bash {{WORKSPACE_DIR}}/scripts/session-guard.sh note-file <path>" >&2
    echo "Or remove from staged:" >&2
    echo "  git restore --staged <file>" >&2
    # Emit AR.216 warn to rule-engine session warn log
    _SESSION_ID="${CLAUDE_SESSION_ID:-default}"
    _WARN_LOG="$HOME/.claude/state/session-${_SESSION_ID}-warns.jsonl"
    mkdir -p "$(dirname "$_WARN_LOG")" 2>/dev/null || true
    printf '{"ts":"%s","event":"pre-commit","rule":"AR.216","verdict":"warn","reason":"Scope gate: staged files outside active session — use git add <specific-path>"}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$_WARN_LOG" 2>/dev/null || true
    exit 6
  fi

  exit 0
fi


# --- FREEZE-CANONICAL (WP-485 Phase14 / WP-520) ---
if [ "$CMD" = "freeze-canonical" ]; then
  FREEZE_PATH="${POSITIONAL[0]:-}"
  [ -z "$FREEZE_PATH" ] && fail "freeze-canonical: missing path argument" 1
  [ -d "$FREEZE_PATH" ] || fail "freeze-canonical: '$FREEZE_PATH' is not a directory" 1
  if [ -L "$FREEZE_PATH" ]; then
    fail "freeze-canonical: '$FREEZE_PATH' is a symlink — pass the resolved path" 1
  fi
  if [ "${FORCE_FLAG:-0}" != "1" ]; then
    LIVE=$(list_candidates "${AGENT:-${IWE_AGENT:-claude-code}}")
    if [ -n "$LIVE" ]; then
      echo "session-guard: freeze-canonical: agent has open semaphore(s) — close them first or pass --force:" >&2
      echo "$LIVE" >&2
      exit 1
    fi
  fi
  chflags -R uchg "$FREEZE_PATH" \
    || fail "freeze-canonical: chflags -R uchg failed on '$FREEZE_PATH'" 1
  echo "Frozen (chflags -R uchg): $FREEZE_PATH"
  exit 0
fi

if [ "$CMD" = "unfreeze-canonical" ]; then
  FREEZE_PATH="${POSITIONAL[0]:-}"
  [ -z "$FREEZE_PATH" ] && fail "unfreeze-canonical: missing path argument" 1
  fail "unfreeze-canonical no longer removes chflags on its own — pilot manually: 'chflags -R nouchg $FREEZE_PATH'. Agent: request-unfreeze-canonical --reason \"...\"" 1
fi

if [ "$CMD" = "request-unfreeze-canonical" ]; then
  FREEZE_PATH="${POSITIONAL[0]:-}"
  [ -z "$FREEZE_PATH" ] && fail "request-unfreeze-canonical: missing path argument" 1
  [ -z "${UNFREEZE_REASON:-}" ] && fail "request-unfreeze-canonical: --reason is required" 1
  UNFREEZE_LOG="$IWE_ROOT/.iwe-runtime/unfreeze-requests.log"
  mkdir -p "$(dirname "$UNFREEZE_LOG")"
  NONCE=$(date +%s%N 2>/dev/null || date +%s)-$$
  {
    echo "---"
    echo "requested_at: $(now_iso)"
    echo "path: $FREEZE_PATH"
    echo "reason: $UNFREEZE_REASON"
    echo "agent: ${AGENT:-${IWE_AGENT:-unknown}}"
    echo "nonce: $NONCE"
    echo "---"
  } >> "$UNFREEZE_LOG"
  echo "Unfreeze request has been registered (nonce: $NONCE)."
  echo "Reason: $UNFREEZE_REASON"
  echo ""
  echo "Unfreeze — manually by the pilot only:"
  echo "  chflags -R nouchg $FREEZE_PATH"
  echo ""
  echo "This command did not unfreeze anything — only recorded the request in $UNFREEZE_LOG."
  exit 0
fi

fail "Unknown command: $CMD (use: open, close, audit, renew, heartbeat, note-file, recover-orphaned, pre-commit-check, freeze-canonical, unfreeze-canonical, request-unfreeze-canonical)"
