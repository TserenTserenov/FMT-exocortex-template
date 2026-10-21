#!/bin/bash
# inject-code-style.sh
# Event: PreToolUse (matcher: Edit|Write)
# see DP.SC.172 (commitment «Engineering Code Style Foundation»), WP-408 Phase3
#
# Purpose: inject the L0 core L0 (P0-P5) + L1-L1 extensions into the agent context BEFORE
#   editing a code-file. Mirror of inject-communication-style.sh, but the axis is — code and
#   event — PreToolUse (code is being edited), not UserPromptSubmit (any response).
#
# Style hook composition contract (delta-ArchGate WP-408, invariant):
#   1. Style hooks do not know about each other.
#   2. State-file with PREFIX code-style-injected-* (NOT comm-style-injected-*).
#   3. Contexts are additive — we only append additionalContext.
#
# Behavior:
# - Extension filter: code files only-files (.py/.ts/.js/.tsx/.jsx/.sh/.go/.rs/...).
#   Docs (.md/.txt/.yaml/.json/.toml) → silent skip (echo '{}').
# - Inject ONLY the core between markers CODE-STYLE-INJECT-START/END (limit
#   PreToolUse additionalContext = 10000 chars; hard-cap 9500 for concatenating L0+L1).
# - Density-reinject: first code-touch + as conversation grows/turns (like comm-hook).
# - L0 absent → silent skip. L1 absent → only L0.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

command -v jq >/dev/null 2>&1 || { echo '{}'; exit 0; }

INPUT=$(cat 2>/dev/null || echo '{}')

# Filter by extension: inject only when editing a CODE-file
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
case "$FILE_PATH" in
  *.py|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.sh|*.bash|*.go|*.rs|*.rb|*.java|*.kt|*.c|*.h|*.cpp|*.hpp|*.sql) : ;;
  *) echo '{}'; exit 0 ;;   # not code — do not inject
esac

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"
SESSION_ID=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
STATE_DIR="$PROJECT_DIR/.claude/state"
STATE_FILE="$STATE_DIR/code-style-injected-$SESSION_ID"   # prefix ≠ comm-style

REINJECT_EVERY_TURNS="${CODE_STYLE_REINJECT_TURNS:-12}"
REINJECT_BYTES="${CODE_STYLE_REINJECT_BYTES:-60000}"
HARD_CAP="${CODE_STYLE_INJECT_CAP:-9500}"   # headroom for the limit PreToolUse 10000

TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
CUR_BYTES=0
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  CUR_BYTES=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ' || echo 0)
  [ -n "$CUR_BYTES" ] || CUR_BYTES=0
fi

TURN=0; LAST_INJECT_TURN=0; LAST_INJECT_BYTES=0
if [ -f "$STATE_FILE" ]; then
  read -r TURN LAST_INJECT_TURN LAST_INJECT_BYTES < "$STATE_FILE" 2>/dev/null || true
  [ -n "${TURN:-}" ] || TURN=0
  [ -n "${LAST_INJECT_TURN:-}" ] || LAST_INJECT_TURN=0
  [ -n "${LAST_INJECT_BYTES:-}" ] || LAST_INJECT_BYTES=0
  # corrupted/tampered state (non-numeric) under set -u would crash $(( )) with empty stdout
  case "$TURN$LAST_INJECT_TURN$LAST_INJECT_BYTES" in *[!0-9]*) TURN=0; LAST_INJECT_TURN=0; LAST_INJECT_BYTES=0 ;; esac
fi
TURN=$((TURN + 1))

DO_INJECT=0
if [ ! -f "$STATE_FILE" ]; then
  DO_INJECT=1                                                     # first code-touch
elif [ $((TURN - LAST_INJECT_TURN)) -ge "$REINJECT_EVERY_TURNS" ]; then
  DO_INJECT=1
elif [ "$CUR_BYTES" -gt 0 ] && [ $((CUR_BYTES - LAST_INJECT_BYTES)) -ge "$REINJECT_BYTES" ]; then
  DO_INJECT=1
fi

if [ "$DO_INJECT" -eq 0 ]; then
  mkdir -p "$STATE_DIR"
  echo "$TURN $LAST_INJECT_TURN $LAST_INJECT_BYTES" > "$STATE_FILE"
  echo '{}'
  exit 0
fi

# Content: registry dispatcher (if available) → file-snapshot p05-core.md → skip.
# Dispatcher: WP-412 Phase6 (thin hook with cascade L0+L1). Path to it via PROJECT_DIR.
# File-snapshot: WP-412 Phase11 (FMT-fallback, self-contained). Path via BASH_SOURCE — works in env -i.
# Runtime-mechanics (re-injection, cap, state, silent-skip) stays in the hook. Rollback: git revert.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P05_CORE="$HOOK_DIR/../styles/p05-core.md"

DISPATCHER="$PROJECT_DIR/PACK-rhetoric/pack/language-style/registry/dispatcher.py"
if [ -f "$DISPATCHER" ]; then
  FRAGMENT=$(python3 "$DISPATCHER" --event pretooluse-edit --quiet --no-cache 2>/dev/null)
fi

# If the dispatcher returned no content — read the file-snapshot (strip frontmatter between --- --- )
if [ -z "${FRAGMENT:-}" ] && [ -f "$P05_CORE" ]; then
  FRAGMENT=$(awk '/^---/{n++; if(n==2){found=1; next}} found' "$P05_CORE" 2>/dev/null)
fi

[ -n "${FRAGMENT:-}" ] || { echo '{}'; exit 0; }   # both sources are empty/failed → skip (safe)

CONTEXT="## 🔧 IWE engineering code style IWE (L0 base + L1 author) — apply when writing/editing code

Source of truth: \`DP.SC.172\` (Pack). List of smells with «before/after». Quality = absence of smells. Context detector: «does the code have a future reader?» Yes → P1-P5 required.

$FRAGMENT"

# Hard-cap: we count and truncate in Unicode Unicode-characters. `wc -c` was counting bytes,
# whereas Python Python below slices characters: with Cyrillic text this produced a false
# cap overrun and appended a truncation marker to an already valid context.
# (Outside this block CUR_BYTES intentionally remains a byte counter:
# this is a separate transcript growth threshold transcript for re-injection.)
if ! CTX_LEN=$(printf '%s' "$CONTEXT" | python3 -c 'import sys; print(len(sys.stdin.read()))'); then
  echo '{}'
  exit 0
fi
if [ "$CTX_LEN" -gt "$HARD_CAP" ]; then
  echo "inject-code-style: context $CTX_LEN > cap $HARD_CAP — truncating at sentence boundary" >&2
  CONTEXT=$(CTX="$CONTEXT" CAP="$HARD_CAP" python3 - <<'PY'
import os
ctx = os.environ["CTX"]
cap = int(os.environ["CAP"])
clipped = ctx[:cap]
# fall back to the last sentence boundary/paragraph, so as not to split a rule
fence = chr(96) * 3 + "\n"   # triple backtick without a literal (breaks the bash parser bash inside $())
m = max(clipped.rfind(". "), clipped.rfind(".\n"), clipped.rfind("\n\n"), clipped.rfind(fence))
if m > 0:
    clipped = clipped[:m + 1]
print(clipped.rstrip() + "\n\n[…truncated to limit; full text — DP.SC.172 in Pack]")
PY
)
fi

mkdir -p "$STATE_DIR"
echo "$TURN $TURN $CUR_BYTES" > "$STATE_FILE"
find "$STATE_DIR" -name "code-style-injected-*" -mmin +1440 -delete 2>/dev/null || true

jq -n --arg ctx "$CONTEXT" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": $ctx
  }
}'
