#!/bin/bash
# pull-on-touch.sh — PreToolUse hook: lazy pull git-repo on first touch in the session.
#
# Implements the rule Pull-on-Touch (CLAUDE.md §2 p.5) deterministically, and not "from agent memory".
# Reason: the rule is behavioral → systematically skipped (incident 5 May 2026 and 14 June 2026 —
# false diagnosis "Day Open was skipped" due to-reading a stale local copy).
#
# Contract:
#   Trigger: first touch in the session of a path under ~/IWE/<repo> by any of the tools
#            Read | Write | Edit | MultiEdit | NotebookEdit | Bash.
#   Input:    stdin JSON {tool_name, tool_input, session_id}.
#   Action: classification read-only (scripts/lib/git-sync-status.sh, ls-remote,
#             never touches stash/rebase/refs) + on a provably clean working tree —
#             atomic `git merge --ff-only` — once per repo per session.
#             NEVER performs autostash: issue #1245 (16.10.2026, recurrence
#             bug-2026-07-17) — conflict on stash pop silently destroyed unsaved
#             edits, the warning was visible only in additionalContext of one session.
#   Failures::  NEVER blocks (exit 0 always). Dirty tree / network failure / history
#            has diverged → pull skipped, in additionalContext note "data potentially stale".
#   State:: ~/.claude/state/repo-pulled-<session>.txt (one repo name per line).

set -uo pipefail

[[ "${1:-}" == "--help" ]] && {
    echo "pull-on-touch.sh — lazy read-only freshness check + safe ff-only fast-forward on first repo touch per session (CLAUDE.md §2 p.5)"
    exit 0
}

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

# Quick filter:: no repo under IWE mentioned IWE → nothing to pull.
echo "$INPUT" | grep -q "IWE/" || exit 0

IWE_ROOT="${IWE_WORKSPACE:-$HOME/IWE}"

# Session name for the state file.
SESSION_ID=$(echo "$INPUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("session_id",""))' 2>/dev/null)
[ -z "$SESSION_ID" ] && SESSION_ID="${CLAUDE_SESSION_ID:-default}"

STATE_DIR="$HOME/.claude/state"
STATE_FILE="$STATE_DIR/repo-pulled-${SESSION_ID}.txt"
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

# Extract repo names (first path segment under IWE/) from path (Read/Edit) or command (Bash).
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

    # Will never autostash again (issue #1245, recurrence bug-2026-07-17): autostash
    # could conflict on pop and silently destroy unsaved edits — in stash,
    # with a warning, visible only in additionalContext of this tool-call.
    # Now:: dirty tree (tracked OR untracked) — do not touch the repo at all,
    # to avoid risking local work. Clean tree — we classify
    # read-only (ls-remote, same library, as Sync Gate) and advance the branch
    # only with the atomic `merge --ff-only`: it either cleanly advances HEAD, or
    # fails without side effects — no intermediate state exists.
    if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
        warns="${warns}${repo}: there are unsaved edits, fresh from origin not pulling (to avoid risking them), data potentially stale. "
        continue
    fi

    check_git_sync_status "$dir" "$branch" 20
    case "$GIT_SYNC_STATUS" in
        OK)
            ;;
        STALE)
            # Single-ref fetch, not the library's "never fetch" guarantee: we
            # need the new commit object locally before `merge --ff-only` can
            # use it. Narrower than a full fetch, and `&&`-gated — a concurrent
            # session's lock on the same ref surfaces as the warning below,
            # not as a partial state.
            if $TO git -C "$dir" fetch --quiet origin "$branch" 2>/dev/null \
                && git -C "$dir" merge --ff-only --quiet "origin/$branch" 2>/dev/null; then
                pulled="${pulled}${repo} "
            else
                warns="${warns}${repo}: pull failed (network/conflict while updating branch), data potentially stale. "
            fi
            ;;
        *)
            warns="${warns}${repo}: pull failed ($GIT_SYNC_STATUS), data potentially stale. "
            ;;
    esac
done <<< "$REPOS"

# Notify the agent only if there is something to say (fresh data or stale marker stale).
msg=""
[ -n "$pulled" ] && msg="🔄 Pulled fresh: ${pulled}"
[ -n "$warns" ] && msg="${msg}⚠️ ${warns}"

if [ -n "$msg" ]; then
    printf '%s' "$msg" | python3 -c 'import sys,json; print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": sys.stdin.read()}}))'
fi

exit 0
