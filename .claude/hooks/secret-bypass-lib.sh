#!/bin/bash
# Shared security primitives for secret hooks (WP-544 D6.4/D6.8).
# The library owns temporary bypass validation, durable audit writes and the
# canonical secret-pattern corpus used by both input blocking and output
# redaction. Pattern matches never leave the helper: callers receive only
# class identifiers, counts and already-redacted JSON.

SECRET_BYPASS_MAX_TTL=900
SECRET_BYPASS_STATE="absent"
SECRET_BYPASS_REASON=""
SECRET_BYPASS_REMAINING=0
SECRET_BYPASS_JQ=""
SECRET_BYPASS_PYTHON=""

for secret_bypass_candidate in /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq /bin/jq; do
  if [ -x "$secret_bypass_candidate" ]; then
    SECRET_BYPASS_JQ="$secret_bypass_candidate"
    break
  fi
done
# 2026-08-25: none of the hardcoded FHS paths above exist on NixOS hosts
# (tsekh-1) - jq and python3 live under /run/current-system/sw/bin there,
# not under /usr or /opt/homebrew. The hardcoded loop stayed as the fast
# common-case path; this PATH-based fallback covers NixOS and any other
# layout without hardcoding one more absolute path per host.
if [ -z "$SECRET_BYPASS_JQ" ]; then
  SECRET_BYPASS_JQ="$(command -v jq 2>/dev/null || true)"
fi
for secret_bypass_candidate in /usr/bin/python3 /usr/local/bin/python3 /opt/homebrew/bin/python3; do
  if [ -x "$secret_bypass_candidate" ]; then
    SECRET_BYPASS_PYTHON="$secret_bypass_candidate"
    break
  fi
done
if [ -z "$SECRET_BYPASS_PYTHON" ]; then
  SECRET_BYPASS_PYTHON="$(command -v python3 2>/dev/null || true)"
fi

secret_pattern_process() {
  # Modes read their payload from stdin. No mode prints a matched secret or
  # surrounding source text; detect/analyze return identifiers and lengths,
  # while redact-envelope returns only the transformed tool response.
  local mode="$1"
  [ -x "$SECRET_BYPASS_PYTHON" ] || return 1
  # issue #832: the analyzer used to be a single-quoted inline Python program
  # passed via -c (about 2125 lines, 87KB) -- Windows CreateProcess caps the
  # whole command line at roughly 32767 characters, so every invocation
  # there failed with E2BIG (silently, since this hook redirects stderr)
  # while macOS/Linuxs much higher per-argument limits hid the same defect.
  # The program source now lives in its own file and is passed as a script
  # argument instead of inline text -- no argv-length exposure regardless of
  # size, and the quote-fragility hazard the removed comment above warned
  # about (one stray apostrophe anywhere in ~2000 lines breaking every tool
  # call in the session) is gone with it.
  local analyzer_dir
  analyzer_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local analyzer="$analyzer_dir/secret-bypass-analyzer.py"
  [ -r "$analyzer" ] || return 1
  "$SECRET_BYPASS_PYTHON" "$analyzer" "$mode"
}

