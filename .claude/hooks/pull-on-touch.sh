#!/bin/bash
# pull-on-touch.sh — PreToolUse hook: ленивая подтяжка git-репо при первом касании за сессию.
#
# Реализует правило Pull-on-Touch (CLAUDE.md §2 п.4) детерминированно, а не "по памяти агента".
# Причина: правило поведенческое → системно пропускается (инцидент 5 мая 2026 и 14 июня 2026 —
# ложный диагноз "Day Open пропущен" из-за чтения устаревшей локальной копии).
#
# Контракт:
#   Триггер: первое за сессию касание пути под ~/IWE/<repo> любым из инструментов
#            Read | Write | Edit | MultiEdit | NotebookEdit | Bash.
#   Вход:    stdin JSON {tool_name, tool_input, session_id}.
#   Действие: классификация read-only (scripts/lib/git-sync-status.sh, ls-remote,
#             никогда не трогает stash/rebase/refs) + на заведомо чистом дереве —
#             `git merge --ff-only --no-autostash` — один раз на репо на сессию.
#             НИКОГДА не делает autostash: issue #1245 (16.10.2026, рецидив
#             bug-2026-07-17) — конфликт при возврате стеша тихо топил несохранённые
#             правки, предупреждение было видно только в additionalContext одной сессии.
#   Отказы:  НИКОГДА не блокирует (exit 0 всегда). Грязное дерево / сетевой сбой / история
#            разошлась → подтяжка пропущена, в additionalContext пометка "данные potentially stale".
#   Состояние: ~/.claude/state/repo-pulled-<session>.txt (одно имя репо на строку).

set -uo pipefail

[[ "${1:-}" == "--help" ]] && {
    echo "pull-on-touch.sh — lazy read-only freshness check + safe ff-only fast-forward on first repo touch per session (CLAUDE.md §2 п.4)"
    exit 0
}

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

# Быстрый отсев: нет упоминания репо под IWE → нечего тянуть.
echo "$INPUT" | grep -q "IWE/" || exit 0

IWE_ROOT="${IWE_WORKSPACE:-$HOME/IWE}"

# Имя сессии для файла состояния.
SESSION_ID=$(echo "$INPUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("session_id",""))' 2>/dev/null)
[ -z "$SESSION_ID" ] && SESSION_ID="${CLAUDE_SESSION_ID:-default}"

STATE_DIR="$HOME/.claude/state"
STATE_FILE="$STATE_DIR/repo-pulled-${SESSION_ID}.txt"
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

# Извлечь имена репо (первый сегмент под IWE/) из пути (Read/Edit) или команды (Bash).
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
    grep -qxF "$repo" "$STATE_FILE" && continue   # уже трогали этот репо в сессии
    echo "$repo" >> "$STATE_FILE"                  # пометить ДО pull (lazy: одна попытка на сессию)

    dir="$IWE_ROOT/$repo"
    branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null)

    # Больше никогда не стешит (issue #1245, рецидив bug-2026-07-17): autostash
    # мог конфликтовать на возврате и тихо топить несохранённые правки — в stash,
    # с предупреждением, видимым только в additionalContext этого тул-колла.
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

# Сообщить агенту только если есть что сказать (свежие данные или пометка stale).
msg=""
[ -n "$pulled" ] && msg="🔄 Подтянул свежее: ${pulled}"
[ -n "$warns" ] && msg="${msg}⚠️ ${warns}"

if [ -n "$msg" ]; then
    printf '%s' "$msg" | python3 -c 'import sys,json; print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": sys.stdin.read()}}))'
fi

exit 0
