"""Длинные команды (охрана destructive-guard, issue #940): опасный признак в начале, затем ~70 КБ заполнения.

Запуск: python3 long_cases.py [<хук> [<хук для сравнения>]]  (по умолчанию — хук рядом, .claude/hooks/destructive-guard.sh)
Каждое правило destructive-guard должно срабатывать и на короткой, и на длинной команде.
"""
import json
import pathlib
import subprocess
import sys
import tempfile

PAD = 70_000
# Обрыв канала случается, когда совпадение — в начальной строке, а за ней ещё больше ~64 КБ строк:
# grep -q выходит после первой строки, echo ещё пишет. Одну длинную строку grep дочитывает до конца.
FILLER = "; : " + "\n: filler line" * (PAD // 14)          # команды-заполнители отдельными строками
ARGS = " \\\n" + " \\\n".join(f"b{i}" for i in range(PAD // 8))   # хвост аргументов той же git-команды, с переносами

# (правило, команда, cwd или None)
CASES = [
    ("rm -r -f", "rm -rf /important" + FILLER, None),
    ("psql DROP", 'psql -c "DROP TABLE users"' + FILLER, None),
    ("psql DELETE без WHERE", 'psql -c "DELETE FROM users"' + FILLER, None),
    ("gh repo delete", "gh repo delete owner/repo" + FILLER, None),
    ("git push --force", "git push --force origin" + ARGS, None),
    ("git reset --hard", "git reset --hard HEAD" + " -q" * (PAD // 3), None),
    ("git clean -fdx", "git clean -fdx" + ARGS, None),
    ("git add -A", "git add -A" + ARGS, None),
    ("git add .", "git add ." + ARGS, None),
    ("git add -A, многострочный аргумент в кавычках", 'git add -A "' + "\n".join(f"p{i}" for i in range(PAD // 6)) + '"', None),
    ("git push --force, многострочный аргумент в кавычках",
     'git push --force origin "' + "\n".join(f"r{i}" for i in range(PAD // 6)) + '"', None),
    ("git reset --hard, многострочный аргумент в кавычках",
     'git reset --hard HEAD "' + "\n".join(f"h{i}" for i in range(PAD // 6)) + '"', None),
    ("git add ., многострочный аргумент в кавычках", 'git add . "' + "\n".join(f"d{i}" for i in range(PAD // 6)) + '"', None),
    ("git clean -fdx, многострочный аргумент в кавычках", 'git clean -fdx "' + "\n".join(f"c{i}" for i in range(PAD // 6)) + '"', None),
    # Разрешённые длинные команды (отрицательные условия): ожидается 0.
    ("разрешено: guarded-rm во временном каталоге", "/home/user/IWE/.claude/bin/guarded-rm -rf /tmp/build-x" + FILLER, None),
    ("обычный rm -rf во временном каталоге (вариант Г)", "rm -rf /tmp/build-x" + FILLER, None),
    ("разрешено: psql DELETE ... WHERE", "psql -c \"DELETE FROM users WHERE id = 1\"" + FILLER, None),
    # Правило «путь от корня IWE не из корня» здесь не проверяется: хук читает stdin дважды,
    # cwd у него всегда пуст, и правило не срабатывает ни на какой длине (отдельная находка).
]


# The hook inspects the repository at its own cwd for a harmless `git reset --hard HEAD`, so the
# result would depend on where the suite is started (a clean repository lets it through).
# Run every case from a directory that is not a repository.
NEUTRAL_CWD = tempfile.mkdtemp(prefix="dg-long-")


def run(hook, command, cwd):
    payload = {"tool_input": {"command": command}}
    if cwd:
        payload["cwd"] = cwd
    proc = subprocess.run(["bash", hook], input=json.dumps(payload), capture_output=True, text=True,
                          encoding="utf-8", errors="replace", cwd=NEUTRAL_CWD)
    return proc.returncode


def main():
    hooks = sys.argv[1:] or [str(pathlib.Path(__file__).resolve().parents[2] / "destructive-guard.sh")]
    failed = 0
    for name, command, cwd in CASES:
        short = command.split("; : ")[0][:200] if FILLER in command else command[:120]
        codes = []
        for hook in hooks:
            codes.append((run(hook, short, cwd), run(hook, command, cwd)))
        want = 0 if name.startswith("разрешено") else 2
        ok = codes[0] == (want, want)
        failed += not ok
        other = f"; сравнение: коротк. {codes[1][0]}, длин. {codes[1][1]}" if len(codes) > 1 else ""
        print(f"{'ok ' if ok else 'НЕ '} {name}: коротк. {codes[0][0]}, длин. ({len(command) // 1024} КБ) {codes[0][1]}{other}")
    print(f"итог: {len(CASES) - failed} из {len(CASES)} как ожидалось")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
