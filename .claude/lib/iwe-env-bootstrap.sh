#!/bin/bash
# IWE Environment Bootstrap — Unified Variables
# Source this in any script that needs workspace/root paths
# Usage: source "$IWE_SCRIPTS/iwe-env-bootstrap.sh"

# Exit early if already sourced
[ -n "${_IWE_ENV_BOOTSTRAP_SOURCED:-}" ] && return 0
_IWE_ENV_BOOTSTRAP_SOURCED=1

set -u

# ============================================================================
# PRIMARY SOURCE: WORKSPACE_DIR
# ============================================================================
# WORKSPACE_DIR is the canonical root of the IWE workspace.
# Resolution strategy (in order):
#   1. Environment variable WORKSPACE_DIR (e.g., from .exocortex.env or caller)
#   2. Derive from script location (PREFERRED for portability)
#   3. Fail with clear error (no guessing with $HOME)
# ============================================================================

if [ -z "${WORKSPACE_DIR:-}" ]; then
  # Try to infer from script location
  # (Script is typically at $WORKSPACE_DIR/FMT-exocortex-template/scripts/*)
  # Keep this variable bootstrap-owned. This file is sourced into callers, so a
  # generic SCRIPT_DIR would overwrite the caller's own path (#387).
  _IWE_BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  
  # Check if we're in a FMT-exocortex-template/scripts directory
  if [[ "$_IWE_BOOTSTRAP_DIR" =~ /FMT-exocortex-template/scripts ]]; then
    WORKSPACE_DIR="$(cd "$_IWE_BOOTSTRAP_DIR/../../.." && pwd)"
  elif [[ "$_IWE_BOOTSTRAP_DIR" =~ /\.claude/ ]]; then
    # We're in .claude/hooks, .claude/lib, .claude/detectors, or .claude/skills
    # When bootstrap is sourced from inside FMT-exocortex-template/.claude/,
    # going up two levels lands inside FMT, not in the real workspace root.
    _IWE_BOOTSTRAP_CANDIDATE="$(cd "$_IWE_BOOTSTRAP_DIR/../.." && pwd)"
    # The template folder name is not an invariant (issue #933: a clone named
    # e.g. "myexocortex"). The template is recognised by its own marker
    # (update-manifest.json) AND by sitting inside a workspace (.exocortex.env
    # in the parent, none inside it). Either alone is too broad: a partial
    # layout must not lift WORKSPACE_DIR to an unrelated parent.
    if [[ "$(basename "$_IWE_BOOTSTRAP_CANDIDATE")" == "FMT-exocortex-template" ]] \
       || { [ -f "$_IWE_BOOTSTRAP_CANDIDATE/update-manifest.json" ] \
            && [ ! -f "$_IWE_BOOTSTRAP_CANDIDATE/.exocortex.env" ] \
            && [ -f "$_IWE_BOOTSTRAP_CANDIDATE/../.exocortex.env" ]; }; then
      WORKSPACE_DIR="$(cd "$_IWE_BOOTSTRAP_CANDIDATE/.." && pwd)"
    else
      WORKSPACE_DIR="$_IWE_BOOTSTRAP_CANDIDATE"
    fi
  elif [[ "$_IWE_BOOTSTRAP_DIR" =~ /.iwe-runtime/ ]]; then
    # Runtime-generated scripts
    WORKSPACE_DIR="$(cd "$_IWE_BOOTSTRAP_DIR/../../.." && pwd)"
  else
    # Cannot infer — require explicit WORKSPACE_DIR
    echo "ERROR [iwe-env-bootstrap]: Unable to infer WORKSPACE_DIR" >&2
    echo "  Script location: $_IWE_BOOTSTRAP_DIR" >&2
    echo "  Expected locations:" >&2
    echo "    - $WORKSPACE_DIR/FMT-exocortex-template/scripts/..." >&2
    echo "    - $WORKSPACE_DIR/.claude/{lib,detectors,hooks,skills}/..." >&2
    echo "    - $WORKSPACE_DIR/.iwe-runtime/..." >&2
    echo "  Solution: Set WORKSPACE_DIR explicitly or source from correct location" >&2
    return 1 2>/dev/null || exit 1
  fi
fi

unset _IWE_BOOTSTRAP_DIR _IWE_BOOTSTRAP_CANDIDATE

# Expand tilde in WORKSPACE_DIR only if HOME exists (portable safety)
if [ -n "${HOME:-}" ]; then
  WORKSPACE_DIR="${WORKSPACE_DIR/#\~/$HOME}"
fi

