"""
Тесты destructive-guard.sh (PreToolUse:Bash — блокирует необратимые git-операции).

Прогоняют хук как subprocess с JSON-payload на stdin и проверяют returncode:
  exit 2 = block (force-push / reset --hard / clean -fdx)
  exit 0 = allow (безопасные варианты, read-only git)

В отличие от dry-run-gate.sh этот хук работает всегда (нет sentinel/dry-run
условия) — блокирует независимо от режима.

Сценарий (2026-07-23, аудит барьеров): git_segment() матчил `git` только когда
ему предшествовали начало строки / `;&|` / пробел — путь-префикс без пробела
(`/usr/bin/git`, `./git`) этому условию не удовлетворял и обходил блок целиком.
Фикс — необязательный path-prefix `(?:\\S*\\/)?` перед `git` в регэкспе.
"""

import json
import subprocess
from pathlib import Path

HOOK = Path(__file__).parent.parent.parent / ".claude" / "hooks" / "destructive-guard.sh"


def _run_hook(command: str) -> subprocess.CompletedProcess:
    payload = json.dumps({"tool_input": {"command": command}})
    return subprocess.run(
        ["bash", str(HOOK)],
        input=payload,
        capture_output=True,
        text=True,
        timeout=10,
    )


class TestBaseline:
    """Существовавшее поведение — не должно сломаться фиксом."""

    def test_plain_force_push_long_flag_blocked(self):
        assert _run_hook("git push --force").returncode == 2

    def test_plain_force_push_short_flag_blocked(self):
        assert _run_hook("git push -f origin main").returncode == 2

    def test_force_with_lease_allowed(self):
        r = _run_hook("git push --force-with-lease origin main")
        assert r.returncode == 0, r.stderr

    def test_plain_reset_hard_blocked(self):
        assert _run_hook("git reset --hard HEAD~1").returncode == 2

    def test_reset_soft_allowed(self):
        r = _run_hook("git reset --soft HEAD~1")
        assert r.returncode == 0, r.stderr

    def test_plain_clean_fdx_blocked(self):
        assert _run_hook("git clean -fdx").returncode == 2

    def test_readonly_git_allowed(self):
        for cmd in ("git status --short", "git log --oneline -3", "git push origin main"):
            r = _run_hook(cmd)
            assert r.returncode == 0, cmd

    def test_no_git_in_command_allowed(self):
        r = _run_hook("echo hello world")
        assert r.returncode == 0, r.stderr


class TestAbsolutePathBypass:
    """2026-07-23: полный/относительный путь к git должен блокироваться так же, как bare `git`."""

    def test_absolute_path_force_push_blocked(self):
        assert _run_hook("/usr/bin/git push --force").returncode == 2

    def test_absolute_path_force_push_short_flag_blocked(self):
        assert _run_hook("/usr/bin/git push -f origin main").returncode == 2

    def test_absolute_path_reset_hard_blocked(self):
        assert _run_hook("/usr/bin/git reset --hard HEAD~1").returncode == 2

    def test_absolute_path_clean_fdx_blocked(self):
        assert _run_hook("/usr/bin/git clean -fdx").returncode == 2

    def test_relative_dot_path_force_push_blocked(self):
        assert _run_hook("./git push --force").returncode == 2

    def test_nested_path_force_push_blocked(self):
        assert _run_hook("/usr/local/bin/git push --force").returncode == 2

    def test_absolute_path_force_with_lease_allowed(self):
        r = _run_hook("/usr/bin/git push --force-with-lease origin main")
        assert r.returncode == 0, r.stderr

    def test_absolute_path_readonly_git_allowed(self):
        for cmd in ("/usr/bin/git status --short", "/usr/bin/git push origin main"):
            r = _run_hook(cmd)
            assert r.returncode == 0, cmd

    def test_lookalike_word_not_falsely_blocked(self):
        """Слово, оканчивающееся на 'git' без разделителя '/' — не git-инвокация."""
        r = _run_hook("mygit push --force")
        assert r.returncode == 0, r.stderr
