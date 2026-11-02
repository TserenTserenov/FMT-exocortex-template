#!/usr/bin/env bash
# hermes-peer-adapter.sh — Hermes adapter for peer-conversation (the partner role)
# see DP.SC.154, DP.SC.167 (symmetric analogue of claude-peer-adapter.sh)
# WP-392 Phase 10, WP-509
#
# Called by the WRITER agent (Claude, Kimi or another) when Hermes acts as the PARTNER.
# Reads the prompt from stdin, sends it to Hermes via the native CLI `hermes chat -q`,
# returns the answer to stdout.
#
# Usage (from the writer agent's script):
#   bash scripts/hermes-peer-adapter.sh [--session-id "$HERMES_SESSION_ID"] \
#     < "${SESSION_DIR}/peer-prompt.md" > "$PEER_FILE" 2>/dev/null
# The prompt is passed as a file, not inline `echo "$peer_prompt" | ...` — otherwise the prompt
# text ends up on the command line and the B7.7c hook falsely blocks repeated
# calls (bug-2026-06-30-peer-adapter-b77c-block).
#
# Environment variables:
#   HERMES_BIN         — path to the hermes CLI (default: first `hermes` in PATH)
#   HERMES_SESSION_ID  — session ID to continue the dialogue (optional)
#   HERMES_MAX_TURNS   — iteration limit (default: 1, a peer session does not use tools)

# Fail-closed: we deliberately inspect nonzero CLI exit codes below and
# normalize them to 1. Keeping `set -e` would abort the script before the
# normalization, so the adapter only runs with `set -uo pipefail`.
set -uo pipefail

HERMES_BIN="${HERMES_BIN:-$(command -v hermes 2>/dev/null || true)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HERMES_START_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

SESSION_ID="${HERMES_SESSION_ID:-}"
MAX_TURNS="${HERMES_MAX_TURNS:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id)
      [ $# -ge 2 ] || { echo "ERROR: --session-id requires a value" >&2; exit 1; }
      SESSION_ID="$2"; shift 2 ;;
    # WP-516 Phase 5 (§0в.1): cross-vendor flags that hermes does not support
    # (table §0в) are rejected with explicit diagnostics, not silently ignored.
    -p|--model|--add-dir|--permission-mode)
      echo "ERROR: flag '$1' is not supported by hermes adapter (see vendor table §0в). Supported: --session-id" >&2
      exit 1
      ;;
    # An unknown flag is an explicit error (§0в.1).
    *)
      echo "ERROR: unknown flag '$1'. Known: --session-id" >&2
      exit 1
      ;;
  esac
done

if [ -z "$HERMES_BIN" ] || [ ! -x "$HERMES_BIN" ]; then
  echo "ERROR: hermes binary not found. Install Hermes Agent CLI or set HERMES_BIN env var." >&2
  exit 1
fi

# Read the prompt from stdin
PROMPT=$(cat)

if [ -z "$PROMPT" ]; then
  echo "ERROR: empty prompt from stdin" >&2
  exit 1
fi

# === Run Hermes headless: `hermes chat -q ... -Q --max-turns 1` + 5min timeout ===
# -Q (quiet) removes the banner/spinner; --max-turns 1 limits the frame to a single answer.
#
# WP-516 Phase 5 (peer-session 2026-08-11-22-wp516-f5-contract-adapter): the hermes
# transport limit is 4000 characters (symmetry with the original MCP adapter).
# Previously the prompt was silently truncated (head -c 4000) — the partner answered the wrong
# context from the one the writer sent (a violation of prompt integrity, §0в.1).
# Now — an explicit refusal BEFORE launch with diagnostics, without truncation.
# Override via HERMES_PROMPT_LIMIT is possible only DOWNWARD: the transport limit
# of 4000 is a property of the CLI, not a setting; a non-numeric value → default.
HERMES_PROMPT_LIMIT="${HERMES_PROMPT_LIMIT:-4000}"
case "$HERMES_PROMPT_LIMIT" in
  ''|*[!0-9]*) HERMES_PROMPT_LIMIT=4000 ;;
esac
# Strip leading zeros + length check BEFORE the numeric comparison: a huge
# decimal value must not crash '[ -gt ]' by overflow (review-02).
HERMES_PROMPT_LIMIT=$(printf '%s' "$HERMES_PROMPT_LIMIT" | sed 's/^0*//')
[ -z "$HERMES_PROMPT_LIMIT" ] && HERMES_PROMPT_LIMIT=0
if [ "${#HERMES_PROMPT_LIMIT}" -gt 4 ] || [ "$HERMES_PROMPT_LIMIT" -gt 4000 ]; then
  HERMES_PROMPT_LIMIT=4000
