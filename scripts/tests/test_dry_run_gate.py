"""
Тесты dry-run-gate.sh (issue #237 v2 + issue #264 whitelist).

Прогоняют хук как subprocess с JSON-payload на stdin и проверяют returncode:
  exit 2 = block (sentinel активен/протух/owner-residue, команда write/индиректная)
  exit 0 = allow (никакой репетиции не объявлено, команда read-only или whitelisted)

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
STOP_HOOK = Path(__file__).parent.parent.parent / ".claude" / "hooks" / "protocol-stop-gate.sh"
SENTINEL = Path("/tmp/iwe-dry-run.flag")
OWNER = Path("/tmp/iwe-dry-run-owner-pytest-session.token")

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
    OWNER.write_text("pytest-capability", encoding="utf-8")
    SENTINEL.write_text(
        json.dumps(
            {
                "initiator": "pytest",
                "created_at": "test",
                "session_id": "pytest-session",
                "owner_token": "pytest-capability",
                "owner_file": str(OWNER),
            }
        ),
        encoding="utf-8",
    )
    yield SENTINEL
    SENTINEL.unlink(missing_ok=True)
    OWNER.unlink(missing_ok=True)


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

    def test_python_script_blocked(self, sentinel):
        """issue #460 path 5: extensions run `python3 garmin-collect.py`
        (network + file writes) — the matcher had no branch for it at all."""
        for cmd in ("python3 garmin-collect.py", "python script.py --write"):
            assert _run_hook(cmd).returncode == 2, cmd

    def test_python_decoy_path_blocked(self, sentinel):
        """Same basename in a different directory must not ride on the
        whitelist — same review-01 High lesson as the bash decoy test above."""
        r = _run_hook("python3 /tmp/evil/memory-drift-scan.py")
        assert r.returncode == 2, r.stderr

    def test_python_template_injection_blocked(self, sentinel):
        """round-2 code review Critical: an early version matched
        `${IWE_TEMPLATE:-[^}]*}/...` (wildcard default) — command substitution
        inside the default value got swallowed by the whitelist marker BEFORE
        step-2 segmentation could see it, so `$(...)` injected there rode
        straight through as allow. Fixed to an exact $HOME-anchored literal,
        same lesson as WL_ABS/WL_ABS2 (review-01 High/review-02 H1)."""
        r = _run_hook("python3 ${IWE_TEMPLATE:-$(touch /tmp/iwe-drg-test-pwned)}/.claude/scripts/memory-drift-scan.py")
        assert r.returncode == 2, r.stderr
        assert not Path("/tmp/iwe-drg-test-pwned").exists()

    def test_python_whitelisted_readonly_scripts_allowed(self, sentinel):
        """issue #460 path 5 code review (Critical): day-close/SKILL.md steps 1-2
        call these two read-only diagnostics unconditionally via unquoted
        `${IWE_TEMPLATE:-<home>/IWE/FMT-exocortex-template}/...` — an
        unconditional python|python3 block would fail the ritual on its very
        first step, exactly the "❌ ритуал ломается рано" case the contract
        itself warns about. Confirmed no write paths in both scripts."""
        for script in ("memory-drift-scan.py", "check-index-health.py"):
            cmd = f"python3 ${{IWE_TEMPLATE:-{Path.home()}/IWE/FMT-exocortex-template}}/.claude/scripts/{script}"
            r = _run_hook(cmd)
            assert r.returncode == 0, f"{script}: {r.stderr}"

    def test_python_inline_c_snippet_allowed(self, sentinel):
        """day-close-details.md's STRATEGY_DAY_NAME guard runs a read-only
        `python3 -c "..."` before step 1 — already outside this contract's
        threat model per §«Не входит в контракт» (malicious -c bypass is a
        documented accepted gap), so exempting it doesn't remove protection
        that existed; it only stops a new false block on a legitimate read."""
        cmd = 'STRATEGY_DAY_NAME=$(python3 -c "import yaml; print(1)")'
        r = _run_hook(cmd)
        assert r.returncode == 0, r.stderr

    def test_python_rule_classifier_still_blocked(self, sentinel):
        """rule-classifier.py is NOT whitelisted — day-close/SKILL.md itself
        documents it writes ("его правки уходят в незакоммиченный хвост"),
        so it must stay blocked under dry-run, real invocation form."""
        cmd = 'SCRIPT="$HOME/IWE/.claude/scripts/rule-classifier.py"; [ -f "$SCRIPT" ] && python3 "$SCRIPT"'
        r = _run_hook(cmd)
        assert r.returncode == 2, r.stderr


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
        """No sentinel AND no owner-file: nothing claims a rehearsal is active."""
        if SENTINEL.exists():
            pytest.skip("живой dry-run sentinel активен")
        assert not OWNER.exists(), "test owner-file leaked from a prior test"
        r = _run_hook("git commit -m x")
        assert r.returncode == 0, r.stderr

    def test_no_sentinel_with_owner_file_blocks(self):
        """issue #460 path 2: sentinel gone but owner-file still claims an
        active rehearsal — fail-CLOSED instead of the old silent allow."""
        if SENTINEL.exists():
            pytest.skip("живой dry-run sentinel активен")
        OWNER.write_text("pytest-capability", encoding="utf-8")
        try:
            r = _run_hook("git commit -m x")
            assert r.returncode == 2, r.stderr
            assert "BLOCKED" in r.stderr
        finally:
            OWNER.unlink(missing_ok=True)

    def test_stale_sentinel_blocks_and_is_kept(self):
        """issue #460 path 3: TTL expiry used to rm+allow — now fail-closed,
        sentinel kept in place (not deleted) for manual inspection."""
        if SENTINEL.exists():
            pytest.skip("живой dry-run sentinel активен")
        SENTINEL.write_text("{}", encoding="utf-8")
        stale = time.time() - 2500  # > TTL_SECONDS (2400) in dry-run-gate.sh
        os.utime(SENTINEL, (stale, stale))
        try:
            r = _run_hook("git commit -m x")
            assert r.returncode == 2, r.stderr
            assert SENTINEL.exists(), "протухший sentinel не должен удаляться гейтом"
        finally:
            SENTINEL.unlink(missing_ok=True)

    def test_fresh_sentinel_within_extended_ttl_still_blocks(self):
        """TTL raised from 600s to 2400s (issue #460 path 3) so a live
        rehearsal at the old 700s mark keeps protecting, not falls through."""
        if SENTINEL.exists():
            pytest.skip("живой dry-run sentinel активен")
        SENTINEL.write_text("{}", encoding="utf-8")
        aged = time.time() - 700
        os.utime(SENTINEL, (aged, aged))
        try:
            r = _run_hook("git commit -m x")
            assert r.returncode == 2, r.stderr
        finally:
            SENTINEL.unlink(missing_ok=True)


class TestJqMissing:
    """issue #460 path 1: a gate that can't parse its own payload must
    fail-CLOSED, not silently allow every write while jq is absent."""

    def test_jq_missing_blocks(self):
        # The hook hardcodes its own PATH (export PATH=... near the top) to
        # standard install locations, so an empty $PATH in the parent shell
        # can't hide jq from it — and using that same empty $PATH to invoke
        # `bash` itself just makes bash unfindable instead. Point the hook's
        # own hardcoded PATH at an empty directory via a stubbed copy, and
        # invoke that copy with an absolute `bash` binary so bash-the-runner
        # is never affected by the PATH we're hiding jq behind.
        empty_bin = Path("/tmp/iwe-drg-test-empty-bin")
        empty_bin.mkdir(exist_ok=True)
        stub_hook = Path("/tmp/iwe-drg-test-stub-hook.sh")
        original = HOOK.read_text(encoding="utf-8")
        patched = original.replace(
            'export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"',
            f'export PATH="{empty_bin}"',
        )
        assert patched != original, "hook's PATH export line changed shape — update this stub"
        stub_hook.write_text(patched, encoding="utf-8")
        try:
            payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": "git commit -m x"}})
            r = subprocess.run(
                ["/bin/bash", str(stub_hook)], input=payload, capture_output=True, text=True, timeout=10
            )
            assert r.returncode == 2, r.stderr
            assert "FAIL-CLOSED" in r.stderr
            assert "jq" in r.stderr
        finally:
            stub_hook.unlink(missing_ok=True)
            empty_bin.rmdir()


class TestStopOwnership:
    def _run_stop(self, session_id: str) -> subprocess.CompletedProcess:
        payload = json.dumps({"session_id": session_id, "transcript_path": "/missing"})
        return subprocess.run(
            ["bash", str(STOP_HOOK)],
            input=payload,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_foreign_stop_cannot_remove_sentinel(self, sentinel):
        result = self._run_stop("neighbour-session")
        assert result.returncode == 0, result.stderr
        assert SENTINEL.exists(), "чужой Stop не должен снимать dry-run защиту"

    def test_owner_stop_no_longer_removes_live_sentinel(self, sentinel):
        """issue #460 path 6: audit-installation's parent turn can Stop
        (session_id matches trivially) while a same-session background
        subagent is still writing under the sentinel. The old atomic
        session_id+token match still deleted it in that case — now the
        Stop hook never removes a live sentinel, owned or not."""
        result = self._run_stop("pytest-session")
        assert result.returncode == 0, result.stderr
        assert SENTINEL.exists(), "Stop не должен снимать ещё живой sentinel, даже свой"
        assert OWNER.exists(), "owner-файл не трогается, пока sentinel жив"

    def test_owner_stop_clears_residue_owner_file_once_sentinel_gone(self):
        """Owner-file cleanup still happens, but only once the sentinel is
        confirmed already removed (explicit rm by the owning procedure) —
        not as a side effect of the same-session Stop that used to delete both."""
        if SENTINEL.exists():
            pytest.skip("живой dry-run sentinel активен")
        OWNER.write_text("pytest-capability", encoding="utf-8")
        try:
            result = self._run_stop("pytest-session")
            assert result.returncode == 0, result.stderr
            assert not OWNER.exists(), "sentinel уже снят явно — owner-файл residue, чистится"
        finally:
            OWNER.unlink(missing_ok=True)
