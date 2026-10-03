"""Behavioural checks of .claude/hooks/destructive-guard.sh (issue #940).

Usage: python3 hook_cases.py [<hook>]      (default: the hook two directories up)

The cases were contributed with issue #940 (the reporter's suite for the same hook after moving
the check from text to execution) and adapted to this hook: where the two hooks deliberately
differ the expectation here is the behaviour of THIS hook:
  - a heredoc body fed to a non-shell interpreter (cat, python) is data, not commands (WP-545);
  - a `# comment` is not executed, and a `-A` on its own line is its own command;
  - `command -v ... add -A` is blocked conservatively;
  - an empty command is rejected as an unparsable request.

Groups: (1) commands with the expected exit code (0 allowed, 2 blocked) and, for a block, a
marker in the message; (2) `git reset --hard` in a clean repository, and after a cd;
(3) fail-closed: a broken jq, perl, grep or sed, an unexpected exit under set -e and a failing
printf inside the matcher all block instead of letting the call through; (4) the pilot's bypass
CC_ALLOW_DESTRUCTIVE_INPUT=1 works even with a broken jq; (5) docs/DESTRUCTIVE-GUARD.md names
every listed pass-through the hook really has and says the bypass covers the whole process.
Commands are passed to the hook as data, nothing is executed.
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile

G = "/home/user/IWE/.claude/bin/guarded-rm"
SCR = "/tmp/claude/project/session/scratchpad"

# (name, command, expected exit code, substring of the message or None)
CASES = [
    ('rm -rf во временном каталоге', 'rm -rf /tmp/x', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('rm -rf в scratchpad буквально', 'rm -rf /tmp/claude/project/session/scratchpad/pkg', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('scratchpad через переменную с косой', 'S="/tmp/claude/project/session/scratchpad/"; rm -rf "$S/x"', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('worktree Claude', 'rm -rf .claude/worktrees/wt1', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('/tmp в соседней команде больше не освобождает', 'rm -rf /important; ls /tmp/', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('реальный случай: данные проекта', 'SCRATCH=/c/x/scratchpad/f; DEST=/home/user/IWE/project-repo; cp -r "$SCRATCH/a" "$DEST/"; rm -rf "$DEST/data/analysis"/*.xlsx 2>/dev/null', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('/usr/bin/rm', '/usr/bin/rm -rf build', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('/bin/rm', '/bin/rm -rf build', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('\\rm', '\\rm -rf build', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('find -exec во временном каталоге', "find /tmp/x -name '*.pyc' -exec rm -rf {} \\;", 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('xargs rm во временном каталоге', 'ls -d /tmp/x/* | xargs rm -rf', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('rm -rf в репозитории (как раньше)', 'rm -rf ~/IWE/DS-strategy', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('git rm -r -f — своё сообщение', 'git -C repo rm -r -f dir', 2, 'git rm с -r и -f'),
    ('guarded-rm по полному пути', '/home/user/IWE/.claude/bin/guarded-rm -rf "$S/x"', 0, None),
    ('guarded-rm через xargs', 'ls -d /tmp/x/* | xargs /home/user/IWE/.claude/bin/guarded-rm -rf', 0, None),
    ('guarded-rm относительным путём', '.claude/bin/guarded-rm -r -f /tmp/x', 0, None),
    ('rm -f без рекурсии', 'rm -f file.txt', 0, None),
    ('git rm -r --cached', 'git rm -r --cached dir', 0, None),
    ('флаги у разных команд', 'git -C r rm -q a.txt; git -C r log --format=%h --reverse', 0, None),
    ('строка «rm -r -f» в коде Python', 'python - <<\'EOF\'\nif "rm -r -f" in text:\n    print(1)\nEOF', 0, None),
    ('обычная команда', 'ls -la', 0, None),
    ('git add конкретных путей', 'git add a.txt b.txt', 0, None),
    ('git push --force-with-lease', 'git push --force-with-lease origin main', 0, None),
    ('git clean -n', 'git clean -n', 0, None),
    ('пустая команда: нечего разбирать, вход отклоняется', '', 2, None),
    ('второй git add -A', 'git add one; git add -A', 2, 'git add -A'),
    ('второй git push --force', 'git push origin; git push --force origin', 2, 'git push --force'),
    ('git push --force на следующей строке', 'git status\ngit push --force origin', 2, 'git push --force'),
    ('второй git clean -fdx', 'git clean -n; git clean -fdx', 2, 'git clean'),
    ('второй git reset --hard', 'git reset --soft HEAD; git reset --hard HEAD~3', 2, 'git reset --hard'),
    ('Codex r1: git после then', 'git add one; if true; then git add -A; fi', 2, 'git add -A'),
    ('Codex r1: git после !', 'git push origin; ! git push --force origin', 2, 'git push --force'),
    ('Codex r1: слитный -C<путь>', 'git add one; git -Cother add -A', 2, 'git add -A'),
    ('--no-pager перед подкомандой', 'git --no-pager push --force origin', 2, 'git push --force'),
    ('git за xargs', 'echo . | xargs git clean -fdx', 2, 'git clean'),
    ('git за sudo с ключами', 'sudo -u build git push --force origin', 2, 'git push --force'),
    ('git за env с присваиванием', 'env GIT_TRACE=1 git add -A', 2, 'git add -A'),
    ('git после do в цикле', 'for r in a b; do git -C "$r" clean -fdx; done', 2, 'git clean'),
    ('Codex r2: echo sudo git — не вызов', 'echo sudo git add -A', 0, None),
    ('Codex r2: printf env git — не вызов', "printf '%s\\n' env git add -A", 0, None),
    ('Codex r2: command -p git', 'git add one; command -p git add -A', 2, 'git add -A'),
    ('Codex r2: time -p git', 'git add one; time -p git add -A', 2, 'git add -A'),
    ('Codex r2: перенаправление перед git', 'git add one; > /dev/null git add -A', 2, 'git add -A'),
    ('перенаправление вплотную перед git', '2>/dev/null git push --force origin', 2, 'git push --force'),
    ('timeout с длительностью', 'timeout 30 git push --force origin', 2, 'git push --force'),
    ('xargs -I {} git', 'ls | xargs -I {} git -C {} clean -fdx', 2, 'git clean'),
    ('Codex r3: xargs --replace git', 'git add one; xargs --replace git add -A', 2, 'git add -A'),
    ('Codex r3: env -S git', 'git add one; env -S git add -A', 2, 'git add -A'),
    ('Codex r3: sudo --user build git', 'git add one; sudo --user build git add -A', 2, 'git add -A'),
    ('Codex r3: time -o файл git', 'git add one; /usr/bin/time -o /tmp/timing git add -A', 2, 'git add -A'),
    ('Codex r3: 2>&1 перед git', 'git add one; 2>&1 git add -A', 2, 'git add -A'),
    ('Codex r3: >| перед git', 'git add one; >| /dev/null git add -A', 2, 'git add -A'),
    ('Codex r3: апостроф в теле heredoc не прячет git после', "git add one; cat <<'EOF'\nDon't panic.\nEOF\ngit add -A", 2, 'git add -A'),
    ('command --help git add -A: консервативно блокируется', 'command --help git add -A', 2, None),
    ('апостроф в комментарии не прячет git после', "# don't\ngit add -A", 2, 'git add -A'),
    ('экранированная ; делит, как в v8 (консервативно)', 'echo a\\; git add -A', 2, 'git add -A'),
    ('экранированная кавычка не прячет git после', "echo it\\'s; git add -A", 2, 'git add -A'),
    ('nice -n 5 git', 'nice -n 5 git push --force origin', 2, 'git push --force'),
    ('вложенные обёртки sudo env git', 'sudo env GIT_TRACE=1 git add -A', 2, 'git add -A'),
    ('аргумент ключа env -u — не команда, echo — данные', 'env -u HOME echo git add -A', 0, None),
    ('Codex r4: экранированный пробел перед #', 'echo \\ #; git add -A', 2, 'git add -A'),
    ('Codex r4: перенос строки после heredoc', 'cat <<EOF\nx\nEOF\ntrue; git add \\\n -A', 2, 'git add -A'),
    ('Codex r4: аргумент ключа обёртки = имя данных', 'env -u cat git add -A', 2, 'git add -A'),
    ('Codex r4: strace -o git git', 'strace -o git git add -A', 2, 'git add -A'),
    ('Codex r4: перенаправление перед подкомандой', 'git 2>/dev/null add -A', 2, 'git add -A'),
    ('Codex r4: флаг слит с перенаправлением', 'git add -A>/dev/null', 2, 'git add -A'),
    ("Codex r4: $'...' в соседней команде", "echo $'it\\'s'; git add -A", 2, 'git add -A'),
    ('echo за обёрткой env — данные, не вызов git', 'env echo git add -A', 0, None),
    ("Codex r5: '>' в кавычках перед -f", "git clean '>' -f .", 2, 'git clean'),
    ("Codex r5: '>' в кавычках перед -A", "git add '>' -A", 2, 'git add -A'),
    ("Codex r5: '>' в кавычках перед --force", "git push '>' --force", 2, 'git push --force'),
    ('git после # в комментарии не исполняется', 'echo ok # ; git add -A', 0, None),
    ('-A на следующей строке — отдельная команда, не флаг git add', 'git add foo\n-A', 0, None),
    ('then: экранированный пробел перед #', 'echo \\ # ; if x; then git add -A; fi', 2, 'git add -A'),
    ('then: перенос строки после heredoc', 'cat <<EOF\nx\nEOF\nif true; then git add \\\n -A; fi', 2, 'git add -A'),
    ("then: '>' в кавычках перед -f", "true; if true; then git clean '>' -f .; fi", 2, 'git clean'),
    ('if echo git — данные', 'if echo git add -A; then :; fi', 0, None),
    ('перенаправление перед echo git — данные', '2>/dev/null echo git add -A', 0, None),
    ('перенаправление отдельным словом перед echo git — данные', '> out.txt echo git add -A', 0, None),
    ('перенаправление отдельным словом перед git — вызов (v8 пропускал)', '> out.txt git add -A', 2, 'git add -A'),
    ('присваивание перед echo git — данные', 'X=1 echo git add -A', 0, None),
    ('& перенаправления перед echo git — данные', '2>&1 echo git add -A', 0, None),
    ('git за неизвестной командой (strace)', 'strace git push --force origin', 2, 'git push --force'),
    ('git за ssh', 'ssh host git clean -fdx', 2, 'git clean'),
    ('git как аргумент grep — данные', 'grep -r git add -A .', 0, None),
    ('apt install git — не вызов подкоманды', 'apt install git', 0, None),
    ('command -v git — запрос, не запуск', 'command -v git', 0, None),
    ('command -v git add -A: консервативно блокируется', 'command -v git add -A', 2, None),
    ('строка git в теле heredoc для cat — данные (WP-545)', "cat > f.md <<'EOF'\ngit push --force origin\nEOF", 0, None),
    ('строка git в теле heredoc для python — данные (WP-545)', "python - <<EOF\nprint('git add -A')\ngit add -A\nEOF", 0, None),
    ('после тела heredoc — снова команды', "cat > f.md <<'EOF'\ntext\nEOF\ngit add -A", 2, 'git add -A'),
    ('тело heredoc для bash — команды', "bash <<'EOF'\ngit push --force origin\nEOF", 2, 'git push --force'),
    ('bash heredoc без пробела', 'bash<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('sh heredoc без пробела', 'sh<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('zsh heredoc без пробела', 'zsh<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('ksh heredoc без пробела', 'ksh<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('dash heredoc без пробела', 'dash<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('quoted bash heredoc без пробела', "'bash'<<EOF\nrm -rf /important\nEOF", 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('double quoted bash heredoc без пробела', '"bash"<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('абсолютный bash heredoc без пробела', '/bin/bash<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('Windows bash.exe heredoc без пробела', 'bash.exe<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('bash heredoc с quoted delimiter без пробела', "bash<<'EOF'\nrm -rf /important\nEOF", 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('bash heredoc с tab strip без пробела', 'bash<<-EOF\n\trm -rf /important\n\tEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('env bash heredoc без пробела', 'env bash<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('command bash heredoc без пробела', 'command bash<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('sudo bash heredoc без пробела', 'sudo bash<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('ssh host bash heredoc без пробела', 'ssh host bash<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('bash heredoc через продолжение строки', 'bash\\\n<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('bash heredoc внутри группы', '(bash<<EOF\nrm -rf /important\nEOF\n)', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('heredoc после группы с quoted bash', '("bash")<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('heredoc после группы с абсолютным bash', '(/bin/bash)<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('heredoc после группы с sh', '(sh)<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('heredoc после группы с env bash', '(env bash)<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('heredoc после brace-группы с bash', '{ bash; }<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('heredoc после brace-группы с sh', '{ sh; }<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('heredoc после многострочной brace-группы с bash', '{\nbash\n}<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('psql heredoc без пробела', 'psql<<SQL\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('quoted psql heredoc без пробела', "'psql'<<SQL\nDROP TABLE t;\nSQL", 2, 'DROP/TRUNCATE'),
    ('heredoc после группы с psql', '(psql)<<SQL\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('heredoc после группы с quoted psql', '("psql")<<SQL\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('heredoc после brace-группы с psql', '{ psql; }<<SQL\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('Windows psql.exe heredoc без пробела', 'psql.exe<<SQL\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('mysql heredoc без пробела с удалением таблицы', 'mysql<<SQL\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('heredoc после группы с абсолютным mysql', '(/usr/bin/mysql)<<SQL\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('sqlite3 heredoc без пробела с удалением таблицы', 'sqlite3<<SQL\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('mysql heredoc с пробелом также под защитой', 'mysql <<SQL\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('sqlite3 heredoc с пробелом также под защитой', 'sqlite3 <<SQL\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('cat heredoc рядом с bash: тело остаётся данными', 'cat <<EOF; bash -c true\nrm -rf /important\nEOF', 0, None),
    ('cat с аргументом bash перед heredoc: тело остаётся данными', 'cat bash<<EOF\nrm -rf /important\nEOF', 0, None),
    ('cat с quoted аргументом bash перед heredoc: тело остаётся данными', 'cat "bash" <<EOF\nrm -rf /important\nEOF', 0, None),
    ('cat в группе после heredoc: тело остаётся данными', '(cat)<<EOF\nrm -rf /important\nEOF', 0, None),
    ('cat в многострочной группе после heredoc: тело остаётся данными', '{\ncat\n}<<EOF\nrm -rf /important\nEOF', 0, None),
    ('if then bash fi с heredoc', 'if true; then bash; fi<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('if then cat fi с heredoc: тело остаётся данными', 'if true; then cat; fi<<EOF\nrm -rf /important\nEOF', 0, None),
    ('многострочный if then bash fi с heredoc', 'if true; then\nbash\nfi<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('многострочный if then cat fi: тело остаётся данными', 'if true; then\ncat\nfi<<EOF\nrm -rf /important\nEOF', 0, None),
    ('вложенный if с bash перед внутренним cat', 'if true; then bash; if true; then cat; fi; fi<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('предыдущий bash не относится к if с cat', 'bash -c true; if true; then cat; fi<<EOF\nrm -rf /important\nEOF', 0, None),
    ('for do bash done с heredoc', 'for i in 1; do bash; done<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('for do cat done: тело остаётся данными', 'for i in 1; do cat; done<<EOF\nrm -rf /important\nEOF', 0, None),
    ('while do bash done с heredoc', 'while :; do bash; break; done<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('while do cat done: тело остаётся данными', 'while :; do cat; break; done<<EOF\nrm -rf /important\nEOF', 0, None),
    ('case bash esac с heredoc', 'case x in x) bash;; esac<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('case cat esac: тело остаётся данными', 'case x in x) cat;; esac<<EOF\nrm -rf /important\nEOF', 0, None),
    ('until do bash done с heredoc', 'until false; do bash; break; done<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('select do bash done с heredoc', 'select x in one; do bash; break; done<<EOF\n1\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('многострочный for do bash done с heredoc', 'for i in 1; do\nbash\ndone<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('многострочный case bash esac с heredoc', 'case x in\nx) bash;;\nesac<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('for со словом bash в списке и cat: данные', 'for i in bash; do cat; done<<EOF\nrm -rf /important\nEOF', 0, None),
    ('case со словом bash в шаблоне и cat: данные', 'case bash in bash) cat;; esac<<EOF\nrm -rf /important\nEOF', 0, None),
    ('while с printf bash и cat: данные', 'while printf bash >/dev/null; do cat; break; done<<EOF\nrm -rf /important\nEOF', 0, None),
    ('недостижимая ветка bash: консервативный отказ', 'if false; then bash; else cat; fi<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('for do psql done с heredoc', 'for i in 1; do psql; done<<SQL\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('case psql esac с heredoc', 'case x in x) psql;; esac<<SQL\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('for do sqlite3 done с heredoc', 'for i in 1; do sqlite3 :memory:; done<<SQL\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('for со словом psql в списке и cat: SQL-данные', 'for i in psql; do cat; done<<SQL\nDROP TABLE t;\nSQL', 0, None),
    ('case со словом psql в шаблоне и cat: SQL-данные', 'case psql in psql) cat;; esac<<SQL\nDROP TABLE t;\nSQL', 0, None),
    ('if test bash затем cat: слово bash не вызов', 'if test bash; then cat; fi<<EOF\nrm -rf /important\nEOF', 0, None),
    ('if command -v bash затем cat: поиск не вызов', 'if command -v bash; then cat; fi<<EOF\nrm -rf /important\nEOF', 0, None),
    ('while test bash затем cat: слово bash не вызов', 'while test bash; do cat; break; done<<EOF\nrm -rf /important\nEOF', 0, None),
    ('префиксный heredoc перед bash', '<<EOF bash\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('префиксный heredoc fd 0 перед bash', '0<<EOF bash\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('префиксный heredoc перед env bash', '<<EOF env bash\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('префиксный heredoc перед psql', '<<SQL psql\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('assignment перед префиксным bash heredoc', 'FOO=x <<EOF bash\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('assignment и fd перед префиксным bash heredoc', 'FOO=x 0<<EOF bash\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('output redirect перед префиксным bash heredoc', '2>/dev/null <<EOF bash\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('assignment перед префиксным psql heredoc', 'FOO=x <<SQL psql\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('два assignment и fd перед bash', 'A=1 B=2 0<<EOF bash\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('assignment и redirect перед fd 0 bash', 'A=1 2>/dev/null 0<<EOF bash\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('env перед префиксным bash', 'env <<EOF bash\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('env assignment перед префиксным bash', 'env A=1 <<EOF bash\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('sudo перед префиксным bash', 'sudo -u nobody <<EOF bash\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('assignment перед env bash', 'A=1 <<EOF env bash\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('assignment и fd перед psql', 'A=1 0<<SQL psql\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('quoted bash после assignment и heredoc', "A=1 <<EOF 'bash'\nrm -rf /important\nEOF", 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('quoted path bash после assignment и heredoc', 'A=1 <<EOF "/bin/bash"\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('quoted psql после redirect и heredoc', '2>/dev/null <<SQL "psql"\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('env assignment перед sqlite3 heredoc', 'env A=1 <<SQL sqlite3 :memory:\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('префиксный heredoc перед cat: данные', '<<EOF cat\nrm -rf /important\nEOF', 0, None),
    ('cat с heredoc и поздним аргументом bash: данные', 'cat <<EOF bash\nrm -rf /important\nEOF', 0, None),
    ('assignment и cat с поздним аргументом bash: данные', 'FOO=x cat <<EOF bash\nrm -rf /important\nEOF', 0, None),
    ('output redirect и cat с поздним bash: данные', '2>/dev/null cat <<EOF bash\nrm -rf /important\nEOF', 0, None),
    ('assignment перед префиксным cat: данные', 'A=1 <<EOF cat\nrm -rf /important\nEOF', 0, None),
    ('redirect перед префиксным cat: данные', '2>/dev/null <<EOF cat\nrm -rf /important\nEOF', 0, None),
    ('env assignment перед префиксным cat: данные', 'env A=1 <<EOF cat\nrm -rf /important\nEOF', 0, None),
    ('sudo перед префиксным cat: данные', 'sudo -u nobody <<EOF cat\nrm -rf /important\nEOF', 0, None),
    ('assignment и cat с поздним psql: SQL-данные', 'A=1 cat <<SQL psql\nDROP TABLE t;\nSQL', 0, None),
    ('env assignment и cat с поздним bash: данные', 'env A=1 cat <<EOF bash\nrm -rf /important\nEOF', 0, None),
    ('sudo и cat с поздним bash: данные', 'sudo -u nobody cat <<EOF bash\nrm -rf /important\nEOF', 0, None),
    ('fd 2 heredoc для bash: консервативный отказ', '2<<EOF bash\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('позиционный 2 перед stdin bash', 'bash -s 2 <<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('позиционный 1 перед stdin bash', 'bash -s 1 <<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('позиционный 22 перед stdin bash', 'bash -s 22  <<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('позиционный 0 перед stdin bash', 'bash -s 0 <<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('позиционный 2 и quoted delimiter', "bash -s 2 <<'EOF'\nrm -rf /important\nEOF", 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('позиционный 2 после prefix redirect', '2>/dev/null bash -s 2 <<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('stderr merge перед stdin bash', 'bash 2>&1 <<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('both streams redirect перед stdin bash', 'bash &>/dev/null <<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('both streams append перед stdin bash', 'bash &>>/dev/null <<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('clobber redirect перед stdin bash', 'bash >|/dev/null <<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('stdout dup перед stdin bash', 'bash >&2 <<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('stderr merge adjacent перед stdin bash', 'bash 2>&1<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('stdin dup перед heredoc bash', 'bash 2<&1 <<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('stderr merge перед prefix stdin bash', '2>&1 <<EOF bash\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('fd 2 adjacent для bash: консервативный отказ', 'bash -s 2<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('fd 1 adjacent для bash: консервативный отказ', 'bash -s 1<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('fd 0 adjacent подаёт stdin в bash', 'bash -s 0<<EOF\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('номер порта psql перед stdin SQL', 'psql -p 5432 <<SQL\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('номер порта mysql перед stdin SQL', 'mysql --port 3306 <<SQL\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('номер порта psql и quoted delimiter', "psql -p 5432 <<'SQL'\nDROP TABLE t;\nSQL", 2, 'DROP/TRUNCATE'),
    ('номер базы sqlite3 перед stdin SQL', 'sqlite3 2 <<SQL\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('номер порта psql после prefix redirect', 'A=1 2>/dev/null psql -p 5432 <<SQL\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('stderr merge перед stdin psql', 'psql 2>&1 <<SQL\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('номер порта ssh перед stdin shell', 'ssh -p 22 <<EOF host\ngit clean -fdx\nEOF', 2, 'git clean'),
    ('stderr merge перед stdin ssh', 'ssh host 2>&1 <<EOF\ngit clean -fdx\nEOF', 2, 'git clean'),
    ('номер порта ssh и tab перед heredoc', 'ssh -p 22\t<<-EOF host\n\tgit clean -fdx\n\tEOF', 2, 'git clean'),
    ('quoted semicolon в prefix env не завершает shell', "<<EOF env A='x;y' bash\nrm -rf /important\nEOF", 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('quoted pipe в prefix env не завершает shell', "<<EOF env A='x|y' bash\nrm -rf /important\nEOF", 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('quoted ampersand в prefix env не завершает shell', '<<EOF env A="x&y" bash\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('cat pipe передаёт тело bash', 'cat <<EOF | bash\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('cat pipe передаёт тело psql', 'cat <<SQL | psql\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('tee pipe передаёт тело bash', 'tee /dev/null <<EOF | bash\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('cat pipe через data stage передаёт тело bash', 'cat <<EOF | cat | bash\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('cat pipe через env передаёт тело bash', 'cat <<EOF | env bash\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('cat pipe and передаёт тело bash', 'cat <<EOF |& bash\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('cat pipe через cat: тело данные', 'cat <<EOF | cat\nrm -rf /important\nEOF', 0, None),
    ('cat рядом с отдельным bash: тело данные', 'cat <<EOF; bash -c true\nrm -rf /important\nEOF', 0, None),
    ('fd 2 затем stdin dup: тело bash', '2<<EOF bash <&2\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('fd 2 затем явный stdin dup: тело bash', '2<<EOF bash 0<&2\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('fd 2 затем stdin dup перед shell', '2<<EOF 0<&2 bash\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('fd 3 затем stdin dup: тело SQL', '3<<SQL psql 0<&3\nDROP TABLE t;\nSQL', 2, 'DROP/TRUNCATE'),
    ('fd 3 через fd 2 затем stdin: тело bash', 'bash 3<<EOF 2<&3 0<&2\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('fd 2 через fd 3 затем stdin: тело bash', 'bash 2<<EOF 3<&2 0<&3\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('fd 2 затем stdin через output dup: тело bash', 'bash 2<<EOF 0>&2\nrm -rf /important\nEOF', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('fd 3 через fd 2 затем stdin: текст cat данные', 'cat 3<<EOF 2<&3 0<&2\nrm -rf /important\nEOF', 0, None),
    ('fd 2 для cat: тело данные', '2<<EOF cat\nrm -rf /important\nEOF', 0, None),
    ('cat heredoc с SQL-текстом остаётся данными', 'cat <<SQL\nDROP TABLE t;\nSQL', 0, None),
    ('<< внутри многострочной кавычки не скрывает следующую команду', "echo 'bash\\\n<<EOF'\nrm -rf /important\nEOF", 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('тело heredoc для ssh — команды', 'ssh host <<EOF\ngit clean -fdx\nEOF', 2, 'git clean'),
    ('незавершённый heredoc — разбирается как команды', 'cat <<EOF\ngit add -A', 2, 'git add -A'),
    ('два heredoc, один для bash — оба разбираются', 'cat <<A; bash <<B\nx\nA\ngit add -A\nB', 2, 'git add -A'),
    ('упоминание git в echo — не вызов', 'echo git add -A', 0, None),
    ('упоминание git в кавычках — не вызов', 'git commit -m "не делай git add -A"', 0, None),
    ('первый git add -A (как раньше)', 'git add -A', 2, 'git add -A'),
    ('верхнеуровневый cd (как раньше)', 'cd /c/Users', 2, 'cd'),
    ('psql DROP (как раньше)', 'psql -c "DROP TABLE t"', 2, 'DROP'),
    ('gh repo delete (как раньше)', 'gh repo delete a/b', 2, 'gh repo delete'),
    ('ssh host rm -rf', 'ssh build-host rm -rf /srv/data', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('ssh с командой строкой', 'ssh build-host "rm -rf /srv/data"', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('docker exec rm -rf', 'docker exec c1 rm -rf /data', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('bash -c со строкой', 'bash -c "rm -rf /important"', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('bash -o перед -c', 'bash -o pipefail -c "rm -rf /important"', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('bash -o перед -c с данными', "bash -o pipefail -c 'printf \"%s\" \"rm -rf /important\"'", 0, None),
    ('bash -O перед -c', 'bash -O extglob -c "rm -rf /important"', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('bash -c -- перед строкой', 'bash -c -- "rm -rf /important"', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('bash в кавычках с heredoc', "'bash' <<EOF\nrm -rf /important\nEOF", 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('верхнеуровневый cd с пробелом', ' cd /important', 2, 'cd'),
    ('регистр RM на macOS/Windows', 'RM -rf /important', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('регистр абсолютного пути на macOS/Windows', '/BIN/RM -rf /important', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('-- завершает ключи rm', 'rm -r -- -f', 0, None),
    ('-- внутри имени цели не завершает ключи rm', 'rm -r "/tmp/absent -- marker" -f /tmp/also-absent', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('-rf до -- по-прежнему блокируется', 'rm -rf -- -f', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('-- завершает ключи git rm', 'git rm -r -- -f', 0, None),
    ('-- внутри имени цели не завершает ключи git rm', 'git rm -r "path -- marker" -f victim', 2, 'git rm'),
    ('git clean -nd только просмотр', 'git clean -nd', 0, None),
    ('git clean --dry-run -fdx только просмотр', 'git clean --dry-run -fdx', 0, None),
    ('git clean без ключей может удалять при clean.requireForce=false', 'git -c clean.requireForce=false clean', 2, 'git clean'),
    ('git clean -e при clean.requireForce=false тоже удаляет', 'git -c clean.requireForce=false clean -e keep', 2, 'git clean'),
    ('git clean без -f после --no-dry-run', 'git clean -n --no-dry-run', 2, 'git clean'),
    ('git clean без -f после --dry-run --no-dry-run', 'git clean --dry-run --no-dry-run', 2, 'git clean'),
    ('git clean -e потребляет --no-dry-run как шаблон', 'git clean -e --no-dry-run -n', 0, None),
    ('git clean: просмотр не скрывает следующий delete', 'git clean -nd; git clean -fdx', 2, 'git clean'),
    ('git clean: --dry-run как аргумент -e не просмотр', 'git clean -fdx -e --dry-run', 2, 'git clean'),
    ('git clean: -n как аргумент -e не просмотр', 'git clean -fdx -e -n', 2, 'git clean'),
    ('git clean: --dry-run как значение --exclude не просмотр', 'git clean -fdx --exclude --dry-run', 2, 'git clean'),
    ('git clean: -n как значение последнего -e в кластере', 'git clean -fdx -fe -n', 2, 'git clean'),
    ('git clean: --dry-run как значение последнего -e в кластере', 'git clean -fxe --dry-run', 2, 'git clean'),
    ('git clean: значение прицеплено к -e в кластере', 'git clean -fen', 2, 'git clean'),
    ('git clean: сокращение --exclude потребляет -n', 'git clean -fdx --ex -n', 2, 'git clean'),
    ('git clean: сокращение --force удаляет', 'git clean --fo', 2, 'git clean'),
    ('git clean: сокращение --dry-run только просмотр', 'git clean -fdx --dry-r', 0, None),
    ('git clean: --no-dry-run отменяет прежний -n', 'git clean -n --no-dry-run -fdx', 2, 'git clean'),
    ('git clean: -X удаляет ignored', 'git clean -X', 2, 'git clean'),
    ('git clean: длинный --dir удаляет', 'git clean --dir', 2, 'git clean'),
    ('git clean: длинный --ignored удаляет', 'git clean --ignored', 2, 'git clean'),
    ('git clean: длинный --ignored-only удаляет', 'git clean --ignored-only', 2, 'git clean'),
    ('git clean: long flags с удалением', 'git clean --force --dir', 2, 'git clean'),
    ('git clean: исключение перед настоящим -n', 'git clean -fdx -e cache -n', 0, None),
    ('GIT clean на регистронезависимой ФС', 'GIT clean -fdx', 2, 'git clean'),
    ('GIT push на регистронезависимой ФС', 'GIT push --force origin main', 2, 'git push --force'),
    ('ECHO с текстом rm на регистронезависимой ФС', 'ECHO "rm -rf /important"', 0, None),
    ('sh -lc со строкой', "sh -lc 'cd x; rm -rf build'", 2, None),
    ('eval со строкой', 'eval "rm -rf /important"', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('вложенный bash -c', 'bash -c "bash -c \'rm -rf /important\'"', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('env -S со строкой', 'env -S "rm -rf /important"', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('раздельные ключи -r -f', 'rm -r -f /important', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('длинные ключи', 'rm --recursive --force /important', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('сокращённые длинные ключи GNU', 'rm --recur --for /important', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('rm -Rf', 'rm -Rf /important', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('rm с -v в кластере', 'rm -vrf /important', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('rm после sudo -u', 'sudo -u build rm -rf /important', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('rm после /usr/bin/time -o', '/usr/bin/time -o /tmp/t rm -rf /important', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('rm после then', 'if true; then rm -rf /important; fi', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('rm в цикле do', 'for d in a b; do rm -rf "$d"; done', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('rm с ANSI-C кавычкой в соседней команде', "echo $'it\\'s'; rm -rf /important", 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('rm после комментария с апострофом', "# don't\nrm -rf /important", 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('rm через перенос строки с обратной косой', 'rm \\\n -rf /important', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('rm за перенаправлением', '> /dev/null rm -rf /important', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('rm внутри подстановки', 'echo $(rm -rf /important)', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('rm внутри группы', '(rm -rf /important)', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('rm -rf после || и &&', 'false || rm -rf /important && true', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('Windows: rm.exe, косые вперёд', 'C:/Git/usr/bin/rm.exe -rf build', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
  ('Windows: rm.exe в кавычках, обратные косые', '"C:\\Git\\usr\\bin\\rm.exe" -rf build', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('--verbose и --preserve-root — не ключи рекурсии', 'rm --verbose --preserve-root file.txt', 0, None),
    ('rm -f --verbose без рекурсии', 'rm -f --verbose file.txt', 0, None),
    ('rm -r без -f', 'rm -r build', 0, None),
    ('guarded-rm за sudo', 'sudo /home/user/IWE/.claude/bin/guarded-rm -rf /tmp/x', 0, None),
    ('guarded-rm через bash -c', "bash -c '/home/user/IWE/.claude/bin/guarded-rm -rf /tmp/x'", 0, None),
    ('git rm -rf с тем же сообщением через -C', 'git -C r rm -rf dir', 2, 'git rm с -r и -f'),
    ('вызов git через путь', '/usr/bin/git add -A', 2, 'git add -A'),
    ('git с -Cпуть слитно', 'git -Cr push --force origin', 2, 'git push --force'),
    ('git --no-pager после ssh', 'ssh h git --no-pager push --force origin', 2, 'git push --force'),
    ('ANSI-C: флаг -rf через \\x66', "rm $'-r\\x66' /important", 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('ANSI-C: флаг -rf через восьмеричный код', "rm $'-r\\146' /important", 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('ANSI-C: имя команды по буквам', "$'\\x72\\x6d' -rf /important", 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('locale-кавычки $"rm"', '$"rm" -rf /important', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('продолжение строки внутри имени команды', 'r\\\nm -rf /important', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('перенаправление вплотную к rm', 'rm>/dev/null -rf /important', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('перенаправление вплотную к git', 'git>/dev/null push --force origin', 2, 'git push --force'),
    ('перенаправление в конце ключа', 'rm -rf>/dev/null /important', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('вложенный sh -c за docker exec', "docker exec c sh -c 'rm -rf /important'", 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('вложенный bash -c за kubectl exec', "kubectl exec pod -- bash -c 'rm -rf /important'", 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('2>&1 перед rm', '2>&1 rm -rf /important', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('find -exec rm с перенаправлением', 'find . -name tmp -exec rm -rf {} + >/dev/null', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('xargs -I {} sh -c', 'ls | xargs -I{} sh -c \'rm -rf "$1"\' _ {}', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('sudo -E rm', 'sudo -E rm -rf /important', 2, '.claude/bin/guarded-rm (те же ключи и цели)'),
    ('git grep -e rm -e -rf — поиск, не удаление', 'git grep -e rm -e -rf', 0, None),
    ('git log --grep rm', 'git log --grep=rm --oneline -n 5', 0, None),
    ('docker rm -f — без рекурсии', 'docker rm -f c1', 0, None),
    ('docker rm -fv', 'docker rm -fv c1', 0, None),
    ('docker run --rm', 'docker run --rm alpine ls', 0, None),
    ('npm run с именем rm в аргументах, без флагов', 'npm run build -- rm', 0, None),
]


def fd_heredoc_matrix():
    """Literal interpreters must retain a dangerous body on every heredoc FD.

    A nonzero FD can reach the interpreter through a path or later duplication;
    the static guard deliberately refuses even the safe plain-FD case. Cat is a
    data receiver on the same forms and remains allowed.
    """
    targets = (
        ('bash', 'EOF', 'rm -rf /important', '.claude/bin/guarded-rm (те же ключи и цели)'),
        ('sh', 'EOF', 'rm -rf /important', '.claude/bin/guarded-rm (те же ключи и цели)'),
        ('psql', 'SQL', 'DROP TABLE t;', 'DROP/TRUNCATE'),
        ('mysql', 'SQL', 'DROP TABLE t;', 'DROP/TRUNCATE'),
        ('sqlite3 :memory:', 'SQL', 'DROP TABLE t;', 'DROP/TRUNCATE'),
    )
    for recipient, delim, body, marker in targets:
        for fd in range(4):
            headers = (
                ('слева', f'{recipient} {fd}<<{delim}'),
                ('справа', f'{fd}<<{delim} {recipient}'),
                ('dev-fd после', f'{recipient} {fd}<<{delim} /dev/fd/{fd}'),
                ('proc-fd до', f'{recipient} /proc/self/fd/{fd} {fd}<<{delim}'),
                ('цепочка', f'{recipient} {fd}<<{delim} 2<&{fd} 0<&2'),
            )
            for form, header in headers:
                yield (f'FD matrix {recipient} {fd} {form}', f'{header}\n{body}\n{delim}', 2, marker)
    for fd in range(4):
        for header in (f'cat {fd}<<EOF', f'{fd}<<EOF cat'):
            yield (f'FD matrix данные {header}', f'{header}\nrm -rf /important\nEOF', 0, None)


CASES.extend(fd_heredoc_matrix())

REAL = {}


def real(tool):
    if tool not in REAL:
        REAL[tool] = subprocess.run(["bash", "-c", f"command -v {tool}"], capture_output=True, text=True).stdout.strip()
    return REAL[tool]


# The hook looks at the repository in its own cwd for a harmless `git reset --hard HEAD`; run
# from a directory that is not a repository unless a case brings its own.
NEUTRAL_CWD = tempfile.mkdtemp(prefix="dg-cwd-")


def run(hook, command, env=None, raw_input=None, cwd=None):
    data = raw_input if raw_input is not None else json.dumps({"tool_input": {"command": command}})
    proc = subprocess.run(["bash", hook], input=data, capture_output=True, text=True, encoding="utf-8",
                          errors="replace", env=env, cwd=cwd or NEUTRAL_CWD)
    return proc.returncode, proc.stderr.strip()


def clean_repo():
    """A clean git repository: `git reset --hard HEAD` is harmless there and the hook's exception applies."""
    repo = tempfile.mkdtemp(prefix="dg-repo-")
    for args in (["init", "-q"], ["config", "user.email", "t@t.test"], ["config", "user.name", "t"]):
        subprocess.run(["git", "-C", repo, *args], check=True)
    with open(os.path.join(repo, "a.txt"), "w") as f:
        f.write("a\n")
    subprocess.run(["git", "-C", repo, "add", "a.txt"], check=True)
    subprocess.run(["git", "-C", repo, "commit", "-qm", "a"], check=True)
    return repo