fi
PROMPT_LEN=${#PROMPT}
if [ "$PROMPT_LEN" -gt "$HERMES_PROMPT_LIMIT" ]; then
  echo "ERROR: prompt is $PROMPT_LEN chars, exceeds hermes transport limit ($HERMES_PROMPT_LIMIT). Shorten the prompt or use another peer adapter. Refusing to truncate silently." >&2
  exit 1
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hermes-peer-XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

OUT_FILE="$TMP_ROOT/hermes-output.txt"

HERMES_ARGS=(chat -q "$PROMPT" -Q --max-turns "$MAX_TURNS")
if [ -n "$SESSION_ID" ]; then
  HERMES_ARGS+=(--resume "$SESSION_ID")
fi

perl -e 'alarm 300; exec @ARGV' -- "$HERMES_BIN" "${HERMES_ARGS[@]}" > "$OUT_FILE" 2>&1
PERL_EXIT=$?

if [ "$PERL_EXIT" -eq 142 ]; then
  echo "ERROR: Hermes peer call timed out after 5 minutes (SIGALRM)" >&2
  exit 1
fi

# WP-516 Phase 5 (§0в.1, Codex finding 12.08): a non-timeout nonzero CLI exit
# must be normalized to 1 — otherwise the CLI error text in OUT_FILE was taken
# for a successful peer answer.
if [ "$PERL_EXIT" -ne 0 ]; then
  echo "ERROR: Hermes peer call failed with exit code $PERL_EXIT (cli_exit=$PERL_EXIT)" >&2
  tail -20 "$OUT_FILE" >&2 2>/dev/null || true
  exit 1
fi

if [ ! -s "$OUT_FILE" ]; then
  echo "ERROR: hermes returned empty output" >&2
  exit 1
fi

# Remove the service session_id line from the start of the answer (hermes -Q still prints session_id)
# and leading empty lines, but keep internal line breaks.
RESPONSE=$(tail -n +2 "$OUT_FILE" | sed -e '/./,$!d')

# WP-516 Phase 5 (§0в.1): stdout must begin with frontmatter; an answer without
# frontmatter = format violation → exit 1 with diagnostics.
# The check is for peer turns of the turn-loop. The writer's service calls
# (review/verify/synth), whose output is NOT a peer turn, disable it
# via IWE_PEER_PLAIN=1 (the IWE integration layer, §0в.1).
if [ "${IWE_PEER_PLAIN:-0}" != "1" ]; then
  # awk in one process: 'sed | head' under pipefail catches SIGPIPE on a long
  # valid turn and crashes the adapter without diagnostics (review-02, WP-516 Phase 5).
  _FIRST_LINE=$(printf '%s\n' "$RESPONSE" | awk 'length { print; exit }')
  _FM_FENCES=$(printf '%s\n' "$RESPONSE" | grep -c '^---$' || true)
  if [ "$_FIRST_LINE" != "---" ] || [ "${_FM_FENCES:-0}" -lt 2 ]; then
    echo "ERROR: peer response missing frontmatter (first non-empty line must be '---' with a closing '---')." >&2
    exit 1
  fi

  # WP-484 Phase 89: alert-only self-check — share of Cyrillic in the answer after
  # subtracting code/paths/A2 glosses. Never blocks output, only
  # warns on stderr — a non-peer turn (IWE_PEER_PLAIN=1) does not see it.
  _LANG_CHECK="$SCRIPT_DIR/lib/language-check.py"
  if [ -f "$_LANG_CHECK" ]; then
    _LANG_RESULT=$(printf '%s' "$RESPONSE" | python3 "$_LANG_CHECK" 2>/dev/null || true)
    if printf '%s' "$_LANG_RESULT" | grep -q '"alert": true'; then
      echo "WARNING: peer response may not be in Russian (language-check alert) — $_LANG_RESULT" >&2
    fi
  fi
fi

# === WP-454: write to agent-sessions journal (best-effort, non-blocking) ===
# Security: only timestamps and duration written — no content from RESPONSE.
{
  _HERMES_END_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  _SID="${SESSION_ID:-hermes-standalone-$$}"
  python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/lib')
from datetime import datetime
from agent_session_time import write_journal_entry

start_s, end_s, sid = sys.argv[1:4]
fmt = lambda s: datetime.fromisoformat(s.replace('Z', '+00:00'))
try:
    agent_h = round((fmt(end_s) - fmt(start_s)).total_seconds() / 3600, 4)
except ValueError:
    agent_h = 0.0
write_journal_entry('hermes', sid, start_s[:10], start_s, end_s, agent_active_h=agent_h)
" "$_HERMES_START_TIME" "$_HERMES_END_TIME" "$_SID"
} 2>/dev/null &

echo "$RESPONSE"
