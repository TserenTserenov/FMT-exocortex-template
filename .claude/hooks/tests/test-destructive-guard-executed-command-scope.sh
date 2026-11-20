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
# Run: bash .claude/hooks/tests/test-destructive-guard-executed-command-scope.sh

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

# issue #940: a temporary path anywhere in the call text no longer excuses a recursive forced
# rm (the target depends on variables, cd and links known only at run time). The same removal
# goes through .claude/bin/guarded-rm, which checks the real path when it runs.
expect "rm -rf в /tmp блокируется: удаление идёт через guarded-rm (issue #940)" block \
'rm -rf /tmp/wp-sync-bundle-512'

expect "путь /tmp в соседней команде не освобождает rm -rf (issue #940)" block \
'rm -rf /important; ls /tmp/'

expect "guarded-rm с теми же ключами проходит (issue #940)" pass \
'.claude/bin/guarded-rm -rf /tmp/wp-sync-bundle-512'

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

# === WP-529 F275, rc.6 red team F3: a backslash that ends the call escapes nothing ===
# bash, zsh and sh drop it and run the command; the guard used to keep it glued to the last word.
expect "F3: git push --force с обратной косой в конце блокируется" block \
'git push --force\'
expect "F3: git push --force с обратной косой и переводом строки в конце блокируется" block \
'git push --force\
'
expect "F3: git reset --hard с обратной косой в конце блокируется" block \
'git reset --hard\'
expect "F3: find -delete с обратной косой в конце блокируется" block \
'find . -name x -delete\'
expect "F3: git remote update --prune с обратной косой и переводом строки блокируется" block \
'git remote update --prune\
'
expect "F3: git branch --unset-upstream после переноса и с обратной косой в конце блокируется" block \
'git -C repo \
  branch --unset-upstream\'
expect "F3: экранированная обратная коса в конце остаётся словом, безобидная команда проходит" pass \
'git log --format=%h -1 -- a\\'

# === WP-529 F275, rc.6 red team F4: `<<` inside an expansion is not a here-doc ===
# The guard dropped the lines up to WORD as a data body; bash runs them.
expect "F4: << внутри \${…} не прячет git push --force" block \
'ls ${x:-<<ls}
git push --force
ls'
expect "F4: << внутри \$((…)) не прячет rm -rf" block \
'ls $((1<<ls))
rm -rf /Users/.../IWE/DS-strategy/sessions
ls'
expect "F4: << внутри \$[…] не прячет git reset --hard" block \
'ls $[1<<ls]
git reset --hard
ls'
expect "F4: << внутри ((…)) не прячет find -delete" block \
'(( a = 1<<ls ))
find . -delete
ls'
expect "F4: << внутри if ((…)) не прячет git branch -D" block \
'if (( 1<<ls )); then :; fi
git branch -D main
ls'
expect "F4: << внутри вложенного \${…} не прячет запись в settings.json" block \
'ls ${x:-${y:-<<ls}}
cat README.md > .claude/settings.json
ls'
expect "F4: \$((…)) на двух строках с << не прячет git push --force" block \
'echo $((1+
1<<ls))
git push --force
ls'
expect "F4: настоящий here-doc после \$((…)) и \${…} остаётся данными" pass \
'x=${y:-1}; echo $((1<<2)); cat <<EOF
git push --force
EOF'


