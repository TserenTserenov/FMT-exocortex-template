#!/bin/bash
# pull-on-touch.sh — PreToolUse hook: lazy pull of a git repo on first touch per session.
#
# Implements the Pull-on-Touch rule (CLAUDE.md §2 item 4) deterministically, not "from the agent's memory".
# Reason: the rule is behavioral → systematically skipped (incident of May 5, 2026 and June 14, 2026 —
# a false diagnosis "Day Open skipped" caused by reading a stale local copy).
#
# Contract:
#   Trigger: the first touch per session of a path under ~/IWE/<repo> by any tool
#            Read | Write | Edit | MultiEdit | NotebookEdit | Bash.
#   Input:   stdin JSON {tool_name, tool_input, session_id}.
#   Action: read-only classification (scripts/lib/git-sync-status.sh, ls-remote,
#             never touches stash/rebase/refs) + on a clearly clean tree —
#             `git merge --ff-only --no-autostash` — once per repo per session.
#             NEVER does autostash: issue #1245 (16.10.2026, recurrence of
#             bug-2026-07-17) — a conflict on stash restore silently drowned unsaved
#             edits, the warning was visible only in the additionalContext of a single session.
#   Refusals: NEVER blocks (always exit 0). Dirty tree / network failure / history
#            diverged → pull skipped, a "data potentially stale" note in additionalContext.
#   State: ~/.claude/state/repo-pulled-<session>.txt (one repo name per line).

set -uo pipefail

[[ "${1:-}" == "--help" ]] && {
    echo "pull-on-touch.sh — lazy read-only freshness check + safe ff-only fast-forward on first repo touch per session (CLAUDE.md §2 п.4)"
    exit 0
}

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

# Quick filter: no mention of a repo under IWE → nothing to pull.
echo "$INPUT" | grep -q "IWE/" || exit 0

IWE_ROOT="${IWE_WORKSPACE:-$HOME/IWE}"

# Session name for the state file.
SESSION_ID=$(echo "$INPUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("session_id",""))' 2>/dev/null)
[ -z "$SESSION_ID" ] && SESSION_ID="${CLAUDE_SESSION_ID:-default}"

STATE_DIR="$HOME/.claude/state"
STATE_FILE="$STATE_DIR/repo-pulled-${SESSION_ID}.txt"
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

# Extract repo names (the first segment under IWE/) from a path (Read/Edit) or a command (Bash).
REPOS=$(INPUT="$INPUT" IWE_ROOT="$IWE_ROOT" python3 -c '
import sys, json, re, os
d = json.loads(os.environ["INPUT"])
ti = d.get("tool_input", {}) or {}
blob = (ti.get("file_path") or ti.get("path") or "") + "\n" + (ti.get("command") or "")
root = os.environ["IWE_ROOT"]
seen, out = set(), []
for name in re.findall(r"IWE/([A-Za-z0-9._-]+)", blob):
    if name in seen:
        continue
    seen.add(name)
    if os.path.isdir(os.path.join(root, name, ".git")):
        out.append(name)
print("\n".join(out))
' 2>/dev/null)

[ -z "$REPOS" ] && exit 0

TO=""
command -v timeout >/dev/null 2>&1 && TO="timeout 20"

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/lib/git-sync-status.sh
. "$HOOK_DIR/../../scripts/lib/git-sync-status.sh"

warns=""
pulled=""
while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    grep -qxF "$repo" "$STATE_FILE" && continue   # this repo was already touched in the session
    echo "$repo" >> "$STATE_FILE"                  # mark BEFORE pull (lazy: one attempt per session)

    dir="$IWE_ROOT/$repo"
    branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null)

    # Never stashes anymore (issue #1245, recurrence of bug-2026-07-17): autostash
    # could conflict on restore and silently drown unsaved edits — in the stash,
    # with a warning visible only in the additionalContext of this tool call.
    # Include untracked files even when status.showUntrackedFiles=no is set.
    # A failed status query is not proof of a clean tree. Optional locks are
    # disabled so inspecting another session's index does not refresh it.
    if ! tree_status=$(GIT_OPTIONAL_LOCKS=0 git -C "$dir" status --porcelain --untracked-files=all 2>/dev/null); then
        warns="${warns}${repo}: не удалось проверить несохранённые правки, данные potentially stale. "
        continue
    fi
    if [ -n "$tree_status" ]; then
        warns="${warns}${repo}: есть несохранённые правки, свежее с origin не подтягиваю (чтобы не рисковать ими), данные potentially stale. "
        continue
    fi

    initial_head=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || {
        warns="${warns}${repo}: не удалось определить текущий коммит, данные potentially stale. "
        continue
    }
    check_git_sync_status "$dir" "$branch" 20
    case "$GIT_SYNC_STATUS" in
        OK)
            ;;
        STALE)
            # Fetch does not touch working files, but another session can write
            # while it runs. Recheck the branch, HEAD and tree before merging.
            if ! $TO git -C "$dir" fetch --quiet --refmap= origin "+refs/heads/$branch:refs/remotes/origin/$branch" 2>/dev/null; then
                warns="${warns}${repo}: не удалось получить обновление, данные potentially stale. "
                continue
            fi
            if ! target=$(git -C "$dir" rev-parse "refs/remotes/origin/$branch" 2>/dev/null) \
                || ! tree_status=$(GIT_OPTIONAL_LOCKS=0 git -C "$dir" status --porcelain --untracked-files=all 2>/dev/null) \
                || [ -n "$tree_status" ] \
                || [ "$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null)" != "$branch" ] \
                || [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$initial_head" ]; then
                warns="${warns}${repo}: состояние изменилось или не проверено после fetch, обновление пропущено, данные potentially stale. "
                continue
            fi
            # The final check cannot exclude a later concurrent write. Explicitly
            # disable config-driven autostash so Git refuses overlapping edits
            # instead of stashing them and reporting success after a failed pop.
            if git -C "$dir" merge --ff-only --no-autostash --no-overwrite-ignore --quiet "$target" 2>/dev/null; then
                pulled="${pulled}${repo} "
            else
                warns="${warns}${repo}: подтяжка не удалась (конфликт при обновлении ветки), данные potentially stale. "
            fi
            ;;
        *)
            warns="${warns}${repo}: подтяжка не удалась ($GIT_SYNC_STATUS), данные potentially stale. "
            ;;
    esac
done <<< "$REPOS"

# Tell the agent only if there is something to say (fresh data or a stale note).
msg=""
[ -n "$pulled" ] && msg="🔄 Подтянул свежее: ${pulled}"
[ -n "$warns" ] && msg="${msg}⚠️ ${warns}"

if [ -n "$msg" ]; then
    printf '%s' "$msg" | python3 -c 'import sys,json; print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": sys.stdin.read()}}))'
fi

exit 0
