#!/bin/bash
# pull-on-touch.sh — PreToolUse hook: ленивая подтяжка git-репо при первом касании за сессию.
#
# Реализует правило Pull-on-Touch (CLAUDE.md §2 п.5) детерминированно, а не "по памяти агента".
# Причина: правило поведенческое → системно пропускается (инцидент 5 мая 2026 и 14 июня 2026 —
# ложный диагноз "Day Open пропущен" из-за чтения устаревшей локальной копии).
#
# Контракт:
#   Триггер: первое за сессию касание пути под ~/IWE/<repo> любым из инструментов
#            Read | Write | Edit | MultiEdit | NotebookEdit | Bash.
#   Вход:    stdin JSON {tool_name, tool_input, session_id}.
#   Действие: git -C <repo> pull --rebase — один раз на репо на сессию.
#   Отказы:  НИКОГДА не блокирует (exit 0 всегда). Грязное дерево / сетевой сбой / конфликт rebase
#            → pull пропущен, в additionalContext пометка "данные potentially stale".
#   Состояние: ~/.claude/state/repo-pulled-<session>.txt (одно имя репо на строку).

set -uo pipefail

[[ "${1:-}" == "--help" ]] && {
    echo "pull-on-touch.sh — lazy 'git pull --rebase' on first repo touch per session (CLAUDE.md §2 п.5)"
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

warns=""
pulled=""
while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    grep -qxF "$repo" "$STATE_FILE" && continue   # уже трогали этот репо в сессии
    echo "$repo" >> "$STATE_FILE"                  # пометить ДО pull (lazy: одна попытка на сессию)

    dir="$IWE_ROOT/$repo"

    # autostash тянет даже на грязном дереве (прячет правки → rebase → возвращает),
    # поэтому пропуска-на-грязном нет. Считаем стэши до/после, чтобы поймать
    # незавершённый возврат при конфликте и НЕ потерять локальную работу молча.
    stash_before=$(git -C "$dir" stash list 2>/dev/null | wc -l | tr -d ' ')

    if out=$($TO git -C "$dir" pull --rebase --autostash --quiet 2>&1); then
        [ -n "$out" ] && pulled="${pulled}${repo} "
    else
        git -C "$dir" rebase --abort >/dev/null 2>&1 || true   # вернуть репо в исходное состояние
        warns="${warns}${repo}: подтяжка не удалась (сеть/конфликт), данные potentially stale. "
    fi

    stash_after=$(git -C "$dir" stash list 2>/dev/null | wc -l | tr -d ' ')
    if [ "${stash_after:-0}" -gt "${stash_before:-0}" ]; then
        warns="${warns}${repo}: локальные правки не вернулись автоматически (конфликт), лежат в git stash — верни вручную (git -C $dir stash pop). "
    fi
done <<< "$REPOS"

# Сообщить агенту только если есть что сказать (свежие данные или пометка stale).
msg=""
[ -n "$pulled" ] && msg="🔄 Подтянул свежее: ${pulled}"
[ -n "$warns" ] && msg="${msg}⚠️ ${warns}"

if [ -n "$msg" ]; then
    printf '%s' "$msg" | python3 -c 'import sys,json; print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": sys.stdin.read()}}))'
fi

exit 0
