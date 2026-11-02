#!/usr/bin/env bash
# response-clarity-hook.sh -- detector of conversational-style violations (WP-388 Phase 5/Phase 9)
#
# Type: Stop hook (checks agent replies in the COMPLETED turn)
# Level: warning (nudge), does not block -- always exit 0
# Log: ~/.claude/logs/style-violations.log
# Line format (WP-388 contract): TIMESTAMP | agent | A-rule | description | context(redacted)
#
# Deterministic rules (peer-session 2026-06-04-56 consensus):
#   A1   file path as the subject of a sentence
#   A8   process log at the start of a reply (Reading…, Проверяю…)
#   A10  bare English status markers (exit 0, PASS, SHA, status: done)
#   BASE5 em dash outside the «— это» construction (base style rule #5)
#
# A11 (passive voice) is NOT caught: high risk of false positives,
# deferred until manual calibration on the data of the trial week (see WP-388 Phase 6).
#
# Input: the Claude Code Stop hook passes JSON on stdin, the transcript_path field
# points to the JSONL transcript. assistant_response is NOT passed in Stop --
# so we extract the assistant text of the current turn from the transcript.

set -euo pipefail

AGENT="claude-code"
INPUT=$(cat)
if [ -z "$INPUT" ]; then exit 0; fi

# Recursion guard: if the hook is already active -- exit
STOP_HOOK_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then exit 0; fi

TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then exit 0; fi

# session_id for the per-session violation counter (peer-session 2026-06-08-23)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo unknown)
SESSION_ID=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-'); [ -n "$SESSION_ID" ] || SESSION_ID="unknown"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
COUNT_DIR="$PROJECT_DIR/.claude/state"
COUNT_FILE="$COUNT_DIR/style-violations-count-$SESSION_ID"

# --- Assistant text of the CURRENT turn ---
# One turn = several JSONL records (text / tool_use / text). We take all
# assistant text blocks after the last user message and join them. Parsing is
# a single pass in Python (more reliable than element-wise shell + jq under set -e).
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

# индекс последнего user-сообщения; всё после — текущий ход
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
# 2026-10-16-14-wp412-base5-mechanism, Kimi+Codex consensus): the violation log
# by itself does not say whether there are fewer violations or just fewer
# checked turns. One line per each actually checked turn
# (RESPONSE is non-empty, we already passed the early exit above), separate from the
# violation lines -- we do not mix the format.
# Both writes below are protected by `|| true` (code review of this same session, High):
# under `set -euo pipefail` a failed mkdir/echo (disk full, no permissions,
# read-only home) would otherwise abort the WHOLE hook before the rule checks, violating
# the hard invariant "the hook always exits 0".
CHECKS_LOG="${HOME}/.claude/logs/style-checks-total.log"
mkdir -p "$(dirname "$CHECKS_LOG")" 2>/dev/null || true
echo "$TIMESTAMP | $AGENT" >> "$CHECKS_LOG" 2>/dev/null || true

# redact: truncate to 100 characters, mask tokens (including short
# provider ones), replace the | separator so as not to break the aggregator parser
redact() {
  printf '%s' "$1" | tr '\n' ' ' | cut -c1-100 \
    | sed -E 's/(gh[pousr]_|sk-|xox[baprs]-|AKIA)[A-Za-z0-9_-]+/<REDACTED>/g; s/[A-Za-z0-9_-]{32,}/<REDACTED>/g; s/[a-f0-9]{16,}/<REDACTED>/g; s/\|/¦/g'
}

log_violation() {
  local rule="$1" desc="$2" example="$3"
  VIOLATIONS="${VIOLATIONS}${rule} "
  echo "$TIMESTAMP | $AGENT | $rule | $desc | $(redact "$example")" >> "$LOG_FILE" 2>/dev/null || true
}

# --- A1: file path as the subject ---
A1_MATCH=$(printf '%s\n' "$RESPONSE" | grep -E '^\s*`?[A-Za-z0-9_/.-]+\.(py|md|ts|sh|js|yaml|json)(:[0-9]+)?`?\s+(—|is|was|has|содержит|отвечает|обрабатывает|делает|создаёт|хранит|возвращает|пишет|читает)' | head -1 || true)
[ -n "$A1_MATCH" ] && log_violation "A1" "path-as-subject" "$A1_MATCH"

# --- A10: bare English status markers ---
# exit 0 / SHA: / status: done are deterministic. PASS/FAIL we catch only in a
# test context (next to тест/smoke/проверка/G-gate) -- otherwise a false positive
# on an ordinary word («полный FAIL»).
# NB: no Cyrillic ranges ([а-я]) here — GNU grep under C.UTF-8 (GitHub runner)
# rejects them with "Invalid collation character" and the hook goes silently
# blind (found by T16 in CI, 2026-08-04). [^:[:space:]] is locale-independent.
A10_MATCH=$(printf '%s\n' "$RESPONSE" | grep -E '(\bexit\s+0\b|SHA:\s*[a-f0-9]{7,}|status:\s*(done|success)|\bG[0-9]\s+(PASS|FAIL)\b|(smoke|тест[^:[:space:]]*|проверк[^:[:space:]]*)\s*:\s*(PASS|FAIL)\b|`(PASS|FAIL)`)' | head -1 || true)
[ -n "$A10_MATCH" ] && log_violation "A10" "bare-english-marker" "$A10_MATCH"

