#!/usr/bin/env bash
# PreToolUse:Bash guard — blocks irreversible git operations regardless of flag order.
# Complements the global rm -rf blocker (which forces `trash`). Exit 2 = block.
set -euo pipefail

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -z "$CMD" ] && exit 0

block() {
  echo "BLOCKED: $1" >&2
  exit 2
}

git_segment() {
  # Return only the shell segment containing `git <global-opts> <subcmd>`.
  # This prevents flags from neighbouring commands (`[ -f file ]`, `rm -f`)
  # from being attributed to `git push`.
  # `(?:\S*\/)?` before `git` (2026-07-23): optional path prefix so
  # `/usr/bin/git push --force` / `./git push --force` are recognised the same
  # as bare `git push --force` — the boundary check previously required git to
  # be preceded by whitespace/`;&|`/start-of-string, which a leading `/…/` defeated.
  local subcmd="$1"
  SUBCMD="$subcmd" perl -ne '
    my $subcmd = quotemeta($ENV{"SUBCMD"});
    while (/(?:^|[;&|]\s*|\s+)((?:\S*\/)?git(?:\s+(?:-C\s+\S+|--git-dir(?:=|\s+)\S+|--work-tree(?:=|\s+)\S+))*\s+$subcmd\b[^;&|]*)/g) {
      print "$1\n";
      exit 0;
    }
  ' <<< "$CMD"
}

is_git_subcmd() {
  [ -n "$(git_segment "$1")" ]
}

# git push --force / -f (allow the safe --force-with-lease)
PUSH_SEGMENT=$(git_segment push)
if [ -n "$PUSH_SEGMENT" ]; then
  PUSH_FORCE_SCAN=$(echo "$PUSH_SEGMENT" | sed -E 's/--force-with-lease(=[^[:space:]]*)?//g')
  if echo "$PUSH_FORCE_SCAN" | grep -qE -- '(^|[[:space:]])(--force([[:space:]]|=|$)|-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$))'; then
    block "git push --force запрещён. Используй --force-with-lease или согласуй с владельцем (CLAUDE.md §2)."
  fi
fi

# git reset --hard
RESET_SEGMENT=$(git_segment reset)
if [ -n "$RESET_SEGMENT" ] && echo "$RESET_SEGMENT" | grep -qE -- '(^|[[:space:]])--hard([[:space:]]|$)'; then
  block "git reset --hard запрещён (теряет незакоммиченное). Используй git stash."
fi

# git clean with delete flags (-f/-d/-x)
CLEAN_SEGMENT=$(git_segment clean)
if [ -n "$CLEAN_SEGMENT" ] && echo "$CLEAN_SEGMENT" | grep -qE -- '(^|[[:space:]])-[a-zA-Z]*[dfx]'; then
  block "git clean -fdx запрещён (удаляет неотслеживаемые файлы). Согласуй с владельцем."
fi

exit 0
