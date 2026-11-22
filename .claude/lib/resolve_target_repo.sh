#!/bin/bash
# resolve_target_repo.sh
# OwnerIntegrity: determining the target repo for capture-record.
#
# Chain:
#   1. Explicit hint (argument --hint=PATH or variable TARGET_REPO_HINT)
#   2. Absolute file_path from tool_input — find git-root above
#   3. cwd, if inside ~/IWE/*/ — take the first segment
#   4. NO FALLBACK. Return 1 + reason to stderr.
#
# Usage:
#   resolve_target_repo --hint=<path> --file=<path> --cwd=<path>
# Stdout:
#   absolute path to the target repo (success)
# Stderr:
#   reason on failure
# Exit:
#   0 — success
#   1 — unresolved

set -euo pipefail

HINT=""
FILE=""
CWD=""

for arg in "$@"; do
  case "$arg" in
    --hint=*) HINT="${arg#--hint=}" ;;
    --file=*) FILE="${arg#--file=}" ;;
    --cwd=*)  CWD="${arg#--cwd=}" ;;
  esac
done

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./iwe-env-bootstrap.sh
source "$LIB_DIR/iwe-env-bootstrap.sh" || exit 1

normalize() {
  # Accepts a path, returns absolute path without trailing slash trailing slash
  local p="$1"
  [ -z "$p" ] && return 1
  # If the path exists — realpath. If not — simple tilde expansion ~
  if [ -e "$p" ]; then
    realpath "$p" 2>/dev/null || echo "$p"
  else
    echo "${p/#\~/$HOME}"
  fi
}

# Step 1. Explicit hint
if [ -n "$HINT" ]; then
  RESOLVED=$(normalize "$HINT")
  if [ -d "$RESOLVED" ]; then
    echo "$RESOLVED"
    exit 0
  fi
  echo "hint provided but path does not exist: $HINT" >&2
  exit 1
fi

# Step 2. file_path → git root (directory must exist, file may be new)
if [ -n "$FILE" ]; then
  FILE_ABS=$(normalize "$FILE")
  DIR=$(dirname "$FILE_ABS")
  if [ -d "$DIR" ]; then
    GIT_ROOT=$(cd "$DIR" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)
    if [ -n "$GIT_ROOT" ]; then
      echo "$GIT_ROOT"
      exit 0
    fi
  fi
fi

# Step 3. cwd inside ~/IWE/*/
if [ -n "$CWD" ]; then
  CWD_ABS=$(normalize "$CWD")
  if [[ "$CWD_ABS" == "$IWE_ROOT"/* ]]; then
    REL="${CWD_ABS#$IWE_ROOT/}"
    FIRST_SEG="${REL%%/*}"
    if [ -n "$FIRST_SEG" ] && [ -d "$IWE_ROOT/$FIRST_SEG" ]; then
      echo "$IWE_ROOT/$FIRST_SEG"
      exit 0
    fi
  fi
fi

echo "target_repo_unresolved: hint='$HINT' file='$FILE' cwd='$CWD'" >&2
exit 1