# ============================================================================
# SOURCE OF TRUTH: .exocortex.env (single config — values + secrets)
# ============================================================================
# Once WORKSPACE_DIR is known, load the user config. Values defined here win
# over derived defaults below. This is the single env source for all scripts —
# no inline ". $IWE_ROOT/.exocortex.env" snippets elsewhere.
if [ -f "$WORKSPACE_DIR/.exocortex.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$WORKSPACE_DIR/.exocortex.env"
  set +a
fi

# ============================================================================
# DERIVED VARIABLES (fallbacks — .exocortex.env values take precedence)
# ============================================================================

# Legacy variable for backward compatibility
export IWE_ROOT="${IWE_ROOT:-$WORKSPACE_DIR}"

# Platform locations
export IWE_GOVERNANCE_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
export IWE_DS_MY_STRATEGY="${IWE_DS_MY_STRATEGY:-${WORKSPACE_DIR}/${IWE_GOVERNANCE_REPO}}"
export IWE_TEMPLATE="${IWE_TEMPLATE:-${WORKSPACE_DIR}/FMT-exocortex-template}"
export IWE_RUNTIME="${IWE_RUNTIME:-${WORKSPACE_DIR}/.iwe-runtime}"
# WP-7 F161 (peer session 2026-09-21-04-wp537-wp7-fmt-decisions-followup,
# Claude+Codex): a live scripts/ checkout at workspace root is canonical --
# agents commit fixes there -- while the template's own copy is
# deliberately trimmed (WP-546) and lags behind. Default to the live one;
# fall back to the template only for installs that have no live checkout.
# Issue #957: "a live checkout" is a REGULAR (non-symlink) session-guard.sh in
# workspace scripts/, not just an existing directory -- a scripts/ holding only
# a README and audit logs, or personal scripts plus symlinks into the template,
# must not hide the platform scripts. The marker proves "live checkout", not a
# complete file set. Keep in sync with setup/install-iwe-paths.sh (same rule).
#
# Issue #957 recurrence (Artem, 21.10): a short local exec-wrapper around the
# template's session-guard.sh (common workaround for an env/launchd gap) is a
# regular, non-symlink file too -- it used to win this check the same way a
# real checkout would. Treat a small file that execs into IWE_TEMPLATE as a
# wrapper, not a checkout.
_IWE_SG_MARKER="${WORKSPACE_DIR}/scripts/session-guard.sh"
if [ -z "${IWE_SCRIPTS:-}" ]; then
  if [ -f "$_IWE_SG_MARKER" ] && [ ! -L "$_IWE_SG_MARKER" ] \
     && ! { [ "$(wc -l < "$_IWE_SG_MARKER" 2>/dev/null || echo 0)" -le 30 ] \
            && grep -qE 'exec[[:space:]]+(bash[[:space:]]+)?"?\$\{?IWE_TEMPLATE' "$_IWE_SG_MARKER" 2>/dev/null; }; then
    export IWE_SCRIPTS="${WORKSPACE_DIR}/scripts"
  else
    # IWE_TEMPLATE honours .exocortex.env (renamed template folder, #933);
    # its default is the historical ${WORKSPACE_DIR}/FMT-exocortex-template.
    export IWE_SCRIPTS="${IWE_TEMPLATE}/scripts"
  fi
fi
unset _IWE_SG_MARKER

# Export to child processes
export WORKSPACE_DIR
export IWE_ROOT
# IWE_WORKSPACE: alias for WORKSPACE_DIR, referenced by SPF/Pack CLAUDE.md paths.
# Fallback only — keeps any value already set by the user's shell profile.
export IWE_WORKSPACE="${IWE_WORKSPACE:-$WORKSPACE_DIR}"

# Validation: ensure WORKSPACE_DIR exists
if [ ! -d "$WORKSPACE_DIR" ]; then
  echo "ERROR [iwe-env-bootstrap]: WORKSPACE_DIR=$WORKSPACE_DIR does not exist" >&2
  echo "  Set WORKSPACE_DIR manually or ensure .exocortex.env is loaded" >&2
  return 1 2>/dev/null || exit 1
fi

# ============================================================================
# OS DETECTION
# ============================================================================
# IWE_OS: "macos" | "linux" | "unknown" — use this instead of calling uname
# in individual scripts.
case "$(uname -s)" in
  Darwin) export IWE_OS="macos" ;;
  Linux)  export IWE_OS="linux" ;;
  *)      export IWE_OS="unknown" ;;
esac