# === WP-529 F275, rc.8 red team F5/F6: comments, quotes and expansions around `<<` ===
# A backslash ending a comment line is part of the comment; `<<` in a comment, an array subscript,
# for((/if((, or a $(…) closed on its line opens no here-doc; quotes of $'…' and "${…"…"}" nest.
# A lone backslash ending a script run by another shell is dropped by that shell.
expect 'F5: два << в $((…)), затем комментарий с обратной косой — git push --force' block \
': $((1<<true)) $((1<<true))
# c \
git push --force
true'
expect 'F5: три << в разных подстановках, затем комментарий с обратной косой — find -delete' block \
': $((1<<true)) ${x:-<<true} $[1<<true]
# c \
find . -delete
true'
expect 'F5: то же — git branch -D' block \
': $((1<<true)) $((1<<true))
# c \
git branch -D main
true'
expect 'F6: обратная коса в конце комментария не склеивает следующую строку' block \
': # c \
git push --force'
expect 'F6: строка-комментарий с обратной косой, затем rm -rf' block \
'# c \
rm -rf /Users/.../IWE/DS-strategy/sessions'
expect 'F6: << в комментарии не открывает here-doc' block \
': # <<true
data \
true
git push --force
true'
expect 'F6: кавычка в комментарии, затем << в кавычках' block \
': # '"'"'
echo '"'"'<<EOF'"'"'
git push --force
EOF'
expect 'F6: $'"'"'…'"'"' с экранированной кавычкой и <<' block \
'echo $'"'"'\'"'"'<<EOF'"'"'
git push --force
EOF'
expect 'F6: вложенные кавычки в "${…}"' block \
'echo "${x:-"<<EOF"}"
git push --force
EOF'
expect 'F6: << в индексе массива' block \
'x[1<<EOF]=5
git push --force
EOF'
expect 'F6: << в составном присваивании массива' block \
'x=([1<<true]=5)
find . -delete
true'
expect 'F6: for(( без пробела' block \
'for((i=1<<EOF;i<1;i++)); do :; done
git push --force
EOF'
expect 'F6: if(( без пробела' block \
'if((1<<EOF)); then :; fi
git branch -D main
EOF'
expect 'F6: here-doc внутри $(…), закрытой на той же строке' block \
': $( (:) <<true )
git push --force
true'
expect 'F6: $((1)<<…) — это $( (1)<<… )' block \
': $((1)<<true)
data \
true
git push --force
true'
expect 'F6: комментарий в обратных кавычках' block \
'echo `# '"'"'`; echo '"'"'<<EOF'"'"'
git push --force
EOF'
expect 'F6: ${#x} не начинает комментарий' block \
': ${#x} ; git push --force'
expect 'F6: bash -c с обратной косой в конце' block \
'bash -c '"'"'git push --force\'"'"''
expect 'F6: eval с обратной косой в конце' block \
'eval '"'"'git branch --unset-upstream\'"'"''
expect 'F6: тело bash <<'"'"'EOF'"'"' с обратной косой в конце' block \
'bash <<'"'"'EOF'"'"'
find . -delete\
EOF'
expect 'F6: here-string для bash' block \
'bash <<< '"'"'git push --force\'"'"''
expect 'F6: printf | sh с обратной косой в конце' block \
'printf '"'"'%s'"'"' '"'"'git push --force\'"'"' | sh'
expect 'F6 контроль: настоящий here-doc с данными проходит' pass \
'cat <<EOF
git push --force
EOF'
expect 'F6 контроль: ${#arr[@]} проходит' pass \
'echo ${#arr[@]}'
expect 'F6 контроль: безобидная here-string для bash проходит' pass \
'bash <<< '"'"'ls'"'"''
expect 'F6 контроль: комментарий с обратной косой перед безобидной командой проходит' pass \
'# c \
git status'


