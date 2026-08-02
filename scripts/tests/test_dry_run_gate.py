"""
Тесты dry-run-gate.sh (issue #237 v2 + issue #264 whitelist).

Прогоняют хук как subprocess с JSON-payload на stdin и проверяют returncode:
  exit 2 = block (sentinel активен, команда write)
  exit 0 = allow (sentinel отсутствует/истёк, команда read-only или whitelisted)

Sentinel — единый /tmp/iwe-dry-run.flag. Если файл существует до теста
(живой dry-run прямо сейчас) — весь модуль skip, чтобы не снимать чужой
sentinel. После тестов sentinel удаляется (созданный нами).

Сценарии #237: subshell-обход `(git commit)`, кавычный false-positive
`echo "git commit"`. Сценарий #264: read-only helper
`bash .claude/scripts/load-extensions.sh ...` разрешён, произвольный
`bash script.sh` по-прежнему блокируется.
"""

import json
import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest

HOOK = Path(__file__).parent.parent.parent / ".claude" / "hooks" / "dry-run-gate.sh"
SENTINEL = Path("/tmp/iwe-dry-run.flag")

pytestmark = pytest.mark.skipif(
    not shutil.which("jq"), reason="dry-run-gate требует jq (setup requirement)"
)


def _run_hook(command: str) -> subprocess.CompletedProcess:
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
    return subprocess.run(
        ["bash", str(HOOK)],
        input=payload,
        capture_output=True,
        text=True,
        timeout=10,
    )


@pytest.fixture
def sentinel():
    if SENTINEL.exists():
        pytest.skip("живой dry-run sentinel активен — не трогаем чужой")
    SENTINEL.write_text('{"initiator": "pytest", "created_at": "test"}', encoding="utf-8")
    yield SENTINEL
    SENTINEL.unlink(missing_ok=True)


class TestSentinelActive:
    def test_whitelisted_load_extensions_allowed(self, sentinel):
        """#264: read-only helper из whitelist пропускается."""
        r = _run_hook("bash .claude/scripts/load-extensions.sh day-close before")
        assert r.returncode == 0, r.stderr

    def test_whitelisted_absolute_path_allowed(self, sentinel):
        """Абсолютный путь разрешён только привязанный к workspace ($HOME/IWE)."""
        r = _run_hook(f"bash {Path.home()}/IWE/.claude/scripts/load-extensions.sh day-open after")
        assert r.returncode == 0, r.stderr

    def test_decoy_tmp_path_blocked(self, sentinel):
        """review-01 High: подложный /tmp/.claude/scripts/load-extensions.sh — block."""
        r = _run_hook("bash /tmp/.claude/scripts/load-extensions.sh day-close before")
        assert r.returncode == 2

    def test_arbitrary_bash_script_blocked(self, sentinel):
        """Whitelist узкий: любой другой скрипт — block."""
        r = _run_hook("bash scripts/deploy.sh --prod")
        assert r.returncode == 2

    def test_bash_c_blocked(self, sentinel):
        r = _run_hook("bash -c 'rm -rf /tmp/x'")
        assert r.returncode == 2

    def test_eval_source_xargs_blocked(self, sentinel):
        for cmd in ("eval rm x", "source ~/.secrets/env", ". ./write.sh", "echo f | xargs rm"):
            assert _run_hook(cmd).returncode == 2, cmd

    def test_subshell_git_commit_blocked(self, sentinel):
        """#237 п.1: обход через скобки."""
        assert _run_hook("(git commit -am x)").returncode == 2

    def test_quoted_git_commit_allowed(self, sentinel):
        """#237 п.4: текст в кавычках — не команда."""
        r = _run_hook('echo "see: git commit"')
        assert r.returncode == 0, r.stderr

    def test_plain_git_write_blocked(self, sentinel):
        assert _run_hook("git commit -m x").returncode == 2
        assert _run_hook("git push origin main").returncode == 2

    def test_readonly_git_allowed(self, sentinel):
        for cmd in ("git status --short", "git log --oneline -3", "git diff HEAD"):
            r = _run_hook(cmd)
            assert r.returncode == 0, cmd

    def test_redirect_and_fs_mutation_blocked(self, sentinel):
        assert _run_hook("echo x > /tmp/iwe-drg-test-f").returncode == 2
        assert _run_hook("rm /tmp/iwe-drg-test-f").returncode == 2
        assert _run_hook("sed -i '' s/a/b/ f.txt").returncode == 2

    def test_own_sentinel_cleanup_allowed(self, sentinel):
        """Единственное rm-исключение — собственный sentinel."""
        r = _run_hook("rm -f /tmp/iwe-dry-run.flag")
        assert r.returncode == 0, r.stderr


