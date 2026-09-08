#!/bin/bash
# test-destructive-guard-executed-command-scope.sh — regression corpus for the
# WP-545 narrowing (06.09): destructive-guard.sh must match on the command the
# call actually RUNS, not on the whole text of the call.
#
# The two live false positives that motivated it:
#   1. writing a peer prompt through `cat > "$PROMPT_FILE" <<'PROMPT' … PROMPT`
#      was refused as `rm -rf` — the temp-file cleanup `rm -f "$PROMPT_FILE"`
#      supplied `rm` and `-f`, and another command's `--add-dir` supplied the
#      "recursive" flag;
#   2. a session-close call was refused as `git add .` — the `source` dot of
#      `. "$HOME/…/publish-gate.sh"` two lines below `git add <path>` fell
#      inside the `git add` segment, because a newline was not a separator.
#
# The other half of every case is that nothing got weaker: the same dangerous
# forms, written as commands rather than quoted inside a document, must still
# be refused — including the ones a newline or a shell heredoc could have
# hidden.
#
# Fixture command strings are fed as JSON `tool_input.command`, never embedded
# in this test's own shell commands (same isolation reasoning as the
# neighbouring suites: this guard runs on the test runner's own Bash calls).
#
# Запуск: bash .claude/hooks/tests/test-destructive-guard-executed-command-scope.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/destructive-guard.sh"
WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_DIR=$(mktemp -d)
PASS=0
FAIL=0

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# expect $1=desc $2=want(block|pass) $3=command_text
expect() {
  local desc="$1" want="$2" cmd="$3"
  local input got_exit got err_file="$TMP_DIR/err.$$"
  input=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' \
    "$cmd" "$WORKSPACE_ROOT")
  printf '%s' "$input" | bash "$HOOK" >/dev/null 2>"$err_file"
  got_exit=$?
  if [ "$got_exit" -eq 2 ]; then got="block"; else got="pass"; fi
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc (ожидалось $want, получено $got, exit=$got_exit)"
    echo "  stderr: $(cat "$err_file")"
  fi
}

# === the two live false positives ===
expect "запись промпта в heredoc + уборка своего временного файла НЕ блокируется" pass \
'PROMPT_FILE=$(mktemp)
cat > "$PROMPT_FILE" <<'"'"'PROMPT'"'"'
Ты — напарник в диалоговой сессии.
Задача: проверить архитектурное решение перед реализацией.
PROMPT
cat "$PROMPT_FILE" | bash "$ADAPTER" --add-dir "$SESSION_DIR" > "$PEER_FILE"
rm -f "$PROMPT_FILE"'

expect "git add <path> и source-точка на другой строке НЕ читаются как git add ." pass \
'S=2026-09-06-fmt-delivery-check
SD="$HOME/IWE/MC-sessions"
git -C "$SD" add "2026-09/$S.md"
git -C "$SD" commit -q -m "docs(session): карточка" -- "2026-09/$S.md"
. "$HOME/IWE/DS-strategy/scripts/lib/publish-gate.sh"
push_branch "$SD"'

# === a document that QUOTES a dangerous command is a document ===
expect "heredoc-документ, цитирующий rm -rf, НЕ блокируется" pass \
'cat > /Users/.../IWE/DS-strategy/inbox/bugs/bug.md <<'"'"'EOF'"'"'
Хук сработал на команде rm -rf /Users/.../IWE/DS-strategy/sessions/2026-09
и заблокировал штатную работу.
EOF'

expect "heredoc-документ, цитирующий git add -A, НЕ блокируется" pass \
'cat > /Users/.../IWE/notes.md <<'"'"'EOF'"'"'
Правило: git add -A и git add . запрещены, стейдж только конкретные пути.
EOF'

expect "heredoc-документ, цитирующий psql DROP TABLE, НЕ блокируется" pass \
'cat > /Users/.../IWE/notes.md <<'"'"'EOF'"'"'
Инцидент: psql -c "DROP TABLE learning.events" на проде.
EOF'

expect "python-heredoc с rm внутри регулярки НЕ блокируется" pass \
'python3 - <<'"'"'PY'"'"'
import re
pattern = re.compile(r"(^|\s)rm(\s|$)|-rf")
print(pattern)
PY'

# === same forms, actually executed — still refused ===
expect "настоящий rm -rf по рабочему пути блокируется" block \
'rm -rf /Users/.../IWE/DS-strategy/sessions/2026-09'

expect "rm -rf на третьей строке многострочного вызова блокируется" block \
'mkdir -p /Users/.../IWE/MC-sessions/2026-09
cp a b
rm -rf /Users/.../IWE/DS-strategy/sessions/2026-09'

expect "rm -r -f раздельными флагами блокируется" block \
'rm -r -f /Users/.../IWE/DS-strategy/sessions'

expect "find -exec rm -rf блокируется (rm — исполняемое, не аргумент)" block \
'find /Users/.../IWE/DS-strategy -name tmp -exec rm -rf'