# === WP-529 F275, rc.10 red team F8/F11: readings that disagree about quote state ===
# The parser of this hook and the released guards in destructive-guard.d/ read these texts
# differently; each reading is judged on its own and the strictest verdict wins.
expect 'F8: : x[ <<W, тело с открытой кавычкой, затем find .' block \
': x[ <<W
echo '"'"'a
W
find . -delete'
expect 'F8: : x[ <<W, тело с открытой кавычкой, затем rm -rf' block \
': x[ <<W
echo '"'"'a
W
rm -rf /Users/.../IWE/DS-strategy/sessions'
expect 'F8: : x[ <<W, тело с открытой кавычкой, затем git push' block \
': x[ <<W
echo '"'"'a
W
git push --force'
expect 'F8: : x[ <<W, тело с открытой кавычкой, затем git reset' block \
': x[ <<W
echo '"'"'a
W
git reset --hard'
expect 'F8: : x[ <<W, тело с открытой кавычкой, затем git clean' block \
': x[ <<W
echo '"'"'a
W
git clean -fdx'
expect 'F8: : x[ <<W, тело с открытой кавычкой, затем git branch' block \
': x[ <<W
echo '"'"'a
W
git branch -D main'
expect 'F8: : x[ <<W, тело с открытой кавычкой, затем git add' block \
': x[ <<W
echo '"'"'a
W
git add -A'
expect 'F8: cat notes[ <<W, тело с открытой кавычкой, затем find .' block \
'cat notes[ <<W
echo '"'"'a
W
find . -delete'
expect 'F8: cat notes[ <<W, тело с открытой кавычкой, затем rm -rf' block \
'cat notes[ <<W
echo '"'"'a
W
rm -rf /Users/.../IWE/DS-strategy/sessions'
expect 'F8: cat notes[ <<W, тело с открытой кавычкой, затем git push' block \
'cat notes[ <<W
echo '"'"'a
W
git push --force'
expect 'F8: cat notes[ <<W, тело с открытой кавычкой, затем git reset' block \
'cat notes[ <<W
echo '"'"'a
W
git reset --hard'
expect 'F8: cat notes[ <<W, тело с открытой кавычкой, затем git clean' block \
'cat notes[ <<W
echo '"'"'a
W
git clean -fdx'
expect 'F8: cat notes[ <<W, тело с открытой кавычкой, затем git branch' block \
'cat notes[ <<W
echo '"'"'a
W
git branch -D main'
expect 'F8: cat notes[ <<W, тело с открытой кавычкой, затем git add' block \
'cat notes[ <<W
echo '"'"'a
W
git add -A'
expect 'F8: : a\ #b <<W, тело с открытой кавычкой, затем find .' block \
': a\ #b <<W
echo '"'"'a
W
find . -delete'
expect 'F8: : a\ #b <<W, тело с открытой кавычкой, затем rm -rf' block \
': a\ #b <<W
echo '"'"'a
W
rm -rf /Users/.../IWE/DS-strategy/sessions'
expect 'F8: : a\ #b <<W, тело с открытой кавычкой, затем git push' block \
': a\ #b <<W
echo '"'"'a
W
git push --force'
expect 'F8: : a\ #b <<W, тело с открытой кавычкой, затем git reset' block \
': a\ #b <<W
echo '"'"'a
W
git reset --hard'
expect 'F8: : a\ #b <<W, тело с открытой кавычкой, затем git clean' block \
': a\ #b <<W
echo '"'"'a
W
git clean -fdx'
expect 'F8: : a\ #b <<W, тело с открытой кавычкой, затем git branch' block \
': a\ #b <<W
echo '"'"'a
W
git branch -D main'
expect 'F8: : a\ #b <<W, тело с открытой кавычкой, затем git add' block \
': a\ #b <<W
echo '"'"'a
W
git add -A'
expect 'F8: : $(:)#b <<W, тело с открытой кавычкой, затем find .' block \
': $(:)#b <<W
echo '"'"'a
W
find . -delete'
expect 'F8: : $(:)#b <<W, тело с открытой кавычкой, затем rm -rf' block \
': $(:)#b <<W
echo '"'"'a
W
rm -rf /Users/.../IWE/DS-strategy/sessions'
expect 'F8: : $(:)#b <<W, тело с открытой кавычкой, затем git push' block \
': $(:)#b <<W
echo '"'"'a
W
git push --force'
expect 'F8: : $(:)#b <<W, тело с открытой кавычкой, затем git reset' block \
': $(:)#b <<W
echo '"'"'a
W
git reset --hard'
expect 'F8: : $(:)#b <<W, тело с открытой кавычкой, затем git clean' block \
': $(:)#b <<W
echo '"'"'a
W
git clean -fdx'
expect 'F8: : $(:)#b <<W, тело с открытой кавычкой, затем git branch' block \
': $(:)#b <<W
echo '"'"'a
W
git branch -D main'
expect 'F8: : $(:)#b <<W, тело с открытой кавычкой, затем git add' block \
': $(:)#b <<W
echo '"'"'a
W
git add -A'
expect 'F10: (( сразу после )' block \
'f()((1<<W))
find . -delete
W'
expect 'F10: (( после case-метки' block \
'case x in x)((1<<W));; esac
git push --force
W'
expect 'F10: << внутри <(…)' block \
': <(: <<W)
find . -delete
W'
expect 'F10: << внутри >(…)' block \
': >(: <<'"'"'W'"'"')
git push --force
W'
expect 'F10: $( с here-doc, закрытая на следующей строке' block \
': $( : <<W
)
find . -delete
W'
expect 'F10: обратные кавычки с here-doc, закрытые на следующей строке' block \
': `: <<W
`
git push --force
W'
expect 'F10: << в литерале массива с комментарием' block \
'x=(a <<W #b
find . -delete
W'
expect 'F10: here-string, затем комментарий' block \
': x<<<W #b
find . -delete
W'
expect 'F10: here-string и here-doc для bash, обратная коса в теле' block \
'bash <<< '"'"'x'"'"' <<'"'"'W'"'"'
git push --force\
W'
expect 'F8 контроль: настоящий here-doc с открытой кавычкой в теле остаётся данными' pass \
'cat <<W
echo '"'"'a
W
git status'


# === WP-529 F275, rc.11 red team F13: texts rc.10 blocked and rc.11 let through ===
# An unterminated quote or substitution after a fake here-doc: the shell runs nothing, rc.10
# blocked; the released rc.10 in destructive-guard.d/ keeps that verdict.
expect 'F13 m66: строже, как в rc.10' block \
': a\ #b <<W
W
: "${x:-
git reset --hard
W
)'
expect 'F13 m74: строже, как в rc.10' block \
'cat notes[ <<W
x
W
echo "x
W
git reset --hard
W
)'
expect 'F13 m175: строже, как в rc.10' block \
'cat notes[ <<W
x
W
echo '"'"'x
git reset --hard
	W
)'
expect 'F13 m196: строже, как в rc.10' block \
': $(:)#b <<W
W
echo "x`
git reset --hard
'
expect 'F13 m47: строже, как в rc.10' block \
': a\ #b <<W
W
echo "x
git reset --hard
'"'"''
expect 'F13 m166: строже, как в rc.10' block \
'cat notes[ <<W
x
W
echo "$(
git reset --hard
'
expect 'F13 m59: строже, как в rc.10' block \
'cat notes[ <<W
x
W
echo '"'"'x
git reset --hard
W
)'
expect 'F13 m170: строже, как в rc.10' block \
'cat notes[ <<W
W
echo '"'"'x
git reset --hard
)"'
expect 'F13 m37: строже, как в rc.10' block \
': ${x:-<<W}
W
echo "x
W`
git reset --hard
W
`'
expect 'F13 m57: строже, как в rc.10' block \
': x[ <<W
W
echo '"'"'x
git reset --hard
	W'
