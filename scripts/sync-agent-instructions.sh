#!/usr/bin/env bash
# routing: utility  deterministic=true
# see WP-394 Phase4.2, DP.SC.159
# sync-agent-instructions.sh — generation AGENTS.md from the single source of truth CLAUDE.md + agent-blocks
#
# Single-source agent instructions (WP-394 Phase4.2). Eliminates silent divergence
# between CLAUDE.md (Claude), AGENTS.md (Kimi) and instructions Hermes.
#
# Build (full regeneration, NOT marker insertion):
#   AGENTS.md = [header] + [SYNC-CORE from CLAUDE.md] + [AGENTS-agent-blocks.md]
#
# Sources (in $IWE_ROOT, default $HOME/IWE):
#   CLAUDE.md             — section between <!-- SYNC-CORE-START --> and <!-- SYNC-CORE-END -->
#   AGENTS-agent-blocks.md — agent-specific content (commit attribution, MCP, instructions level)
#
# Usage:
#   ./sync-agent-instructions.sh            # dry-run: unified diff, without writing (DEFAULT)
#   ./sync-agent-instructions.sh --force    # write AGENTS.md (with backup .bak)
#   ./sync-agent-instructions.sh --check    # exit 1 if drift (for CI / Day Open), without writing
#   ./sync-agent-instructions.sh --with-hermes  # also generate persona.md Hermes
#   ./sync-agent-instructions.sh --help
#
# Environment variables:
#   IWE_ROOT            — workspace root (default $HOME/IWE)
#   HERMES_RUNTIME_DIR  — Hermes runtime directory Hermes for --with-hermes (default $HOME/.hermes)
#
# Invariant: CLAUDE.md SYNC-CORE — source-of-truth of the shared core. AGENTS.md derived, do not edit manually.

set -euo pipefail
# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
CLAUDE_MD="$IWE_ROOT/CLAUDE.md"
BLOCKS_MD="$IWE_ROOT/AGENTS-agent-blocks.md"
OUT_MD="$IWE_ROOT/AGENTS.md"
HERMES_DIR="${HERMES_RUNTIME_DIR:-$HOME/.hermes}"

MODE="dry-run"
WITH_HERMES=0
for arg in "$@"; do
  case "$arg" in
    --force)       MODE="force" ;;
    --check)       MODE="check" ;;
    --with-hermes) WITH_HERMES=1 ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -32
      exit 0 ;;
    *) echo "Unknown argument: $arg (see. --help)" >&2; exit 2 ;;
  esac
done

# --- Source validation ---
for f in "$CLAUDE_MD" "$BLOCKS_MD"; do
  if [ ! -f "$f" ]; then
    echo "[ERROR] Source not found: $f" >&2
    exit 1
  fi
done

# --- Guard: markers SYNC-CORE must be present (pre-migration complete?) ---
if ! grep -q '<!-- SYNC-CORE-START -->' "$CLAUDE_MD" || ! grep -q '<!-- SYNC-CORE-END -->' "$CLAUDE_MD"; then
  echo "[ABORT] In $CLAUDE_MD no markers found <!-- SYNC-CORE-START/END -->." >&2
  echo "        Pre-pre-migration not complete — mark up the core BEFORE generating (WP-394 Phase4.2)." >&2
  exit 3
fi

# --- Extract SYNC-CORE core (between markers, not including the markers themselves) ---
extract_core() {
  # Markers are anchored ^...$ — a marker line-marker inside the core body will not close the block prematurely.
  awk '
    /^[[:space:]]*<!-- SYNC-CORE-START -->[[:space:]]*$/ { grab=1; next }
    /^[[:space:]]*<!-- SYNC-CORE-END -->[[:space:]]*$/   { grab=0 }
    grab { print }
  ' "$CLAUDE_MD"
}

# --- Extract agent-blocks (remove outer marker-comments and HTML-comment-instruction) ---
extract_blocks() {
  awk '
    /^[[:space:]]*<!-- AGENT-SPECIFIC-START -->[[:space:]]*$/ { grab=1; next }
    /^[[:space:]]*<!-- AGENT-SPECIFIC-END -->[[:space:]]*$/   { grab=0; next }
    grab {
      # skip the leading HTML-comment (<!-- ... -->) at the start of the block
      if ($0 ~ /^<!--/) { incomment=1 }
      if (incomment) { if ($0 ~ /-->/) { incomment=0 }; next }
      print
    }
  ' "$BLOCKS_MD"
}

# --- Assemble the target AGENTS.md ---
build_agents() {
  cat <<'HEADER'
# AGENTS.md

> **Generated `scripts/sync-agent-instructions.sh` (WP-394 Phase4.2). DO NOT EDIT MANUALLY.**
> Shared core → block `<!-- SYNC-CORE -->` in `CLAUDE.md`. Agent-specific → `AGENTS-agent-blocks.md`.

HEADER
  extract_core
  echo
  extract_blocks
}

GENERATED="$(build_agents)"

# --- Modes ---
case "$MODE" in
  check)
    if [ ! -f "$OUT_MD" ]; then
      echo "[DRIFT] $OUT_MD does not exist — generation is required (--force)." >&2
      exit 1
    fi
    if diff -q <(printf '%s\n' "$GENERATED") "$OUT_MD" >/dev/null 2>&1; then
      echo "Sync: OK (AGENTS.md matches the core)"
      exit 0
    else
      echo "[DRIFT] AGENTS.md diverges from the core CLAUDE.md + agent-blocks. Run --force." >&2
      exit 1
    fi
    ;;
  dry-run)
    echo "=== sync-agent-instructions.sh: dry-run ==="
    echo "IWE_ROOT: $IWE_ROOT"
    if [ -f "$OUT_MD" ]; then
      if diff -q <(printf '%s\n' "$GENERATED") "$OUT_MD" >/dev/null 2>&1; then
        echo "AGENTS.md is already up to date — no changes."
      else
        echo "--- unified diff (current → generated) ---"
        diff -u "$OUT_MD" <(printf '%s\n' "$GENERATED") || true
        echo "--- to write: --force ---"
      fi
    else
      echo "AGENTS.md does not exist — will be created with --force. Preview:"
      printf '%s\n' "$GENERATED" | head -20
    fi
    ;;
  force)
    if [ -f "$OUT_MD" ]; then
      cp "$OUT_MD" "$OUT_MD.bak"
      echo "Backup: $OUT_MD.bak"
    fi
    printf '%s\n' "$GENERATED" > "$OUT_MD"
    echo "Written: $OUT_MD ($(wc -l < "$OUT_MD" | tr -d ' ') lines)"
    ;;
esac

# --- Optional: persona.md Hermes ---
if [ "$WITH_HERMES" -eq 1 ]; then
  if [ ! -d "$HERMES_DIR" ]; then
    echo "[WARN] --with-hermes: directory $HERMES_DIR not found — persona.md skipped (runtime Hermes is absent)." >&2
  elif [ "$MODE" = "force" ]; then
    PERSONA="$HERMES_DIR/persona.md"
    [ -f "$PERSONA" ] && cp "$PERSONA" "$PERSONA.bak"
    {
      echo "# Hermes Persona — IWE Core (generated by sync-agent-instructions.sh)"
      echo
      echo "> Shared core IWE. Hermes-specific — in the Hermes runtime Hermes, not here."
      echo
      extract_core
    } > "$PERSONA"
    echo "Written: $PERSONA"
  else
    echo "[INFO] --with-hermes is active, but persona.md is written only in --force."
  fi
fi
