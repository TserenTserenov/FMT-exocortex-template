#!/usr/bin/env bash
# response-clarity-hook.sh — conversational style violation detector (WP-388 Phase5/Phase9)
#
# Type: Stop hook (checks agent responses in a COMPLETED turn)
# Level: warning (nudge), does not block — always exit 0
# Log: ~/.claude/logs/style-violations.log
# Line format (contract WP-388): TIMESTAMP | agent | A-rule | description | context(redacted)
#
# Deterministic rules (consensus peer-session 2026-06-04-56):
#   A1   file path as the subject of a sentence
#   A8   process log at the start of a response (Reading…, Checking…)
#   A10  bare English status markers (exit 0, PASS, SHA, status: done)
#   BASE5 em dash outside the construction «— is» (base style rule #5)
#
# A11 (passive voice) — NOT caught: high risk of false positives,
# deferred until manual calibration on data from the burn-in week (see. WP-388 Phase6).
#
# Input: Stop-hook Claude Code passes JSON with stdin, field transcript_path
# points to JSONL-transcript. assistant_response in Stop is NOT passed —
# therefore we extract the assistant text of the current turn from the transcript.

set -euo pipefail

AGENT="claude-code"
INPUT=$(cat)
if [ -z "$INPUT" ]; then exit 0; fi

# Guard against recursion: if the hook is already active — exit
STOP_HOOK_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then exit 0; fi

TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then exit 0; fi

# session_id for the violation counter for the session (peer-session 2026-06-08-23)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo unknown)
SESSION_ID=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-'); [ -n "$SESSION_ID" ] || SESSION_ID="unknown"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
COUNT_DIR="$PROJECT_DIR/.claude/state"
COUNT_FILE="$COUNT_DIR/style-violations-count-$SESSION_ID"