expect 'F13 m164: строже, как в rc.10' block \
'cat notes[ <<W
x
W
: "${x:-
git reset --hard
W
)'
expect 'F13 m187: строже, как в rc.10' block \
'cat notes[ <<W
x
W
: "${x:-
git reset --hard
W
`'
expect 'F13 m194: строже, как в rc.10' block \
': # <<W
W
echo "x`
git reset --hard
	W
)'
expect 'F13 m33: строже, как в rc.10' block \
'cat notes[ <<W
x
W
echo "x`
git reset --hard
	W
)'
expect 'F13 m18: строже, как в rc.10' block \
': $(:)#b <<W
W
echo "x
W
git reset --hard
)'
expect 'F13 m136: строже, как в rc.10' block \
': ${x:-<<W}
W
echo "x
W`
git reset --hard
W
)'
expect 'F13 m54: строже, как в rc.10' block \
'cat notes[ <<W
x
W
echo "x
W`
git reset --hard
)'
expect 'F13 m75: строже, как в rc.10' block \
': x[ <<W
W
echo "x
git reset --hard
'"'"''
expect 'F13 m7: строже, как в rc.10' block \
': $(:)#b <<W
W
echo "x`
git reset --hard
`'
expect 'F13 m110: строже, как в rc.10' block \
': ${x:-<<W}
W
echo '"'"'x
git reset --hard
`"'
expect 'F13 m32: строже, как в rc.10' block \
': $(:)#b <<W
W
echo "x
git reset --hard
	W
)'
expect 'F13 m195: строже, как в rc.10' block \
'cat notes[ <<W
W
echo "$(
git reset --hard
)'
expect 'F13 m155: строже, как в rc.10' block \
'cat notes[ <<W
W
echo "x
W
git reset --hard
'
expect 'F13 m3: строже, как в rc.10' block \
': x[ <<W
W
echo '"'"'x
git reset --hard
)"'


