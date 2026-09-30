"""Проверки .claude/bin/guarded-rm (issue #940).

Запуск: python3 guarded_rm_cases.py [<путь к guarded-rm>]  (по умолчанию — .claude/bin/guarded-rm рядом)
Скрипт копируется в поддельное рабочее пространство во временном каталоге со своим реестром:
разрешённый корень `allowed` и «чужой» каталог `outside` лежат рядом, так что даже ошибка
guarded-rm ничего вне временного каталога не удалит. Для каждого случая проверяется код выхода
и что осталось на диске.
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = sys.argv[1] if len(sys.argv) > 1 else os.path.normpath(os.path.join(HERE, "..", "..", "..", "bin", "guarded-rm"))


def posix(path):
    """C:\\a\\b → /c/a/b (форма Git Bash)."""
    p = path.replace("\\", "/")
    if len(p) > 1 and p[1] == ":":
        p = "/" + p[0].lower() + p[2:]
    return p


def mixed(path):
    return path.replace("\\", "/")


class Workspace:
    def __init__(self):
        self.base = tempfile.mkdtemp(prefix="guarded-rm-test-")
        self.ws = os.path.join(self.base, "ws")
        os.makedirs(os.path.join(self.ws, ".claude", "bin"))
        os.makedirs(os.path.join(self.ws, ".claude", "config"))
        os.makedirs(os.path.join(self.ws, ".claude", "worktrees"))
        self.script = os.path.join(self.ws, ".claude", "bin", "guarded-rm")
        shutil.copy(SOURCE, self.script)
        self.allowed = os.path.join(self.base, "allowed")
        self.outside = os.path.join(self.base, "outside")
        os.makedirs(self.allowed)
        os.makedirs(self.outside)
        self.registry(f"# тест\n{mixed(self.allowed)}\n{{WORKSPACE}}/.claude/worktrees\n")

    def registry(self, text):
        with open(os.path.join(self.ws, ".claude", "config", "guarded-rm-roots.txt"), "w", encoding="utf-8", newline="\n") as f:
            f.write(text)

    def make(self, *parts):
        path = os.path.join(*parts)
        os.makedirs(path, exist_ok=True)
        with open(os.path.join(path, "f.txt"), "w") as f:
            f.write("x")
        return path

    def run(self, *args, shell=None):
        if shell:
            cmd = ["bash", "-c", shell]
        else:
            cmd = ["bash", self.script, *args]
        env = dict(os.environ, GRM=posix(self.script))
        proc = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", env=env)
        return proc.returncode, proc.stderr.strip()

    def close(self):
        shutil.rmtree(self.base, ignore_errors=True)


def main():
    failed = 0
    results = []

    def check(name, ok, detail=""):
        nonlocal failed
        failed += not ok
        results.append(f"{'ok ' if ok else 'НЕ '} {name}" + (f" — {detail}" if detail and not ok else ""))

    w = Workspace()
    try:
        # --- разрешено ---
        a = w.make(w.allowed, "a")
        code, err = w.run("-rf", mixed(a))
        check("цель внутри корня, форма C:/…", code == 0 and not os.path.exists(a), err)

        b = w.make(w.allowed, "b")
        code, err = w.run("-rf", posix(b))
        check("цель внутри корня, форма /c/…", code == 0 and not os.path.exists(b), err)

        c = w.make(w.allowed, "c")
        code, err = w.run(shell=f'D="{posix(c)}"; bash "$GRM" -rf "$D"')
        check("цель через переменную", code == 0 and not os.path.exists(c), err)

        g1, g2 = w.make(w.allowed, "g1"), w.make(w.allowed, "g2")
        code, err = w.run(shell=f'bash "$GRM" -rf {posix(w.allowed)}/g*')
        check("шаблон имени", code == 0 and not os.path.exists(g1) and not os.path.exists(g2), err)

        m1, m2 = w.make(w.allowed, "m1"), w.make(w.allowed, "m2")
        code, err = w.run("-r", "-f", mixed(m1), posix(m2))
        check("две цели внутри, раздельные флаги", code == 0 and not os.path.exists(m1) and not os.path.exists(m2), err)

        wt = w.make(w.ws, ".claude", "worktrees", "wt1")
        code, err = w.run("-rf", mixed(wt))
        check("{WORKSPACE}/.claude/worktrees", code == 0 and not os.path.exists(wt), err)

        code, err = w.run("-rf", mixed(os.path.join(w.allowed, "absent")))
        check("несуществующая цель внутри — без ошибки", code == 0, err)

        dash = w.make(w.allowed, "-x")
        code, err = w.run("-rf", "--", mixed(dash))
        check("имя с дефисом после --", code == 0 and not os.path.exists(dash), err)

        if os.name == "nt":
            up = w.make(w.allowed, "up")
            code, err = w.run("-rf", mixed(up).upper())
            check("другой регистр пути на Windows", code == 0 and not os.path.exists(up), err)

        code, err = w.run("-rf")
        check("без целей — ничего не делает", code == 0, err)

        # --- отказ, ничего не удалено ---
        o = w.make(w.outside, "o")
        code, err = w.run("-rf", mixed(o))
        check("цель вне корней", code == 1 and os.path.exists(o) and "вне разрешённых" in err, err)

        keep = w.make(w.allowed, "keep")
        code, err = w.run("-rf", mixed(keep), mixed(o))
        check("одна цель внутри, одна вне — не удалено ничего", code == 1 and os.path.exists(keep) and os.path.exists(o), err)

        code, err = w.run("-rf", mixed(w.allowed))
        check("сам корень", code == 1 and os.path.exists(w.allowed) and "сам разрешённый корень" in err, err)

        code, err = w.run("-rf", mixed(w.allowed) + "/")
        check("сам корень с косой", code == 1 and os.path.exists(w.allowed), err)

        code, err = w.run("-rf", mixed(w.allowed) + "/../outside/o")
        check("выход через ..", code == 1 and os.path.exists(o), err)

        evil = w.make(w.base, "allowed-evil")
        code, err = w.run("-rf", mixed(evil))
        check("соседний каталог с общим началом имени", code == 1 and os.path.exists(evil), err)

        code, err = w.run("-rf", "")
        check("пустая цель", code == 1 and "пустая цель" in err, err)

        code, err = w.run(shell='D=; bash "$GRM" -rf "$D/"')
        check("пустая переменная → /", code == 1, err)

        code, err = w.run("-rf", "--no-preserve-root", mixed(keep))
        check("--no-preserve-root", code == 1 and os.path.exists(keep), err)

        code, err = w.run("-rf", "relative-name")
        check("относительная цель вне корней (текущий каталог)", code == 1, err)

        link = os.path.join(w.allowed, "link")
        subprocess.run(["bash", "-c", f'ln -s "{posix(w.outside)}" "{posix(link)}"'], capture_output=True)
        if os.path.islink(link):
            code, err = w.run("-rf", mixed(link))
            check("ссылка внутри корня на каталог снаружи", code == 1 and os.path.exists(o), err)
            code, err = w.run("-rf", mixed(link) + "/o")
            check("путь через ссылку наружу", code == 1 and os.path.exists(o), err)
        else:
            results.append("пропуск: ln -s в этой среде не создаёт ссылку (копирует) — случаи ссылок не проверены")
            shutil.rmtree(link, ignore_errors=True)

        if os.name == "nt":
            junction = os.path.join(w.allowed, "j")
            subprocess.run(["cmd", "/c", "mklink", "/J", junction, w.outside], capture_output=True)
            if os.path.exists(os.path.join(junction, "o")):
                code, err = w.run("-rf", mixed(junction) + "/o")
                check("путь через junction наружу (Windows)", code == 1 and os.path.exists(o), err)
                code, err = w.run("-rf", mixed(junction))
                check("сама junction наружу (Windows)", code == 1 and os.path.exists(o), err)
                subprocess.run(["cmd", "/c", "rmdir", junction], capture_output=True)
            else:
                results.append("пропуск: mklink /J не создал junction — случай не проверен")

        # --- сбой внешних программ: отказ, ничего не удалено (рецензия Codex, круг 1) ---
        def faulty(tool, fail_from=1):
            """Подделка tool: с вызова номер fail_from выходит с кодом 3, до того — настоящий tool."""
            fake = tempfile.mkdtemp(prefix="grm-fake-")
            counter = posix(os.path.join(fake, "count"))
            real_tool = subprocess.run(["bash", "-c", f"command -v {tool}"], capture_output=True, text=True).stdout.strip()
            with open(os.path.join(fake, tool), "w", newline="\n") as f:
                f.write(f'#!/bin/sh\nn=$(cat "{counter}" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "{counter}"\n'
                        f'if [ "$n" -ge {fail_from} ]; then exit 3; fi\nexec "{real_tool}" "$@"\n')
            os.chmod(os.path.join(fake, tool), 0o755)
            return fake

        def run_with(fake, victim):
            return subprocess.run(["bash", "-c", f'PATH="{posix(fake)}:$PATH"; bash "{posix(w.script)}" -rf "{posix(victim)}"'],
                                  capture_output=True, text=True, encoding="utf-8", errors="replace")

        tools = ("cygpath", "tr", "dirname") if os.name == "nt" else ("dirname",)
        for tool in tools:
            fake = faulty(tool)
            victim = w.make(w.allowed, f"victim-{tool}")
            proc = run_with(fake, victim)
            check(f"сбой {tool} — отказ, цель на месте", proc.returncode != 0 and os.path.exists(victim)
                  and "ничего не удалено" in proc.stderr, proc.stderr.strip())
            shutil.rmtree(fake, ignore_errors=True)

        # Сбой на второй записи реестра, когда первая уже принята (класс дефекта из рецензии Codex, круг 1:
        # там падал sed на строке {WORKSPACE}/..., а уже принятого корня хватало для удаления).
        if os.name == "nt":
            fake = faulty("cygpath", fail_from=2)
            victim = w.make(w.allowed, "victim-second-entry")
            proc = run_with(fake, victim)
            check("сбой нормализации на второй записи реестра — отказ, цель на месте",
                  proc.returncode != 0 and os.path.exists(victim) and "ничего не удалено" in proc.stderr, proc.stderr.strip())
            shutil.rmtree(fake, ignore_errors=True)

        # --- реестр ---
        w.registry("")
        code, err = w.run("-rf", mixed(keep))
        check("пустой реестр", code == 1 and os.path.exists(keep) and "пуст" in err, err)

        w.registry("relative/path\n")
        code, err = w.run("-rf", mixed(keep))
        check("непонятная запись реестра", code == 1 and os.path.exists(keep) and "непонятная запись" in err, err)

        for entry in ("/", "C:/", "c:", "/c"):
            w.registry(f"{mixed(w.allowed)}\n{entry}\n")
            code, err = w.run("-rf", mixed(keep))
            check(f"корень ФС или диска в реестре: {entry}", code == 1 and os.path.exists(keep) and "корень файловой системы или диска" in err, err)

        os.remove(os.path.join(w.ws, ".claude", "config", "guarded-rm-roots.txt"))
        code, err = w.run("-rf", mixed(keep))
        check("нет реестра", code == 1 and os.path.exists(keep) and "нет реестра" in err, err)

        # --- {TMP} / {TMPDIR} where /tmp is ONE path component (Linux): a realpath that does not
        # resolve /tmp to /private/tmp (as macOS does) stands in for it. The check that a registry
        # root has two components used to refuse the temp-dir tokens themselves. ---
        if os.name != "nt":
            stub = tempfile.mkdtemp(prefix="dg-realpath-")
            with open(os.path.join(stub, "realpath"), "w", newline="\n") as f:
                f.write('#!/bin/sh\nfor a; do last="$a"; done\nprintf "%s\\n" "$last"\n')
            os.chmod(os.path.join(stub, "realpath"), 0o755)
            env = dict(os.environ, PATH=stub + os.pathsep + os.environ["PATH"])

            def run_linux(*args, extra_env=None):
                proc = subprocess.run(["bash", w.script, *args], capture_output=True, text=True, encoding="utf-8",
                                      errors="replace", env=dict(env, **(extra_env or {})))
                return proc.returncode, proc.stderr.strip()

            w.registry("{TMP}\n")
            inside = tempfile.mkdtemp(prefix="dg-tmp-target-", dir="/tmp")
            code, err = run_linux("-rf", inside)
            check("{TMP} = /tmp (одна часть пути): цель внутри удаляется", code == 0 and not os.path.exists(inside), err)
            code, err = run_linux("-rf", "/etc/dg-guarded-rm-absent-target")
            check("{TMP} = /tmp: цель вне корня отказ", code == 1 and "вне разрешённых" in err, err)
            w.registry("{TMPDIR}\n")
            inside = tempfile.mkdtemp(prefix="dg-tmpdir-target-", dir="/tmp")
            code, err = run_linux("-rf", inside, extra_env={"TMPDIR": "/tmp"})
            check("{TMPDIR}=/tmp: цель внутри удаляется", code == 0 and not os.path.exists(inside), err)
            code, err = run_linux("-rf", "/tmp/dg-guarded-rm-absent-target", extra_env={"TMPDIR": "/"})
            check("{TMPDIR}=/ — корень ФС в реестре: отказ", code == 1 and "корень файловой системы" in err, err)
            shutil.rmtree(stub, ignore_errors=True)
    finally:
        w.close()

    print("\n".join(results))
    total = sum(1 for r in results if not r.startswith("пропуск"))
    print(f"итог: {total - failed} из {total} как ожидалось")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
