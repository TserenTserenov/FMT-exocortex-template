#!/bin/bash
# detector_incident.sh
# see DP.SC.025 (capture-bus service clause), DP.ROLE.001#R47 (Detector)
# event_type: agent_incident
# cost_class: free (rule-based)
# runtime: shell
#
# Pattern numbering — source-of-truth:
#   PACK-digital-platform/pack/digital-platform/05-failure-modes/DP.FM.010
#
# v1 v1 catches one pattern:
#   P3_structure_without_map — Write new .md into the repo root without checking
#                              routing-map DP.KR.001 §5 (except enumerated CLAUDE.md,
#                              README.md, MEMORY.md etc...).
#
# TODO extension in Phase8.3+: separate detectors for the remaining patterns DP.FM.010 —
#   P1 (detector_pattern_awareness, write into feedback_*.md),
#   P4 (detector_owner_integrity),
#   P5 (detector_verification),
#   P6 (detector_snapshot — destructive-commands without a preceding read),
#   P7 (detector_confirmation — regex against Stop output),
#   P8 (detector_layer_leak),
#   P9 (detector_compound_command).

set -uo pipefail

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
DETECTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$DETECTOR_DIR/.." && pwd)"
# shellcheck source=../lib/iwe-env-bootstrap.sh
source "$CLAUDE_DIR/lib/iwe-env-bootstrap.sh" || exit 1

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# v1: v1: we catch only Write/Edit into enumerated suspicious locations.
# Extension — a separate WP.
if [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ]; then
  exit 0
fi

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# We determine target_repo for emission
IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
TARGET_REPO_HINT=""

# If file_path absolute → we look for git root above
# IMPORTANT: we normalize FILE_PATH via realpath directory, so that prefixes match
# (macOS /var → /private/var, symlinks etc...)
if [[ "$FILE_PATH" == /* ]]; then
  DIR=$(dirname "$FILE_PATH")
  if [ -d "$DIR" ]; then
    DIR_REAL=$(cd "$DIR" 2>/dev/null && pwd -P)
    BASENAME=$(basename "$FILE_PATH")
    FILE_PATH="$DIR_REAL/$BASENAME"
    GIT_ROOT=$(cd "$DIR_REAL" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)
    if [ -n "$GIT_ROOT" ]; then
      TARGET_REPO_HINT="$GIT_ROOT"
    fi
  fi
fi

# Fallback: cwd as hint, if inside ~/IWE/*/
if [ -z "$TARGET_REPO_HINT" ] && [ -n "$CWD" ]; then
  if [[ "$CWD" == "$IWE_ROOT"/* ]]; then
    REL="${CWD#$IWE_ROOT/}"
    FIRST_SEG="${REL%%/*}"
    if [ -n "$FIRST_SEG" ] && [ -d "$IWE_ROOT/$FIRST_SEG" ]; then
      TARGET_REPO_HINT="$IWE_ROOT/$FIRST_SEG"
    fi
  fi
fi

# If target_repo was not resolved — we swallow it (OwnerIntegrity: we do not guess)
if [ -z "$TARGET_REPO_HINT" ]; then
  exit 0
fi

# v1 rule: Write of a new file into a folder, that is not in the routing map.
# We check one specific pattern — new .md in the root of any repo ~/IWE/*
# (knowledge normally goes into docs/, inbox/, memory/ — root is for CLAUDE.md, README.md etc...)
matched=""
pattern=""
description=""

if [ "$TOOL_NAME" = "Write" ] && [[ "$FILE_PATH" == *.md ]]; then
  # relative to target repo
  REL_PATH="${FILE_PATH#$TARGET_REPO_HINT/}"
  # No slash = file is in the root
  if [[ "$REL_PATH" != */* ]]; then
    # Known allowed root-level .md
    base=$(basename "$REL_PATH")
    case "$base" in
      CLAUDE.md|README.md|MEMORY.md|WORKPLAN.md|REGISTRY.md|MAP.md|STAGING.md|PROCESSES.md|CHANGELOG.md)
        : ;;
      *)
        matched="true"
        pattern="P3_structure_without_map"
        description="Write new .md into the repo root ($base). Routing map (DP.KR.001 §5) expects knowledge in docs/, inbox/ or a thematic subdirectory."
        ;;
    esac
  fi
fi

if [ -z "$matched" ]; then
  exit 0
fi

jq -n \
  --arg pattern "$pattern" \
  --arg severity "minor" \
  --arg description "$description" \
  --arg tool_name "$TOOL_NAME" \
  --arg file_path "$FILE_PATH" \
  --arg hint "$TARGET_REPO_HINT" \
  '{
    event_type: "agent_incident",
    payload: {
      pattern: $pattern,
      severity: $severity,
      description: $description,
      tool_context: {
        tool_name: $tool_name,
        file_path: $file_path
      }
    },
    repo_ctx: {
      target_repo_hint: $hint
    }
  }'

exit 0
