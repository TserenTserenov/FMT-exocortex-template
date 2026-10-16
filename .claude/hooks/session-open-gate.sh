#!/bin/bash
# Session Open Gate (PreToolUse, WP-561, 16.10.2026)
#
# Проблема, которую решает: session-guard.sh's own header claims "mechanical
# enforcement: git pre-commit hook checks for an active semaphore" — but the
# live .git/hooks/pre-commit only runs syntax checks, never session-guard.sh.
# A short/trivial session (explicitly exempt from the full WP Gate Ritual per
# CLAUDE.md §2.1 — "тривиальный вопрос, исправление ≤15 мин") can escalate
# into an actual file edit and `git commit` with zero open semaphore at all:
# found live 16.10.2026, a question-only session committed+pushed a CLAUDE.md
# edit directly to the frozen canonical checkout with no session-guard.sh open
# anywhere in its lifetime — Quick Close then had nothing to close.
#
# What this gate does: the same proven git-commit detection this repo already
# uses (close-runner-gate.sh) — but checks for an open semaphore carrying both
# this session's harness_session_id AND a real `wp: WP-N` field. Missing →
# block, point at `session-guard.sh open --wp WP-N`; session-guard.sh's own
# freeze guard then tells the agent to use an isolated worktree, this gate
# does not re-implement that logic.
#
# Why `--wp` only, not `--housekeeping` (pilot decision 16.10.2026, S-68 in
# STAGING.md): a free-text housekeeping reason isn't tracked anywhere as a
# real work product, so every edit must carry a real WP-N — either the one
# already active, the standing umbrella tech-debt РП (e.g. the author's own
# WP-7), or a new one per the WP Entry Filter (S-47). This also happens to
# already be how `session-guard.sh open --housekeeping` behaves today: that
# path never writes a `harness_session_id:` line at all (confirmed by
# reading its heredoc), so it could never have satisfied this gate anyway —
# the wp: field check below just makes that requirement explicit instead of
# relying on an incidental side effect of a different code path.
#
# What this gate does NOT do: it does not require the semaphore to live in the
# repo being committed to — the semaphore directory is session-scoped, not
# repo-scoped, matching the rest of this hook family. It does not block
# `git commit` run as a subprocess of another tool (process-runner.py etc.) —
# PreToolUse only observes the top-level Bash tool call, same limitation
# close-runner-gate.sh documents for the same reason.
#
# Контракт PreToolUse hook (Claude Code):
# - Stdin: JSON {"tool_name", "tool_input", "session_id", ...}
# - Exit 0 = allow; exit 2 = block (stderr = причина, показывается LLM).

set -uo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$COMMAND" ] || exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
# Same fallback as close-runner-gate.sh (bug-2026-08-31): payload .session_id
# has come back empty while CLAUDE_CODE_SESSION_ID was present and correct.
if [ -z "$SESSION_ID" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  SESSION_ID="$CLAUDE_CODE_SESSION_ID"
fi
[ -n "$SESSION_ID" ] || exit 0
case "$SESSION_ID" in
  *[!A-Za-z0-9._-]*) exit 0 ;;
esac
SESSION_ID_SAFE="$SESSION_ID"

# Same hardened git-commit/push detection as close-runner-gate.sh (Ф74а) —
# reused verbatim, not reinvented, to inherit its evasion coverage.
NORMALIZED_COMMAND=$(printf '%s' "$COMMAND" | tr '\n' ';' | tr -s '[:space:]' ' ')
GIT_GLOBAL_FLAGS_RE='(-C [^ ]+|-c [^ ]+|--(git-dir|work-tree|namespace|exec-path)(=[^ ]+| [^ ]+)|--(literal-pathspecs|glob-pathspecs|noglob-pathspecs|icase-pathspecs|no-optional-locks|no-lazy-fetch|no-replace-objects|no-pager|paginate|bare)|-P)'
echo "$NORMALIZED_COMMAND" | grep -qE "(^|[;&|(]) *(([A-Za-z_][A-Za-z0-9_]*=[^ ]+ *)*)(command |builtin |exec )?git( $GIT_GLOBAL_FLAGS_RE)* (commit|push)( |$)" || exit 0

SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
AGENT="${IWE_AGENT:-claude-code}"
# -x (whole-line match), not a bare -F substring search (close-runner-gate.sh
# ПП-74б/31.08 already hit this exact defect: a shorter session_id that is a
# prefix of a longer one would otherwise match it as a substring).
SEM_MATCHES=$(grep -lxF "harness_session_id: $SESSION_ID" "$SESSION_DIR/${AGENT}"-*.open 2>/dev/null)
WP_BOUND=0
while IFS= read -r sem_file; do
  [ -z "$sem_file" ] && continue
  if grep -qE '^wp: .+' "$sem_file" 2>/dev/null; then
    WP_BOUND=1
    break
  fi
done <<< "$SEM_MATCHES"
[ "$WP_BOUND" = 1 ] && exit 0

echo "[session-open-gate] session=$SESSION_ID_SAFE no semaphore with both harness_session_id: $SESSION_ID and a wp: field (${SESSION_DIR}/${AGENT}-*.open) — blocking direct git commit/push" >&2

cat >&2 <<EOF
🚫 Session Open Gate (WP-561/S-68): прямой git commit/push без привязки к РП заблокирован.

Эта сессия ни разу не открывала себя на конкретный РП — каждая правка обязана
нести номер рабочего продукта, свободная причина без номера не считается.

  bash scripts/session-guard.sh open --wp WP-N --task "..." --agent claude-code

WP-N — РП, который уже обсуждался в этой сессии; если его нет, подойдёт
зонтичный РП техдолга платформы или новый РП по фильтру входа (S-47).

Канонический чекаут может быть заморожен (WP-520/WP-484) — session-guard.sh в
этом случае сам укажет, как перейти в изолированную копию (EnterWorktree /
git worktree add); следовать этой инструкции, не обходить её другим путём.
EOF
exit 2
