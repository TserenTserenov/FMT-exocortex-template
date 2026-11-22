#!/bin/bash
# PreCompact Checkpoint Hook (issue #1183)
# Event: PreCompact
# Before compacting the context, takes a snapshot of the working state. It will be returned to the agent by
# hook precompact-restore.sh on the event SessionStart (matcher "compact").
#
# Why this approach: PreCompact does not have a channel to the model — Claude Code discards it
# systemMessage/continue, additionalContext is not supported for it
# (https://code.claude.com/docs/en/hooks). Therefore nothing is printed here:
# the hook only writes a file, delivery — on SessionStart after compaction.
#
# The snapshot contains user and assistant messages — storing it in the repository
# is unsafe: `.gitignore`, with which it is marked in the template, update.sh delivers
# not available on all installations (issue #1183, cold review). That is why the file resides in
# personal directory Claude Code, not in the project working copy.
export LC_ALL=C

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
# Invalid/long identifier is rejected, not sanitized: otherwise "a/b" and
# "ab" would produce the same file, and id thousands of characters long would cause mv to fail mv (ENAMETOOLONG).
case "$SESSION_ID" in '' | *[!A-Za-z0-9_-]* ) exit 0 ;; esac
[ "${#SESSION_ID}" -le 128 ] || exit 0

TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
TRIGGER=$(printf '%s' "$INPUT" | jq -r '.trigger // "unknown"' 2>/dev/null)
CHECKPOINT_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/iwe-checkpoints"
mkdir -p "$CHECKPOINT_DIR" 2>/dev/null || exit 0
chmod 700 "$CHECKPOINT_DIR" 2>/dev/null
CHECKPOINT_FILE="$CHECKPOINT_DIR/checkpoint-$SESSION_ID.md"

# Transcript tail: the most recent user messages and the last assistant response.
# JSONL parsed leniently (fromjson?, not piped into jq as a whole): "tail -n" may
# return an incompletely written last line from a concurrently writing process, and one
# malformed JSON must not abort parsing of the entire tail.
USER_TAIL=""
ASSISTANT_TAIL=""
if [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ]; then
  RECENT=$(tail -n 400 "$TRANSCRIPT" 2>/dev/null)
  # Filter for system injections — at the level of EACH text-block, not the concatenated
  # message: Claude Code appends <system-reminder> as a separate second
  # block of the same user message, and a filter on the beginning of the line after
  # join join does not catch it (issue #1183, cold review, M2).
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
  echo "# Checkpoint before context compaction"
  echo "- Session: $SESSION_ID"
  echo "- Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- Compaction reason: $TRIGGER"
  echo
  echo "## Recent user requests"
  if [ -n "$USER_TAIL" ]; then printf '%s\n' "$USER_TAIL" | sed 's/^/- /'; else echo "- (could not read transcript)"; fi
  echo
  echo "## Last assistant response"
  if [ -n "$ASSISTANT_TAIL" ]; then printf '%s\n' "$ASSISTANT_TAIL"; else echo "(could not read transcript)"; fi
  # Defense in depth: even after filtering blocks above we neutralize any remaining
  # similar tags, so that the output of the restore hook cannot be passed off as a system restore-hook output cannot be passed off as a system
  # injection (issue #1183, cold review, M2/B1).
} | sed -E 's/<(\/?)(system-reminder|command-[a-z-]*|local-command-?[a-z-]*|ide_selection)>/[\1\2]/g' > "$TMP"
if ! mv "$TMP" "$CHECKPOINT_FILE"; then rm -f "$TMP"; fi

# There is no need to accumulate snapshots of old sessions.
find "$CHECKPOINT_DIR" -maxdepth 1 -name 'checkpoint-*.md' -mtime +7 -delete 2>/dev/null
exit 0
