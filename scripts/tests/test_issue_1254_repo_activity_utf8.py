#!/usr/bin/env python3
"""Exercise the shipped activity renderer with Git fixtures under hostile locales."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(os.environ.get("SCAFFOLD_UNDER_TEST", ROOT / "scripts/day-open-scaffold.sh"))


class RepoActivityUtf8Test(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "workspace" / "repo"
        self.repo.mkdir(parents=True)
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.startswith("GIT_"):
                del self.env[key]
        self.env.update(
            GIT_CONFIG_NOSYSTEM="1",
            GIT_CONFIG_GLOBAL=os.devnull,
            LC_ALL="C",
            LANG="C",
            PYTHONUTF8="0",
            PYTHONCOERCECLOCALE="0",
            PYTHONIOENCODING="ascii",
            IWE=str(self.repo.parent),
            TEST_PYTHON=sys.executable,
        )
        self.git("init", "-q")
        self.script = self.root / "scripts" / "scaffold.sh"
        self.script.parent.mkdir()
        source = SOURCE.read_text(encoding="utf-8")
        functions = []
        for name in ("iwe_repo_dirs", "render_repo_activity"):
            match = re.search(rf"^{name}\(\) \{{\n.*?^\}}", source, re.M | re.S)
            self.assertIsNotNone(match, f"missing production function: {name}")
            functions.append(match.group())
        self.script.write_text("\n\n".join(functions) + "\n", encoding="utf-8")
        self.resolver = self.script.parent / "lib" / "find-python3.sh"
        self.resolver.parent.mkdir()
        self.set_resolver('printf "%s\\n" "$TEST_PYTHON"')

    def git(self, *args, input=None):
        return subprocess.run(
            ["git", "-C", str(self.repo), *args],
            input=input,
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout

    def commit(self, subject):
        self.git(
            "-c", "core.hooksPath=/dev/null",
            "-c", "commit.gpgsign=false",
            "-c", "user.name=Fixture",
            "-c", "user.email=fixture@example.invalid",
            "commit", "--allow-empty", "-q", "-F", "-",
            input=(subject + "\n").encode("utf-8"),
        )

    def set_resolver(self, body):
        self.resolver.write_text("#!/bin/sh\n" + body + "\n", encoding="utf-8")
        self.resolver.chmod(0o755)

    def render(self, **environment):
        result = subprocess.run(
            ["bash", "-c", 'set -uo pipefail; . "$1"; render_repo_activity',
             "fixture", str(self.script)],
            env={**self.env, **environment},
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        self.assertNotIn(b"Traceback", result.stderr)
        # The downstream patchers open DayPlan with strict UTF-8 decoding.
        plan = self.root / "DayPlan.md"
        plan.write_bytes(result.stdout)
        return plan.read_text(encoding="utf-8")

    def assert_subject(self, output, subject):
        self.assertEqual(len(output.splitlines()), 3, output)
        expected = subject if len(subject) <= 50 else subject[:50] + "…"
        self.assertEqual(output.splitlines()[2], f"| repo | 1 | {expected} |")

    def test_character_boundaries_and_output_encodings(self):
        for count in (49, 50, 51, 80):
            for encoding in ("ascii", "cp1251", "utf-8"):
                with self.subTest(count=count, encoding=encoding):
                    subject = ("Ж🙂я" * 30)[:count]
                    self.commit(subject)
                    output = self.render(PYTHONIOENCODING=encoding)
                    expected = subject if count <= 50 else subject[:50] + "…"
                    self.assertEqual(len(output.splitlines()), 3)
                    self.assertTrue(output.splitlines()[2].endswith(f"| {expected} |"))

    def test_literal_backslashes_are_not_interpreted(self):
        subject = r"fix: \xD0 \320 \n \c C:\new\test %s"
        self.commit(subject)
        self.assert_subject(self.render(), subject)

    def test_missing_python_has_visible_safe_fallback(self):
        self.commit("a" + "я" * 60)
        self.set_resolver("exit 1")
        output = self.render()
        self.assertEqual(len(output.splitlines()), 3)
        self.assertIn("заголовок недоступен", output)
        self.assertIn("Python 3 не найден", output)

    def test_python_failure_has_visible_safe_fallback(self):
        self.commit("Русская тема")
        self.env["TEST_PYTHON"] = shutil.which("false")
        output = self.render()
        self.assertEqual(len(output.splitlines()), 3)
        self.assertIn("заголовок недоступен", output)
        self.assertIn("ошибка чтения", output)

    def test_malformed_git_subject_is_replaced_at_input(self):
        self.commit("placeholder")
        # Inject exactly the broken-byte input reported by #1254, after Git.
        stubs = self.root / "bin"
        stubs.mkdir()
        git = stubs / "git"
        git.write_text(
            '#!/bin/sh\ncase "$*" in\n'
            '  *"log -1"*) printf "broken \\320\\n" ;;\n'
            '  *) printf "one commit\\n" ;;\nesac\n', encoding="utf-8"
        )
        git.chmod(0o755)
        output = self.render(PATH=str(stubs) + os.pathsep + self.env["PATH"])
        self.assert_subject(output, "broken �")

    def test_no_commits_has_visible_status(self):
        self.assertEqual(self.render().strip(), "Активности в репозиториях за 2 дня нет.")


if __name__ == "__main__":
    unittest.main()
