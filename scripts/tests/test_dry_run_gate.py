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

    def test_nice_wrapper_blocked(self, sentinel):
        """issue #825: `nice` was missing from the wrapper-skip list, so
        `nice rm -f ...` rode past the classifier unclassified. Cold-review
        (second pass) found the fix only closed the bare `nice cmd` form —
        `nice -n 19 cmd`/`nice -n19 cmd` (the common real-world form, an
        adjustment value is normal usage) still bypassed because the
        argument itself doesn't match any wrapper/VAR= pattern and stops the
        loop on it. All of nice's argument forms plus the legacy `-N` form
        must be skipped, not just the bare wrapper word."""
        for cmd in (
            "nice rm -f /tmp/iwe-drg-nice-test",
            "nice -n 19 rm -f /tmp/iwe-drg-nice-test",
            "nice -n19 rm -f /tmp/iwe-drg-nice-test",
            "nice --adjustment=19 rm -f /tmp/iwe-drg-nice-test",
            "nice -19 rm -f /tmp/iwe-drg-nice-test",
        ):
            assert _run_hook(cmd).returncode == 2, cmd
        # read-only under the same wrapper still allowed
        assert _run_hook("nice -n 19 git status").returncode == 0

    def test_absolute_path_wrapper_and_command_blocked(self, sentinel):
        """issue #825 part 2: the classifier matched the leading token
        literally, so an absolute-path invocation of a wrapper (`/usr/bin/nice
        ...`) or of the real command itself (`/usr/bin/git commit`, `/bin/rm`)
        matched no case arm and fell through to the default allow at the end
        of the file. Basename resolution (`${token##*/}`) closes this without
        touching the WL_ABS*/whitelist literal-path comparisons, which stay
        deliberately exact-match (review-01/02: glob or env-based resolution
        there let a decoy path or IWE_ROOT injection through)."""
        for cmd in (
            "/usr/bin/nice rm -f /tmp/iwe-drg-nice-test",
            "/usr/bin/git commit -am x",
            "/bin/rm -f /tmp/iwe-drg-nice-test",
        ):
            assert _run_hook(cmd).returncode == 2, cmd

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

    def test_ordinary_stop_survives_leftover_dry_dir(self, tmp_path):
        """issue #818: `complete_dry_run_on_stop` arms a RETURN trap that
        references its own locals (lock_dir/nonce) and never clears it. bash
        does not scope a RETURN trap to the function that set it — it stays
        armed for the next `source` in the same process. This hook sources
        iwe-env-bootstrap.sh right after calling this function (line ~167),
        so an ordinary Stop with a leftover (no active gate) dry-run state
        directory used to crash with "unbound variable" under `set -u`, even
        with zero active rehearsal. Reproduces the exact trigger: a real
        dry_dir that exists (matching test-mode override contract used by
        dry-run-gate.sh) but no matching active gate-*.state for this
        session_id — exercises the code past the trap-arming line, not just
        the earlier no-op return paths."""
        dry_dir = tmp_path / "dry-dir"
        dry_dir.mkdir()
        (dry_dir / ".iwe-dry-run-test-mode").write_text("1", encoding="utf-8")
        # transcript_path must exist and be readable: the hook short-circuits
        # (exits before sourcing iwe-env-bootstrap.sh, the actual trap
        # trigger) on a missing/empty path — an empty JSONL file is enough,
        # only its existence matters for reaching the source line.
        transcript = tmp_path / "transcript.jsonl"
        transcript.write_text("", encoding="utf-8")
        env = dict(os.environ, IWE_DRY_RUN_DIR=str(dry_dir), IWE_DRY_RUN_SENTINEL=str(dry_dir / "sentinel.flag"))
        payload = json.dumps({"session_id": "no-active-gate-session", "transcript_path": str(transcript)})
        result = subprocess.run(
            ["bash", str(STOP_HOOK)],
            input=payload,
            capture_output=True,
            text=True,
            timeout=10,
            env=env,
        )
        assert result.returncode == 0, result.stderr
        assert "unbound variable" not in result.stderr
