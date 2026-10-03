#!/usr/bin/env bash
# see .claude/skills/iwe-platform-redteam/SKILL.md — IWE Integration Contract.
#
# Disposable-boundary guard for the platform Red Team skill.
#
# Usage:  boundary-guard.sh -- <command> [args...]
#
# Runs <command> only when IWE_REDTEAM_FIXTURE_ROOT points at a real directory
# under a hardcoded disposable temp prefix. It then executes <command> in a
# redirected environment: HOME, WORKSPACE_DIR, TMPDIR and the bespoke
# fixture var are ALL redirected into the fixture. This matters because real
# IWE scripts derive their target the pervasive way — `${WORKSPACE_DIR:-$HOME/IWE}`
# or bare `$HOME/IWE` — so blanking one variable while keeping the real HOME
# would silently send a destructive command back to the real workspace. Every
# env-derived target path therefore resolves inside the fixture.
#
# Scope limits: an explicit real absolute path passed as a command ARGUMENT is
# outside this guard. Service-manager calls resolved through the inherited PATH
# are denied and recorded, including failures swallowed by a child script. An
# arbitrary child can still call an absolute manager path or replace PATH; that
# requires an OS sandbox/VM, not a shell wrapper.
#
# Bash 3.2 compatible (stock macOS /bin/bash): no associative arrays, no mapfile.

set -u

die() { printf 'boundary-guard: BLOCKED: %s\n' "$1" >&2; exit 3; }

# --- Parse: everything after the first `--` is the command to run. ------------
cmd_seen=0
CMD=()
for arg in "$@"; do
  if [ "$cmd_seen" -eq 1 ]; then
    CMD+=("$arg")
  elif [ "$arg" = "--" ]; then
    cmd_seen=1
  fi
done
[ "$cmd_seen" -eq 1 ] || die "missing '--'; usage: boundary-guard.sh -- <command>"
[ "${#CMD[@]}" -ge 1 ] || die "no command after '--'"

# --- Fixture root must be a declared, existing directory. ---------------------
FIX="${IWE_REDTEAM_FIXTURE_ROOT:-}"
[ -n "$FIX" ] || die "IWE_REDTEAM_FIXTURE_ROOT is not set — refusing to run against an undeclared target"
[ -d "$FIX" ] || die "IWE_REDTEAM_FIXTURE_ROOT ($FIX) is not an existing directory"

# Resolve to an absolute, symlink-free path (a temp symlink pointing into the
# real workspace de-references here and then fails the prefix check below).
FIX_ABS=$(cd "$FIX" 2>/dev/null && pwd -P) || die "cannot resolve IWE_REDTEAM_FIXTURE_ROOT ($FIX)"

# --- Fixture root must live under a hardcoded disposable temp prefix. ----------
# TMPDIR is deliberately NOT trusted as a prefix source: a hostile TMPDIR could
# otherwise bless an arbitrary real directory as "disposable".
allowed=0
case "$FIX_ABS" in
  # macOS resolves /tmp -> /private/tmp and /var/folders -> /private/var/folders
  # via pwd -P, so the /private/* forms must be listed too.
  /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) allowed=1 ;;
esac
[ "$allowed" -eq 1 ] || die "target ($FIX_ABS) is not under a disposable temp prefix (/tmp, /private/tmp, /var/folders) — use a mktemp fixture, never a real path"

