#!/usr/bin/env bash
# session-guard.sh — единый gate open/close/audit для всех агентов (Claude, Kimi, Hermes)
# see WP-398 Ф5, AGENTS.md (WP Gate — CRITICAL), protocol-open.md
#
# Инвариант: любая сессия с изменениями файлов должна пройти open → ORZ → commit → close.
# Mechanical enforcement: git pre-commit hook проверяет наличие активного семафора.
#
# Команды:
#   open --wp WP-N [--task "..."] [--files "a,b"] [--slug "..."] [--agent claude-code|kimi|hermes] [--personality <unassigned|UUID>]
#   open --housekeeping <reason> [--agent ...]        # фоновая housekeeping-сессия без ORZ
#   close [--wp WP-N] [--slug "..."] [--agent ...]
#   close ... --force-no-reflection "<причина>"       # закрыть без ответа на рефлексию —
#                                                      # только если раннер стоит именно на
#                                                      # blocked-witness-unavailable И push уже
#                                                      # подтверждён (all_pushed: true)
#   close --housekeeping <reason> [--agent ...]       # закрыть housekeeping-сессию
#   audit [--since YYYY-MM-DD] [--cleanup-orphans]
#   renew [--wp WP-N] [--slug "..."] [--agent ...]    # продлить право на коммит
#   heartbeat --agent <agent> --session-id <id> --owner-pid <pid>
#   pre-commit-check
#   note-file <path> [--agent ...] [--session-id <id>]
#   lock-hot-file <path> [--agent ...]    # WP-7 SessionGitRaceIsolation: короткий
#   unlock-hot-file <path>                # mkdir-замок на файл, который часто
#                                          # коллизирует между параллельными сессиями
#                                          # (DayPlan, активная карточка РП, hypotheses-log,
#                                          # MEMORY.md) — не на всё рабочее дерево
#
# Аренда (WP-484 Ф49): существование сессии и её право разрешать коммит — разные
# вещи. Возраст отзывает только право (по умолчанию 4h, `IWE_SESSION_LEASE_SEC`);
# существование снимает лишь close или доказанная смерть процесса-владельца.
#
# Exit codes:
#   0 — OK
#   1 — общая ошибка
#   2 — open без wp
#   3 — close без предшествующего open
#   4 — git pre-commit блок (семафор не найден)
#   5 — ORZ не прошёл валидацию
#   6 — scope gate block (staged файл вне активных сессий)

set -euo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SESSION_GUARD_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
# issue #266: hardcoded "DS-strategy" broke every template user whose
# governance repo is named "DS-strategy" (the shipped default — see create-wp.sh).
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
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
    || fail "session-transition: небезопасный путь семафора '$semaphore'" 1

  if [ -n "${IWE_SESSION_TRANSITION_FD:-}" ] || \
     [ -n "${IWE_SESSION_TRANSITION_TARGET:-}" ]; then
    _validate_inherited_session_lock "$canonical" \
      || fail "session-transition: унаследованный lock не прошёл проверку" 1
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
# containing a literal ": " (a real one arrived 2026-09-09, "РП170: R15-триаж
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
    print("task: %s" % value)
    raise SystemExit(0)
sys.stdout.write(yaml.safe_dump({"task": value}, allow_unicode=True, default_flow_style=False, width=10**7).rstrip("\n"))
' "$1"
}

# resolve_orz_sessions_dir -- forward-port from ~/IWE/scripts/session-guard.sh
# (WP-526 Ф2, 29.08; this FMT copy stays on the reduced/freeze-canonical
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
    fail "IWE_SESSIONS_ROOT=$IWE_SESSIONS_ROOT задан явно, но недоступен или не git-репозиторий"
  fi

  local default_mc="$IWE_ROOT/MC-sessions"
  if [ -d "$default_mc" ]; then
    if git -C "$default_mc" rev-parse --git-dir >/dev/null 2>&1; then
      echo "$default_mc"
      return 0
    fi
    fail "MC-sessions существует ($default_mc), но не похож на git-репозиторий -- похоже на сломанную мигрированную установку, не откатываюсь на legacy-путь молча"
  fi

  echo "WARN: MC-sessions не найден ($default_mc) -- использую legacy-путь \$GOV_REPO/sessions (обычное поведение немигрированной установки шаблона)" >&2
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

# --- Lease: право семафора разрешать коммит (WP-484 Ф49, 04.08, пир-сессия с Codex) ---
#
# Семафор несёт две РАЗНЫЕ функции, которые до сих пор были склеены в одном
# состоянии `.open`:
#   А — «сессия существует, не трогай её»;
#   Б — «файлы этой сессии разрешены к коммиту» (scope gate ниже).
# WP-507 (30.07) — брошенный семафор 4.5h раздавал функцию Б чужим файлам.
# Лечили это авто-карантином по возрасту в `open`, но он отнимает функцию А:
# любая сессия старше TTL уезжала в `.orphaned-*`, как только тот же агент
# открывал вторую, и после этого не могла завершить Quick Close (`close`
# выбирает только `*.open`). На диске 155 таких файлов против 293 закрытых
# штатно. Разделение функций снимает конфликт: возраст отзывает только Б.
#
# Аренда живёт в ОТДЕЛЬНОМ файле `<semaphore>.lease`, а не строкой в семафоре:
#   1. append в семафор двигает его mtime, а scope gate сравнивает mtime файлов
#      с mtime семафора — продление аренды молча отзывало бы право у файлов,
#      отредактированных до продления;
#   2. повторные append дают неоднозначность «первая или последняя запись»
#      (sweep_orphaned_semaphores выше читает `head -1`);
#   3. имя файла аренды производно от имени семафора — привязка к конкретной
#      сессии структурная, продлить чужую аренду «заодно» нельзя.
LEASE_SEC="${IWE_SESSION_LEASE_SEC:-14400}"  # 4h; продление — `renew`

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