# === WP-529 F275, rc.12 red team F16: CR characters around here-docs ===
# Every CR variant of the generated set that rc.12 let through while bash, sh or zsh run the last
# command. Written with $'...' so the CRs survive the LF normalisation of .gitattributes.
expect 'F16 cr858: CR у here-doc, bash,sh,zsh' block \
$'let a=1<<W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr861: CR у here-doc, bash,sh,zsh' block \
$'let a=1<<W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1155: CR у here-doc, bash,sh,zsh' block \
$': a#<<W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1158: CR у here-doc, bash,sh,zsh' block \
$': a#<<W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1391: CR у here-doc, bash,sh,zsh' block \
$'(:)<<W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1394: CR у here-doc, bash,sh,zsh' block \
$'(:)<<W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1402: CR у here-doc, bash,sh,zsh' block \
$': <<W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1405: CR у here-doc, bash,sh,zsh' block \
$': <<W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1413: CR у here-doc, bash,sh,zsh' block \
$'cat <<W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1416: CR у here-doc, bash,sh,zsh' block \
$'cat <<W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1424: CR у here-doc, bash,sh,zsh' block \
$': <<-W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1427: CR у here-doc, bash,sh,zsh' block \
$': <<-W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1435: CR у here-doc, bash,sh,zsh' block \
$': <<\'W\'\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1438: CR у here-doc, bash,sh,zsh' block \
$': <<\'W\'\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1446: CR у here-doc, bash,sh,zsh' block \
$': <<"W"\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1449: CR у here-doc, bash,sh,zsh' block \
$': <<"W"\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1457: CR у here-doc, bash,sh,zsh' block \
$': <<\\W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1460: CR у here-doc, bash,sh,zsh' block \
$': <<\\W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1468: CR у here-doc, bash,sh,zsh' block \
$': 2<<W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1471: CR у here-doc, bash,sh,zsh' block \
$': 2<<W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1490: CR у here-doc, bash,sh,zsh' block \
$': ${x:-}<<W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1493: CR у here-doc, bash,sh,zsh' block \
$': ${x:-}<<W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1501: CR у here-doc, bash,sh,zsh' block \
$': $((1))<<W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1504: CR у here-doc, bash,sh,zsh' block \
$': $((1))<<W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1512: CR у here-doc, bash,sh,zsh' block \
$': $[1]<<W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1515: CR у here-doc, bash,sh,zsh' block \
$': $[1]<<W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1523: CR у here-doc, bash,sh,zsh' block \
$'((a=1))<<W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1526: CR у here-doc, bash,sh,zsh' block \
$'((a=1))<<W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1534: CR у here-doc, bash,sh,zsh' block \
$': ${x:-} <<W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1537: CR у here-doc, bash,sh,zsh' block \
$': ${x:-} <<W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1545: CR у here-doc, bash,sh,zsh' block \
$': $((1)) <<W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1548: CR у here-doc, bash,sh,zsh' block \
$': $((1)) <<W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1611: CR у here-doc, bash,sh' block \
$': } <<W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1614: CR у here-doc, bash,sh' block \
$': } <<W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1622: CR у here-doc, bash,sh,zsh' block \
$': ]] <<W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1625: CR у here-doc, bash,sh,zsh' block \
$': ]] <<W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1754: CR у here-doc, bash,sh,zsh' block \
$'integer a=1<<W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1757: CR у here-doc, bash,sh,zsh' block \
$'integer a=1<<W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1809: CR у here-doc, bash,sh' block \
$': x[ <<W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1812: CR у here-doc, bash,sh' block \
$': x[ <<W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1820: CR у here-doc, bash,sh,zsh' block \
$'cat notes[ <<W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1823: CR у here-doc, bash,sh,zsh' block \
$'cat notes[ <<W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1831: CR у here-doc, bash,sh,zsh' block \
$': a\\ #b <<W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1834: CR у here-doc, bash,sh,zsh' block \
$': a\\ #b <<W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1842: CR у here-doc, bash,sh,zsh' block \
$': $(:)#b <<W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1845: CR у here-doc, bash,sh,zsh' block \
$': $(:)#b <<W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1853: CR у here-doc, bash,sh,zsh' block \
$': `:`#b <<W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1856: CR у here-doc, bash,sh,zsh' block \
$': `:`#b <<W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1919: CR у here-doc, bash,sh,zsh' block \
$'cat <<\'W\'\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1922: CR у here-doc, bash,sh,zsh' block \
$'cat <<\'W\'\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1930: CR у here-doc, bash,sh,zsh' block \
$'cat <<-W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1933: CR у here-doc, bash,sh,zsh' block \
$'cat <<-W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 cr1941: CR у here-doc, bash,sh,zsh' block \
$'bash <<W\r\necho \'a\r\nW\r\nfind . -delete'
expect 'F16 cr1944: CR у here-doc, bash,sh,zsh' block \
$'bash <<W\r\necho \'a\nW\r\nfind . -delete'
expect 'F16 контроль: here-doc с CR в данных остаётся данными' pass \
$'cat > /tmp/n <<\'EOF\'\r\ndon\'t\r\nEOF\r\n'

