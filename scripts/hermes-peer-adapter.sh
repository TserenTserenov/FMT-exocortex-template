#!/usr/bin/env bash
# hermes-peer-adapter.sh — adapter Hermes for peer-conversation (partner role)
# see DP.SC.154, DP.SC.167 (symmetric counterpart claude-peer-adapter.sh)
# WP-392 Phase10, WP-509
#
# Invoked by the WRITER agent-WRITER (Claude, Kimi or another) when Hermes acts as PARTNER.
# Reads the prompt from stdin, sends to Hermes via the native CLI `hermes chat -q`,
# returns the response to stdout.
#
# Usage (from the writer agent script-writer):
#   bash scripts/hermes-peer-adapter.sh [--session-id "$HERMES_SESSION_ID"] \
#     < "${SESSION_DIR}/peer-prompt.md" > "$PEER_FILE" 2>/dev/null
# The prompt is passed via a file, not inline `echo "$peer_prompt" | ...` — otherwise the text
# of the prompt ends up in the command line and hook B7.7c falsely blocks repeated
# calls (bug-2026-06-30-peer-adapter-b77c-block).
#
# Environment variables:
#   HERMES_BIN         — path to hermes CLI (default: first `hermes` in PATH)
#   HERMES_SESSION_ID  — ID session ID for continuing the dialogue (optional)
#   HERMES_MAX_TURNS   — iteration limit (default: 1, peer-peer session does not use tools)

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
    # WP-516 Phase5 (§0c.1): cross-vendor flags, that hermes does not support
    # (table §0c), are rejected with an explicit diagnostic, not silently ignored.
    -p|--model|--add-dir|--permission-mode)
      echo "ERROR: flag '$1' is not supported by hermes adapter (see vendor table §0c). Supported: --session-id" >&2
      exit 1
      ;;
    # Unknown flag — explicit error (§0c.1).
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

# === Launch Hermes headless: `hermes chat -q ... -Q --max-turns 1` + 5min timeout ===
# -Q (quiet) removes the banner/spinner; --max-turns 1 limits the scope to a single response.
#
# WP-516 Phase5 (peer-session 2026-08-11-22-wp516-f5-contract-adapter): limit
# transport hermes — 4000 characters (parity with the original MCP-adapter).
# Previously the prompt was silently truncated (head -c 4000) — the peer responded to the wrong
# context, that the writer sent (prompt integrity violation, §0c.1).
# Now — an explicit rejection BEFORE launch with a diagnostic, without truncation.
# Override Override via HERMES_PROMPT_LIMIT is allowed only DOWNWARD: the transport limit: transport limit
# 4000 — property CLI, not a setting; non-numeric value → default.
HERMES_PROMPT_LIMIT="${HERMES_PROMPT_LIMIT:-4000}"
case "$HERMES_PROMPT_LIMIT" in
  ''|*[!0-9]*) HERMES_PROMPT_LIMIT=4000 ;;
esac
# Stripping leading zeros + length check BEFORE numeric comparison: a huge
# decimal value must not crash '[ -gt ]' with overflow (review-02).
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

# WP-516 Phase5 (§0c.1, finding Codex 12.08): non-timeout non-zero exit CLI
# must be normalized to 1 — otherwise the CLI error text CLI in OUT_FILE was being accepted
# as a successful peer response.
if [ "$PERL_EXIT" -ne 0 ]; then
  echo "ERROR: Hermes peer call failed with exit code $PERL_EXIT (cli_exit=$PERL_EXIT)" >&2
  tail -20 "$OUT_FILE" >&2 2>/dev/null || true
  exit 1
fi

if [ ! -s "$OUT_FILE" ]; then
  echo "ERROR: hermes returned empty output" >&2
  exit 1
fi

# Strip the internal session_id service line session_id from the beginning of the response (hermes -Q still prints session_id)
# and leading blank lines, but preserve internal line breaks.
RESPONSE=$(tail -n +2 "$OUT_FILE" | sed -e '/./,$!d')

# WP-516 Phase5 (§0c.1): stdout must begin with frontmatter; response without
# frontmatter = format violation → exit 1 with diagnostics.
# Check — for peer-replies turn-loop. Internal writer calls
# (review/verify/synth), whose output — NOT peer-reply, disable it
# via IWE_PEER_PLAIN=1 (layer IWE-integration, §0c.1).
if [ "${IWE_PEER_PLAIN:-0}" != "1" ]; then
  # awk in a single process: 'sed | head' under pipefail catches SIGPIPE on a long
  # valid reply and crashes the adapter without diagnostics (review-02, WP-516 Phase5).
  _FIRST_LINE=$(printf '%s\n' "$RESPONSE" | awk 'length { print; exit }')
  _FM_FENCES=$(printf '%s\n' "$RESPONSE" | grep -c '^---$' || true)
  if [ "$_FIRST_LINE" != "---" ] || [ "${_FM_FENCES:-0}" -lt 2 ]; then
    echo "ERROR: peer response missing frontmatter (first non-empty line must be '---' with a closing '---')." >&2
    exit 1
  fi

  # WP-484 Phase89: alert-only self-check — share of Cyrillic characters in the response after
  # code subtraction/paths/A2-gloss. Never blocks output, only
  # warns to stderr — not peer-replica (IWE_PEER_PLAIN=1) does not see it.
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