# Семафор без разбираемой метки времени (до-WP-484 или битый) НЕ получает
# полномочий: именно этот случай независимое ревью 01.08 пометило как риск
# ослабления scope gate, а авто-карантин его не покрывает by design.
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
      # WP-530 Ф12 (20.08, пир-сессия с Codex): with both selectors given, this
      # must be an intersection -- a plain OR (as this copy had until now)
      # matches a stale sibling session sharing only the wp, causing false
      # ambiguity. Synced from the canonical ~/IWE/scripts/session-guard.sh
      # (WP-484 Ф49, 04.08) -- same fix, this copy just hadn't received it.
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

    # WP-484 Ф49 (04.08, Codex): раньше здесь стоял `break` на первом совпадении,
    # то есть при двух открытых сессиях одного РП выбиралась просто новейшая по
    # mtime — и `close` закрывал не ту сессию, а `note-file` отдавал право на
    # коммит чужой работе. Совпало несколько — это отказ, а не догадка: уточни
    # --slug или --session-id.
    if [ "${#matches[@]}" -gt 1 ]; then
      echo "session-guard: под wp='$want_wp' slug='$want_slug' подходит несколько сессий агента '$agent' — уточни:" >&2
      print_candidates "$(printf '%s\n' "${matches[@]}")"
      return 2
    fi

    # Explicit --wp/--slug was given and matched nothing — never silently
    # fall back to "the only open one", even when there's exactly one.
    # Falling back here would close/note-file the WRONG session under the
    # operator's own explicit (but mistyped/stale) --wp, defeating the
    # entire point of this fix.
    echo "session-guard: ни один открытый семафор агента '$agent' не совпал с wp='$want_wp' slug='$want_slug':" >&2
    print_candidates "$candidates"
    return 2
  fi

  count=$(echo "$candidates" | grep -c . || true)
  if [ "$count" -eq 1 ]; then
    echo "$candidates"
    return 0
  fi

  echo "session-guard: несколько открытых семафоров для агента '$agent' — укажи --wp/--slug:" >&2
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
    echo "небезопасный agent '$agent'" >&2
    return 2
  }
  _safe_session_token "$session_id" || {
    echo "небезопасный --session-id '$session_id'" >&2
    return 2
  }
  semaphore="$SESSION_DIR/${agent}-${session_id}.open"
  [ -f "$semaphore" ] || return 1
  sem_wp=$(grep '^wp: ' "$semaphore" | cut -d' ' -f2- || true)
  sem_slug=$(grep '^slug: ' "$semaphore" | cut -d' ' -f2- || true)
  if [ -n "$want_wp" ] && [ "$sem_wp" != "$want_wp" ]; then
    echo "--session-id $session_id указывает на wp='$sem_wp', а передан --wp='$want_wp'" >&2
    return 2
  fi
  if [ -n "$want_slug" ] && [ "$sem_slug" != "$want_slug" ]; then
    echo "--session-id $session_id указывает на slug='$sem_slug', а передан --slug='$want_slug'" >&2
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
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wp)     WP="$2"; shift 2 ;;
    --task)   TASK="$2"; shift 2 ;;
    --files)  FILES="$2"; shift 2 ;;
    --slug|--topic) SLUG="$2"; shift 2 ;;
    --agent)  AGENT="$2"; shift 2 ;;
    --housekeeping) HOUSEKEEPING="$2"; shift 2 ;;
    --personality) PERSONALITY="$2"; shift 2 ;;
    --session-id) SESSION_ID_ARG="$2"; shift 2 ;;
    --owner-pid) OWNER_PID="$2"; shift 2 ;;
    --since)  SINCE="$2"; shift 2 ;;
    --cleanup-orphans) CLEANUP_ORPHANS=1; shift ;;
    --force-no-reflection) FORCE_NO_REFLECTION="$2"; shift 2 ;;
    --close-path) CLOSE_PATH="$2"; shift 2 ;;
    --)       shift; POSITIONAL+=("$@"); break ;;
    # WP-7 Ф83: was a silent `shift` -- unrecognized flags vanished with no diagnostic.
    -*)       fail "неизвестный флаг: $1" 1 ;;
    *)        POSITIONAL+=("$1"); shift ;;
  esac
done