expect "xargs rm -rf блокируется" block \
'ls /Users/.../IWE/DS-strategy | xargs rm -rf'

expect "rm -rf внутри heredoc, скормленного bash, блокируется" block \
'bash <<'"'"'EOF'"'"'
rm -rf /Users/.../IWE/DS-strategy/sessions
EOF'

expect "уборка своего временного файла (rm -f без -r) не блокируется" pass \
'rm -f /Users/.../IWE/DS-strategy/tmp-prompt.txt'

expect "rm -rf в /tmp остаётся штатной уборкой" pass \
'rm -rf /tmp/wp-sync-bundle-512'

# === git staging: the real forms are still refused ===
expect "git add . блокируется" block \
'git add .'

expect "git add -A блокируется" block \
'git -C /Users/.../IWE/MC-sessions add -A'

expect "git add . на второй строке блокируется" block \
'git -C /Users/.../IWE/MC-sessions status --short
git -C /Users/.../IWE/MC-sessions add .'

expect "git add конкретного пути с точкой в имени не блокируется" pass \
'git -C /Users/.../IWE/MC-sessions add 2026-09/2026-09-06-session.md'

# === regressions on the neighbouring checks ===
expect "git reset --hard блокируется" block \
'git -C /Users/.../IWE/PACK-digital-platform reset --hard origin/main'

expect "git push --force блокируется" block \
'git -C /Users/.../IWE push --force origin main'

expect "psql DROP TABLE блокируется" block \
'psql "$DB" -c "DROP TABLE learning.events"'

expect "gh repo delete блокируется" block \
'gh repo delete Owner/Repo --yes'

expect "верхнеуровневый cd блокируется" block \
'cd /Users/.../IWE/DS-strategy && git status'

expect "cd на второй строке блокируется (раньше проскакивал)" block \
'git -C /Users/.../IWE/DS-strategy status
cd /Users/.../IWE/DS-strategy'

expect "(cd ... && ...) в подоболочке остаётся разрешён" pass \
'(cd /Users/.../IWE/DS-strategy && git status --short)'

# === the isolated-commit wrapper: named as an argument is not a launch ===
expect "имя обёртки в аргументе find НЕ блокируется" pass \
'find /Users/.../IWE -maxdepth 4 -name iwe-commit-isolated.sh | head -3'

expect "чтение файла обёртки НЕ блокируется" pass \
'sed -n 1,60p /Users/.../IWE/scripts/iwe-commit-isolated.sh'

expect "запуск обёртки с довеском через && блокируется" block \
'/Users/.../IWE/scripts/iwe-commit-isolated.sh --repo DS-strategy && git push'

expect "одиночный запуск обёртки не блокируется" pass \
'/Users/.../IWE/scripts/iwe-commit-isolated.sh --repo DS-strategy --message "fix"'

# === closed by cold review 06.09: who receives the heredoc body ===
expect "heredoc с DROP TABLE, скормленный psql, блокируется" block \
'psql "$DB" <<'"'"'SQL'"'"'
DROP TABLE learning.events;
SQL'

expect "heredoc с TRUNCATE, скормленный psql, блокируется" block \
'psql "$DB" <<'"'"'SQL'"'"'
TRUNCATE learning.events;
SQL'

expect "heredoc с DELETE без WHERE, скормленный psql, блокируется" block \
'psql "$DB" <<'"'"'SQL'"'"'
DELETE FROM learning.events;
SQL'

expect "heredoc для шелла по абсолютному пути блокируется" block \
'/bin/bash <<'"'"'EOF'"'"'
rm -rf /Users/.../IWE/DS-strategy/sessions
EOF'

expect "heredoc для шелла через ssh блокируется" block \
'ssh host bash <<'"'"'EOF'"'"'
rm -rf /Users/.../IWE/DS-strategy/sessions
EOF'

# === closed by cold review 06.09: wrappers must not take the command slot ===
expect "timeout перед rm -rf блокируется" block \
'timeout 5 rm -rf /Users/.../IWE/DS-strategy/sessions'

expect "nice перед rm -rf блокируется" block \
'nice rm -rf /Users/.../IWE/DS-strategy/sessions'

expect "sudo с опцией перед rm -rf блокируется" block \
'sudo -u nobody rm -rf /Users/.../IWE/DS-strategy/sessions'

expect "env с опцией перед rm -rf блокируется" block \
'env -i rm -rf /Users/.../IWE/DS-strategy/sessions'

expect "xargs с опцией перед rm -rf блокируется" block \
'ls /Users/.../IWE | xargs -n 1 rm -rf'

expect "stdbuf с опцией перед git add . блокируется" block \
'stdbuf -o0 git add .'

expect "timeout перед безобидной командой не блокируется" pass \
'timeout 30 git -C /Users/.../IWE/MC-sessions status --short'

# === the heredoc reduction must not swallow real commands ===
expect "непарный << (сдвиг/проза) не прячет последующий rm -rf" block \
'echo "$(( 1 << 2 ))"
rm -rf /Users/.../IWE/DS-strategy/sessions'

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