secret_bypass_check() {
  local scope="$1" flag_name until_name flag until now remaining

  case "$scope" in
    INPUT|OUTPUT) ;;
    *)
      SECRET_BYPASS_STATE="rejected"
      SECRET_BYPASS_REASON="unknown scope"
      return 2
      ;;
  esac

  flag_name="CC_ALLOW_SECRETS_${scope}"
  until_name="${flag_name}_UNTIL"
  flag="${!flag_name:-}"
  until="${!until_name:-}"
  SECRET_BYPASS_STATE="absent"
  SECRET_BYPASS_REASON=""
  SECRET_BYPASS_REMAINING=0

  if [ -z "$flag" ] && [ -z "$until" ]; then
    return 1
  fi
  if [ "$flag" != "1" ]; then
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="${flag_name} must equal 1"
    return 2
  fi
  case "$until" in
    ''|*[!0-9]*)
      SECRET_BYPASS_STATE="rejected"
      SECRET_BYPASS_REASON="${until_name} must be a Unix timestamp"
      return 2
      ;;
  esac
  if [ "${#until}" -gt 10 ]; then
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="${until_name} is outside the supported timestamp range"
    return 2
  fi

  now=$(date +%s)
  case "$now" in
    ''|*[!0-9]*)
      SECRET_BYPASS_STATE="rejected"
      SECRET_BYPASS_REASON="current time is unavailable"
      return 2
      ;;
  esac
  until=$((10#$until))
  now=$((10#$now))
  remaining=$((until - now))
  if [ "$remaining" -le 0 ]; then
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="temporary override expired"
    return 2
  fi
  if [ "$remaining" -gt "$SECRET_BYPASS_MAX_TTL" ]; then
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="temporary override exceeds ${SECRET_BYPASS_MAX_TTL}s"
    return 2
  fi

  SECRET_BYPASS_STATE="active"
  SECRET_BYPASS_REMAINING="$remaining"
  return 0
}

secret_path_bypass_check() {
  # A one-file override needs three independent fields. Target and allow value
  # must be the same absolute normalized spelling of one existing user-owned
  # regular file. Component-wise O_NOFOLLOW pins validation to descriptors;
  # symlinks, hard links, relative paths and realpath fallbacks are rejected.
  local target="$1" flag allow_file until now remaining
  flag="${CC_ALLOW_SECRET_PATH:-}"
  allow_file="${CC_ALLOW_SECRET_PATH_FILE:-}"
  until="${CC_ALLOW_SECRET_PATH_UNTIL:-}"
  SECRET_BYPASS_STATE="absent"
  SECRET_BYPASS_REASON=""
  SECRET_BYPASS_REMAINING=0

  if [ -z "$flag" ] && [ -z "$allow_file" ] && [ -z "$until" ]; then
    return 1
  fi
  if [ "$flag" != "1" ]; then
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="CC_ALLOW_SECRET_PATH must equal 1"
    return 2
  fi
  case "$until" in
    ''|*[!0-9]*)
      SECRET_BYPASS_STATE="rejected"
      SECRET_BYPASS_REASON="CC_ALLOW_SECRET_PATH_UNTIL must be a Unix timestamp"
      return 2
      ;;
  esac
  if [ "${#until}" -gt 10 ]; then
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="CC_ALLOW_SECRET_PATH_UNTIL is outside the supported timestamp range"
    return 2
  fi
  now=$(date +%s)
  case "$now" in
    ''|*[!0-9]*)
      SECRET_BYPASS_STATE="rejected"
      SECRET_BYPASS_REASON="current time is unavailable"
      return 2
      ;;
  esac
  until=$((10#$until))
  now=$((10#$now))
  remaining=$((until - now))
  if [ "$remaining" -le 0 ]; then
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="temporary one-file override expired"
    return 2
  fi
  if [ "$remaining" -gt "$SECRET_BYPASS_MAX_TTL" ]; then
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="temporary one-file override exceeds ${SECRET_BYPASS_MAX_TTL}s"
    return 2
  fi
  [ -x "$SECRET_BYPASS_PYTHON" ] || {
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="canonical path validator unavailable"
    return 2
  }
  if ! "$SECRET_BYPASS_PYTHON" -c '
import os
import stat
import sys

target, allowed = sys.argv[1:3]
if target != allowed:
    raise SystemExit(1)
if not os.path.isabs(target) or os.path.normpath(target) != target:
    raise SystemExit(1)
if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY"):
    raise SystemExit(1)

parent, name = os.path.split(target)
if not name or name in (".", ".."):
    raise SystemExit(1)
dir_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
dir_flags |= getattr(os, "O_CLOEXEC", 0)
file_flags = os.O_RDONLY | os.O_NOFOLLOW
file_flags |= getattr(os, "O_CLOEXEC", 0)
parent_fd = -1
file_fd = -1
try:
    parent_fd = os.open("/", dir_flags)
    for component in (part for part in parent.split(os.sep) if part):
        next_fd = os.open(component, dir_flags, dir_fd=parent_fd)
        os.close(parent_fd)
        parent_fd = next_fd
    file_fd = os.open(name, file_flags, dir_fd=parent_fd)
    info = os.fstat(file_fd)
    entry = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_nlink != 1
        or not stat.S_ISREG(entry.st_mode)
        or entry.st_dev != info.st_dev
        or entry.st_ino != info.st_ino
    ):
        raise OSError("unsafe one-file override")
except (OSError, OverflowError, UnicodeError):
    raise SystemExit(1)
finally:
    if file_fd >= 0:
        os.close(file_fd)
    if parent_fd >= 0:
        os.close(parent_fd)
' "$target" "$allow_file" 2>/dev/null; then
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="target and CC_ALLOW_SECRET_PATH_FILE must name the same canonical existing regular file"
    return 2
  fi

  SECRET_BYPASS_STATE="active"
  SECRET_BYPASS_REMAINING="$remaining"
  return 0
}

secret_bypass_active_message() {
  printf 'Temporary secret %s bypass is active for %ss more.' \
    "$1" "$SECRET_BYPASS_REMAINING"
}

secret_bypass_rejected_message() {
  printf 'Requested secret %s bypass was rejected: %s. Protection remains active.' \
    "$1" "$SECRET_BYPASS_REASON"
}

secret_bypass_audit_append() {
  # Keep path resolution, validation, append, verification and fsync on pinned
  # descriptors. Component-wise O_NOFOLLOW prevents a parent symlink from
  # redirecting the audit between shell-level checks and the write.
  local log_file="$1" record="$2"
  [ -x "$SECRET_BYPASS_PYTHON" ] || return 1
  if ! printf '%s' "$record" | "$SECRET_BYPASS_PYTHON" -c '
import fcntl
import json
import os
import stat
import sys

raw = sys.stdin.read()
if "\n" in raw or "\r" in raw:
    raise SystemExit(1)
try:
    value = json.loads(raw)
except (TypeError, ValueError):
    raise SystemExit(1)
if not isinstance(value, dict) or not isinstance(value.get("hook"), str):
    raise SystemExit(1)
decision = value.get("decision", value.get("action"))
if not isinstance(decision, str) or not decision:
    raise SystemExit(1)

log_file = sys.argv[1]
if not os.path.isabs(log_file) or os.path.normpath(log_file) != log_file:
    raise SystemExit(1)
parent, name = os.path.split(log_file)
if not name or name in (".", ".."):
    raise SystemExit(1)
if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY"):
    raise SystemExit(1)

dir_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
dir_flags |= getattr(os, "O_CLOEXEC", 0)
file_flags = os.O_RDWR | os.O_APPEND | os.O_NOFOLLOW
file_flags |= getattr(os, "O_CLOEXEC", 0)
payload = (raw + "\n").encode("utf-8")
parent_fd = -1
file_fd = -1

def secure_regular(info):
    return (
        stat.S_ISREG(info.st_mode)
        and info.st_uid == os.geteuid()
        and info.st_nlink == 1
    )

try:
    parent_fd = os.open("/", dir_flags)
    for component in (part for part in parent.split(os.sep) if part):
        next_fd = os.open(component, dir_flags, dir_fd=parent_fd)
        os.close(parent_fd)
        parent_fd = next_fd

    parent_info = os.fstat(parent_fd)
    if (
        not stat.S_ISDIR(parent_info.st_mode)
        or parent_info.st_uid != os.geteuid()
        or stat.S_IMODE(parent_info.st_mode) & 0o022
    ):
        raise OSError("unsafe audit directory")

    created = False
    try:
        file_fd = os.open(
            name,
            file_flags | os.O_CREAT | os.O_EXCL,
            0o600,
            dir_fd=parent_fd,
        )
        created = True
    except FileExistsError:
        file_fd = os.open(name, file_flags, dir_fd=parent_fd)

    fcntl.flock(file_fd, fcntl.LOCK_EX)
    before_info = os.fstat(file_fd)
    if not secure_regular(before_info):
        raise OSError("unsafe audit file")
    os.fchmod(file_fd, 0o600)
    before_info = os.fstat(file_fd)
    if not secure_regular(before_info) or stat.S_IMODE(before_info.st_mode) != 0o600:
        raise OSError("audit permissions unavailable")

    before = before_info.st_size
    if before:
        os.lseek(file_fd, before - 1, os.SEEK_SET)
        if os.read(file_fd, 1) != b"\n":
            raise OSError("truncated audit log")

    written = 0
    while written < len(payload):
        count = os.write(file_fd, payload[written:])
        if count <= 0:
            raise OSError("short audit write")
        written += count
    os.fsync(file_fd)

    after_info = os.fstat(file_fd)
    if (
        not secure_regular(after_info)
        or after_info.st_dev != before_info.st_dev
        or after_info.st_ino != before_info.st_ino
        or after_info.st_size != before + len(payload)
    ):
        raise OSError("audit file changed during append")
    os.lseek(file_fd, before, os.SEEK_SET)
    if os.read(file_fd, len(payload)) != payload:
        raise OSError("audit verification failed")

    entry_info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if (
        not secure_regular(entry_info)
        or entry_info.st_dev != after_info.st_dev
        or entry_info.st_ino != after_info.st_ino
        or stat.S_IMODE(entry_info.st_mode) != 0o600
    ):
        raise OSError("audit pathname changed during append")
    if created:
        os.fsync(parent_fd)
except (OSError, OverflowError, UnicodeError):
    raise SystemExit(1)
finally:
    if file_fd >= 0:
        os.close(file_fd)
    if parent_fd >= 0:
        os.close(parent_fd)
' "$log_file" 2>/dev/null; then
    return 1
  fi
}

secret_bypass_emit_alert() {
  local notice="$1" alert_json
  [ -x "$SECRET_BYPASS_JQ" ] || return 1
  [ -x "$SECRET_BYPASS_PYTHON" ] || return 1
  # The jq program references jq variables, not shell variables.
  # shellcheck disable=SC2016
  if ! alert_json=$("$SECRET_BYPASS_JQ" -n --arg message "$notice" '{systemMessage:$message}') \
    || [ -z "$alert_json" ] \
    || ! printf '%s' "$alert_json" | "$SECRET_BYPASS_PYTHON" -c '
import json
import sys

expected = sys.argv[1]
value = json.load(sys.stdin)
if not isinstance(value, dict) or value.get("systemMessage") != expected:
    raise SystemExit(1)
' "$notice"; then
    return 1
  fi
  printf '%s\n' "$alert_json"
}

secret_bypass_authorize() {
  # The override becomes effective only after both durable audit and a visible
  # user alert succeed. A logging/alert failure keeps the protection active.
  local scope="$1" notice
  shift

  if [ "$SECRET_BYPASS_STATE" != "active" ]; then
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="temporary override was not validated"
    return 2
  fi
  if [ "$#" -eq 0 ] || ! "$@"; then
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="audit record unavailable"
    return 2
  fi
  notice=$(secret_bypass_active_message "$scope")
  if ! secret_bypass_emit_alert "$notice"; then
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="user alert unavailable"
    return 2
  fi
  return 0
}

secret_bypass_self_test() {
  local now failures=0 authorize_output audit_tmp audit_file audit_link audit_truncated saved_jq
  local audit_real_dir audit_parent_link audit_hard_source audit_hard_link
  local path_file path_link path_hard_link path_real_dir path_parent_link path_parent_file
  now=$(date +%s)

  if secret_pattern_process self-test </dev/null; then
    :
  else
    printf 'FAIL secret_pattern_process\n' >&2
    failures=$((failures + 1))
  fi

  run_case() {
    local name expected_rc expected_state actual_rc
    name="$1"
    expected_rc="$2"
    expected_state="$3"
    shift 3
    (
      unset CC_ALLOW_SECRETS_INPUT CC_ALLOW_SECRETS_INPUT_UNTIL
      eval "$*"
      secret_bypass_check INPUT
    )
    actual_rc=$?
    if [ "$actual_rc" -ne "$expected_rc" ]; then
      printf 'FAIL %s: rc=%s expected=%s\n' "$name" "$actual_rc" "$expected_rc" >&2
      failures=$((failures + 1))
      return
    fi

    unset CC_ALLOW_SECRETS_INPUT CC_ALLOW_SECRETS_INPUT_UNTIL
    eval "$*"
    secret_bypass_check INPUT >/dev/null 2>&1 || true
    if [ "$SECRET_BYPASS_STATE" != "$expected_state" ]; then
      printf 'FAIL %s: state=%s expected=%s\n' "$name" "$SECRET_BYPASS_STATE" "$expected_state" >&2
      failures=$((failures + 1))
    else
      printf 'PASS %s\n' "$name"
    fi
  }

  run_case absent 1 absent ':'
  run_case zero 2 rejected 'export CC_ALLOW_SECRETS_INPUT=0'
  run_case missing_expiry 2 rejected 'export CC_ALLOW_SECRETS_INPUT=1'
  run_case leading_zero 2 rejected 'export CC_ALLOW_SECRETS_INPUT=1 CC_ALLOW_SECRETS_INPUT_UNTIL=09'
  run_case expired 2 rejected "export CC_ALLOW_SECRETS_INPUT=1 CC_ALLOW_SECRETS_INPUT_UNTIL=$((now - 1))"
  run_case excessive 2 rejected "export CC_ALLOW_SECRETS_INPUT=1 CC_ALLOW_SECRETS_INPUT_UNTIL=$((now + SECRET_BYPASS_MAX_TTL + 60))"
  run_case valid 0 active "export CC_ALLOW_SECRETS_INPUT=1 CC_ALLOW_SECRETS_INPUT_UNTIL=$((now + 60))"

  secret_bypass_test_audit_ok() { return 0; }
  secret_bypass_test_audit_fail() { return 1; }

  SECRET_BYPASS_STATE="active"
  SECRET_BYPASS_REMAINING=60
  if authorize_output=$(secret_bypass_authorize INPUT secret_bypass_test_audit_ok) \
    && printf '%s' "$authorize_output" | jq -e '.systemMessage | length > 0' >/dev/null 2>&1; then
    printf 'PASS audited_authorization\n'
  else
    printf 'FAIL audited_authorization\n' >&2
    failures=$((failures + 1))
  fi

  SECRET_BYPASS_STATE="active"
  SECRET_BYPASS_REMAINING=60
  if secret_bypass_authorize INPUT secret_bypass_test_audit_fail >/dev/null 2>&1; then
    printf 'FAIL audit_failure_rejected\n' >&2
    failures=$((failures + 1))
  elif [ "$SECRET_BYPASS_STATE" = "rejected" ]; then
    printf 'PASS audit_failure_rejected\n'
  else
    printf 'FAIL audit_failure_rejected: state=%s\n' "$SECRET_BYPASS_STATE" >&2
    failures=$((failures + 1))
  fi

  saved_jq="$SECRET_BYPASS_JQ"
  SECRET_BYPASS_JQ="/usr/bin/true"
  SECRET_BYPASS_STATE="active"
  SECRET_BYPASS_REMAINING=60
  if secret_bypass_authorize INPUT secret_bypass_test_audit_ok >/dev/null 2>&1; then
    printf 'FAIL alert_failure_rejected\n' >&2
    failures=$((failures + 1))
  elif [ "$SECRET_BYPASS_STATE" = "rejected" ]; then
    printf 'PASS alert_failure_rejected\n'
  else
    printf 'FAIL alert_failure_rejected: state=%s\n' "$SECRET_BYPASS_STATE" >&2
    failures=$((failures + 1))
  fi
  SECRET_BYPASS_JQ="$saved_jq"

  audit_tmp=$(mktemp -d "${TMPDIR:-/tmp}/secret-bypass-audit.XXXXXX") || return 1
  audit_tmp=$(CDPATH='' cd -- "$audit_tmp" && pwd -P) || return 1
  audit_file="$audit_tmp/audit.jsonl"
  audit_link="$audit_tmp/audit-link.jsonl"
  audit_truncated="$audit_tmp/audit-truncated.jsonl"
  # Portable octal-permission read (docs/PLATFORM-COMPAT.md): `stat -f` is
  # BSD-only, `stat -c` is GNU-only — same Darwin/else split already used by
  # destructive-guard.sh's neighbour dry-run-gate.sh for the same field.
  # Called lazily inside the `&&` chain below (not hoisted above the `if`):
  # $audit_file does not exist until secret_bypass_audit_append creates it.
  portable_octal_perm() {
    case "$(uname -s)" in
      Darwin) stat -f '%Lp' "$1" 2>/dev/null ;;
      *)      stat -c '%a' "$1" 2>/dev/null ;;
    esac
  }
  if secret_bypass_audit_append "$audit_file" '{"hook":"self-test","decision":"test"}' \
    && [ "$(portable_octal_perm "$audit_file")" = "600" ] \
    && grep -q '"decision":"test"' "$audit_file"; then
    printf 'PASS durable_private_audit\n'
  else
    printf 'FAIL durable_private_audit\n' >&2
    failures=$((failures + 1))
  fi
  ln -s /dev/null "$audit_link"
  if secret_bypass_audit_append "$audit_link" '{"hook":"self-test","decision":"test"}'; then
    printf 'FAIL audit_symlink_rejected\n' >&2
    failures=$((failures + 1))
  else
    printf 'PASS audit_symlink_rejected\n'
  fi
  audit_real_dir="$audit_tmp/real-parent"
  audit_parent_link="$audit_tmp/parent-link"
  mkdir "$audit_real_dir"
  ln -s "$audit_real_dir" "$audit_parent_link"
  if secret_bypass_audit_append "$audit_parent_link/audit.jsonl" '{"hook":"self-test","decision":"test"}'; then
    printf 'FAIL audit_parent_symlink_rejected\n' >&2
    failures=$((failures + 1))
  else
    printf 'PASS audit_parent_symlink_rejected\n'
  fi
  audit_hard_source="$audit_tmp/audit-hard-source.jsonl"
  audit_hard_link="$audit_tmp/audit-hard-link.jsonl"
  printf '%s\n' '{"hook":"self-test","decision":"existing"}' > "$audit_hard_source"
  chmod 600 "$audit_hard_source"
  ln "$audit_hard_source" "$audit_hard_link"
  if secret_bypass_audit_append "$audit_hard_link" '{"hook":"self-test","decision":"test"}'; then
    printf 'FAIL audit_hardlink_rejected\n' >&2
    failures=$((failures + 1))
  else
    printf 'PASS audit_hardlink_rejected\n'
  fi
  printf 'x' > "$audit_truncated"
  chmod 600 "$audit_truncated"
  if secret_bypass_audit_append "$audit_truncated" '{"hook":"self-test","decision":"test"}'; then
    printf 'FAIL truncated_audit_rejected\n' >&2
    failures=$((failures + 1))
  else
    printf 'PASS truncated_audit_rejected\n'
  fi

  path_file="$audit_tmp/allowed.env"
  path_link="$audit_tmp/allowed-link.env"
  printf '%s\n' 'synthetic fixture' > "$path_file"
  chmod 600 "$path_file"
  ln -s "$path_file" "$path_link"

  export CC_ALLOW_SECRET_PATH=1
  export CC_ALLOW_SECRET_PATH_FILE="$path_file"
  export CC_ALLOW_SECRET_PATH_UNTIL=$((now + 60))
  if secret_path_bypass_check "$path_file" && [ "$SECRET_BYPASS_STATE" = "active" ]; then
    printf 'PASS path_bypass_canonical_file\n'
  else
    printf 'FAIL path_bypass_canonical_file\n' >&2
    failures=$((failures + 1))
  fi
  if secret_path_bypass_check "$path_link" >/dev/null 2>&1; then
    printf 'FAIL path_bypass_symlink_rejected\n' >&2
    failures=$((failures + 1))
  elif [ "$SECRET_BYPASS_STATE" = "rejected" ]; then
    printf 'PASS path_bypass_symlink_rejected\n'
  else
    printf 'FAIL path_bypass_symlink_rejected: state=%s\n' "$SECRET_BYPASS_STATE" >&2
    failures=$((failures + 1))
  fi

  path_hard_link="$audit_tmp/allowed-hard.env"
  ln "$path_file" "$path_hard_link"
  export CC_ALLOW_SECRET_PATH_FILE="$path_file"
  if secret_path_bypass_check "$path_file" >/dev/null 2>&1; then
    printf 'FAIL path_bypass_hardlink_rejected\n' >&2
    failures=$((failures + 1))
  else
    printf 'PASS path_bypass_hardlink_rejected\n'
  fi
  rm "$path_hard_link"

  path_real_dir="$audit_tmp/path-real"
  path_parent_link="$audit_tmp/path-parent-link"
  path_parent_file="$path_real_dir/linked.env"
  mkdir "$path_real_dir"
  printf '%s\n' 'synthetic fixture' > "$path_parent_file"
  chmod 600 "$path_parent_file"
  ln -s "$path_real_dir" "$path_parent_link"
  export CC_ALLOW_SECRET_PATH_FILE="$path_parent_link/linked.env"
  if secret_path_bypass_check "$path_parent_link/linked.env" >/dev/null 2>&1; then
    printf 'FAIL path_bypass_parent_symlink_rejected\n' >&2
    failures=$((failures + 1))
  else
    printf 'PASS path_bypass_parent_symlink_rejected\n'
  fi

  export CC_ALLOW_SECRET_PATH=1
  export CC_ALLOW_SECRET_PATH_FILE="allowed.env"
  export CC_ALLOW_SECRET_PATH_UNTIL=$((now + 60))
  if secret_path_bypass_check "$path_file" >/dev/null 2>&1; then
    printf 'FAIL path_bypass_relative_allow_rejected\n' >&2
    failures=$((failures + 1))
  else
    printf 'PASS path_bypass_relative_allow_rejected\n'
  fi

  export CC_ALLOW_SECRET_PATH="$path_file"
  unset CC_ALLOW_SECRET_PATH_FILE CC_ALLOW_SECRET_PATH_UNTIL
  if secret_path_bypass_check "$path_file" >/dev/null 2>&1; then
    printf 'FAIL path_bypass_legacy_format_rejected\n' >&2
    failures=$((failures + 1))
  else
    printf 'PASS path_bypass_legacy_format_rejected\n'
  fi
  unset CC_ALLOW_SECRET_PATH CC_ALLOW_SECRET_PATH_FILE CC_ALLOW_SECRET_PATH_UNTIL
  rm -rf "$audit_tmp"

  [ "$failures" -eq 0 ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --self-test) secret_bypass_self_test ;;
    *) printf 'usage: %s --self-test\n' "$0" >&2; exit 2 ;;
  esac
fi
