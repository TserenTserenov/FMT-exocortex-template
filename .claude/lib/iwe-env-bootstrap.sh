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
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  
  # Check if we're in a FMT-exocortex-template/scripts directory
  if [[ "$SCRIPT_DIR" =~ /FMT-exocortex-template/scripts ]]; then
    WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
  elif [[ "$SCRIPT_DIR" =~ /\.claude/ ]]; then
    # We're in .claude/hooks, .claude/lib, .claude/detectors, or .claude/skills
    WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
  elif [[ "$SCRIPT_DIR" =~ /.iwe-runtime/ ]]; then
    # Runtime-generated scripts
    WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
  else
    # Cannot infer — require explicit WORKSPACE_DIR
    echo "ERROR [iwe-env-bootstrap]: Unable to infer WORKSPACE_DIR" >&2
    echo "  Script location: $SCRIPT_DIR" >&2
    echo "  Expected locations:" >&2
    echo "    - $WORKSPACE_DIR/FMT-exocortex-template/scripts/..." >&2
    echo "    - $WORKSPACE_DIR/.claude/{lib,detectors,hooks,skills}/..." >&2
    echo "    - $WORKSPACE_DIR/.iwe-runtime/..." >&2
    echo "  Solution: Set WORKSPACE_DIR explicitly or source from correct location" >&2
    return 1 2>/dev/null || exit 1
  fi
fi

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
export IWE_SCRIPTS="${IWE_SCRIPTS:-${WORKSPACE_DIR}/FMT-exocortex-template/scripts}"

# Export to child processes
export WORKSPACE_DIR
export IWE_ROOT

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

# IWE_ICLOUD_BACKUP_DIR: macOS iCloud Drive path for IWE backups.
# Empty on non-macOS platforms — scripts must guard with [ -n "$IWE_ICLOUD_BACKUP_DIR" ].
if [ "$IWE_OS" = "macos" ]; then
  export IWE_ICLOUD_BACKUP_DIR="${HOME}/Library/Mobile Documents/com~apple~CloudDocs/IWE-backups"
  export IWE_ICLOUD_ROOT="${HOME}/Library/Mobile Documents/com~apple~CloudDocs"
else
  export IWE_ICLOUD_BACKUP_DIR=""
  export IWE_ICLOUD_ROOT=""
fi

# Debug output (optional)
if [ "${IWE_ENV_BOOTSTRAP_DEBUG:-0}" = "1" ]; then
  echo "[iwe-env-bootstrap] Loaded successfully:" >&2
  echo "  WORKSPACE_DIR=$WORKSPACE_DIR" >&2
  echo "  IWE_ROOT=$IWE_ROOT" >&2
  echo "  IWE_TEMPLATE=$IWE_TEMPLATE" >&2
  echo "  IWE_OS=$IWE_OS" >&2
fi