# --- Defense-in-depth: reject a fixture nested inside the real workspace. ------
# Normally unreachable (temp prefixes are not under a /Users home), but guards
# the abnormal layout where the workspace itself lives under a temp prefix.
if [ -n "${HOME:-}" ] && [ -d "$HOME/IWE" ]; then
  IWE_REAL=$(cd "$HOME/IWE" 2>/dev/null && pwd -P) || IWE_REAL=""
  if [ -n "$IWE_REAL" ]; then
    case "$FIX_ABS" in
      "$IWE_REAL"|"$IWE_REAL"/*) die "target ($FIX_ABS) is inside the real IWE workspace ($IWE_REAL) — refusing" ;;
    esac
  fi
fi

# Create private deny shims only for managers already visible on the caller's
# PATH. This preserves platform detection in installers (a Linux fixture must
# not suddenly look like macOS). Each shim records only its command name; no
# arguments, which might contain user data. Keep the bin under the fixture so
# descendants retain the deny path for the lifetime of the disposable audit.
umask 077
SERVICE_BIN=$(command -p mktemp -d "$FIX_ABS/.iwe-redteam-service-bin.XXXXXXXX" 2>/dev/null) ||
  die "cannot create a private service-manager deny directory"
VIOLATIONS="$SERVICE_BIN/blocked-calls"
: > "$VIOLATIONS" || die "cannot create the service-manager audit record"
SHIMMED_MANAGERS=()
for manager in launchctl systemctl crontab; do
  if command -v "$manager" >/dev/null 2>&1; then
    # shellcheck disable=SC2016 # Variables expand in the generated shim.
    printf '%s\n' \
      '#!/bin/sh' \
      'guard_bin=${0%/*}' \
      'manager=${0##*/}' \
      'printf "%s\n" "$manager" >> "$guard_bin/blocked-calls" || {' \
      '  printf "boundary-guard: BLOCKED: cannot record %s\n" "$manager" >&2' \
      '  exit 3' \
      '}' \
      'printf "boundary-guard: BLOCKED: service-manager call (%s)\n" "$manager" >&2' \
      'exit 3' > "$SERVICE_BIN/$manager" || die "cannot write $manager deny shim"
    command -p chmod 700 "$SERVICE_BIN/$manager" || die "cannot make $manager deny shim executable"
    SHIMMED_MANAGERS+=("$manager")
  fi
done

# A top-level absolute manager path cannot bypass the PATH shims. Record this
# refusal too, so every attempted manager call leaves the same audit evidence.
case "${CMD[0]##*/}" in
  launchctl|systemctl|crontab)
    printf '%s\n' "${CMD[0]##*/}" >> "$VIOLATIONS" ||
      die "cannot record direct service-manager command (${CMD[0]})"
    die "service-manager command (${CMD[0]}) is forbidden in a disposable audit (record: $VIOLATIONS)"
    ;;
esac

# --- Run the command in a redirected environment. -----------------------------
# Every path a delivered script might use to find its target is redirected into
# the fixture: HOME, WORKSPACE_DIR, TMPDIR, and the bespoke fixture var. All
# other inherited variables (IWE_*, governance, provider-routing) are dropped.
# cwd is also moved into the fixture so cwd-relative paths and
# `git rev-parse --show-toplevel` resolve inside it, not the invocation dir.
# An explicit real absolute path passed as an argument is still out of scope.
cd "$FIX_ABS" || die "cannot chdir into fixture ($FIX_ABS)"
/usr/bin/env -i \
  PATH="$SERVICE_BIN:${PATH:-/usr/bin:/bin}" \
  LANG="${LANG:-C}" \
  HOME="$FIX_ABS" \
  TMPDIR="$FIX_ABS" \
  WORKSPACE_DIR="$FIX_ABS" \
  IWE_REDTEAM_FIXTURE_ROOT="$FIX_ABS" \
  IWE_REDTEAM_SERVICE_BIN="$SERVICE_BIN" \
  SETUP_CI=1 \
  "${CMD[@]}"
child_rc=$?

# update.sh and installers can deliberately swallow a manager failure. The
# wrapper's final status must still expose the safety violation to the auditor.
# A child can also remove the fixture-owned record/bin during cleanup: missing
# protection is a failed audit, never evidence that no manager was called.
if [ ! -d "$SERVICE_BIN" ] || [ -L "$SERVICE_BIN" ] ||
   [ ! -f "$VIOLATIONS" ] || [ -L "$VIOLATIONS" ]; then
  die "service-manager audit protection disappeared during child command"
fi
for manager in "${SHIMMED_MANAGERS[@]-}"; do
  [ -n "$manager" ] || continue  # Bash 3.2 + set -u expands an empty array once.
  if [ ! -f "$SERVICE_BIN/$manager" ] || [ ! -x "$SERVICE_BIN/$manager" ] ||
     [ -L "$SERVICE_BIN/$manager" ]; then
    die "service-manager deny shim disappeared during child command ($manager)"
  fi
done
if [ -s "$VIOLATIONS" ]; then
  die "service-manager call attempted inside fixture (record: $VIOLATIONS)"
fi
exit "$child_rc"