def fake_env(tool, condition="true"):
    """PATH with a fake `tool`: exits 3 when the sh condition over "$*" holds, else runs the real one."""
    d = tempfile.mkdtemp(prefix="dg-fake-")
    with open(os.path.join(d, tool), "w", newline="\n") as f:
        f.write(f'#!/bin/sh\nif {condition}; then exit 3; fi\nexec {real(tool)} "$@"\n')
    os.chmod(os.path.join(d, tool), 0o755)
    return dict(os.environ, PATH=d + os.pathsep + os.environ["PATH"])


def main():
    hook = sys.argv[1] if len(sys.argv) > 1 else str(pathlib.Path(__file__).resolve().parents[2] / "destructive-guard.sh")
    failed = 0
    lines = []

    def check(ok, text):
        nonlocal failed
        failed += not ok
        lines.append(("ok  " if ok else "NOT ") + text)

    for name, command, want, marker in CASES:
        got, err = run(hook, command)
        ok = got == want and (marker is None or marker in err)
        check(ok, f"{got} (want {want}) - {name}" + ("" if ok or not err else f"\n      >> {err[:220]}"))

    # --- reset --hard: the harmless-reset exception works in a clean repo, not after a cd ---
    repo = clean_repo()
    code, err = run(hook, "git reset --hard HEAD", cwd=repo)
    check(code == 0, f"reset --hard HEAD in a clean repository -> {code}: the exception applies")
    code, err = run(hook, "(cd /home/user/IWE/other-repo && git reset --hard HEAD)", cwd=repo)
    check(code == 2, f"reset --hard after a cd -> {code}: the exception does not apply (the wrong repo would be inspected)")

    # --- fail closed ---
    code, err = run(hook, "ls -la", env=fake_env("perl"))
    check(code == 2, f"a broken perl -> {code}: blocked")
    code, err = run(hook, "ls -la", env=fake_env("perl", 'case "$*" in *"cd\\\\s+"*) true;; *) false;; esac'))
    check(code == 2 and "ошибка проверки" in err, f"only the perl of the cd check broken -> {code}: blocked as a failed check")
    code, err = run(hook, "ls -la", env=fake_env("jq"))
    check(code == 2, f"a broken jq -> {code}: every command is blocked")
    code, err = run(hook, "git push origin main", env=fake_env("grep"))
    check(code == 2 and "ошибка проверки" in err, f"a broken grep, git push -> {code}: blocked as a failed check, not 'no match'")
    code, err = run(hook, "git push origin main", env=fake_env("sed"))
    check(code == 2 and "ошибка проверки" in err, f"a broken sed, git push -> {code}: blocked")
    code, err = run(hook, "", raw_input="{not json")
    check(code == 2, f"input that is not JSON -> {code}: blocked")
    text = open(hook, encoding="utf-8", newline="").read()
    anchor = "trap on_exit EXIT"
    if anchor in text:
        broken = os.path.join(tempfile.mkdtemp(prefix="dg-trap-"), "destructive-guard.sh")
        with open(broken, "w", encoding="utf-8", newline="") as f:
            f.write(text.replace(anchor, anchor + "\nfalse", 1))
        code, err = run(broken, "ls -la")
        check(code == 2 and "неожиданный выход" in err, f"an unexpected failure under set -e -> {code}: blocked")
    else:
        check(False, "the hook has no exit trap")
    env_file = os.path.join(tempfile.mkdtemp(prefix="dg-env-"), "env.sh")
    with open(env_file, "w", newline="\n") as f:
        f.write('printf() { if [ "${FUNCNAME[1]:-}" = matches ]; then return 3; fi; builtin printf "$@"; }\n')
    code, err = run(hook, "git add -A", env=dict(os.environ, BASH_ENV=env_file))
    check(code == 2 and "ошибка проверки" in err, f"a failing printf inside matches -> {code}: blocked as a failed check")

    # --- the pilot's bypass works even with a broken jq ---
    env = fake_env("jq")
    env["CC_ALLOW_DESTRUCTIVE_INPUT"] = "1"
    code, err = run(hook, "rm -rf /important", env=env)
    check(code == 0, f"broken jq + bypass -> {code}: let through")
    env = dict(os.environ, CC_ALLOW_DESTRUCTIVE_INPUT="0")
    code, err = run(hook, "rm -rf /important", env=env)
    check(code == 2, f"CC_ALLOW_DESTRUCTIVE_INPUT=0 is not a bypass -> {code}")

    # --- the guide tells the truth (WP-7): a pass-through below that the hook really has is named
    # under «Вне гарантии»; the bypass is described as covering the whole process, not one command ---
    doc_path = pathlib.Path(hook).resolve().parents[2] / "docs" / "DESTRUCTIVE-GUARD.md"
    if doc_path.is_file():
        doc = doc_path.read_text(encoding="utf-8")
        for command, named in (("rm -r ./data", "`rm -r`"), ("rm -R data/", "`rm -R`"),
                               ("rm --recursive data", "`rm --recursive`"),
                               ("git submodule foreach 'rm -rf build'", "`git submodule foreach")):
            code, err = run(hook, command)
            check(code != 0 or named in doc, f"{command!r} -> {code}: a pass-through the guide names as {named}")
        # Known limits remain observable until an executable detector replaces them (#1002).
        for command, named in (("bash <<< 'rm -rf /important'", "`bash <<<`"),
                               ("sh -s <<< 'rm -rf /important'", "`sh -s <<<`"),
                               ("printf '%s\\n' 'rm -rf /important' | sh", "`| sh`"),
                               ('echo "$(rm -rf /important)"', "`$(...)`"),
                               ('echo "`rm -rf /important`"', "обратных кавычках"),
                               ('cat <<EOF\n$(rm -rf /important)\nEOF', "`cat <<EOF`"),
                               ('cat <<EOF > >(bash)\nrm -rf /important\nEOF', "> >(bash)")):
            code, err = run(hook, command)
            check(code == 0 and named in doc, f"{command!r} -> {code}: unresolved pass-through named as {named}")
        env = dict(os.environ, CC_ALLOW_DESTRUCTIVE_INPUT="1")
        code, err = run(hook, "git push --force origin main", env=env)
        check(code == 0 and "не разовый" in doc and "всей сессии агента" in doc,
              f"bypass -> {code}: the guide says it covers the whole process, not one command")
    else:
        print(f"skipped the guide checks: {doc_path} is not next to this hook")

    print("\n".join(lines))
    print(f"result: {len(lines) - failed} of {len(lines)} as expected")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