# === WP-529 F275, rc.14 red team F18/F19: the here-doc delimiter is the whole word, as bash reads it ===
# One row per delimiter word of the shell-truth search that rc.14 let through (bash, sh or zsh run the
# last line), the realistic rows of the red team, and substitutions in an unquoted body (F19).
expect 'F18 dl0: ограничитель bash,sh,zsh' block \
$'cat <<!W\necho \'a\n!W\nfind . -delete'
expect 'F18 dl8: ограничитель bash,sh,zsh' block \
$'cat <<W!x\necho \'a\nW!x\nfind . -delete'
expect 'F18 dl16: ограничитель bash,sh,zsh' block \
$'cat <<W!\necho \'a\nW!\nfind . -delete'
expect 'F18 dl56: ограничитель bash,sh,zsh' block \
$'cat <<W#x\necho \'a\nW#x\nfind . -delete'
expect 'F18 dl64: ограничитель bash,sh,zsh' block \
$'cat <<W#\necho \'a\nW#\nfind . -delete'
expect 'F18 dl72: ограничитель bash,sh,zsh' block \
$'cat <<$W\necho \'a\n$W\nfind . -delete'
expect 'F18 dl80: ограничитель bash,sh,zsh' block \
$'cat <<W$x\necho \'a\nW$x\nfind . -delete'
expect 'F18 dl88: ограничитель bash,sh,zsh' block \
$'cat <<W$\necho \'a\nW$\nfind . -delete'
expect 'F18 dl96: ограничитель bash,sh,zsh' block \
$'cat <<%W\necho \'a\n%W\nfind . -delete'
expect 'F18 dl104: ограничитель bash,sh,zsh' block \
$'cat <<W%x\necho \'a\nW%x\nfind . -delete'
expect 'F18 dl112: ограничитель bash,sh,zsh' block \
$'cat <<W%\necho \'a\nW%\nfind . -delete'
expect 'F18 dl216: ограничитель bash,sh,zsh' block \
$'cat <<*W\necho \'a\n*W\nfind . -delete'
expect 'F18 dl224: ограничитель bash,sh,zsh' block \
$'cat <<W*x\necho \'a\nW*x\nfind . -delete'
expect 'F18 dl232: ограничитель bash,sh,zsh' block \
$'cat <<W*\necho \'a\nW*\nfind . -delete'
expect 'F18 dl240: ограничитель bash,sh,zsh' block \
$'cat <<+W\necho \'a\n+W\nfind . -delete'
expect 'F18 dl248: ограничитель bash,sh,zsh' block \
$'cat <<W+x\necho \'a\nW+x\nfind . -delete'
expect 'F18 dl256: ограничитель bash,sh,zsh' block \
$'cat <<W+\necho \'a\nW+\nfind . -delete'
expect 'F18 dl264: ограничитель bash,sh,zsh' block \
$'cat <<,W\necho \'a\n,W\nfind . -delete'
expect 'F18 dl272: ограничитель bash,sh,zsh' block \
$'cat <<W,x\necho \'a\nW,x\nfind . -delete'
expect 'F18 dl280: ограничитель bash,sh,zsh' block \
$'cat <<W,\necho \'a\nW,\nfind . -delete'
expect 'F18 dl292: ограничитель bash,sh,zsh' block \
$'cat <<--W\n\techo \'a\n\t-W\nfind . -delete'
expect 'F18 dl296: ограничитель bash,sh,zsh' block \
$'cat <<W-x\necho \'a\nW-x\nfind . -delete'
expect 'F18 dl304: ограничитель bash,sh,zsh' block \
$'cat <<W-\necho \'a\nW-\nfind . -delete'
expect 'F18 dl312: ограничитель bash,sh,zsh' block \
$'cat <<.W\necho \'a\n.W\nfind . -delete'
expect 'F18 dl320: ограничитель bash,sh,zsh' block \
$'cat <<W.x\necho \'a\nW.x\nfind . -delete'
expect 'F18 dl328: ограничитель bash,sh,zsh' block \
$'cat <<W.\necho \'a\nW.\nfind . -delete'
expect 'F18 dl336: ограничитель bash,sh,zsh' block \
$'cat <</W\necho \'a\n/W\nfind . -delete'
expect 'F18 dl344: ограничитель bash,sh,zsh' block \
$'cat <<W/x\necho \'a\nW/x\nfind . -delete'
expect 'F18 dl352: ограничитель bash,sh,zsh' block \
$'cat <<W/\necho \'a\nW/\nfind . -delete'
expect 'F18 dl360: ограничитель bash,sh,zsh' block \
$'cat <<:W\necho \'a\n:W\nfind . -delete'
expect 'F18 dl368: ограничитель bash,sh,zsh' block \
$'cat <<W:x\necho \'a\nW:x\nfind . -delete'
expect 'F18 dl376: ограничитель bash,sh,zsh' block \
$'cat <<W:\necho \'a\nW:\nfind . -delete'
expect 'F18 dl432: ограничитель bash,sh,zsh' block \
$'cat <<=W\necho \'a\n=W\nfind . -delete'
expect 'F18 dl440: ограничитель bash,sh,zsh' block \
$'cat <<W=x\necho \'a\nW=x\nfind . -delete'
expect 'F18 dl448: ограничитель bash,sh,zsh' block \
$'cat <<W=\necho \'a\nW=\nfind . -delete'
expect 'F18 dl480: ограничитель bash,sh,zsh' block \
$'cat <<?W\necho \'a\n?W\nfind . -delete'
expect 'F18 dl488: ограничитель bash,sh,zsh' block \
$'cat <<W?x\necho \'a\nW?x\nfind . -delete'
expect 'F18 dl496: ограничитель bash,sh,zsh' block \
$'cat <<W?\necho \'a\nW?\nfind . -delete'
expect 'F18 dl504: ограничитель bash,sh,zsh' block \
$'cat <<@W\necho \'a\n@W\nfind . -delete'
expect 'F18 dl512: ограничитель bash,sh,zsh' block \
$'cat <<W@x\necho \'a\nW@x\nfind . -delete'
expect 'F18 dl520: ограничитель bash,sh,zsh' block \
$'cat <<W@\necho \'a\nW@\nfind . -delete'
expect 'F18 dl528: ограничитель bash,sh,zsh' block \
$'cat <<[W\necho \'a\n[W\nfind . -delete'
expect 'F18 dl536: ограничитель bash,sh,zsh' block \
$'cat <<W[x\necho \'a\nW[x\nfind . -delete'
expect 'F18 dl544: ограничитель bash,sh,zsh' block \
$'cat <<W[\necho \'a\nW[\nfind . -delete'
expect 'F18 dl576: ограничитель bash,sh,zsh' block \
$'cat <<]W\necho \'a\n]W\nfind . -delete'
expect 'F18 dl584: ограничитель bash,sh,zsh' block \
$'cat <<W]x\necho \'a\nW]x\nfind . -delete'
expect 'F18 dl592: ограничитель bash,sh,zsh' block \
$'cat <<W]\necho \'a\nW]\nfind . -delete'
expect 'F18 dl600: ограничитель bash,sh,zsh' block \
$'cat <<^W\necho \'a\n^W\nfind . -delete'
expect 'F18 dl608: ограничитель bash,sh,zsh' block \
$'cat <<W^x\necho \'a\nW^x\nfind . -delete'
expect 'F18 dl616: ограничитель bash,sh,zsh' block \
$'cat <<W^\necho \'a\nW^\nfind . -delete'
expect 'F18 dl672: ограничитель bash,sh,zsh' block \
$'cat <<{W\necho \'a\n{W\nfind . -delete'
expect 'F18 dl680: ограничитель bash,sh,zsh' block \
$'cat <<W{x\necho \'a\nW{x\nfind . -delete'
expect 'F18 dl688: ограничитель bash,sh,zsh' block \
$'cat <<W{\necho \'a\nW{\nfind . -delete'
expect 'F18 dl720: ограничитель bash,sh,zsh' block \
$'cat <<}W\necho \'a\n}W\nfind . -delete'
expect 'F18 dl728: ограничитель bash,sh,zsh' block \
$'cat <<W}x\necho \'a\nW}x\nfind . -delete'
expect 'F18 dl736: ограничитель bash,sh' block \
$'cat <<W}\necho \'a\nW}\nfind . -delete'
expect 'F18 dl744: ограничитель bash,sh,zsh' block \
$'cat <<~W\necho \'a\n~W\nfind . -delete'
expect 'F18 dl752: ограничитель bash,sh,zsh' block \
$'cat <<W~x\necho \'a\nW~x\nfind . -delete'
expect 'F18 dl760: ограничитель bash,sh,zsh' block \
$'cat <<W~\necho \'a\nW~\nfind . -delete'
expect 'F18 dl768: ограничитель bash,sh,zsh' block \
$'cat <<\'W.x\'\necho \'a\nW.x\nfind . -delete'
expect 'F18 dl784: ограничитель bash,sh,zsh' block \
$'cat <<"W.x"\necho \'a\nW.x\nfind . -delete'
expect 'F18 dl800: ограничитель bash,sh,zsh' block \
$'cat <<W\\.x\necho \'a\nW.x\nfind . -delete'
expect 'F18 dl816: ограничитель bash,sh,zsh' block \
$'cat <<E"O"F\necho \'a\nEOF\nfind . -delete'
expect 'F18 dl832: ограничитель bash,sh,zsh' block \
$'cat <<\'E\'O"F"\necho \'a\nEOF\nfind . -delete'
expect 'F18 dl848: ограничитель bash,sh,zsh' block \
$'cat <<$\'W\'\necho \'a\nW\nfind . -delete'
expect 'F18 dl880: ограничитель bash,sh,zsh' block \
$'cat <<\'END-MSG\'\necho \'a\nEND-MSG\nfind . -delete'
expect 'F18 dl896: ограничитель bash,sh,zsh' block \
$'cat <<END-MSG\necho \'a\nEND-MSG\nfind . -delete'
expect 'F18 dl904: ограничитель bash,sh,zsh' block \
$'cat <<"W x"\necho \'a\nW x\nfind . -delete'
expect 'F18 dl920: ограничитель bash,sh,zsh' block \
$'cat <<\'W;x\'\necho \'a\nW;x\nfind . -delete'
expect 'F18 dl936: ограничитель bash,sh,zsh' block \
$'cat <<W\\ x\necho \'a\nW x\nfind . -delete'
expect 'F18 real-0' block \
$'cat > /tmp/n.md <<END-NOTE\nDon\'t forget\nEND-NOTE\ngit reset --hard'
expect 'F18 real-1' block \
$'cat <<END-NOTE\nDon\'t forget\nEND-NOTE\ngit reset --hard'
expect 'F18 real-2' block \
$'cat <<END-NOTE\nit\'s\nEND-NOTE\ngit reset --hard'
expect 'F18 real-3' block \
$'cat <<W.x\nit\'s\nW.x\ngit reset --hard'
expect 'F18 real-4' block \
$'cat <<W.x\nit\'s\nW.x\nfind . -delete'
expect 'F18 real-5' block \
$'cat <<W.x\nit\'s a\nW.x\nfind . -delete'
expect 'F18 real-6' block \
$'git commit -F - <<END-MSG\nfix: don\'t crash\nEND-MSG\ngit push --force origin main'
expect 'F18 real-7' block \
$'python3 - <<PY.EOF\nprint("it\'s")\nPY.EOF\ngit clean -fdx'
expect 'F18 real-8' block \
$'cat <<EOF-1\nsay "hi\nEOF-1\nrm -rf ~/work'
expect 'F18 real-9' block \
$'cat <<EOF\nDon\'t forget\nEOF\ngit reset --hard'
expect 'F19: перенос в теле без кавычек склеивает строку с ограничителем' block \
$': <<W\na \\\nW\n$(find . -delete)\nW'
expect 'F19: обратные кавычки в теле без кавычек выполняются' block \
$'git commit -F - <<EOF\nfix: `git push --force origin main`\nEOF'
expect 'F19 контроль: в теле с кавычками ограничителя подстановки не выполняются' pass \
$'git commit -F - <<\'EOF\'\nrun `rm -rf build` to clean\nEOF'
expect 'F19 контроль: безобидные обратные кавычки в сообщении коммита' pass \
$'git commit -F - <<EOF\nfix: use `git status` before `ls`\nEOF'

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
