#!/bin/bash
# PreCompact Checkpoint Hook (issue #1183)
# Event: PreCompact
# Before context compaction takes a snapshot of the working state. The precompact-restore.sh
# hook returns it to the agent on the SessionStart event (matcher "compact").
#
# Why this way: PreCompact has no channel to the model — Claude Code discards its
# systemMessage/continue, additionalContext is not provided for it
# (https://code.claude.com/docs/en/hooks). Therefore nothing is printed here:
# the hook only writes a file, delivery happens at SessionStart after compaction.
#
# The snapshot contains user and assistant turns — keeping it in a repository
# is unsafe: the `.gitignore` that marks it in the template is not delivered by update.sh
# on all installations (issue #1183, cold review). Therefore the file lies in
# the personal Claude Code directory, not in the project working copy.
export LC_ALL=C

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
# An invalid/long identifier is rejected, not sanitized: otherwise "a/b" and
# "ab" would give one file, and an id of thousands of characters would crash mv (ENAMETOOLONG).
case "$SESSION_ID" in '' | *[!A-Za-z0-9_-]* ) exit 0 ;; esac
[ "${#SESSION_ID}" -le 128 ] || exit 0

TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
TRIGGER=$(printf '%s' "$INPUT" | jq -r '.trigger // "unknown"' 2>/dev/null)
CHECKPOINT_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/iwe-checkpoints"
mkdir -p "$CHECKPOINT_DIR" 2>/dev/null || exit 0
chmod 700 "$CHECKPOINT_DIR" 2>/dev/null
CHECKPOINT_FILE="$CHECKPOINT_DIR/checkpoint-$SESSION_ID.md"

# Transcript tail: the last user turns and the last assistant answer.
# JSONL is parsed tolerantly (fromjson?, not piping all of it into jq): "tail -n" may
# return an unfinished last line from a concurrently writing process, and one
# broken JSON must not abort parsing of the whole tail.
USER_TAIL=""
ASSISTANT_TAIL=""
if [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ]; then
  RECENT=$(tail -n 400 "$TRANSCRIPT" 2>/dev/null)
  # Filter of service insertions — at the level of EACH text block, not the joined
  # message: Claude Code adds <system-reminder> as a separate second
  # block of the same user message, and a filter by line start after
  # join does not catch it (issue #1183, cold review, M2).
  USER_TAIL=$(printf '%s\n' "$RECENT" | jq -R -r '
      (fromjson? // empty)
      | select(.type == "user")
      | .message.content
      | if type == "string" then [.] else [.[]? | select(.type == "text") | .text] end
      | map(select(test("^<(system-reminder|command-|local-command|ide_)") | not) | gsub("\n"; " "))
      | join(" ")
      | select(length > 0)
      | .[0:600]' 2>/dev/null | tail -n 3)
  ASSISTANT_TAIL=$(printf '%s\n' "$RECENT" | jq -R -r '
      (fromjson? // empty)
      | select(.type == "assistant")
      | .message.content
      | if type == "string" then [.] else [.[]? | select(.type == "text") | .text] end
      | map(gsub("\n"; " "))
      | join(" ")
      | select(length > 0)' 2>/dev/null | tail -n 1 | cut -c1-1500)
fi

TMP=$(mktemp "$CHECKPOINT_DIR/.checkpoint.XXXXXX") || exit 0
chmod 600 "$TMP"
{
  echo "# Checkpoint перед сжатием контекста"
  echo "- Сессия: $SESSION_ID"
  echo "- Время: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- Причина сжатия: $TRIGGER"
  echo
  echo "## Последние запросы пользователя"
  if [ -n "$USER_TAIL" ]; then printf '%s\n' "$USER_TAIL" | sed 's/^/- /'; else echo "- (не удалось прочитать транскрипт)"; fi
  echo
  echo "## Последний ответ ассистента"
  if [ -n "$ASSISTANT_TAIL" ]; then printf '%s\n' "$ASSISTANT_TAIL"; else echo "(не удалось прочитать транскрипт)"; fi
  # Defense in depth: even after filtering the blocks above we neutralize the remainder
  # of similar tags so that the restore hook output cannot be passed off as a system
  # insertion (issue #1183, cold review, M2/B1).
} | sed -E 's/<(\/?)(system-reminder|command-[a-z-]*|local-command-?[a-z-]*|ide_selection)>/[\1\2]/g' > "$TMP"
if ! mv "$TMP" "$CHECKPOINT_FILE"; then rm -f "$TMP"; fi

# There is no point accumulating snapshots of old sessions.
find "$CHECKPOINT_DIR" -maxdepth 1 -name 'checkpoint-*.md' -mtime +7 -delete 2>/dev/null
exit 0
