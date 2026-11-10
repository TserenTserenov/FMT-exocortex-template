#!/usr/bin/env python3
"""Tests for scripts/check-changelog-fields.py (WP-529 Phase 252)."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "check-changelog-fields.py"

GOOD = """\
- [behavior] Good entry (#1).
  - Цель: 77 · Результат: Ц77-03
  - Как проверить: bash scripts/tests/test_x.sh
  - Как откатить: git revert of merge #1
"""

SERVICE = """\
- [optional] Service entry (#2).
  - Цель: 84, 90 · Результат: служебное — внутренняя проверка CI, пользователь не видит
  - Как проверить: запустить CI
  - Как откатить: git revert of merge #2
"""

NO_ROLLBACK = """\
- [behavior] Entry without rollback (#3).
  - Цель: 77 · Результат: Ц77-03
  - Как проверить: bash scripts/tests/test_y.sh
  - Как откатить:
"""

BARE = "- [docs] Bare entry without fields (#4).\n"

BAD_CODES = """\
- [behavior] Entry with wrong codes (#5).
  - Цель: потребность про выпуск · Результат: Ц77
  - Как проверить: x
  - Как откатить: y
"""


def changelog(unreleased: str, released: str = "") -> str:
    text = "# Changelog\n\n## [Unreleased]\n\n### Changed\n\n" + unreleased + "\n"
    if released:
        text += "## [0.42.0] — 2026-11-20\n\n### Changed\n\n" + released + "\n"
    return text + "## [0.41.11] — 2026-11-02\n\n### Changed\n\n" + BARE


def run(*args: str, cwd: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args], capture_output=True, text=True, cwd=cwd, check=False
    )


class FileModeTests(unittest.TestCase):
    def check(self, text: str, *args: str) -> subprocess.CompletedProcess[str]:
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as handle:
            handle.write(text)
        return run("--file", handle.name, *args)

    def test_complete_entries_pass(self) -> None:
        result = self.check(changelog(GOOD + "\n" + SERVICE))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("у всех 2 записей", result.stdout)

    def test_empty_rollback_fails(self) -> None:
        result = self.check(changelog(GOOD + "\n" + NO_ROLLBACK))
        self.assertEqual(result.returncode, 1)
        self.assertIn("Entry without rollback", result.stdout)
        self.assertIn("поле «Как откатить» пустое", result.stdout)
        self.assertNotIn("Good entry", result.stdout)

    def test_bare_entry_lists_all_four_fields(self) -> None:
        result = self.check(changelog(BARE))
        self.assertEqual(result.returncode, 1)
        for name in ("Цель", "Результат", "Как проверить", "Как откатить"):
            self.assertIn(f"нет поля «{name}»", result.stdout)

    def test_wrong_need_and_result_codes_fail(self) -> None:
        result = self.check(changelog(BAD_CODES))
        self.assertEqual(result.returncode, 1)
        self.assertIn("«Цель» — не номер потребности", result.stdout)
        self.assertIn("«Результат» — не код Ц", result.stdout)

    def test_version_section_is_checked_separately(self) -> None:
        text = changelog(GOOD, released=NO_ROLLBACK)
        self.assertEqual(self.check(text).returncode, 0)
        released = self.check(text, "--section", "0.42.0")
        self.assertEqual(released.returncode, 1)
        self.assertIn("Entry without rollback", released.stdout)


class OnlyAddedTests(unittest.TestCase):
    def test_old_bare_entries_are_ignored_new_ones_checked(self) -> None:
        with tempfile.TemporaryDirectory() as repo:
            def git(*args: str) -> None:
                subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)

            git("init", "-q")
            git("config", "user.email", "test@example.invalid")
            git("config", "user.name", "test")
            path = Path(repo) / "CHANGELOG.md"
            path.write_text(changelog(BARE), encoding="utf-8")
            git("add", "CHANGELOG.md")
            git("commit", "-q", "-m", "base")
            base = subprocess.run(
                ["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True, check=True
            ).stdout.strip()

            path.write_text(changelog(GOOD + "\n" + BARE), encoding="utf-8")
            git("commit", "-q", "-am", "good entry")
            ok = run("--ref", "HEAD", "--only-added", base, cwd=repo)
            self.assertEqual(ok.returncode, 0, ok.stdout)
            self.assertIn("у всех 1 новых записей", ok.stdout)

            path.write_text(changelog(GOOD + "\n" + NO_ROLLBACK + "\n" + BARE), encoding="utf-8")
            git("commit", "-q", "-am", "entry without rollback")
            bad = run("--ref", "HEAD", "--only-added", base, cwd=repo)
            self.assertEqual(bad.returncode, 1)
            self.assertIn("Entry without rollback", bad.stdout)
            self.assertNotIn("Bare entry", bad.stdout)

    def test_unreadable_ref_is_an_invocation_error(self) -> None:
        with tempfile.TemporaryDirectory() as repo:
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            result = run("--ref", "no-such-ref", cwd=repo)
            self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
