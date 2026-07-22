#!/usr/bin/env bash
# Safe non-interactive Codex entrypoint for IWE protocols.
# Authentication and hook trust must be configured before unattended use.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CODEX_BIN="${CODEX_BIN:-$(command -v codex 2>/dev/null || true)}"
CODEX_TIMEOUT="${CODEX_TIMEOUT:-1800}"
CODEX_SANDBOX="${CODEX_SANDBOX:-workspace-write}"
OUTPUT_FILE=""
PROMPT=""

usage() {
  cat <<'EOF'
Usage: scripts/codex-headless-adapter.sh [options] <prompt>

Options:
  --cd DIR          Working repository (default: template root)
  --sandbox MODE    read-only|workspace-write (default: workspace-write)
  --timeout SEC     Overall timeout (default: 1800)
  --output FILE     Save the final agent message
  --help            Show this help

Environment: CODEX_BIN, CODEX_TIMEOUT, CODEX_SANDBOX.
This adapter never enables danger-full-access, approval bypass, or hook-trust bypass.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cd) REPO_ROOT="$2"; shift 2 ;;
    --sandbox) CODEX_SANDBOX="$2"; shift 2 ;;
    --timeout) CODEX_TIMEOUT="$2"; shift 2 ;;
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    --) shift; PROMPT="$*"; break ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) PROMPT="${PROMPT:+$PROMPT }$1"; shift ;;
  esac
done

[ -n "$CODEX_BIN" ] || { echo "ERROR: codex CLI not found; set CODEX_BIN." >&2; exit 127; }
[ -d "$REPO_ROOT/.git" ] || { echo "ERROR: not a Git repository: $REPO_ROOT" >&2; exit 2; }
[ -n "$PROMPT" ] || { echo "ERROR: prompt is required." >&2; usage >&2; exit 2; }
[[ "$CODEX_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: timeout must be a positive integer." >&2; exit 2; }
case "$CODEX_SANDBOX" in
  read-only|workspace-write) ;;
  *) echo "ERROR: sandbox must be read-only or workspace-write." >&2; exit 2 ;;
esac

args=(exec --strict-config --json --color never --cd "$REPO_ROOT" --sandbox "$CODEX_SANDBOX")
if [ -n "$OUTPUT_FILE" ]; then
  args+=(--output-last-message "$OUTPUT_FILE")
fi

exec timeout --foreground "$CODEX_TIMEOUT" "$CODEX_BIN" "${args[@]}" "$PROMPT"