# --- A8: process log at the start of a reply line ---
# We check the start of EACH line of the joined text: one turn = several text blocks,
# each starts on a new line; an intermediate «Проверяю…» before a tool-call
# lands at the start of its own line (a case important by consensus with Kimi).
A8_MATCH=$(printf '%s\n' "$RESPONSE" | grep -iE '^(Reading|Checking|Looking|Searching|Let me|Сейчас (посмотрю|проверю|прочитаю)|Читаю|Проверяю|Ищу|Смотрю)' | head -1 || true)
[ -n "$A8_MATCH" ] && log_violation "A8" "process-journal" "$A8_MATCH"

# --- BASE5: em dash outside the «— это» construction ---
# Line-by-line check, not over the whole text (found by Codex, peer-session
# 2026-10-16-14-wp412-base5-mechanism): the previous version checked and grepped the
# WHOLE joined reply with one regex. Two consequences:
#   (1) `\s*` between the dash and «это» also matches across a line break -- a dash at the
#       end of a line and «это» at the start of the NEXT one were falsely counted as an allowed
#       exception;
#   (2) the log took the first line with ANY dash (`grep '—' | head -1`) -- if the
#       allowed «X — это Y» came earlier than the real violation, the allowed
#       non-violating example landed in the log.
# Line-by-line parsing fixes both bugs in one go: `\s*` within one line
# does not cross a line boundary, and the first VIOLATING line is exactly what
# is logged.
# Word boundary after «это» (Codex): without it «— этот»/«— этому» matched the
# exception, although «это» there is not a standalone word. A negative lookahead on
# a Cyrillic continuation after «это» closes this; `\*{0,2}` before «это» is an
# allowed bold/italic emphasis («X — **это** Y»), not a violation.
# Perl, not grep: a Cyrillic character class is safe here (unlike
# A10 above) -- this is a perl regex with `-CSD -Mutf8`, not GNU grep under C.UTF-8,
# and the previous BASE5 version already used perl with Cyrillic in CI without failures.
BASE5_MATCH=$(printf '%s\n' "$RESPONSE" | perl -CSD -Mutf8 -ne '
  if (/—(?!\s*\*{0,2}это(?![а-яёА-ЯЁ]))/) { print; exit }
' 2>/dev/null || true)
[ -n "$BASE5_MATCH" ] && log_violation "BASE5" "em-dash-outside-eto" "$BASE5_MATCH"

# --- Reaction to violations (peer-session 2026-06-08-23) ---
# Two modes. By default warning (as before). STYLE_ENFORCE_BLOCK=1 enables
# blocking mode for high-confidence rules (A1/A10): the Stop hook asks to
# rewrite the reply with a correction line STYLE_FIX. BASE5/A8 do NOT block
# (BASE5 is too frequent; an "auto-fix" of already shown text is impossible).
# In the template the flag is off by default -- a new user does not yet have a log
# for precision calibration (promotion gate >=90% precision).
if [ -z "$VIOLATIONS" ]; then exit 0; fi

# Per-session violation counter
mkdir -p "$COUNT_DIR"
COUNT=0; [ -f "$COUNT_FILE" ] && COUNT=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1)); echo "$COUNT" > "$COUNT_FILE"
# Cleanup of old counters (>24h)
find "$COUNT_DIR" -name "style-violations-count-*" -mmin +1440 -delete 2>/dev/null || true

# Blocking high-confidence rules
BLOCKABLE=""
printf '%s' "$VIOLATIONS" | grep -qE '\bA1\b'  && BLOCKABLE="$BLOCKABLE A1"
printf '%s' "$VIOLATIONS" | grep -qE '\bA10\b' && BLOCKABLE="$BLOCKABLE A10"

ESC_NOTE=""
[ "$COUNT" -ge 3 ] && ESC_NOTE=" | 3+ нарушений стиля за сессию (сигнал пилоту)"

if [ "${STYLE_ENFORCE_BLOCK:-0}" = "1" ] && [ -n "$BLOCKABLE" ]; then
  REASON="Стиль нарушен (правила:${BLOCKABLE} ). Перепиши ответ для пилота. Начни СЛЕДУЮЩЕЕ сообщение со строки коррекции — STYLE_FIX:${BLOCKABLE} «было» → «стало» — затем полезный текст. Правила: A1 путь не подлежащее; A10 без голых маркеров (exit/PASS/SHA).${ESC_NOTE}"
  jq -n --arg r "$REASON" '{"decision":"block","reason":$r}'
  exit 0
fi

# Warning mode (does not block)
echo "⚠️ Стиль: нарушения [${VIOLATIONS}]${ESC_NOTE} — подробности в ~/.claude/logs/style-violations.log"
exit 0
