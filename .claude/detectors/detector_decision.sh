#!/bin/bash
# detector_decision.sh
# see DP.SC.025 (capture-bus service clause), DP.ROLE.001#R47 (Detector)
# event_type: decision_user
# cost_class: free (rule-based, regex on the transcript)
# runtime: shell
# triggers: Stop
#
# WP-109 Phase 7b. Detects user decisions in the session.
# Reads transcript_path from the Stop event, looks for human messages with decision
# patterns (approve/reject/redirect/architectural/strategic).
# Emits one decision_user event per each decision found.
#
# IMPORTANT — invariants (WP-206 Phase 7 §2a):
#   1. ONLY user decisions, not the agent's.
#   2. The filter is conservative: better to miss than to falsely fire.
#   3. Timestamp = time from the transcript (the .timestamp field), not NOW().
#   4. Each emission contains user_utterance — a quote (≤150 characters).
#   5. Typical NON-decisions (do not write): consent to run a command,
#      the reply "делай", approval of an autonomous agent action,
#      technical choices of the agent (file name, test structure, etc.).
#
# v1: emit only approved decisions (type decision_approve).
# v2 extension: recognition of reject/redirect/architectural/strategic.
# warn-before-block principle: the detector NEVER blocks (exit 0).
#
# Limit: no more than MAX_DECISIONS decisions per one Stop session (noise protection).

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

MAX_DECISIONS=5  # warn-before-block: conservative v1 limit

INPUT=$(cat)
if [ -z "$INPUT" ]; then
  exit 0
fi

HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Stop only
[ "$HOOK_EVENT" != "Stop" ] && exit 0

# No transcript — skip (graceful degradation)
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  exit 0
fi

# Determine target_repo: cwd → IWE repo
# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
DETECTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$DETECTOR_DIR/.." && pwd)"
# shellcheck source=../lib/iwe-env-bootstrap.sh
source "$CLAUDE_DIR/lib/iwe-env-bootstrap.sh" || exit 1

TARGET_REPO_HINT=""
if [ -n "$CWD" ] && [[ "$CWD" == "$IWE_ROOT"/* ]]; then
  REL="${CWD#$IWE_ROOT/}"
  FIRST_SEG="${REL%%/*}"
  if [ -n "$FIRST_SEG" ] && [ -d "$IWE_ROOT/$FIRST_SEG" ]; then
    TARGET_REPO_HINT="$IWE_ROOT/$FIRST_SEG"
  fi
fi

# Fallback: governance repo from env IWE_GOVERNANCE_REPO
if [ -z "$TARGET_REPO_HINT" ]; then
  if [ -n "${IWE_GOVERNANCE_REPO:-}" ] && [ -d "$IWE_ROOT/$IWE_GOVERNANCE_REPO" ]; then
    TARGET_REPO_HINT="$IWE_ROOT/$IWE_GOVERNANCE_REPO"
  else
    exit 0
  fi
fi

# ── Extract human messages from the transcript ───────────────────────────────
# The transcript is JSONL. A user turn in Claude Code: type="user" and
# .message.role="user", text in .message.content (a string or an array of blocks).
# Old forms (.role="user", type="human", .content) are kept for compatibility.
# Discarded: tool_result blocks (we take only type="text"), isMeta records,
# service insertions (<system-reminder>, <command-...>, the body of a loaded skill).
# issue #1174: the previous filter looked for .role at the top level and found nothing.
# HUMAN_JQ_BEGIN
HUMAN_JQ='
  def body: if type == "string" then .
            elif type == "array" then (map(select(.type == "text") | .text) | join("\n"))
            else empty end;
  select((.type == "user" and (.isMeta != true)) or .role == "user" or .type == "human")
  | ((.message.content // .content) | body)
  | select(length > 0)
  | select(test("^\\s*<(system-reminder|command-|local-command|user-prompt-submit-hook)") | not)
  | select(test("^\\s*Base directory for this skill:") | not)
'
# HUMAN_JQ_END
HUMAN_MSGS=$(jq -r "$HUMAN_JQ" "$TRANSCRIPT_PATH" 2>/dev/null || true)

if [ -z "$HUMAN_MSGS" ]; then
  exit 0
fi

# ── User decision patterns ───────────────────────────────────────────────────
# Conservative v1 filter: only explicit forks + choices.
# Each pattern: (regex, event_type, cognitive_weight)
#
# NOT matched: "делай", "ok", "да" without context (too noisy for v1).
# Matched: "выбираю X", "принято", "решение: X", "берём вариант X",
#            "да, [specific decision]", "нет, [specific reject]".

detect_decisions() {
  local msg="$1"
  local msg_lower
  msg_lower=$(echo "$msg" | tr '[:upper:]' '[:lower:]')

  # decision_approve — the user explicitly accepted an architectural/strategic decision
  if echo "$msg_lower" | grep -qE \
    '(выбираю|принято|берём|берем|решение:|решили|выбрали|остановились на|берём вариант|варианте [a-zа-я]|stop-list|в план|добавь в план|закрываем|делать не будем|откладываем|заморозим)'; then
    echo "decision_approve|1"
    return
  fi

  # decision_reject — an explicit rejection of a proposal
  if echo "$msg_lower" | grep -qE \
    '(нет, не (надо|нужно|делай)|отклоняем|отклони|отвергаем|не берём|не берем|откажемся|убираем это|дроп|drop)'; then
    echo "decision_reject|3"
    return
  fi

  # decision_redirect — a change of direction
  if echo "$msg_lower" | grep -qE \
    '(переформулируем|меняем подход|другой путь|иначе|переделай|перепиши концепцию|пересмотрим)'; then
    echo "decision_redirect|3"
    return
  fi
}

# ── Message handling ─────────────────────────────────────────────────────────
count=0
while IFS= read -r msg; do
  [ -z "$msg" ] && continue
  [ ${#msg} -lt 10 ] && continue  # too short — not a decision
  [ "$count" -ge "$MAX_DECISIONS" ] && break

  result=$(detect_decisions "$msg")
  [ -z "$result" ] && continue

  event_type="${result%%|*}"
  cognitive_weight="${result##*|}"

  # Quote: the first 150 characters of the message (schema filter WP-206 Phase 7 §4a)
  utterance="${msg:0:150}"

  # Timestamp: NOW() (v1 — ideally taken from the transcript, but requires jq per line)
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Emit the event (capture_writer will receive it via the stdout dispatcher)
  jq -n \
    --arg event_type "$event_type" \
    --arg session_id "$SESSION_ID" \
    --arg user_utterance "$utterance" \
    --arg ts "$TS" \
    --argjson cognitive_weight "$cognitive_weight" \
    --arg hint "$TARGET_REPO_HINT" \
    '{
      event_type: $event_type,
      payload: {
        session_id: $session_id,
        user_utterance: $user_utterance,
        cognitive_weight: $cognitive_weight,
        source: "iwe",
        ts: $ts
      },
      repo_ctx: {
        target_repo_hint: $hint
      }
    }'

  count=$((count + 1))

done <<< "$HUMAN_MSGS"

exit 0