class TestAbsolutePathBypass:
    """2026-07-23: полный/относительный путь к команде должен классифицироваться
    так же, как bare имя команды (basename-нормализация первого слова фрагмента
    и слова-обёртки sudo/env/... — найдено при аудите барьеров)."""

    def test_absolute_path_git_commit_blocked(self, sentinel):
        assert _run_hook("/usr/bin/git commit -m x").returncode == 2

    def test_absolute_path_git_push_blocked(self, sentinel):
        assert _run_hook("/usr/bin/git push origin main").returncode == 2

    def test_relative_dot_git_commit_blocked(self, sentinel):
        assert _run_hook("./git commit -m x").returncode == 2

    def test_absolute_path_readonly_git_allowed(self, sentinel):
        for cmd in ("/usr/bin/git status --short", "/usr/bin/git log --oneline -3"):
            r = _run_hook(cmd)
            assert r.returncode == 0, cmd

    def test_absolute_path_rm_blocked(self, sentinel):
        assert _run_hook("/bin/rm /tmp/iwe-drg-test-f").returncode == 2

    def test_absolute_path_bash_script_blocked(self, sentinel):
        """Whitelist по-прежнему сверяется с полным путём — произвольный скрипт под /bin/bash тоже блокируется."""
        assert _run_hook("/bin/bash scripts/deploy.sh --prod").returncode == 2

    def test_absolute_sudo_wrapper_git_blocked(self, sentinel):
        """Обёртка sudo/env через полный путь тоже резолвится по basename."""
        assert _run_hook("/usr/bin/sudo git commit -m x").returncode == 2

    def test_absolute_env_wrapper_git_blocked(self, sentinel):
        assert _run_hook("/usr/bin/env git push origin main").returncode == 2

    def test_lookalike_word_not_falsely_blocked(self, sentinel):
        """Слово, оканчивающееся на 'git' без разделителя '/' — не git-команда."""
        r = _run_hook("mygit commit -m x")
        assert r.returncode == 0, r.stderr


class TestDayClosePrepareWhitelist:
    """2026-07-23 (issue #264 расширение): day-close-prepare.sh полностью
    read-only (digest + --verify — только echo/grep/git log/git status
    --porcelain/ls/python3 check-index-health.py), но не был в whitelist и
    блокировался под dry-run как произвольный скрипт."""

    def test_relative_path_allowed(self, sentinel):
        r = _run_hook("bash FMT-exocortex-template/scripts/day-close-prepare.sh")
        assert r.returncode == 0, r.stderr

    def test_absolute_path_allowed(self, sentinel):
        r = _run_hook(f"bash {Path.home()}/IWE/FMT-exocortex-template/scripts/day-close-prepare.sh")
        assert r.returncode == 0, r.stderr

    def test_absolute_path_with_verify_arg_allowed(self, sentinel):
        r = _run_hook(f"bash {Path.home()}/IWE/FMT-exocortex-template/scripts/day-close-prepare.sh --verify")
        assert r.returncode == 0, r.stderr

    def test_decoy_tmp_path_blocked(self, sentinel):
        """Подложный путь (не привязанный к $HOME/IWE) — block, как и для load-extensions.sh."""
        r = _run_hook("bash /tmp/FMT-exocortex-template/scripts/day-close-prepare.sh")
        assert r.returncode == 2

    def test_other_script_still_blocked(self, sentinel):
        """Whitelist узкий — соседний скрипт в той же папке по-прежнему блокируется."""
        r = _run_hook(f"bash {Path.home()}/IWE/FMT-exocortex-template/scripts/day-open-preflight.sh")
        assert r.returncode == 2