if [ -z "$AGENT" ] && { [ "$CMD" = "open" ] || [ "$CMD" = "close" ]; }; then
  fail "--agent обязателен для open/close (или переменная IWE_AGENT)" 1
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
  [ "${#POSITIONAL[@]}" -eq 0 ] || fail "open не принимает позиционные аргументы" 1
  _safe_session_token "$AGENT" || fail "open: небезопасный --agent '$AGENT'" 1
  if [ -n "$SESSION_ID_ARG" ]; then
    _safe_session_token "$SESSION_ID_ARG" || fail "open: небезопасный --session-id '$SESSION_ID_ARG'" 1
  fi
  if [ -n "$OWNER_PID" ]; then
    [[ "$OWNER_PID" =~ ^[1-9][0-9]*$ ]] || fail "open: --owner-pid должен быть положительным PID" 1
    kill -0 "$OWNER_PID" 2>/dev/null || fail "open: --owner-pid $OWNER_PID не существует" 1
  fi
  # WP-510 Патч 4: personality — маршрутизирующая метка "какая ИИ-личность вела
  # сессию", не допуск к памяти (PIPE-14 решает перенос отдельно). Пустой флаг =
  # unassigned — тот же итог, что и явный `--personality unassigned`, разница
  # explicit/default не хранится (consensus 2026-08-04-11-codex-wp510-patch4-proposed).
  PERSONALITY="${PERSONALITY:-unassigned}"
  if [ "$PERSONALITY" != "unassigned" ] && ! [[ "$PERSONALITY" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    fail "--personality: ожидается 'unassigned' либо UUID вида 8-4-4-4-12 (получено: '$PERSONALITY')" 1
  fi

  if [ -n "$HOUSEKEEPING" ]; then
    # Housekeeping session: no ORZ, no WP, one semaphore per (agent, reason).
    _safe_session_token "$HOUSEKEEPING" || fail "open --housekeeping: причина должна быть безопасным slug" 1
    HK_FILE="$SESSION_DIR/${AGENT}-housekeeping-${HOUSEKEEPING}.open"
    HK_SESSION_ID="housekeeping-${HOUSEKEEPING}"
    _safe_session_token "$HK_SESSION_ID" || fail "open --housekeeping: идентификатор слишком длинный" 1
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
              || fail "open --housekeeping: .stale destination collision; существующий open сохранён" 1
            rm -f "${HK_FILE}.lease"
            echo "WARNING: housekeeping semaphore '${HOUSEKEEPING}' stale (${HK_AGE}s), renamed to .stale" >&2
          else
            fail "open --housekeeping: уже есть активная housekeeping-сессия '${HOUSEKEEPING}' (возраст ${HK_AGE}s). Закрой её или дождись TTL ${HK_MAX_AGE}s" 1
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
      # git-wrapper-blocked-by-corrupt-semaphore.md, "Резолюция", 2026-09-10).
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
      || { rm -f "$HK_TMP"; fail "open --housekeeping: семафор появился параллельно; существующий файл не изменён" 1; }
    echo "Housekeeping OPEN: $HK_FILE (reason: $HOUSEKEEPING)"
    exit 0
  fi

  [ -z "$WP" ] && fail "--wp обязателен для open" 2

  # WP-518: создание РП и начало работы — разные решения. Новый создатель
  # карточек пишет `hypothesis_relation: unclassified`, пока пилот не выбрал
  # смысл работы в контуре ставок. Такой РП можно зарегистрировать и
  # обсудить, но нельзя открыть для изменения файлов: иначе значение
  # обязательного поля превращается в необязательную пометку.
  #
  # Отсутствующее поле намеренно не блокируется: это карточка, созданная до
  # введения контракта, и массовое дообогащение исторических РП не является
  # безопасным побочным эффектом открытия одной сессии.
  WP_CARD="$IWE_ROOT/$GOV_REPO/inbox/$WP/$WP.md"
  if [ ! -f "$WP_CARD" ]; then
    WP_CARD="$IWE_ROOT/$GOV_REPO/inbox/$WP.md"
  fi
  if [ -f "$WP_CARD" ] && grep -qE "^hypothesis_relation:[[:space:]]*['\"]?unclassified['\"]?[[:space:]]*$" "$WP_CARD"; then
    fail "РП $WP не классифицирована по гипотезе. До открытия выберите tests, enables, responds, researches или operational в $WP_CARD" 1
  fi

  # Report stale semaphores of the same agent — WITHOUT quarantining them.
  #
  # WP-484 Ф49 (04.08): this loop used to `mv` every semaphore older than the
  # TTL into `.orphaned-*`. Age alone proves nothing about liveness, so it kept
  # killing sessions that were actively working — live case that triggered the
  # fix: a WP-7 session whose semaphore had been written to one minute earlier
  # was quarantined because `opened_at` was 43 minutes old. Once renamed, the
  # session can no longer close (`close` only selects `*.open`) — that is the
  # mechanism behind Ф49's "delivered work, no formal Quick Close".
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
    # WP-484 Нить1 (peer-session 2026-07-31-14-wp484-session-close-discipline):
    # any unrelated append (note-file, a stray write into the wrong semaphore)
    # bumps mtime and resets the TTL clock, which is exactly how a truly
    # abandoned semaphore (WP-507, 30.07) survived auto-orphan for 4.5h while
    # collecting other sessions' files. Falls back to created_at, then to a
    # loud WARN (no more silent mtime fallback — see WP-484 Ф31 below).
    STALE_OPENED_AT=$(grep "^opened_at: " "$STALE" | cut -d' ' -f2- || true)
    STALE_EPOCH=""
    if [ -n "$STALE_OPENED_AT" ]; then
      STALE_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$STALE_OPENED_AT" +%s 2>/dev/null \
        || date -u -d "$STALE_OPENED_AT" +%s 2>/dev/null || echo "")
    fi
    # Fallback to mtime is REMOVED to prevent WP-507-style orphan resurrection
    # (append-operations updating mtime restart the TTL clock).
    # If opened_at failed, try created_at (immutable backup added in WP-484 Ф31).
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
        echo "NOTE: у агента открыта долгая сессия $(basename "$STALE") (WP: $STALE_WP, возраст ${STALE_AGE}s) — права на коммит действуют, не трогаю" >&2
      else
        echo "WARNING: сессия $(basename "$STALE") (WP: $STALE_WP, возраст ${STALE_AGE}s) потеряла права на коммит." >&2
        echo "         Закрой её (close --wp $STALE_WP) или продли: renew --wp $STALE_WP" >&2
      fi
    fi
  done < <(ls -t "$SESSION_DIR/${AGENT}"-*.open 2>/dev/null || true)

  SESSION_ID="${SESSION_ID_ARG:-${IWE_SESSION_LOCKED_SESSION_ID:-${IWE_SESSION_ID:-$(date +%s)-$$-$RANDOM}}}"
  _safe_session_token "$SESSION_ID" || fail "open: небезопасный session_id '$SESSION_ID'" 1
  SEM_FILE="$SESSION_DIR/${AGENT}-${SESSION_ID}.open"
  _ensure_session_transition_lock "$SEM_FILE" "$SESSION_ID"
  if [ -e "$SEM_FILE" ] || [ -L "$SEM_FILE" ]; then
    fail "open: exact session_id '$SESSION_ID' уже открыт; существующий семафор не изменён" 1
  fi
  if find "$SESSION_DIR" -maxdepth 1 \( -type f -o -type l \) \
      -name "$(basename "$SEM_FILE").*" -print -quit 2>/dev/null | grep -q .; then
    fail "open: для exact session_id '$SESSION_ID' уже есть terminal/lease state; выбери новый идентификатор" 1
  fi
  # WP-484 (31.07, data-pipeline-audit-2026-07-30.md §3.3): a caller-supplied slug
  # sometimes already carries today's date (Kimi free-text `--slug`, human habit) —
  # confirmed live on real files, e.g. sessions/2026-07/2026-07-31-2026-07-31-wp510-*.md.
  # This is the ONE place that assembles the path, so it's the one place that can
  # enforce "date appears exactly once" regardless of what any caller passes.
  CLEAN_SLUG="${SLUG:-$WP}"
  CLEAN_SLUG="${CLEAN_SLUG#"$(now_date)"-}"
  ORZ_BASENAME="$(now_month)/$(now_date)-${CLEAN_SLUG}.md"
  # WP-526 Ф2 (29.08): `open` is the only writer, so it's the only place that
  # needs the strict (fail-closed-if-broken) resolution -- overrides the
  # passive default set at the top of the script for read-only commands.
  ORZ_DIR="$(resolve_orz_sessions_dir)"
  ORZ_FILE="$ORZ_DIR/$ORZ_BASENAME"
  mkdir -p "$(dirname "$ORZ_FILE")"
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
    # Ф32 п.5 (WP-484, 31.07): `open` creates the ORZ scaffold itself below — its
    # first commit is a brand-new git path (status A), which the scope gate never
    # mtime-bypasses. Without this line every session's OWN report needed a
    # separate `note-file` call just to survive the gate it forgot about — live-
    # reproduced (mktemp sandbox: open → edit ORZ → git add → pre-commit-check
    # → BLOCK) and matches orphaned untracked ORZ files found sitting in this
    # session's own `git status` from a prior, unrelated WP. Path is relative to
    # $ORZ_DIR's PARENT (governance-repo root — sessions/<...>), same convention
    # every other `file:` line already uses.
    echo "file: $(basename "$ORZ_DIR")/$ORZ_BASENAME"
  } > "$SEM_TMP"
  _publish_open_no_clobber "$SEM_TMP" "$SEM_FILE" \
    || { rm -f "$SEM_TMP"; fail "open: exact session_id '$SESSION_ID' появился параллельно; существующий файл не изменён" 1; }
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

# Сессия $(now_date) — ${TASK:-$WP}

## Главный инсайт

## Контекст

## Достигнуто

| Артефакт | Описание |
|----------|----------|

## Ключевые решения

## Следующий шаг

EOF
    echo "ORZ scaffold создан: $ORZ_FILE"
  fi
  # open-sessions.log
  printf "%s | %s | %s | %s\n" "$(date '+%Y-%m-%d %H:%M')" "$WP" "$AGENT" "${TASK:-standalone}" >> "$OPEN_LOG"
  # agent status (fail-safe)
  if [ -x "$AGENT_STATUS_SCRIPT" ]; then
    "$AGENT_STATUS_SCRIPT" --session-id "$SESSION_ID" --personality "$PERSONALITY" \
      "$AGENT" working "${WP}: ${TASK:-standalone}" "${FILES:-}" 2>/dev/null || true
  fi
  echo "Session OPEN: $SEM_FILE (WP: $WP, agent: $AGENT, slug: ${SLUG:-$WP})"
  exit 0
fi

# --- HEARTBEAT ---
# Exact-id only and no shell redirection: a delayed heartbeat can neither jump
# to a newer pointer nor recreate `.open` after close.  The caller PID must be
# a live ancestor of this guard process, which catches stale/replayed command
# shapes without pretending that a PID is an authentication credential.
if [ "$CMD" = "heartbeat" ]; then
  [ -n "$AGENT" ] || fail "heartbeat требует --agent" 1
  _safe_session_token "$AGENT" || fail "heartbeat: небезопасный --agent '$AGENT'" 1
  [ -n "$SESSION_ID_ARG" ] || fail "heartbeat требует --session-id" 1
  _safe_session_token "$SESSION_ID_ARG" || fail "heartbeat: небезопасный --session-id '$SESSION_ID_ARG'" 1
  if [ -n "${IWE_SESSION_TRANSITION_FD:-}" ]; then
    [ "${IWE_HEARTBEAT_OWNER_VALIDATED:-}" = "$OWNER_PID" ] \
      || fail "heartbeat: owner proof не пережил lock re-entry" 1
  else
    _owner_pid_is_live_ancestor "$OWNER_PID" \
      || fail "heartbeat: --owner-pid должен быть живым процессом-предком" 1
    # The Python lock wrapper adds one process hop before exec. Preserve the
    # already-checked call shape across that re-entry rather than depending on
    # `ps`, which is unavailable in some sandboxed installations.
    export IWE_HEARTBEAT_OWNER_VALIDATED="$OWNER_PID"
  fi
  [ "${#POSITIONAL[@]}" -eq 0 ] || fail "heartbeat не принимает позиционные аргументы" 1
  [ -z "$WP$TASK$FILES$SLUG$HOUSEKEEPING$PERSONALITY$FORCE_NO_REFLECTION$CLOSE_PATH" ] \
    || fail "heartbeat принимает только --agent/--session-id/--owner-pid" 1

  SEM_FILE="$SESSION_DIR/${AGENT}-${SESSION_ID_ARG}.open"
  [ -f "$SEM_FILE" ] || fail "heartbeat: exact сессия ${AGENT}-${SESSION_ID_ARG} не открыта" 3
  _ensure_session_transition_lock "$SEM_FILE" "$SESSION_ID_ARG"
  _locked_open_identity "$SEM_FILE" "$AGENT" "$SESSION_ID_ARG" 0 \
    || fail "heartbeat: open-семафор не прошёл exact identity/no-terminal проверку" 1
  _atomic_append_open "$SEM_FILE" "$AGENT" "$SESSION_ID_ARG" heartbeat \
    "heartbeat_at: $(now_iso)" "heartbeat_pid: $OWNER_PID" \
    || fail "heartbeat: атомарная запись отклонена; сессия могла начать close" 1
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
    echo "  ❌ ORZ-файл не найден: $orz" >&2
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
        echo "  ❌ в frontmatter отсутствует ключ '$key'" >&2
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
      echo "  ❌ agent в ORZ ('$orz_agent') не совпадает с агентом сессии ('$agent')" >&2
      errors=$((errors + 1))
    fi
  fi

  # 4. required sections
  local sections=("## Главный инсайт" "## Контекст" "## Достигнуто" "## Ключевые решения")
  for sec in "${sections[@]}"; do
    case "$content" in
      *"$sec"*) : ;;
      *)
        echo "  ❌ отсутствует секция '$sec'" >&2
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
      echo "  ✓ ORZ-файл не в git index, но побайтно совпадает с опубликованным blob в '$published_ref' — принят как эквивалент" >&2
    else
      echo "  ❌ ORZ-файл не добавлен в git index (git add $rel) и не совпадает ни с одним blob в refs/remotes/*" >&2
      errors=$((errors + 1))
    fi
  fi

  return $errors
}