# --- Assistant text of the CURRENT turn ---
# One turn = multiple JSONL-records (text / tool_use / text). We take all
# assistant text-blocks after the last user-message, concatenate. Parsing —
# in a single pass with Python (more reliable than element-by-element shell + jq under set -e).
RESPONSE=$(TRANSCRIPT_PATH="$TRANSCRIPT_PATH" python3 <<'PY' 2>/dev/null || echo ""
import json, os
path = os.environ["TRANSCRIPT_PATH"]
rows = []
with open(path, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except Exception:
            continue

def role_of(r):
    return r.get("type") or r.get("role") or ""

# index of the last user-message; everything after is — the current turn
last_user = -1
for i, r in enumerate(rows):
    if role_of(r) == "user":
        last_user = i

out = []
for r in rows[last_user + 1:]:
    if role_of(r) != "assistant":
        continue
    content = r.get("message", {}).get("content", r.get("content", []))
    if isinstance(content, str):
        out.append(content)
    elif isinstance(content, list):
        for blk in content:
            if isinstance(blk, dict) and blk.get("type") == "text":
                out.append(blk.get("text", ""))
print("\n".join(out))
PY
)

if [ -z "$RESPONSE" ]; then exit 0; fi

LOG_FILE="${HOME}/.claude/logs/style-violations.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
VIOLATIONS=""

# Denominator for frequency statistics (peer-session
# 2026-10-16-14-wp412-base5-mechanism, consensus Kimi+Codex): violation log
# on its own does not indicate, whether violations decreased or simply fewer
# checked turns. One line for each actually checked turn
# (RESPONSE non-empty, we have already passed the early exit above), separately from lines
# violations — we do not mix formats.
# Both writes below are guarded `|| true` (code review of this same session, High):
# under `set -euo pipefail` a failing mkdir/echo (disk full, no write permission,
# read-only home) otherwise it would abort the ENTIRE hook before the rules check — violating
# hard invariant «hook always exit 0».
CHECKS_LOG="${HOME}/.claude/logs/style-checks-total.log"
mkdir -p "$(dirname "$CHECKS_LOG")" 2>/dev/null || true
echo "$TIMESTAMP | $AGENT" >> "$CHECKS_LOG" 2>/dev/null || true

# redact: truncate to 100 characters, mask tokens (including.incl. short
# provider), replace delimiter | so as not to break the aggregator parser
redact() {
  printf '%s' "$1" | tr '\n' ' ' | cut -c1-100 \
    | sed -E 's/(gh[pousr]_|sk-|xox[baprs]-|AKIA)[A-Za-z0-9_-]+/<REDACTED>/g; s/[A-Za-z0-9_-]{32,}/<REDACTED>/g; s/[a-f0-9]{16,}/<REDACTED>/g; s/\|/¦/g'
}

log_violation() {
  local rule="$1" desc="$2" example="$3"
  VIOLATIONS="${VIOLATIONS}${rule} "
  echo "$TIMESTAMP | $AGENT | $rule | $desc | $(redact "$example")" >> "$LOG_FILE" 2>/dev/null || true
}

# --- A1: file path as subject ---
A1_MATCH=$(printf '%s\n' "$RESPONSE" | grep -E '^\s*`?[A-Za-z0-9_/.-]+\.(py|md|ts|sh|js|yaml|json)(:[0-9]+)?`?\s+(—|is|was|has|contains|handles|processes|does|creates|stores|returns|writes|reads)' | head -1 || true)
[ -n "$A1_MATCH" ] && log_violation "A1" "path-as-subject" "$A1_MATCH"

# --- A10: bare English status markers ---
# exit 0 / SHA: / status: done — are deterministic. PASS/FAIL we catch only in
# test-context (nearby test/smoke/check/G-gate) — otherwise false positive
# as an ordinary word («total FAIL»).
# NB: no Cyrillic ranges ([a-ya]) here — GNU grep under C.UTF-8 (GitHub runner)
# rejects them with "Invalid collation character" and the hook goes silently
# blind (found by T16 in CI, 2026-08-04). [^:[:space:]] is locale-independent.
A10_MATCH=$(printf '%s\n' "$RESPONSE" | grep -E '(\bexit\s+0\b|SHA:\s*[a-f0-9]{7,}|status:\s*(done|success)|\bG[0-9]\s+(PASS|FAIL)\b|(smoke|test[^:[:space:]]*|check[^:[:space:]]*)\s*:\s*(PASS|FAIL)\b|`(PASS|FAIL)`)' | head -1 || true)
[ -n "$A10_MATCH" ] && log_violation "A10" "bare-english-marker" "$A10_MATCH"

# --- A8: process log at the beginning of a response line ---
# We check the beginning of EACH line of the concatenated output: one turn = several text-blocks,
# each starts on a new line; intermediate «Checking…» before tool-call
# will appear at the start of its own line (case, important per consensus with Kimi).
A8_MATCH=$(printf '%s\n' "$RESPONSE" | grep -iE '^(Reading|Checking|Looking|Searching|Let me|Let me (take a look|check|read)|Reading|Checking|Searching|Looking)' | head -1 || true)
[ -n "$A8_MATCH" ] && log_violation "A8" "process-journal" "$A8_MATCH"

# --- BASE5: em dash outside the construction «— is» ---
# Line-by-line check, not against the entire text (found Codex, peer-session
# 2026-10-16-14-wp412-base5-mechanism): the previous version checked and grepped
# THE ENTIRE concatenated response with a single regex'Two consequences. Two consequences:
#   (1) `\s*` between the dash and «is» matches across a newline boundary — dash at the
#       end of a line and «is» at the start of the NEXT line were falsely treated as an allowed
#       exception;
#   (2) the log took the first line containing ANY dash (`grep '—' | head -1`) — if
#       the allowed «X — is Y» appeared before the actual violation, the log, into the log
#       received the allowed example, which is not a violation, which is not a violation.
# Line-by-line parsing fixes both bugs in one pass: `\s*` within a single line
# does not cross line boundaries, and the first VIOLATING line — is exactly what,
# gets logged.
# Word boundary after «is» (Codex): without it «— this»/«— this» matched
# as an exception, even though «it» is not a standalone word there. Negative lookahead for
# a Cyrillic continuation after «it» closes that case; `\*{0,2}` before «this» —
# allowed bold emphasis/italic («X — **this** Y»), not a violation.
# Perl, not grep: Cyrillic in a character class is safe here (unlike
# A10 above) — this is a Perl regex with `-CSD -Mutf8`, not GNU grep under C.UTF-8,
# and the previous version BASE5 already used Perl with Cyrillic in CI without failures.
BASE5_MATCH=$(printf '%s\n' "$RESPONSE" | perl -CSD -Mutf8 -ne '
  if (/—(?!\s*\*{0,2}this(?![a-yaYoA-YaYo]))/) { print; exit }
' 2>/dev/null || true)
[ -n "$BASE5_MATCH" ] && log_violation "BASE5" "em-dash-outside-eto" "$BASE5_MATCH"

# --- Reaction to violations (peer-session 2026-06-08-23) ---
# Two modes. By default warning (as before). STYLE_ENFORCE_BLOCK=1 enables
# blocking mode for high-confidence rules (A1/A10): Stop-hook requests
# rewrite the response with the correction line-correction STYLE_FIX. BASE5/A8 do NOT block
# (BASE5 too frequent; «auto-fix» auto-fix of already displayed text is not possible).
# In the template the flag is off by default — a new user does not yet have a log
# for precision calibration (promotion gate ≥90% precision).
if [ -z "$VIOLATIONS" ]; then exit 0; fi

# Violation counter for the session
mkdir -p "$COUNT_DIR"
COUNT=0; [ -f "$COUNT_FILE" ] && COUNT=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1)); echo "$COUNT" > "$COUNT_FILE"
# Cleanup old counters (>24h)
find "$COUNT_DIR" -name "style-violations-count-*" -mmin +1440 -delete 2>/dev/null || true

# Blockable high-confidence rules
BLOCKABLE=""
printf '%s' "$VIOLATIONS" | grep -qE '\bA1\b'  && BLOCKABLE="$BLOCKABLE A1"
printf '%s' "$VIOLATIONS" | grep -qE '\bA10\b' && BLOCKABLE="$BLOCKABLE A10"

ESC_NOTE=""
[ "$COUNT" -ge 3 ] && ESC_NOTE=" | 3+ style violations in the session (signal to pilot)"

if [ "${STYLE_ENFORCE_BLOCK:-0}" = "1" ] && [ -n "$BLOCKABLE" ]; then
  REASON="Style violated (rules:${BLOCKABLE} ). Rewrite the response for the pilot. Start the NEXT message with the correction line — STYLE_FIX:${BLOCKABLE} «before» → «after» — then the useful text. Rules: A1 path is not a subject; A10 no bare markers (exit/PASS/SHA).${ESC_NOTE}"
  jq -n --arg r "$REASON" '{"decision":"block","reason":$r}'
  exit 0
fi

# Warning-mode (does not block)
echo "⚠️ Style: violations [${VIOLATIONS}]${ESC_NOTE} — details in ~/.claude/logs/style-violations.log"
exit 0