class TestDayClosePrepareQuotedInvocation:
    """2026-07-23: реальный вызов из day-close/SKILL.md шаг 0б —
    `bash "$IWE_SCRIPTS/day-close-prepare.sh"`, путь В КАВЫЧКАХ. До v3 quote-strip
    стирал кавычный спан в фиксированный "QSTR" ДО whitelist-проверки, поэтому
    именно эта, реальная форма вызова гарантированно блокировалась — plain-путь
    без кавычек (см. TestDayClosePrepareWhitelist выше) проходил и маскировал баг.
    v3 хранит исходный текст спана в QVALS[] и разворачивает его точечно внутри
    check_indirect(), сегментация видит только безопасный плейсхолдер."""

    def test_quoted_literal_iwe_scripts_var_allowed(self, sentinel):
        """Буквально то, что написано в SKILL.md: переменная НЕ развёрнута самим
        хуком (он не исполняет команду, только парсит текст) — сравнение идёт
        по литеральному тексту '$IWE_SCRIPTS/day-close-prepare.sh'."""
        r = _run_hook('bash "$IWE_SCRIPTS/day-close-prepare.sh"')
        assert r.returncode == 0, r.stderr

    def test_quoted_absolute_path_allowed(self, sentinel):
        r = _run_hook(f'bash "{Path.home()}/IWE/FMT-exocortex-template/scripts/day-close-prepare.sh"')
        assert r.returncode == 0, r.stderr

    def test_quoted_relative_path_allowed(self, sentinel):
        r = _run_hook('bash "FMT-exocortex-template/scripts/day-close-prepare.sh"')
        assert r.returncode == 0, r.stderr

    def test_quoted_absolute_path_with_verify_allowed(self, sentinel):
        r = _run_hook(f'bash "{Path.home()}/IWE/FMT-exocortex-template/scripts/day-close-prepare.sh" --verify')
        assert r.returncode == 0, r.stderr

    def test_quoted_decoy_tmp_path_blocked(self, sentinel):
        """Кавычки сами по себе не открывают обход — подложный путь всё ещё вне whitelist."""
        r = _run_hook('bash "/tmp/FMT-exocortex-template/scripts/day-close-prepare.sh"')
        assert r.returncode == 2

    def test_quoted_other_script_still_blocked(self, sentinel):
        """Whitelist матчит точный литерал, не префикс/директорию — соседний скрипт в кавычках тоже блок."""
        r = _run_hook(f'bash "{Path.home()}/IWE/FMT-exocortex-template/scripts/day-open-preflight.sh"')
        assert r.returncode == 2

    def test_quoted_iwe_scripts_var_other_script_blocked(self, sentinel):
        """Whitelist по литералу '$IWE_SCRIPTS/day-close-prepare.sh' — не по всей директории $IWE_SCRIPTS."""
        r = _run_hook('bash "$IWE_SCRIPTS/day-open-preflight.sh"')
        assert r.returncode == 2


class TestSentinelInactive:
    def test_no_sentinel_allows_everything(self):
        if SENTINEL.exists():
            pytest.skip("живой dry-run sentinel активен")
        r = _run_hook("git commit -m x")
        assert r.returncode == 0, r.stderr

    def test_stale_sentinel_removed_and_allows(self):
        if SENTINEL.exists():
            pytest.skip("живой dry-run sentinel активен")
        SENTINEL.write_text("{}", encoding="utf-8")
        stale = time.time() - 700
        os.utime(SENTINEL, (stale, stale))
        try:
            r = _run_hook("git commit -m x")
            assert r.returncode == 0, r.stderr
            assert not SENTINEL.exists(), "протухший sentinel должен быть удалён хуком"
        finally:
            SENTINEL.unlink(missing_ok=True)