# IWE_ICLOUD_BACKUP_DIR: backup destination for week-close §7a/7b.
# Empty when there is none — scripts must guard with [ -n "$IWE_ICLOUD_BACKUP_DIR" ].
#
# issue #880: a user whose data-residency rules forbid iCloud had no way to
# point this elsewhere — the var was unconditionally overwritten on every env
# load, and params.yaml had no matching key. Precedence: a pre-exported
# IWE_ICLOUD_BACKUP_DIR (set by the caller's shell) wins outright; else
# params.yaml's backup_dir (any OS, not just macOS — the point is to let the
# pilot choose, not to extend iCloud support to Linux); else the macOS-iCloud
# default, unchanged for everyone who sets neither.
PARAMS_FILE_FOR_BACKUP="${WORKSPACE_DIR}/params.yaml"
BACKUP_DIR_OVERRIDE=""
if [ -f "$PARAMS_FILE_FOR_BACKUP" ]; then
  # issue #1235: a missing backup_dir: key (the common case -- params.yaml.example
  # doesn't set one) makes grep exit 1; under pipefail that fails the whole
  # assignment, and bash 3.2 (macOS's /bin/bash, what backup-icloud.sh's
  # `#!/bin/bash` shebang resolves to) doesn't suspend errexit for a sourced
  # file the way bash 4.4+/5 do -- the caller silently exits here instead of
  # falling back to the default iCloud path. `|| true` on the whole pipeline
  # (not just grep) absorbs any stage's failure, since this value is optional.
  BACKUP_DIR_OVERRIDE=$(grep -E '^backup_dir:' "$PARAMS_FILE_FOR_BACKUP" 2>/dev/null | head -1 \
    | sed -E 's/^backup_dir:[[:space:]]*//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//; s/^["'"'"']//; s/["'"'"']$//' \
    || true)
  # Same leading-~ expansion as WORKSPACE_DIR above and linear_sync_path in
  # scripts/day-close.sh — bash does not expand ~ inside a variable
  # substitution, so a params.yaml value written the same way as every other
  # documented path key (e.g. "~/Backups") would otherwise be used literally.
  BACKUP_DIR_OVERRIDE="${BACKUP_DIR_OVERRIDE/#\~/$HOME}"
fi
if [ -n "${IWE_ICLOUD_BACKUP_DIR:-}" ]; then
  export IWE_ICLOUD_BACKUP_DIR
elif [ -n "$BACKUP_DIR_OVERRIDE" ]; then
  export IWE_ICLOUD_BACKUP_DIR="$BACKUP_DIR_OVERRIDE"
elif [ "$IWE_OS" = "macos" ]; then
  export IWE_ICLOUD_BACKUP_DIR="${HOME}/Library/Mobile Documents/com~apple~CloudDocs/IWE-backups"
else
  export IWE_ICLOUD_BACKUP_DIR=""
fi
# IWE_ICLOUD_ROOT stays iCloud-specific regardless of backup_dir: it is the
# mount that must exist when the backup target lies inside iCloud Drive
# (backup-icloud.sh, iwe-backup-check.sh — issue #1349). A backup_dir outside it
# is a plain directory on any OS and is not checked against this root; use
# iwe_path_inside to tell the two cases apart.
if [ "$IWE_OS" = "macos" ]; then
  export IWE_ICLOUD_ROOT="${HOME}/Library/Mobile Documents/com~apple~CloudDocs"
else
  export IWE_ICLOUD_ROOT=""
fi

# iwe_normalize_path PATH — physical absolute path (symlinks resolved). The
# path may not exist yet (a backup target is created on first use): the
# nearest existing ancestor is resolved and the missing tail is appended
# lexically, with "." and ".." folded.
iwe_normalize_path() {
  local path="$1" tail="" name head skip=0
  case "$path" in /*) ;; *) path="$PWD/$path" ;; esac
  while [ ! -d "$path" ]; do
    name="${path##*/}"
    path="${path%/*}"
    [ -n "$path" ] || path="/"
    case "$name" in
      ""|.) ;;
      ..) skip=$((skip + 1)) ;;
      *) if [ "$skip" -gt 0 ]; then skip=$((skip - 1)); else tail="/$name$tail"; fi ;;
    esac
  done
  head=$(CDPATH='' cd -P -- "$path" 2>/dev/null && pwd -P) || return 1
  while [ "$skip" -gt 0 ]; do
    head="${head%/*}"
    skip=$((skip - 1))
  done
  [ "$head" = "/" ] && head=""
  head="${head}${tail}"
  printf '%s\n' "${head:-/}"
}

# iwe_path_inside CHILD PARENT — true when CHILD is PARENT or lies under it,
# compared component-wise on normalised paths (not a raw string prefix, so
# ".../CloudDocs-other" is not inside ".../CloudDocs"). Empty PARENT → false.
iwe_path_inside() {
  local child parent
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  child=$(iwe_normalize_path "$1") || return 1
  parent=$(iwe_normalize_path "$2") || return 1
  [ "$parent" = "/" ] && return 0
  case "$child/" in
    "$parent"/*) return 0 ;;
  esac
  return 1
}

# Debug output (optional)
if [ "${IWE_ENV_BOOTSTRAP_DEBUG:-0}" = "1" ]; then
  echo "[iwe-env-bootstrap] Loaded successfully:" >&2
  echo "  WORKSPACE_DIR=$WORKSPACE_DIR" >&2
  echo "  IWE_ROOT=$IWE_ROOT" >&2
  echo "  IWE_TEMPLATE=$IWE_TEMPLATE" >&2
  echo "  IWE_OS=$IWE_OS" >&2
fi