# --- CLOSE ---
if [ "$CMD" = "close" ]; then
  [ "${#POSITIONAL[@]}" -eq 0 ] || fail "close не принимает позиционные аргументы" 1
  _safe_session_token "$AGENT" || fail "close: небезопасный --agent '$AGENT'" 1
  if [ -n "$HOUSEKEEPING" ]; then
    _safe_session_token "$HOUSEKEEPING" || fail "close --housekeeping: причина должна быть безопасным slug" 1
    HK_FILE="$SESSION_DIR/${AGENT}-housekeeping-${HOUSEKEEPING}.open"
    HK_SESSION_ID="housekeeping-${HOUSEKEEPING}"
    if [ ! -f "$HK_FILE" ]; then
      fail "close --housekeeping: нет активной housekeeping-сессии '${HOUSEKEEPING}' для $AGENT" 3
    fi
    _ensure_session_transition_lock "$HK_FILE" "$HK_SESSION_ID"
    _locked_open_identity "$HK_FILE" "$AGENT" "$HK_SESSION_ID" 1 \
      || fail "close --housekeeping: exact identity/terminal state не прошли проверку" 1
    HK_CLOSE_ATTEMPT=$(_atomic_append_open "$HK_FILE" "$AGENT" "$HK_SESSION_ID" \
      close-stage "$(now_iso)") \
      || fail "close --housekeeping: не удалось подготовить durable receipt" 1
    [ -n "$HK_CLOSE_ATTEMPT" ] \
      || fail "close --housekeeping: durable receipt не вернул attempt id" 1
    _terminal_close_no_clobber "$HK_FILE" "$AGENT" "$HK_SESSION_ID" "$HK_CLOSE_ATTEMPT" \
      || fail "close --housekeeping: terminal destination занят другим inode; open сохранён" 1
    rm -f "${HK_FILE}.lease"
    echo "Housekeeping CLOSE: ${HOUSEKEEPING} ✅"
    exit 0
  fi

  if [ -n "$SESSION_ID_ARG" ]; then
    _safe_session_token "$SESSION_ID_ARG" || fail "close: небезопасный --session-id '$SESSION_ID_ARG'" 1
    EXACT_OPEN="$SESSION_DIR/${AGENT}-${SESSION_ID_ARG}.open"
    EXACT_CLOSED="$EXACT_OPEN.closed"
    if [ ! -e "$EXACT_OPEN" ] && [ -f "$EXACT_CLOSED" ]; then
      _ensure_session_transition_lock "$EXACT_OPEN" "$SESSION_ID_ARG"
      _closed_receipt_identity "$EXACT_CLOSED" "$AGENT" "$SESSION_ID_ARG" \
        || fail "close: existing .closed не является доверенным durable receipt этой exact сессии" 1
      CLOSED_WP=$(grep '^wp: ' "$EXACT_CLOSED" | cut -d' ' -f2- || true)
      CLOSED_SLUG=$(grep '^slug: ' "$EXACT_CLOSED" | cut -d' ' -f2- || true)
      [ -z "$WP" ] || [ "$WP" = "$CLOSED_WP" ] \
        || fail "close: durable receipt относится к wp='$CLOSED_WP', а передан --wp='$WP'" 1
      [ -z "$SLUG" ] || [ "$SLUG" = "$CLOSED_SLUG" ] \
        || fail "close: durable receipt относится к slug='$CLOSED_SLUG', а передан --slug='$SLUG'" 1
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
      echo "Session CLOSE: ${CLOSED_WP:-unknown} — durable receipt уже terminal; проекции сверены ✅"
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
    fail "close без open: семафор не найден для $AGENT. Сначала session-guard.sh open --wp WP-N" 3
  fi
  SESSION_ID_FROM_NAME="${SEM_FILE#"$SESSION_DIR/${AGENT}-"}"
  SESSION_ID_FROM_NAME="${SESSION_ID_FROM_NAME%.open}"
  _safe_session_token "$SESSION_ID_FROM_NAME" \
    || fail "close: имя семафора не содержит безопасный exact session_id" 1
  _ensure_session_transition_lock "$SEM_FILE" "$SESSION_ID_FROM_NAME"
  _locked_open_identity "$SEM_FILE" "$AGENT" "$SESSION_ID_FROM_NAME" 1 \
    || fail "close: open-семафор не прошёл exact identity/no-clobber проверку" 1

  WP_FROM_SEM=$(grep "^wp: " "$SEM_FILE" | cut -d' ' -f2- || true)
  WP="${WP:-$WP_FROM_SEM}"
  SLUG_FROM_SEM=$(grep "^slug: " "$SEM_FILE" | cut -d' ' -f2- || true)
  SLUG="${SLUG:-$SLUG_FROM_SEM}"
  TASK_FROM_SEM=$(grep "^task: " "$SEM_FILE" | cut -d' ' -f2- || true)
  TASK="${TASK:-$TASK_FROM_SEM}"
  SESSION_ID=$(grep "^session_id: " "$SEM_FILE" | cut -d' ' -f2- || echo "unknown")
  [ "$SESSION_ID" = "$SESSION_ID_FROM_NAME" ] \
    || fail "close: session_id внутри семафора не совпадает с exact именем" 1
  PERSONALITY_FROM_SEM=$(grep "^personality: " "$SEM_FILE" | cut -d' ' -f2- || true)
  PERSONALITY_FROM_SEM="${PERSONALITY_FROM_SEM:-unassigned}"

  ORZ_BASENAME=$(grep "^orz_file: " "$SEM_FILE" | cut -d' ' -f2- || true)
  if [ -z "$ORZ_BASENAME" ]; then
    # Fallback для старых семафоров без поля orz_file
    OPENED_DATE=$(grep "^opened_at: " "$SEM_FILE" | cut -d' ' -f2- | cut -dT -f1 || true)
    OPENED_DATE="${OPENED_DATE:-$(now_date)}"
    ORZ_BASENAME="${OPENED_DATE:0:7}/${OPENED_DATE}-${SLUG:-$WP}.md"
  fi
  # WP-526 Ф2 (29.08): must resolve the same way `open` did, or `close` looks
  # for the ORZ file at the passive legacy default while `open` actually
  # wrote it under MC-sessions -- validate_orz below would then fail on an
  # existing, correctly-written file. This semaphore has no orz_sessions_dir
  # field (root's more evolved variant does) to read the resolved dir back
  # from, but the resolver is a pure function of current filesystem state,
  # so recomputing it here agrees with what `open` computed moments earlier.
  ORZ_DIR="$(resolve_orz_sessions_dir)"
  ORZ_FILE="$ORZ_DIR/$ORZ_BASENAME"

  echo "Session CLOSE: проверяю ORZ $ORZ_FILE ..."
  if ! validate_orz "$ORZ_FILE" "$AGENT"; then
    fail "ORZ не прошёл валидацию. Исправь замечания выше и повтори close. Семафор остаётся активным." 5
  fi

  # issue #356: карта раннера — capability-aware гейт. У свежей пользовательской
  # установки шаблона может не быть process-runner.py/quick-close.yaml вовсе —
  # тогда Quick Close продолжается вручную (runner_check=not_applicable), видимо
  # для пилота, а не блокируется навсегда несуществующим раннером. Проверка
  # потерялась при доставке авторской копии 09-11.08 (у автора раннер есть всегда)
  # — восстановлена в WP-7 Ф71, сторожится тестом T22.
  RUNNER_BIN="$IWE_ROOT/$GOV_REPO/scripts/process-runner.py"
  RUNNER_GRAPH="$IWE_ROOT/$GOV_REPO/scripts/processes/quick-close.yaml"
  if [ ! -f "$RUNNER_BIN" ] || [ ! -f "$RUNNER_GRAPH" ]; then
    echo "Session CLOSE: runner_check=not_applicable — process-runner не установлен, ручной Quick Close"
  else
  # Quick Close — не текстовая декларация: именно терминальная карточка раннера
  # доказывает, что эта сессия прошла обязательный процесс. Сопоставление по slug
  # не даёт чужой параллельной карточке закрыть текущую сессию.
  RUNNER_CARD="$IWE_ROOT/$GOV_REPO/inbox/agent/tasks/RUN-quick-close-${SLUG}"'*.md'
  RUNNER_OK=""
  for card in $RUNNER_CARD; do
    [ -f "$card" ] || continue
    grep -q '^process_id: quick-close$' "$card" || continue
    grep -q '^status: completed$' "$card" || continue
    RUNNER_OK="$card"
    break
  done

  # WP-484 Ф118 / WP-530 Ф18 (порт из авторского source, 30.08.2026): сессия,
  # открытая с "open --close-path peer-session", по определению никогда не
  # создаёт RUN-quick-close-*.md — её протокол закрытия (DP.SC.154 Шаг
  # 4.5.1/4.5.2) прямой git commit, не раннер. Без этого обхода close требовал
  # у пир-сессии карточку чужого ритуала (живой отказ 30.08). close_path
  # записан этим же скриптом при open — достаточное свидетельство.
  # ${SEM_FILE:-}: T22 sources this window standalone under set -u with no
  # semaphore stub; empty path -> grep fails -> bypass correctly not taken.
  if [ -z "$RUNNER_OK" ] && grep -q '^close_path: peer-session$' "${SEM_FILE:-}" 2>/dev/null; then
    RUNNER_OK="declared-peer-session:$SLUG"
    # WP-484 Ф133 (порт из авторского source, найдено 04.09.2026, пир-сессия
    # 2026-09-04-23-wp561-peer-session-closed-ledger-gap): без FORCED_CARD
    # блок ledger session_closed_direct ниже не срабатывает для этой ветки —
    # пир-сессии молча оставались без записи о закрытии в дневном журнале.
    FORCED_CARD="declared-peer-session:$SLUG"
    echo "Session CLOSE: close_path=peer-session объявлен при open — раннер не требуется (WP-484 Ф118)." >&2
  fi

  # --force-no-reflection (WP-484, 08.08, пилот): рефлексия про настроение дня
  # блокирует close, даже когда содержательная работа (commit+push) уже
  # подтверждена картой раннера — живой разбор показал, что вопрос рефлексии
  # часто рендерится ПОСЛЕ команды «закрывай», пилот её физически не видит.
  # Bypass узкий и предметный, не общий «пропусти карту раннера»: требует
  # ИМЕННО блокировку на этом шаге и подтверждённый push — другой сбой раннера
  # (упавший push, отменённый до commit-push прогон) этим флагом не спрятать.
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
      fail "force-no-reflection: не нашёл RUN-quick-close-${SLUG}*.md с current_step=blocked-witness-unavailable и all_pushed=true — этот флаг обходит только эту конкретную блокировку, не любой сбой раннера." 7
    fi
    FORCE_EVENT=$(python3 -c '
import json, sys
print(json.dumps({"wp": sys.argv[1], "slug": sys.argv[2], "agent": sys.argv[3], "card": sys.argv[4], "reason": sys.argv[5]}))
' "$WP" "$SLUG" "$AGENT" "$FORCED_CARD" "$FORCE_NO_REFLECTION")
    echo "force-no-reflection: доказательство принято ($FORCED_CARD); ledger будет обновлён после terminal transition" >&2
  fi

  if [ -z "$RUNNER_OK" ]; then
    fail "Quick Close не завершён для slug '$SLUG': нет terminal RUN-quick-close-${SLUG}*.md. Сначала запусти process-runner.py start quick-close с тем же --slug." 7
  fi
  fi

  # Authoritative transition first.  A complete, fsync'd `.closed` receipt is
  # published with hard-link no-clobber semantics before status, pointer,
  # lease, warnings or ledger projections.  If the process dies between link
  # and unlink, retry recognizes the same inode and completes the unlink.
  CLOSE_ATTEMPT=$(_atomic_append_open "$SEM_FILE" "$AGENT" "$SESSION_ID" \
    close-stage "$(now_iso)") \
    || fail "close: не удалось подготовить durable receipt; open сохранён" 1
  [ -n "$CLOSE_ATTEMPT" ] \
    || fail "close: durable receipt не вернул attempt id; open сохранён" 1
  _terminal_close_no_clobber "$SEM_FILE" "$AGENT" "$SESSION_ID" "$CLOSE_ATTEMPT" \
    || fail "close: terminal destination занят другим inode; open не удалён" 1
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
        || echo "  ⚠️  ledger session_closed_no_reflection не записан (terminal receipt уже durable)" >&2
    else
      echo "  ⚠️  ledger-append.sh отсутствует; причина force-close сохранена только вызывающей стороной" >&2
    fi
  fi

  # Warn if local commits are not pushed in repos touched by this session
  _warn_unpushed() {
    local repo="$1"
    local ahead
    ahead=$(git -C "$repo" rev-list --left-only --count HEAD...origin/main 2>/dev/null || echo "")
    if [ -n "$ahead" ] && [ "$ahead" -gt 0 ]; then
      echo "⚠️  $ahead незапушенных коммита в $(basename "$repo"). Выполни: git -C $repo push" >&2
    fi
  }
  # Always check the ORZ repo (governance repo, $GOV_REPO)
  _warn_unpushed "$ORZ_DIR"
  # Also check repos inferred from file: entries in the semaphore
  # Семафор к этому моменту уже опубликован как durable .closed receipt.
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

  # Best-effort атрибуция ТОЛЬКО для закрытий, обошедших process-runner.py
  # (порт из авторского source, WP-484 Ф133 — найдено 04.09.2026, пир-сессия
  # 2026-09-04-23-wp561-peer-session-closed-ledger-gap: этот блок в FMT-копии
  # отсутствовал вовсе, из-за чего пир-сессии молча не попадали в дневной
  # журнал). FORCED_CARD непустой на bypass-путях выше (peer-session,
  # force-no-reflection). Условие обязательно: без него событие писалось бы и
  # для нормального завершённого раннера, задваивая r23_verdict тем же
  # смыслом под другим именем. Никогда не проваливает close.
  if [ -n "${FORCED_CARD:-}" ] && [ -f "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" ]; then
    _cp_from_sem=$(grep "^close_path: " "$_sem_read" 2>/dev/null | cut -d' ' -f2- || echo "unknown")
    _direct_event=$(python3 -c '
import json, sys
print(json.dumps({"wp": sys.argv[1], "slug": sys.argv[2], "agent": sys.argv[3], "close_path": sys.argv[4]}))
' "$WP" "$SLUG" "$AGENT" "$_cp_from_sem" 2>/dev/null) || _direct_event=""
    if [ -n "$_direct_event" ]; then
      bash "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" day "$(now_date)" session_closed_direct "$_direct_event" session-guard \
        >/dev/null 2>&1 || echo "  ⚠️  ledger session_closed_direct не записан (best-effort, не блокирует close)" >&2
    fi
  fi

  exit 0
fi

# --- NOTE-FILE (manual scope registration for Bash-created/deleted files) ---
if [ "$CMD" = "note-file" ]; then
  FILE_PATH="${POSITIONAL[0]:-}"
  [ -z "$FILE_PATH" ] && fail "note-file: missing path argument" 1
  [ "${#POSITIONAL[@]}" -eq 1 ] || fail "note-file: ожидается ровно один path argument" 1
  NOTE_AGENT="${AGENT:-${IWE_AGENT:-claude-code}}"
  _safe_session_token "$NOTE_AGENT" || fail "note-file: небезопасный --agent '$NOTE_AGENT'" 1
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
    fail "note-file: нет открытой сессии для агента '$NOTE_AGENT'. Для разовой операции открой housekeeping-сессию:\n  session-guard.sh open --housekeeping note-file --agent $NOTE_AGENT\n  session-guard.sh note-file <path> --agent $NOTE_AGENT\n  session-guard.sh close --housekeeping note-file --agent $NOTE_AGENT" 1
  fi
  NOTE_SESSION_ID="${SEM_FILE#"$SESSION_DIR/${NOTE_AGENT}-"}"
  NOTE_SESSION_ID="${NOTE_SESSION_ID%.open}"
  _safe_session_token "$NOTE_SESSION_ID" \
    || fail "note-file: имя семафора не содержит безопасный exact session_id" 1
  _ensure_session_transition_lock "$SEM_FILE" "$NOTE_SESSION_ID"
  _locked_open_identity "$SEM_FILE" "$NOTE_AGENT" "$NOTE_SESSION_ID" 0 \
    || fail "note-file: open-семафор не прошёл exact identity/no-terminal проверку" 1
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
    *$'\n'*|*$'\r'*) fail "note-file: путь с переводом строки запрещён" 1 ;;
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
      echo "note-file: путь '$REL_PATH' нормализован до репо-относительного '$STRIPPED' (префикс имени репозитория отброшен)" >&2
      REL_PATH="$STRIPPED"
    elif [ "$STRIPPED" != "$REL_PATH" ]; then
      # Prefix textually matches the repo name but neither form exists yet —
      # overwhelmingly the prefix mistake, not a self-named future subdir.
      echo "note-file: WARNING — '$REL_PATH' начинается с имени репозитория '$REPO_NAME/'; записываю без префикса как '$STRIPPED' (scope gate сравнивает репо-относительные пути)" >&2
      REL_PATH="$STRIPPED"
    else
      echo "note-file: WARNING — '$REL_PATH' пока не существует в репо '$REPO_NAME' (ни на диске, ни в индексе, ни в HEAD); записан как будущий файл. Если это опечатка — scope gate не пропустит staged-файл." >&2
    fi
  fi
  # A directory is registered as a directory (QUICKCLOSE-GAPS1 п.2): the trailing
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
    || fail "note-file: атомарная запись отклонена; сессия могла начать close" 1
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
# (its own header: "единый gate ... для всех агентов"), so a lock here is the
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
# --- RENEW (WP-484 Ф49) ---
# Продлевает право семафора разрешать коммит. Отдельная команда, а не побочный
# эффект note-file: продление — намеренный сигнал «сессия жива», и связано оно
# с конкретным семафором через имя файла аренды, чтобы активность одной сессии
# не продлевала соседнюю.
if [ "$CMD" = "renew" ]; then
  [ "${#POSITIONAL[@]}" -eq 0 ] || fail "renew не принимает позиционные аргументы" 1
  RENEW_AGENT="${AGENT:-${IWE_AGENT:-claude-code}}"
  _safe_session_token "$RENEW_AGENT" || fail "renew: небезопасный --agent '$RENEW_AGENT'" 1
  if [ -n "$SESSION_ID_ARG" ]; then
    SEM_FILE=$(resolve_semaphore_by_session_id "$RENEW_AGENT" "$SESSION_ID_ARG" "${WP:-}" "${SLUG:-}") && SG_RC=0 || SG_RC=$?
    [ "$SG_RC" -eq 2 ] && exit 1
    [ "$SG_RC" -eq 0 ] || fail "renew: нет открытой сессии ${RENEW_AGENT}-${SESSION_ID_ARG}" 3
  else
    # Отказ при неоднозначности теперь живёт в самом select_semaphore (та же
    # находка Codex касалась и close/note-file), поэтому renew не держит своей
    # копии перебора — достаточно пробросить код возврата.
    SEM_FILE=$(select_semaphore "$RENEW_AGENT" "${WP:-}" "${SLUG:-}") && SG_RC=0 || SG_RC=$?
    [ "$SG_RC" -eq 2 ] && exit 1
    if [ "$SG_RC" -ne 0 ] || [ -z "$SEM_FILE" ] || [ ! -f "$SEM_FILE" ]; then
      fail "renew: нет открытой сессии для агента '$RENEW_AGENT' (уточни --wp/--slug/--session-id)" 3
    fi
  fi
  RENEW_SESSION_ID="${SEM_FILE#"$SESSION_DIR/${RENEW_AGENT}-"}"
  RENEW_SESSION_ID="${RENEW_SESSION_ID%.open}"
  _safe_session_token "$RENEW_SESSION_ID" \
    || fail "renew: имя семафора не содержит безопасный exact session_id" 1
  _ensure_session_transition_lock "$SEM_FILE" "$RENEW_SESSION_ID"
  _locked_open_identity "$SEM_FILE" "$RENEW_AGENT" "$RENEW_SESSION_ID" 0 \
    || fail "renew: open-семафор не прошёл exact identity/no-terminal проверку" 1
  LEASE_TMP="${SEM_FILE}.lease.tmp.$$"
  {
    echo "renewed_at: $(now_iso)"
    echo "session_id: $RENEW_SESSION_ID"
  } > "$LEASE_TMP"
  chmod 600 "$LEASE_TMP"
  # Параллельный close мог переименовать семафор, пока мы собирали аренду —
  # тогда публикация создала бы осиротевший .lease и отрапортовала о продлении
  # уже закрытой сессии (Codex, холодное ревью 04.08).
  if [ ! -f "$SEM_FILE" ]; then
    rm -f "$LEASE_TMP"
    fail "renew: сессия $(basename "$SEM_FILE") закрылась во время продления — продлевать нечего" 3
  fi
  # Замена целиком, а не дописывание: файл аренды всегда хранит одно значение,
  # поэтому у читателя нет выбора «первая или последняя запись».
  mv "$LEASE_TMP" "${SEM_FILE}.lease"
  echo "Lease RENEW: $(basename "$SEM_FILE") — права на коммит продлены на $((LEASE_SEC / 60)) мин"
  exit 0
fi

if [ "$CMD" = "audit" ]; then
  # WP-526 Ф2 fix (29.08, peer-session 2026-08-29-06-wp526-worktree-guard-continue):
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

  # 1. Активные семафоры (open без close)
  ACTIVE=$(find "$SESSION_DIR" -name "*.open" -type f 2>/dev/null)
  if [ -n "$ACTIVE" ]; then
    echo "⚠️ Активные сессии без close:"
    for f in $ACTIVE; do
      if lease_valid "$f"; then
        echo "  $(basename "$f")"
      else
        # WP-484 Ф49: просроченная аренда — не смерть сессии, а потеря права
        # разрешать коммит. Показываем отдельно, чтобы долг был виден человеку
        # в штатном ритме (Открытие дня читает этот же вывод), а не всплывал
        # внезапным блоком на коммите.
        echo "  $(basename "$f")  ⏳ права на коммит истекли (renew или close)"
      fi
      sed 's/^/    /' "$f"
    done
    echo
  fi

  # 2. Сессии в open-sessions.log без ORZ-файла
  if [ -f "$OPEN_LOG" ]; then
    echo "Сессии в open-sessions.log без ORZ (после $SINCE):"
    awk -v since="$SINCE" '
      $1 >= since {
        wp=$3; gsub(/\|/,"",wp); print $1, wp
      }
    ' "$OPEN_LOG" | sort -u | while read -r dt wp; do
      ORZ=$(ls "$ORZ_DIR/${dt:0:7}/$dt"-*"$wp"*.md 2>/dev/null | head -1 || true)
      if [ -z "$ORZ" ]; then
        echo "  $dt | $wp | ORZ отсутствует"
      fi
    done
    echo
  fi

  # 3. ORZ-файлы с невалидным frontmatter/секциями
  echo "ORZ-файлы с дефектами (после $SINCE):"
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

  # 4. Untracked ORZ-файлы
  echo "Незакоммиченные ORZ-файлы:"
  git -C "$ORZ_DIR" status --short . 2>/dev/null | grep '^??' || echo "  (нет)"
  echo

  # 5. Stale семафоры старше 7 дней
  echo "Stale-семафоры старше 7 дней:"
  find "$SESSION_DIR" -name "*.open" -type f -mtime +7 2>/dev/null | while read -r f; do
    echo "  $(basename "$f")"
  done

  echo "=== Audit done ==="
  exit 0
fi

# --- RECOVER-ORPHANED (WP-484 Ф49, contract designed 04.08 peer-session
# 2026-08-04-13-session-ttl-f47-draft, ход 1: Codex В4) ---
# Карантинный файл — уже честная терминальная запись места, где сессия
# застряла; переименование обратно в `.open` имитировало бы штатное
# закрытие, которого не было (явно запрещено в записи Ф49). recover-orphaned
# вместо этого пишет отдельное ledger-событие и метит файл — сам файл
# карантина остаётся на диске как есть, историю не переписываем.
if [ "$CMD" = "recover-orphaned" ]; then
  ORPHAN_ARG="${POSITIONAL[0]:-}"
  [ -z "$ORPHAN_ARG" ] && fail "recover-orphaned: missing path argument" 1
  case "$ORPHAN_ARG" in
    /*) ORPHAN_FILE="$ORPHAN_ARG" ;;
    *)  ORPHAN_FILE="$SESSION_DIR/$ORPHAN_ARG" ;;
  esac
  [ -f "$ORPHAN_FILE" ] || fail "recover-orphaned: файл не найден: $ORPHAN_FILE" 1
  # Review post-consensus (одноразовый verification-запрос Codex, 04.08): команда
  # принимала любой путь на диске с подходящим именем — не ослабляет Scope gate
  # (.recovered не даёт прав коммита), но лишняя способность переименовывать файлы
  # вне каталога семафоров. Канонизируем и запираем в $SESSION_DIR, отклоняем
  # symlink и повторный вызов на уже восстановленном файле.
  CANON_FILE=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$ORPHAN_FILE")
  CANON_DIR=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$SESSION_DIR")
  case "$CANON_FILE" in
    "$CANON_DIR"/*) : ;;
    *) fail "recover-orphaned: '$ORPHAN_FILE' вне каталога семафоров ($SESSION_DIR)" 1 ;;
  esac
  [ -L "$ORPHAN_FILE" ] && fail "recover-orphaned: '$ORPHAN_FILE' — символическая ссылка, не карантинный файл" 1
  case "$(basename "$CANON_FILE")" in
    *.recovered) fail "recover-orphaned: '$(basename "$CANON_FILE")' уже восстановлен" 1 ;;
    *.orphaned-*) : ;;
    *) fail "recover-orphaned: '$(basename "$CANON_FILE")' не похож на карантинный семафор (ожидается суффикс .orphaned-*)" 1 ;;
  esac
  REC_OPEN_KEY="${CANON_FILE%%.orphaned-*}"
  case "$REC_OPEN_KEY" in
    *.open) : ;;
    *) fail "recover-orphaned: не удалось восстановить canonical .open key" 1 ;;
  esac
  _ensure_session_transition_lock "$REC_OPEN_KEY" ""
  [ -f "$CANON_FILE" ] || fail "recover-orphaned: карантинный файл исчез под lock" 1
  ORPHAN_FILE="$CANON_FILE"
  grep -qE '^(agent|opened_at|session_id): ' "$ORPHAN_FILE" || \
    fail "recover-orphaned: '$(basename "$CANON_FILE")' не похож на семафор session-guard (нет полей agent:/opened_at:/session_id:)" 1

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
    || fail "recover-orphaned: destination .recovered уже принадлежит другому inode" 1
  if [ -f "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" ]; then
    bash "$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh" day "$(now_date)" \
      session_recovered_closed "$EVENT_JSON" session-guard >/dev/null 2>&1 \
      || echo "  ⚠️  ledger session_recovered_closed не записан (terminal state уже durable)" >&2
  else
    echo "  ⚠️  ledger-append.sh отсутствует (terminal state уже durable)" >&2
  fi

  echo "Recovered: $(basename "$ORPHAN_FILE") — файл помечен .recovered, session_recovered_closed записан в ledger ($REC_PATH, wp=${REC_WP:-unknown}, session_id=$REC_SID). Исходный карантинный файл НЕ возвращён в .open — это честная терминальная запись, не имитация штатного закрытия."
  exit 0
fi

# A registered directory covers everything under it (QUICKCLOSE-GAPS1 п.2, found
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
  # WP-484 Ф49: право разрешать коммит истекает по аренде и отзывается у ВСЕГО
  # набора файлов семафора сразу. Частичный отзыв (запретить только новые
  # `file:`) дыру WP-507 не закрывает: уже перечисленные пути продолжали бы
  # пропускать чужие правки, сделанные после того, как сессия фактически
  # прекратилась. Отсюда же исчезновение mtime-байпаса просроченного семафора —
  # чем он старше, тем больше посторонних файлов проходило «по свежести».
  # Граница механизма (осознанная, не недосмотр): срок проверяется один раз за
  # хук, поэтому коммит, начатый за мгновение до истечения аренды, пройдёт.
  # Повторная проверка перед выходом окно не закрывает — между концом хука и
  # записью объекта git время идёт в любом случае, — а выглядела бы как
  # гарантия атомарности. При сроке в 4 часа «просрочен на доли секунды» и
  # «действителен» описывают одно и то же состояние сессии.
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
      echo "🚫 SESSION-GUARD: коммит заблокирован — у открытых сессий истёк срок полномочий." >&2
      echo "" >&2
      for sem in $EXPIRED; do
        sem_wp=$(grep "^wp: " "$sem" | cut -d' ' -f2- || echo "?")
        echo "  · $(basename "$sem") (WP: $sem_wp)" >&2
      done
      echo "" >&2
      echo "Сессия по-прежнему существует и закрывается штатно. Выбери:" >&2
      echo "  продлить:  bash {{WORKSPACE_DIR}}/scripts/session-guard.sh renew --wp WP-N" >&2
      echo "  закрыть:   bash {{WORKSPACE_DIR}}/scripts/session-guard.sh close --wp WP-N" >&2
      exit 4
    fi
    cat >&2 <<'EOF'
🚫 SESSION-GUARD: коммит заблокирован.

Сессия не открыта по протоколу. Перед работой с файлами:
  bash {{WORKSPACE_DIR}}/scripts/session-guard.sh open --wp WP-N --task "..."

Или, если это emergency-фикс без РП:
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
        echo "🚫 BLOCK: $f удалён, но не числится в scope активных сессий" >&2
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
        echo "🚫 BLOCK: $f — новый файл вне scope активных сессий (нужен note-file, mtime не засчитывается)" >&2
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
      echo "🚫 BLOCK: $f не тронут в активных сессиях (mtime <= всех семафоров, нет в note-file)" >&2
      BLOCKED=1
    fi
  done < <(git -c core.quotepath=false diff --cached --name-status)

  if [ "$BLOCKED" -ne 0 ]; then
    echo "" >&2
    echo "Scope gate: staged-файлы вне текущих сессий." >&2
    echo "Если файл относится к сессии, добавь его вручную:" >&2
    echo "  bash {{WORKSPACE_DIR}}/scripts/session-guard.sh note-file <path>" >&2
    echo "Или убери из staged:" >&2
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

fail "Unknown command: $CMD (use: open, close, audit, renew, heartbeat, note-file, recover-orphaned, pre-commit-check)"
