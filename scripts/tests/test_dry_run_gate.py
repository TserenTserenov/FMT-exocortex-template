"""
Тесты dry-run-gate.sh (issue #237 v2 + issue #264 whitelist).

Прогоняют хук как subprocess с JSON-payload на stdin и проверяют returncode:
  exit 2 = block (sentinel активен/протух/owner-residue, команда write/индиректная)
  exit 0 = allow (никакой репетиции не объявлено, команда read-only или whitelisted)

Sentinel и owner-файлы лежат в личном каталоге тестового режима
(маркер .iwe-dry-run-test-mode, переменные IWE_DRY_RUN_DIR/IWE_DRY_RUN_SENTINEL
только в окружении вызова хука): общий /tmp/iwe-dry-run.flag живой репетиции
тесты не создают и не удаляют.

Сценарии #237: subshell-обход `(git commit)`, кавычный false-positive
`echo "git commit"`. Сценарий #264: read-only helper
`bash .claude/scripts/load-extensions.sh ...` разрешён, произвольный
`bash script.sh` по-прежнему блокируется.
"""

import atexit
import json
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

import pytest

HOOK = Path(__file__).parent.parent.parent / ".claude" / "hooks" / "dry-run-gate.sh"
STOP_HOOK = Path(__file__).parent.parent.parent / ".claude" / "hooks" / "protocol-stop-gate.sh"
DRY_RUN_LIB = Path(__file__).parent.parent.parent / ".claude" / "lib" / "dry-run-dir.sh"
# The hook whitelists absolute paths under the IWE root it derives from its own
# location (`$HOOK_DIR/../..`, `pwd -P`), not under $HOME/IWE. Derive the same
# root here so the whitelist tests pass in any checkout, including CI.
IWE_ROOT = HOOK.parent.parent.parent.resolve()
# Private test-mode dir (0700 from mkdtemp): the hooks honour the override
# paths only when the marker is inside IWE_DRY_RUN_DIR.
DRY_DIR = Path(tempfile.mkdtemp(prefix="iwe-drg-"))
atexit.register(shutil.rmtree, DRY_DIR, ignore_errors=True)
(DRY_DIR / ".iwe-dry-run-test-mode").write_text("1", encoding="utf-8")
SENTINEL = DRY_DIR / "iwe-dry-run.flag"
OWNER = DRY_DIR / "iwe-dry-run-owner-pytest-session.token"
HOOK_ENV = dict(os.environ, IWE_DRY_RUN_DIR=str(DRY_DIR), IWE_DRY_RUN_SENTINEL=str(SENTINEL))

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
        env=HOOK_ENV,
    )


@pytest.fixture
def sentinel():
    if SENTINEL.exists():
        pytest.fail("sentinel leaked from a prior test")
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
        r = _run_hook(f"bash {IWE_ROOT}/.claude/scripts/load-extensions.sh day-open after")
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
        r = _run_hook(f"rm -f {SENTINEL}")
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
            cmd = f"python3 ${{IWE_TEMPLATE:-{IWE_ROOT}/FMT-exocortex-template}}/.claude/scripts/{script}"
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


class TestIwePathsChainWhitelist:
    """issue #1238: #1233's new .iwe-paths fallback-chain resolver
    (day-close/SKILL.md, dry-run-contract.md) is whitelisted as one exact
    text block in dry-run-gate.sh, not per-segment -- see the comment above
    the sed pipeline in the hook for why. The exact text here MUST match
    what's actually deployed in day-close/SKILL.md byte-for-byte; if either
    one changes without the other, these tests (or a live Day Close
    rehearsal) catch the drift."""

    CHAIN = (
        'IWE_PATHS="${IWE_PATHS_FILE:-}"; if [ -z "$IWE_PATHS" ]; then '
        'for _c in "$PWD/.iwe-paths" "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-paths" '
        '"$HOME/.iwe-paths"; do [ -r "$_c" ] && { IWE_PATHS="$_c"; break; }; '
        'done; fi; [ -n "$IWE_PATHS" ] && . "$IWE_PATHS"'
    )

    def test_exact_chain_allowed(self, sentinel):
        r = _run_hook(self.CHAIN)
        assert r.returncode == 0, r.stderr

    def test_chain_with_trailing_command_allowed(self, sentinel):
        """Deployed form: chain followed by the actual Day Close step command."""
        cmd = f'{self.CHAIN} 2>/dev/null; bash "$IWE_SCRIPTS/day-close-prepare.sh"'
        r = _run_hook(cmd)
        assert r.returncode == 0, r.stderr

    def test_extra_space_blocked(self, sentinel):
        """A single added space anywhere breaks the exact-text match --
        fail-closed by design, not a false positive to relax."""
        tampered = self.CHAIN.replace("; if ", ";  if ", 1)
        assert tampered != self.CHAIN
        r = _run_hook(tampered)
        assert r.returncode == 2, r.stderr

    def test_home_reassigned_before_chain_blocked(self):
        """The chain's own HOME fallback is only as trustworthy as the real
        $HOME; a command that reassigns HOME earlier (same attack class as
        the pre-existing #784/#785 HOME_OR_IWE_PATHS_TAMPERED check) must
        still be rejected even though the chain text itself matches
        verbatim -- this is a different sentinel per-test to avoid clashing
        with the fixture's sentinel mid-assertion."""
        if SENTINEL.exists():
            pytest.fail("sentinel leaked from a prior test")
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
        try:
            cmd = f'HOME=/tmp/evil; {self.CHAIN}'
            r = _run_hook(cmd)
            assert r.returncode == 2, r.stderr
        finally:
            SENTINEL.unlink(missing_ok=True)
            OWNER.unlink(missing_ok=True)

    def test_bare_dollar_iwe_paths_source_blocked(self, sentinel):
        """Without the preceding resolver chain, a bare `. "$IWE_PATHS"`
        (e.g. an attacker pre-setting IWE_PATHS some other way) is not a
        recognized whitelist target -- same fail-closed default as any
        other unrecognized source|. argument."""
        r = _run_hook('IWE_PATHS=/tmp/evil; . "$IWE_PATHS"')
        assert r.returncode == 2, r.stderr

    def test_cd_before_chain_blocked(self, sentinel):
        """Cold-review finding (Agent tool, 2026-10-15): the chain's first
        fallback is "$PWD/.iwe-paths", and `cd` -- the ordinary way $PWD
        actually changes in a running shell -- was not in the tamper regex
        at all (only VAR= assignment forms were). Live PoC before this test
        existed: `cd /tmp/evil-poc; <chain>` passed the gate (exit 0) and
        the real shell sourced an attacker-planted /tmp/evil-poc/.iwe-paths."""
        for cmd in (
            f'cd /tmp; {self.CHAIN}',
            f'cd -P /tmp; {self.CHAIN}',
            f'builtin cd /tmp; {self.CHAIN}',
            f'pushd /tmp; {self.CHAIN}',
        ):
            r = _run_hook(cmd)
            assert r.returncode == 2, f"{cmd!r}: {r.stderr}"

    def test_disguised_cd_before_chain_blocked(self, sentinel):
        """issue #1258 (independent red-team audit, 2026-10-17): the fix
        above only matched the literal bytes "cd"/"pushd" with real
        whitespace around them -- exactly the #1238 PoC's own shape. \\cd,
        "cd", 'cd' and $'cd' all strip down to the plain word "cd" once bash
        parses them and invoke the identical builtin -- confirmed live with
        `bash -c '\\cd /tmp/x && pwd'` actually changing directory -- so they
        bypassed the regex while working exactly like the PoC #1238 closed."""
        for cmd in (
            f'\\cd /tmp; {self.CHAIN}',
            f'"cd" /tmp; {self.CHAIN}',
            f"'cd' /tmp; {self.CHAIN}",
            f"$'cd' /tmp; {self.CHAIN}",
            f'\\pushd /tmp; {self.CHAIN}',
        ):
            r = _run_hook(cmd)
            assert r.returncode == 2, f"{cmd!r}: {r.stderr}"


class TestSentinelInactive:
    def test_no_sentinel_allows_everything(self):
        """No sentinel AND no owner-file: nothing claims a rehearsal is active."""
        if SENTINEL.exists():
            pytest.fail("sentinel leaked from a prior test")
        assert not OWNER.exists(), "test owner-file leaked from a prior test"
        r = _run_hook("git commit -m x")
        assert r.returncode == 0, r.stderr

    def test_no_sentinel_with_owner_file_blocks(self):
        """issue #460 path 2: sentinel gone but owner-file still claims an
        active rehearsal — fail-CLOSED instead of the old silent allow."""
        if SENTINEL.exists():
            pytest.fail("sentinel leaked from a prior test")
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
            pytest.fail("sentinel leaked from a prior test")
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
            pytest.fail("sentinel leaked from a prior test")
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
                ["/bin/bash", str(stub_hook)], input=payload, capture_output=True, text=True, timeout=10,
                env=HOOK_ENV,
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
            env=HOOK_ENV,
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
            pytest.fail("sentinel leaked from a prior test")
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



@pytest.fixture
def isolated_gate(tmp_path):
    """A rehearsal sentinel in a test-mode dir: the global /tmp/iwe-dry-run.flag stays untouched."""
    dry_dir = tmp_path / "dry-dir"
    dry_dir.mkdir(mode=0o700)
    (dry_dir / ".iwe-dry-run-test-mode").write_text("1", encoding="utf-8")
    flag = dry_dir / "sentinel.flag"
    flag.write_text(json.dumps({"initiator": "pytest", "created_at": "test", "session_id": "s"}), encoding="utf-8")
    env = dict(os.environ, IWE_DRY_RUN_DIR=str(dry_dir), IWE_DRY_RUN_SENTINEL=str(flag))

    def run(command):
        payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
        return subprocess.run(["bash", str(HOOK)], input=payload, capture_output=True, text=True, timeout=10, env=env)

    return run


@pytest.mark.parametrize(
    "command",
    [
        '"$IWE_SCRIPTS/day-close.sh"',
        "$IWE_SCRIPTS/day-close.sh",
        "./day-close.sh",
        "./day-close",
        "../x",
        "/tmp/day-close.sh --flag",
        "~/IWE/scripts/day-close.sh",
        "/usr/bin/../../tmp/x.sh",
        'scripts"/"x.sh',
        '. "$HOME/.iwe-paths"; "$IWE_SCRIPTS/day-close.sh"',
        '/usr/bin/env "$IWE_SCRIPTS/day-close.sh"',
        "env -i ./x.sh",
        "sudo -u u ./x.sh",
        "command -p ./x.sh",
        "time -p ./x.sh",
        "exec ./x.sh",
        "timeout 5 ./x.sh",
        "nohup ./day-close.sh",
        "if ./x.sh; then echo; fi",
        "! ./x.sh",
        'echo "$(./x.sh)"',
        "PATH=$IWE_SCRIPTS:$PATH day-close.sh",
        "cat <<EOF\ntext\nEOF\n./evil.sh",
        "echo hi # it's\n./x.sh",
        "cat <<<EOF\n./x.sh",
        "x=$((1<<EOF))\n./x.sh",
        "cat <<EOF\r\nb\r\nEOF\r\n./x.sh",
        "cat <<'E F'\nb\nE F\n./x",
        "cat <<$'EOF'\nb\nEOF\n./x.sh",
        "$'\\x2e/x'",
        "echo $'it\\'s'\n./x.sh",
        "${X:-./x.sh}",
        "${X:-x.sh}",
        "echo ${x:-'}'}; ./x.sh",
        "2>/dev/null ./x.sh",
        "0<&- ./x.sh",
        "exec 3>&1 ./x.sh",
        "builtin exec ./x.sh",
        "command -- ./x.sh",
        "sudo -iu u ./x.sh",
        "sudo -uu ./x.sh",
        "env --split-string=./x.sh",
        "$HOME/bin/x",
        '"$PWD"/x',
        "case a in a) ./x.sh;; esac",
        "f(){ ./x.sh; }; f",
    ],
)
def test_program_run_by_path_blocked(isolated_gate, command):
    """#1434: a script run by its own path is indirect execution, like `bash x.sh`."""
    r = isolated_gate(command)
    assert r.returncode == 2, f"{command!r} passed the gate: {r.stderr}"
    assert "indirect execution" in r.stderr


@pytest.mark.parametrize(
    "command",
    [
        "env -i git commit -m x",
        "sudo -u u git push",
        "if bash x.sh; then :; fi",
        "/usr/bin/git commit -m x",
        'IWE_SCRIPTS=/tmp/evil; "$IWE_SCRIPTS/day-close-prepare.sh"',
        'IWE_SCRIPTS=/tmp/evil; bash "$IWE_SCRIPTS/dry-run-complete.sh" g r s t',
        "cd /tmp/evil && scripts/dry-run-complete.sh a b c d",
        'printf -v IWE_SCRIPTS /e; "$IWE_SCRIPTS/day-close-prepare.sh"',
        'for IWE_SCRIPTS in /e; do bash "$IWE_SCRIPTS/dry-run-complete.sh" g r s t; done',
        "popd; scripts/day-close-prepare.sh",
        "</dev/null git commit -m x",
        "echo $(echo a)#; git commit -m x",
        "echo `echo a`#; git commit -m x",
        "echo }#; git commit -m x",
        "x=$(echo)#; bash x.sh",
        "a=(1)#; bash x.sh",
        "echo <(true)#; bash x.sh",
        "echo $(echo a)#; ./x",
        "echo $[1<<2]\ngit commit -m x",
        "cat <<$'A\\x41'\nAA\nbash x.sh\nA\\x41\n",
        "echo $((./x) )",
    ],
)
def test_wrapper_options_keywords_and_tampering_blocked(isolated_gate, command):
    """#1434 (cold review): wrapper options, keywords and a reassigned IWE_SCRIPTS no longer hide a write."""
    r = isolated_gate(command)
    assert r.returncode == 2, f"{command!r} passed the gate: {r.stderr}"


@pytest.mark.parametrize(
    "command",
    [
        "/usr/bin/grep -n x README.md",
        "/bin/ls -la",
        f"{IWE_ROOT}/FMT-exocortex-template/scripts/dry-run-complete.sh gid reason sid token",
        '"$IWE_SCRIPTS/dry-run-complete.sh" gid reason sid token',
        '"$IWE_SCRIPTS/day-close-prepare.sh"',
        'echo "see ./x.sh"',
        "command -v rm",
        "cat <<'EOF'\nsrc/foo.py:12 failed\n./run.sh is the entry\nEOF",
        "jq '.items[]\n | .a/2' data.json",
        'grep -nE "ждёт|блокер" \\\n  $HOME/.claude/projects/*/memory/MEMORY.md 2>/dev/null',
        'T="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}"; PY3="$(bash "$T/.claude/lib/find-python3.sh")" && "$PY3" "$T/.claude/scripts/memory-drift-scan.py"',
        "cat <<EOF\nthen rm the old notes\nEOF",
        "cat <<'EOF'\nif git push fails, retry\nEOF",
        "cat <<EOF\nenv -i git commit\nEOF",
        "jq -n '\n  if .a then\n    .b\n  else rm\n  end'",
        "awk '\n  { if ($1) print }\n  else rm x\n'",
        "case x in\n  ./*) echo rel ;;\n  *.sh) echo sh ;;\nesac",
        "command -v ./x.sh",
        "echo {a,b}.sh",
        "ls # see; ./setup.sh",
        "git status # then (./x.sh)",
        "${IWE_SCRIPTS}/check-dirty-repos.sh",
        "x=$(( 1 << 3 ))\ngit status",
    ],
)
def test_reads_and_whitelisted_paths_allowed(isolated_gate, command):
    """#1434: reads, heredoc bodies, multi-line filters and the rehearsal's own helpers still pass."""
    r = isolated_gate(command)
    assert r.returncode == 0, f"{command!r} blocked: {r.stderr}"

BEGIN = HOOK.parent.parent.parent / "scripts" / "dry-run-begin.sh"


def _begin_and_stop(tmp_path, *begin_args):
    """Start a rehearsal through the real helper in a test-mode dir, then fire Stop for its session."""
    dry_dir = tmp_path / "dry-dir"
    dry_dir.mkdir(mode=0o700)
    (dry_dir / ".iwe-dry-run-test-mode").write_text("1", encoding="utf-8")
    sentinel_path = dry_dir / "sentinel.flag"
    env = dict(os.environ, IWE_DRY_RUN_DIR=str(dry_dir), IWE_DRY_RUN_SENTINEL=str(sentinel_path))
    begin = subprocess.run(
        ["bash", str(BEGIN), "pytest-initiator", "hold-session", *begin_args],
        capture_output=True, text=True, timeout=10, env=env,
    )
    assert begin.returncode == 0, begin.stderr
    gate_id = dict(line.split("=", 1) for line in begin.stdout.splitlines())["gate_id"]
    transcript = tmp_path / "transcript.jsonl"
    transcript.write_text("", encoding="utf-8")
    stop = subprocess.run(
        ["bash", str(STOP_HOOK)],
        input=json.dumps({"session_id": "hold-session", "transcript_path": str(transcript)}),
        capture_output=True, text=True, timeout=10, env=env,
    )
    assert stop.returncode == 0, stop.stderr
    state = json.loads((dry_dir / f"gate-{gate_id}.state").read_text(encoding="utf-8"))
    return state, sentinel_path


def test_stop_hook_keeps_held_rehearsal(tmp_path):
    """#1435: a rehearsal begun with `hold` survives the owner's Stop (background subagent)."""
    state, sentinel_path = _begin_and_stop(tmp_path, "hold")
    assert state["stop_fallback"] == "hold"
    assert state["state"] == "active"
    assert sentinel_path.exists()
    assert json.loads(sentinel_path.read_text(encoding="utf-8"))["initiator"] == "pytest-initiator"


def test_stop_hook_still_completes_plain_rehearsal(tmp_path):
    """#1435: without `hold` the Stop fallback keeps completing the owner's rehearsal."""
    state, sentinel_path = _begin_and_stop(tmp_path)
    assert state["state"] == "completed"
    assert state["completion_reason"] == "stop-hook-fallback"
    assert not sentinel_path.exists()


def test_begin_rejects_unknown_third_argument(tmp_path):
    dry_dir = tmp_path / "dry-dir"
    dry_dir.mkdir(mode=0o700)
    (dry_dir / ".iwe-dry-run-test-mode").write_text("1", encoding="utf-8")
    env = dict(os.environ, IWE_DRY_RUN_DIR=str(dry_dir), IWE_DRY_RUN_SENTINEL=str(dry_dir / "sentinel.flag"))
    r = subprocess.run(["bash", str(BEGIN), "x", "s", "hlod"], capture_output=True, text=True, timeout=10, env=env)
    assert r.returncode == 2
    assert not (dry_dir / "sentinel.flag").exists()



def test_missing_command_reader_fails_closed(tmp_path):
    """#1434: without its command reader the gate blocks instead of allowing."""
    hooks = tmp_path / ".claude" / "hooks"
    hooks.mkdir(parents=True)
    shutil.copy(HOOK, hooks / HOOK.name)
    (tmp_path / ".claude" / "lib").mkdir()
    shutil.copy(DRY_RUN_LIB, tmp_path / ".claude" / "lib" / DRY_RUN_LIB.name)
    dry_dir = tmp_path / "dry-dir"
    dry_dir.mkdir(mode=0o700)
    (dry_dir / ".iwe-dry-run-test-mode").write_text("1", encoding="utf-8")
    flag = dry_dir / "sentinel.flag"
    flag.write_text(json.dumps({"initiator": "pytest", "created_at": "test", "session_id": "s"}), encoding="utf-8")
    env = dict(os.environ, IWE_DRY_RUN_DIR=str(dry_dir), IWE_DRY_RUN_SENTINEL=str(flag))
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": "git status"}})
    r = subprocess.run(["bash", str(hooks / HOOK.name)], input=payload, capture_output=True, text=True, timeout=10, env=env)
    assert r.returncode == 2, r.stderr
    assert "cannot classify" in r.stderr


SKILL = HOOK.parent.parent / "skills" / "audit-installation" / "SKILL.md"


def _skill_command(helper):
    """The step 2.5 command line of audit-installation/SKILL.md that calls `helper`."""
    lines = [line.strip() for line in SKILL.read_text(encoding="utf-8").splitlines() if f"$IWE_SCRIPTS/{helper}" in line and not line.lstrip().startswith(("#", "-", "`", ">"))]
    assert len(lines) == 1, f"expected one {helper} command in {SKILL}: {lines}"
    return lines[0]


@pytest.mark.parametrize("helper", ["dry-run-begin.sh", "dry-run-complete.sh"])
def test_audit_loads_paths(helper):
    """#1439: $IWE_SCRIPTS is unset in a non-interactive call (#688), so both commands load .iwe-paths themselves."""
    assert '. "$IWE_PATHS"' in _skill_command(helper)


def test_audit_complete_passes(isolated_gate):
    """#1439: the skill's completion command, exactly as written, passes under the active rehearsal it ends."""
    command = _skill_command("dry-run-complete.sh")
    for placeholder in ("<gate_id из шага 1>", "<owner_session_id из шага 1>", "<owner_token из шага 1>"):
        command = command.replace(placeholder, "x")
    r = isolated_gate(command)
    assert r.returncode == 0, f"completion command from SKILL.md blocked: {r.stderr}"


def test_arbitrary_paths_blocked(isolated_gate):
    """#1439: sourcing an arbitrary file path stays blocked; the skill uses the standard chain instead."""
    r = isolated_gate('. /home/u/IWE/.iwe-paths; bash "$IWE_SCRIPTS/dry-run-complete.sh" g r s t')
    assert r.returncode == 2, r.stderr


DAY_CLOSE_SKILL = HOOK.parent.parent / "skills" / "day-close" / "SKILL.md"


def _day_close_step_command(helper):
    """The backticked day-close/SKILL.md step command that runs `$IWE_SCRIPTS/<helper>`."""
    found = []
    for line in DAY_CLOSE_SKILL.read_text(encoding="utf-8").splitlines():
        if f"$IWE_SCRIPTS/{helper}" in line and line.startswith("`"):
            found.append(line.split("`")[1])
    assert len(found) == 1, f"expected one {helper} step command in {DAY_CLOSE_SKILL}: {found}"
    return found[0]


def test_day_close_lesson_hygiene_step_passes(isolated_gate):
    """#1454: step 4 (memory-bleed.sh --hot-only), exactly as SKILL.md writes it, passes under a rehearsal."""
    command = _day_close_step_command("memory-bleed.sh")
    assert command.endswith('bash "$IWE_SCRIPTS/memory-bleed.sh" --hot-only'), command
    r = isolated_gate(command)
    assert r.returncode == 0, f"step 4 command from SKILL.md blocked: {r.stderr}"


def test_day_close_write_step_still_blocked(isolated_gate):
    """#1454: step 5 (day-close.sh: backup, reindex, writes) stays blocked in its SKILL.md form."""
    command = _day_close_step_command("day-close.sh")
    r = isolated_gate(command)
    assert r.returncode == 2, r.stderr


CHAIN = (
    'IWE_PATHS="${IWE_PATHS_FILE:-}"; if [ -z "$IWE_PATHS" ]; then for _c in "$PWD/.iwe-paths" '
    '"${IWE_WORKSPACE:-$HOME/IWE}/.iwe-paths" "$HOME/.iwe-paths"; do [ -r "$_c" ] && { IWE_PATHS="$_c"; break; }; '
    'done; fi; [ -n "$IWE_PATHS" ] && . "$IWE_PATHS" 2>/dev/null; '
)


@pytest.mark.parametrize(
    "tail",
    [
        'T="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}"; bash "$T/scripts/memory-bleed.sh" --hot-only',
        'bash "$IWE_SCRIPTS/memory-bleed.sh"',
        'bash "$IWE_SCRIPTS/memory-bleed.sh" --dir /tmp/x',
        'bash "$IWE_SCRIPTS/memory-bleed.sh" --hot-only --dir /tmp/x',
        'bash "$IWE_SCRIPTS/memory-bleed.sh" --hot-only --hot-only',
        'bash "$IWE_SCRIPTS/memory-bleed.sh" --hot-onlyx',
        'bash "$IWE_SCRIPTS/memory-bleed.sh" "--hot-only;touch /tmp/x"',
        'bash "$IWE_SCRIPTS/memory-bleed.sh" --hot-only;bash /tmp/x.sh',
        'bash "$IWE_SCRIPTS/memory-bleed.sh" --hot-only > /tmp/report',
        'bash "$IWE_SCRIPTS/memory-bleed.sh.evil" --hot-only',
        'bash "$IWE_SCRIPTS/x/memory-bleed.sh" --hot-only',
        'bash "$IWE_SCRIPTS/../memory-bleed.sh" --hot-only',
        'IWE_SCRIPTS=/tmp/evil; bash "$IWE_SCRIPTS/memory-bleed.sh" --hot-only',
        'export IWE_SCRIPTS=/tmp/evil; bash "$IWE_SCRIPTS/memory-bleed.sh" --hot-only',
        'bash /tmp/scripts/memory-bleed.sh --hot-only',
        'bash scripts/memory-bleed.sh --hot-only',
        "bash __WL_MEMORY_BLEED__ --hot-only",
        'sh -c "memory-bleed.sh --hot-only"',
    ],
)
def test_memory_bleed_other_forms_blocked(isolated_gate, tail):
    """#1454: only the exact argv is whitelisted — no literal $T, no extra args, no substring or foreign path."""
    r = isolated_gate(CHAIN + tail)
    assert r.returncode == 2, f"{tail!r} allowed"


def _gate_tree(tmp_path, bleed_target=None):
    """A copy of the hook under <root>/.claude/hooks with <root>/FMT-exocortex-template/scripts/memory-bleed.sh."""
    root = tmp_path / "iwe"
    hooks = root / ".claude" / "hooks"
    hooks.mkdir(parents=True)
    for name in (HOOK.name, "dry-run-cmd-parse.pl"):
        shutil.copy(HOOK.parent / name, hooks / name)
    (root / ".claude" / "lib").mkdir()
    shutil.copy(DRY_RUN_LIB, root / ".claude" / "lib" / DRY_RUN_LIB.name)
    scripts = root / "FMT-exocortex-template" / "scripts"
    scripts.mkdir(parents=True)
    bleed = scripts / "memory-bleed.sh"
    if bleed_target is None:
        bleed.write_text("#!/bin/bash\n", encoding="utf-8")
    else:
        bleed.symlink_to(bleed_target)
    dry_dir = tmp_path / "dry-dir"
    dry_dir.mkdir(mode=0o700)
    (dry_dir / ".iwe-dry-run-test-mode").write_text("1", encoding="utf-8")
    flag = dry_dir / "sentinel.flag"
    flag.write_text(json.dumps({"initiator": "pytest", "created_at": "test", "session_id": "s"}), encoding="utf-8")
    env = dict(os.environ, IWE_DRY_RUN_DIR=str(dry_dir), IWE_DRY_RUN_SENTINEL=str(flag))

    def run(command):
        payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
        return subprocess.run(["bash", str(hooks / HOOK.name)], input=payload, capture_output=True, text=True, timeout=10, env=env)

    return run, bleed.parent.resolve() / "memory-bleed.sh"


def test_memory_bleed_trusted_absolute_path_passes(tmp_path):
    """#1454: the trusted absolute path with exactly --hot-only passes; extra arguments do not."""
    run, bleed = _gate_tree(tmp_path)
    assert run(f"bash {bleed} --hot-only").returncode == 0
    assert run(f"bash {bleed} --hot-only --dir /tmp").returncode == 2
    assert run(f"bash {bleed}").returncode == 2


def test_memory_bleed_symlink_outside_blocked(tmp_path):
    """#1454: a trusted-path memory-bleed.sh that is a symlink out of the scripts dir is refused."""
    evil = tmp_path / "evil.sh"
    evil.write_text("#!/bin/bash\ntouch /tmp/pwned\n", encoding="utf-8")
    run, bleed = _gate_tree(tmp_path, bleed_target=evil)
    r = run(f"bash {bleed} --hot-only")
    assert r.returncode == 2
    assert "does not resolve to a file inside" in r.stderr


def _run_tool(tool_name):
    payload = json.dumps({"tool_name": tool_name, "tool_input": {}})
    return subprocess.run(["bash", str(HOOK)], input=payload, capture_output=True, text=True, timeout=10, env=HOOK_ENV)


@pytest.mark.parametrize(
    "tool_name, expected",
    [
        # Kimi Code names the IWE server `aisystant` (#1447): same write-verb rule as iwe-knowledge.
        ("mcp__aisystant__personal_write", 2),
        ("mcp__aisystant__dt_write_digital_twin", 2),
        ("mcp__aisystant__send_telegram_message", 2),
        ("mcp__aisystant__personal_search", 0),
        ("mcp__aisystant__knowledge_get_document", 0),
        # Kimi Code calendar server `google-calendar`: writes blocked, reads pass.
        ("mcp__google-calendar__create-event", 2),
        ("mcp__google-calendar__create-events", 2),
        ("mcp__google-calendar__update-event", 2),
        ("mcp__google-calendar__delete-event", 2),
        ("mcp__google-calendar__respond-to-event", 2),
        ("mcp__google-calendar__list-events", 0),
        ("mcp__google-calendar__get-event", 0),
        # The prefix is exact: another server that merely contains "aisystant" is not pulled in.
        ("mcp__my-aisystant-mirror__personal_write", 0),
        ("mcp__aisystantx__personal_write", 0),
    ],
)
def test_mcp_server_names_of_other_channels(sentinel, tool_name, expected):
    """#1447(b): MCP write tools are blocked under a rehearsal whatever the channel names the server."""
    r = _run_tool(tool_name)
    assert r.returncode == expected, f"{tool_name}: rc={r.returncode} {r.stderr}"


def test_mcp_aisystant_write_allowed_without_rehearsal():
    """#1447(b): without a rehearsal the new prefix changes nothing."""
    assert not SENTINEL.exists()
    assert _run_tool("mcp__aisystant__personal_write").returncode == 0


# --- #1447(a): Git Bash (MINGW/MSYS) — NTFS ACL instead of 0700 ------------------
#
# No Windows here: `uname` is an exported bash function (it wins over the
# PATH the scripts pin), cygpath/icacls.exe/whoami.exe are stub scripts. The
# icacls stub writes the fixture DACL to its /save target in UTF-16LE, like
# the real tool, and logs every call.

COMPLETE = HOOK.parent.parent.parent / "scripts" / "dry-run-complete.sh"
USER_SID = "S-1-5-21-111-222-333-1001"
GOOD_SDDL = f"D:PAI(A;OICI;FA;;;{USER_SID})(A;OICI;FA;;;SY)"
UNAME_SHIM = 'uname() { printf "%s\\n" "$FAKE_UNAME"; }; export -f uname; exec bash "$@"'

ICACLS_STUB = r"""#!/bin/bash
{ printf 'ARGS:%s\n' "$*"; printf 'CONV:%s\n' "${MSYS2_ARG_CONV_EXCL:-}"; } >> "$FAKE_LOG"
case " $* " in
    *" /save "*)
        if [ -n "${FAKE_SAVE_RC:-}" ]; then echo "Access is denied." >&2; exit "$FAKE_SAVE_RC"; fi
        out="${@: -1}"
        if [ -n "${FAKE_RAW:-}" ]; then cp "$FAKE_SDDL_FILE" "$out"; else
            python3 -c 'import sys; open(sys.argv[2], "wb").write(open(sys.argv[1], encoding="utf-8").read().encode("utf-16-le"))' "$FAKE_SDDL_FILE" "$out"
        fi
        ;;
    *" /inheritance:r "*)
        if [ -n "${FAKE_SETUP_RC:-}" ]; then echo "The parameter is incorrect." >&2; exit "$FAKE_SETUP_RC"; fi
        ;;
esac
exit 0
"""

WHOAMI_STUB = f"""#!/bin/bash
printf 'USER INFORMATION\\r\\n----------------\\r\\n\\r\\nUser Name     SID\\r\\n============= ==============\\r\\ndesktop\\\\me   {USER_SID}\\r\\n'
"""

def _production_sentinel_clear():
    return not Path("/tmp/iwe-dry-run.flag").exists() and not list(Path("/tmp").glob("iwe-dry-run-owner-*.token"))


CYGPATH_STUB = """#!/bin/bash
# -u / -w: the fixture paths are already POSIX paths; only the flag is checked.
case "$1" in -u|-w) printf '%s\\n' "$2" ;; *) exit 1 ;; esac
"""


@pytest.fixture
def win(tmp_path):
    """A fake Git Bash host: env + helpers to run scripts or the library under it."""
    stub_bin = tmp_path / "bin"
    stub_bin.mkdir()
    (stub_bin / "cygpath").write_text(CYGPATH_STUB, encoding="utf-8")
    sysroot = tmp_path / "Win Dir"
    (sysroot / "System32").mkdir(parents=True)
    (sysroot / "System32" / "icacls.exe").write_text(ICACLS_STUB, encoding="utf-8")
    (sysroot / "System32" / "whoami.exe").write_text(WHOAMI_STUB, encoding="utf-8")
    for p in (stub_bin / "cygpath", sysroot / "System32" / "icacls.exe", sysroot / "System32" / "whoami.exe"):
        p.chmod(0o755)
    local = tmp_path / "Local App Data"
    local.mkdir()
    sddl_file = tmp_path / "acl.fixture"
    log = tmp_path / "icacls.log"
    env = {k: v for k, v in os.environ.items() if not k.startswith(("IWE_DRY_RUN", "FAKE_"))}
    env.update(
        PATH=f"{stub_bin}:{os.environ['PATH']}",
        FAKE_UNAME="MINGW64_NT-10.0-19045",
        LOCALAPPDATA=str(local),
        SYSTEMROOT=str(sysroot),
        FAKE_SDDL_FILE=str(sddl_file),
        FAKE_LOG=str(log),
    )

    class Win:
        dir = local / "iwe-dry-run"

        def __init__(self):
            self.env = env
            self.sysroot = sysroot
            self.log = log
            self.acl(GOOD_SDDL)

        def acl(self, sddl):
            sddl_file.write_text(f"iwe-dry-run\r\n{sddl}\r\n", encoding="utf-8")

        def run(self, *args, stdin=""):
            return subprocess.run(
                ["bash", "-c", UNAME_SHIM, "_", *map(str, args)],
                input=stdin, capture_output=True, text=True, timeout=30, env=self.env,
            )

        def lib(self, mode="existing", prefix=""):
            """Resolve + check through the shared library; returns (rc, dir, err), rc None = not resolved."""
            script = (
                f'{prefix}. "{DRY_RUN_LIB}"; dry_run_resolve_paths || {{ printf "RES:1\\nERR:%s\\n" "$DRY_RUN_ERR"; exit 0; }}; '
                f'dry_run_dir_check {mode}; printf "RC:%s\\nDIR:%s\\nERR:%s\\n" "$?" "$DRY_RUN_DIR" "$DRY_RUN_ERR"'
            )
            f = tmp_path / "lib-call.sh"
            f.write_text(script, encoding="utf-8")
            out = dict(line.split(":", 1) for line in self.run(f).stdout.splitlines() if ":" in line)
            if "RES" in out:
                return None, None, out.get("ERR", "")
            return int(out["RC"]), out["DIR"], out["ERR"]

    return Win()


def test_win_creates_dir_with_private_acl(win):
    """Begin path: a new dir gets inheritance removed and grants for the user and SYSTEM only."""
    rc, d, err = win.lib("create")
    assert rc == 0, err
    assert d == str(win.dir) and win.dir.is_dir()
    log = win.log.read_text(encoding="utf-8")
    assert f"/inheritance:r /grant:r *{USER_SID}:(OI)(CI)F /grant:r *S-1-5-18:(OI)(CI)F" in log
    assert "/save" in log
    assert "CONV:*" in log  # MSYS must not rewrite /grant:r as a path


@pytest.mark.parametrize(
    "sddl",
    [
        GOOD_SDDL,
        f"D:P(A;OICI;FA;;;{USER_SID})(A;OICI;FA;;;S-1-5-18)",
        f"D:PAI(A;OICI;FA;;;{USER_SID})",
    ],
)
def test_win_private_acl_passes(win, sddl):
    win.dir.mkdir()
    win.acl(sddl)
    rc, _, err = win.lib()
    assert rc == 0, err


@pytest.mark.parametrize(
    "sddl",
    [
        # inherited BU/WD, not protected — the default of a dir under a shared parent
        f"D:AI(A;OICI;FA;;;{USER_SID})(A;OICIID;FA;;;BU)(A;OICIID;FA;;;WD)",
        f"D:(A;OICI;FA;;;{USER_SID})(A;OICI;FA;;;SY)",
        f"D:AI(A;OICI;FA;;;{USER_SID})(A;OICI;FA;;;SY)",  # right entries, but not protected
        f"D:PAI(A;OICI;FA;;;{USER_SID})(A;OICI;FA;;;S-1-5-21-999-888-777-1002)",
        f"D:PAI(A;OICI;FA;;;{USER_SID})(A;OICI;FA;;;WD)",
        f"D:PAI(A;OICI;FA;;;{USER_SID})(A;OICI;FA;;;AC)",
        f"D:PAI(A;OICI;FA;;;{USER_SID})(A;OICI;FA;;;BA)",
        f"D:PAI(A;OICI;FA;;;{USER_SID})(A;OICI;FA;;;AU)",
        f"D:PAI(A;OICI;FA;;;{USER_SID})(A;OICI;FA;;;AN)",
        f"D:PAI(A;OICI;FA;;;{USER_SID})(A;OICI;FA;;;CO)",
        f"D:PAI(A;OICI;FA;;;{USER_SID})(A;OICI;FA;;;S-1-15-2-1)",
        f"D:PAI(A;OICI;FA;;;{USER_SID})(D;OICI;FA;;;WD)",
        f"D:PAI(A;;FA;;;{USER_SID})(A;OICI;FA;;;SY)",
        f"D:PAI(A;OICI;FR;;;{USER_SID})(A;OICI;FA;;;SY)",
        f"D:PAI(A;OICIIO;FA;;;{USER_SID})(A;OICI;FA;;;SY)",
        "D:PAI(A;OICI;FA;;;SY)",
        f"D:PAI(A;OICI;FA;;;{USER_SID})garbage",
        "garbage",
        "",
    ],
)
def test_win_open_or_unparsable_acl_fails(win, sddl):
    """Anything but a protected user+SYSTEM full-access DACL is refused; the existing dir is kept."""
    win.dir.mkdir()
    win.acl(sddl)
    rc, _, err = win.lib()
    assert rc == 1
    assert "права доступа не закрыты" in err and str(win.dir) in err
    assert win.dir.is_dir()


def test_win_non_utf16_output_fails(win):
    win.dir.mkdir()
    win.env["FAKE_RAW"] = "1"
    rc, _, err = win.lib()
    assert rc == 1, err


def test_win_icacls_error_fails_with_code_and_hint(win):
    win.dir.mkdir()
    win.env["FAKE_SAVE_RC"] = "5"
    rc, _, err = win.lib()
    assert rc == 1
    assert "код 5" in err and "Access is denied." in err
    assert "System32/icacls.exe" in err and "удалите каталог" in err


def test_win_setup_failure_removes_only_our_new_dir(win):
    """A dir we just created and could not secure is removed again."""
    win.env["FAKE_SETUP_RC"] = "87"
    rc, _, err = win.lib("create")
    assert rc == 1
    assert "код 87" in err and "The parameter is incorrect." in err
    assert not win.dir.exists()


def test_win_missing_icacls_fails_without_mode_fallback(win):
    """No icacls.exe → refused even for a 0700 dir: the mode bits are not a fallback on Git Bash."""
    win.dir.mkdir(mode=0o700)
    (win.sysroot / "System32" / "icacls.exe").unlink()
    rc, _, err = win.lib()
    assert rc == 1
    assert "icacls.exe" in err


def test_win_icacls_from_path_is_not_used(win, tmp_path):
    """Only %SYSTEMROOT%\\System32\\icacls.exe counts — an icacls.exe on PATH is never called."""
    win.dir.mkdir()
    (win.sysroot / "System32" / "icacls.exe").unlink()
    on_path = tmp_path / "bin" / "icacls.exe"
    on_path.write_text(ICACLS_STUB, encoding="utf-8")
    on_path.chmod(0o755)
    rc, _, _ = win.lib()
    assert rc == 1
    assert not win.log.exists()


@pytest.mark.parametrize("var", ["LOCALAPPDATA", "SYSTEMROOT"])
def test_win_empty_env_fails(win, var):
    win.env[var] = ""
    rc, _, err = win.lib("create")
    assert rc in (None, 1)
    assert var in err
    assert not win.dir.exists()


@pytest.mark.skipif(not _production_sentinel_clear(), reason="a live rehearsal on this host owns /tmp/iwe-dry-run.flag")
def test_win_empty_localappdata_gate_warns_begin_fails_closed(win, tmp_path):
    """Review-01 H1: an unresolvable path blocks only while a rehearsal may run; begin always refuses."""
    win.env["LOCALAPPDATA"] = ""
    read = json.dumps({"tool_name": "Read", "tool_input": {}})
    gate = win.run(HOOK, stdin=read)
    assert gate.returncode == 0 and "LOCALAPPDATA" in gate.stderr and "WARNING" in gate.stderr
    flag = tmp_path / "flag"
    flag.write_text("{}", encoding="utf-8")
    win.env["IWE_DRY_RUN_SENTINEL"] = str(flag)
    gate = win.run(HOOK, stdin=read)
    assert gate.returncode == 2 and "LOCALAPPDATA" in gate.stderr
    begin = win.run(BEGIN, "pytest", "s")
    assert begin.returncode == 1 and "LOCALAPPDATA" in begin.stderr


@pytest.mark.skipif(not _production_sentinel_clear(), reason="a live rehearsal on this host owns /tmp/iwe-dry-run.flag")
def test_win_begin_gate_complete_resolve_same_dir(win):
    """All three components resolve %LOCALAPPDATA%\\iwe-dry-run and refuse the same open dir."""
    win.dir.mkdir()
    win.acl(f"D:AI(A;OICI;FA;;;{USER_SID})(A;OICIID;FA;;;BU)")
    begin = win.run(BEGIN, "pytest", "s")
    gate = win.run(HOOK, stdin=json.dumps({"tool_name": "Read", "tool_input": {}}))
    complete = win.run(COMPLETE, "g", "rehearsal-finished", "s", "t")
    expected = f"каталог репетиции {win.dir}:"
    for name, r in (("begin", begin), ("gate", gate), ("complete", complete)):
        assert r.returncode != 0, name
        assert expected in r.stderr, f"{name}: {r.stderr}"
    assert win.dir.is_dir() and not any(win.dir.iterdir())


@pytest.mark.skipif(not _production_sentinel_clear(), reason="a live rehearsal on this host owns /tmp/iwe-dry-run.flag")
def test_win_gate_without_rehearsal_allows_tools(win):
    """#1447 paralysis: an existing, correctly secured dir and no rehearsal → ordinary tool calls pass."""
    win.dir.mkdir()
    for tool in ({"tool_name": "Read", "tool_input": {}}, {"tool_name": "Bash", "tool_input": {"command": "git commit -m x"}}):
        r = win.run(HOOK, stdin=json.dumps(tool))
        assert r.returncode == 0, r.stderr
    win.acl(f"D:AI(A;OICI;FA;;;{USER_SID})(A;OICIID;FA;;;WD)")
    assert win.run(HOOK, stdin=json.dumps({"tool_name": "Read", "tool_input": {}})).returncode == 2


def test_win_rehearsal_in_secured_test_dir(win, tmp_path):
    """A full begin → gate blocks a write → complete cycle on a secured dir (test-mode override)."""
    dry_dir = tmp_path / "td"
    dry_dir.mkdir()
    (dry_dir / ".iwe-dry-run-test-mode").write_text("1", encoding="utf-8")
    win.env.update(IWE_DRY_RUN_DIR=str(dry_dir), IWE_DRY_RUN_SENTINEL=str(dry_dir / "flag"))
    begin = win.run(BEGIN, "pytest", "s")
    assert begin.returncode == 0, begin.stderr
    out = dict(line.split("=", 1) for line in begin.stdout.splitlines())
    blocked = win.run(HOOK, stdin=json.dumps({"tool_name": "Bash", "tool_input": {"command": "git commit -m x"}}))
    assert blocked.returncode == 2
    done = win.run(COMPLETE, out["gate_id"], "rehearsal-finished", "s", out["owner_token"])
    assert done.returncode == 0, done.stderr
    assert not (dry_dir / "flag").exists()


@pytest.mark.parametrize("uname", ["Linux", "CYGWIN_NT-10.0-19045"])
def test_posix_and_cygwin_still_require_0700(win, tmp_path, uname):
    """Outside MINGW/MSYS the 0700 criterion is unchanged — and icacls is never consulted."""
    win.env["FAKE_UNAME"] = uname
    dry_dir = tmp_path / "td"
    dry_dir.mkdir()
    dry_dir.chmod(0o755)
    (dry_dir / ".iwe-dry-run-test-mode").write_text("1", encoding="utf-8")
    win.env.update(IWE_DRY_RUN_DIR=str(dry_dir), IWE_DRY_RUN_SENTINEL=str(dry_dir / "flag"))
    r = win.run(BEGIN, "pytest", "s")
    assert r.returncode == 1 and "group/other write permissions (755)" in r.stderr
    dry_dir.chmod(0o700)
    r = win.run(BEGIN, "pytest", "s")
    assert r.returncode == 0, r.stderr
    assert not win.log.exists()


def test_single_dry_run_dir_resolver():
    """#1447: path resolution lives only in the shared library; the four consumers source it."""
    repo = HOOK.parent.parent.parent
    files = subprocess.run(["git", "-C", str(repo), "ls-files", "*.sh"], capture_output=True, text=True, check=True).stdout.split()
    offenders = []
    for rel in files:
        if rel.startswith("scripts/tests/") or rel == ".claude/lib/dry-run-dir.sh":
            continue
        for n, line in enumerate((repo / rel).read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            code = "" if line.lstrip().startswith("#") else line
            # The gate's no-library fallback only looks for evidence of a
            # rehearsal there (H1, review-01); it never picks a directory.
            if rel == ".claude/hooks/dry-run-gate.sh" and code.rstrip().endswith("# evidence scan, not a resolver"):
                continue
            if "/tmp/iwe-dry-run-" in code or "IWE_DRY_RUN_DIR:-" in code:
                offenders.append(f"{rel}:{n}: {line.strip()}")
    assert not offenders, "second dry-run dir resolver:\n" + "\n".join(offenders)
    for consumer in (HOOK, STOP_HOOK, BEGIN, COMPLETE):
        assert "dry-run-dir.sh" in consumer.read_text(encoding="utf-8"), consumer


# --- review-01 H1: the gate without its library -----------------------------


def _gate_without_lib(tmp_path):
    """A workspace copy of the gate whose .claude/lib was never delivered (interrupted update)."""
    hooks = tmp_path / "ws" / ".claude" / "hooks"
    hooks.mkdir(parents=True)
    for name in ("dry-run-gate.sh", "dry-run-cmd-parse.pl"):
        shutil.copy2(HOOK.parent / name, hooks / name)
    env = {k: v for k, v in os.environ.items() if not k.startswith("IWE_DRY_RUN")}

    def run(tool="Read", command=None, **extra):
        payload = {"tool_name": tool, "tool_input": {"command": command} if command else {}}
        return subprocess.run(["bash", str(hooks / "dry-run-gate.sh")], input=json.dumps(payload),
                              capture_output=True, text=True, timeout=10, env=dict(env, **extra))

    return run


@pytest.mark.skipif(not _production_sentinel_clear(), reason="a live rehearsal on this host owns /tmp/iwe-dry-run.flag")
def test_missing_library_without_rehearsal_warns_and_allows(tmp_path):
    run = _gate_without_lib(tmp_path)
    for r in (run(), run("Bash", "git status")):
        assert r.returncode == 0, r.stderr
        assert "WARNING" in r.stderr and "dry-run-dir.sh missing" in r.stderr


def test_missing_library_with_sentinel_blocks(tmp_path):
    run = _gate_without_lib(tmp_path)
    flag = tmp_path / "flag"
    flag.write_text("{}", encoding="utf-8")
    r = run(IWE_DRY_RUN_SENTINEL=str(flag))
    assert r.returncode == 2 and "dry-run-dir.sh missing" in r.stderr


@pytest.mark.skipif(not _production_sentinel_clear(), reason="a live rehearsal on this host owns /tmp/iwe-dry-run.flag")
@pytest.mark.parametrize("state,expected", [("active", 2), ("completed", 0), (None, 2)])
def test_missing_library_judges_state_records(tmp_path, state, expected):
    """An active (or unreadable) state record without a sentinel still blocks; a completed one does not."""
    run = _gate_without_lib(tmp_path)
    d = tmp_path / "dd"
    d.mkdir(mode=0o700)
    (d / "gate-g1.state").write_text(json.dumps({"state": state}) if state else "{not json", encoding="utf-8")
    assert run(IWE_DRY_RUN_DIR=str(d)).returncode == expected


# --- review-01 M4: begin/complete load the library copy the gate loads ------


def _workspace_with_scripts(tmp_path):
    ws = tmp_path / "ws"
    (ws / ".claude" / "hooks").mkdir(parents=True)
    (ws / ".claude" / "hooks" / "dry-run-gate.sh").write_text("#!/bin/bash\n", encoding="utf-8")
    (ws / ".claude" / "lib").mkdir()
    (ws / ".claude" / "lib" / "dry-run-dir.sh").write_text(
        'dry_run_resolve_paths() { DRY_RUN_ERR="WORKSPACE-COPY"; return 1; }\n', encoding="utf-8")
    tpl = ws / "FMT-exocortex-template"
    (tpl / "scripts").mkdir(parents=True)
    (tpl / ".claude" / "lib").mkdir(parents=True)
    for s in (BEGIN, COMPLETE):
        shutil.copy2(s, tpl / "scripts" / s.name)
    shutil.copy2(DRY_RUN_LIB, tpl / ".claude" / "lib" / "dry-run-dir.sh")
    # Whatever copy a script ends up loading, it must never reach the host's
    # production rehearsal paths: a test-mode dir catches it.
    dry_dir = tmp_path / "dry-dir"
    dry_dir.mkdir(mode=0o700)
    (dry_dir / ".iwe-dry-run-test-mode").write_text("1", encoding="utf-8")
    env = dict(os.environ, IWE_DRY_RUN_DIR=str(dry_dir), IWE_DRY_RUN_SENTINEL=str(dry_dir / "flag"))
    return ws, tpl, env


def _script(path, *args, env):
    return subprocess.run(["bash", str(path), *args], capture_output=True, text=True, timeout=10, env=env)


def test_begin_and_complete_use_the_gate_library_copy(tmp_path):
    _, tpl, env = _workspace_with_scripts(tmp_path)
    for r in (_script(tpl / "scripts" / BEGIN.name, "p", "s", env=env),
              _script(tpl / "scripts" / COMPLETE.name, "g", "r", "s", "t", env=env)):
        assert r.returncode != 0 and "WORKSPACE-COPY" in r.stderr, r.stderr


def test_begin_refuses_workspace_without_library_complete_falls_back(tmp_path):
    ws, tpl, env = _workspace_with_scripts(tmp_path)
    (ws / ".claude" / "lib" / "dry-run-dir.sh").unlink()
    begin = _script(tpl / "scripts" / BEGIN.name, "p", "s", env=env)
    assert begin.returncode == 1 and "dry-run-dir.sh missing" in begin.stderr, begin.stderr
    complete = _script(tpl / "scripts" / COMPLETE.name, "no-such-gate", "r", "s", "t", env=env)
    assert complete.returncode != 0 and "dry-run-dir.sh missing" not in complete.stderr, complete.stderr


# --- review-01 H2 (#1454): a trusted variable changed in any spelling --------

_PY_HELPER = "${IWE_TEMPLATE:-%s/FMT-exocortex-template}/.claude/scripts/memory-drift-scan.py" % IWE_ROOT
_ABS_PREPARE = f"{IWE_ROOT}/FMT-exocortex-template/scripts/day-close-prepare.sh"


@pytest.mark.parametrize(
    "command",
    [
        # IWE_SCRIPTS, every helper that trusts it
        'IWE_SCRIPTS+=/../../tmp/evil; bash "$IWE_SCRIPTS/memory-bleed.sh" --hot-only',
        'IWE_SCRIPTS+=/x; bash "$IWE_SCRIPTS/day-close-prepare.sh"',
        'IWE_SCRIPTS[0]=/tmp/evil; bash "$IWE_SCRIPTS/dry-run-complete.sh" g r s t',
        'declare -n r=IWE_SCRIPTS; r=/tmp/evil; bash "$IWE_SCRIPTS/memory-bleed.sh" --hot-only',
        'local -n r=IWE_SCRIPTS; r=/tmp/evil; bash "$IWE_SCRIPTS/day-close-prepare.sh"',
        'typeset -n r=IWE_SCRIPTS; r=/tmp/evil; "$IWE_SCRIPTS/day-close-prepare.sh"',
        'v=IWE_; declare -n r=${v}SCRIPTS; r=/tmp/evil; bash "$IWE_SCRIPTS/memory-bleed.sh" --hot-only',
        'v=IWE_SCRIPTS; declare "$v=/tmp/evil"; bash "$IWE_SCRIPTS/day-close-prepare.sh"',
        'read IWE_SCRIPTS <<< /tmp/evil; bash "$IWE_SCRIPTS/day-close-prepare.sh"',
        'read -r IWE_SCRIPTS < /tmp/p; bash "$IWE_SCRIPTS/memory-bleed.sh" --hot-only',
        'printf -v "IWE_SC""RIPTS" /tmp/evil; bash "$IWE_SCRIPTS/day-close-prepare.sh"',
        'v=IWE_SCRIPTS; printf -v "$v" /tmp/evil; "${IWE_SCRIPTS}/check-dirty-repos.sh"',
        'export IWE_SCRIPTS=/tmp/evil; bash "$IWE_SCRIPTS/dry-run-complete.sh" g r s t',
        'export IWE_SCRIPTS+=/x; bash "$IWE_SCRIPTS/memory-bleed.sh" --hot-only',
        'unset IWE_SCRIPTS; bash "$IWE_SCRIPTS/day-close-prepare.sh"',
        'mapfile -t IWE_SCRIPTS < /tmp/p; bash "$IWE_SCRIPTS/day-close-prepare.sh"',
        'v=IWE_SCRIPTS; (( $v = 1 )); bash "$IWE_SCRIPTS/memory-bleed.sh" --hot-only',
        'let "IWE_SCRIPTS=1"; bash "$IWE_SCRIPTS/memory-bleed.sh" --hot-only',
        ': ${IWE_SCRIPTS:=/tmp/evil}; bash "$IWE_SCRIPTS/day-close-prepare.sh"',
        "declare $'IWE_SCRIPTS=/tmp/evil'; bash \"$IWE_SCRIPTS/day-close-prepare.sh\"",
        # IWE_TEMPLATE in the two python helper paths
        f"IWE_TEMPLATE=/tmp/evil; python3 {_PY_HELPER}",
        f"export IWE_TEMPLATE=/tmp/evil; python3 {_PY_HELPER}",
        f"declare -n t=IWE_TEMPLATE; t=/tmp/evil; python3 {_PY_HELPER}",
        # HOME / IWE_PATHS_FILE behind the .iwe-paths whitelist
        'HOME+=/../tmp/evil; . "$HOME/.iwe-paths"',
        'HOME[0]=/tmp/evil; . "$HOME/.iwe-paths"',
        'export HOME+=/x; . "$HOME/.iwe-paths"',
        'declare -n h=HOME; h=/tmp/evil; . "$HOME/.iwe-paths"',
        'v=HOME; printf -v "$v" /tmp/evil; . "$HOME/.iwe-paths"',
        'IWE_PATHS_FILE+=x; . "${IWE_PATHS_FILE:-$HOME/.iwe-paths}"',
        # a relative whitelisted path after cd, the pre-existing load-extensions entry included
        "cd /tmp/evil && bash .claude/scripts/load-extensions.sh",
        # code the gate cannot read, run by a whitelisted helper
        'BASH_ENV=/tmp/evil bash "$IWE_SCRIPTS/day-close-prepare.sh"',
        f"BASH_ENV=/tmp/evil bash {_ABS_PREPARE}",
        f"env 'BASH_FUNC_cat%%=() {{ :; }}' bash {_ABS_PREPARE}",
        f"SHELLOPTS=xtrace PS4='$(x)' bash {_ABS_PREPARE}",
        f"PYTHONPATH=/tmp/evil python3 {_PY_HELPER}",
    ],
)
def test_trusted_variable_tampering_blocked(isolated_gate, command):
    r = isolated_gate(command)
    assert r.returncode == 2, f"{command!r} passed the gate: {r.stderr}"


@pytest.mark.parametrize(
    "command",
    [
        'bash "$IWE_SCRIPTS/memory-bleed.sh" --hot-only',
        'bash "$IWE_SCRIPTS/day-close-prepare.sh" --verify',
        '. "$HOME/.iwe-paths"; bash "$IWE_SCRIPTS/day-close-prepare.sh"',
        f"python3 {_PY_HELPER}",
        "bash .claude/scripts/load-extensions.sh day-close before",
        f"bash {_ABS_PREPARE}",
    ],
)
def test_untampered_helpers_still_pass(isolated_gate, command):
    r = isolated_gate(command)
    assert r.returncode == 0, f"{command!r} blocked: {r.stderr}"


# --- review-01 M3: Git Bash accounts the first version refused ---------------

ENTRA_SID = "S-1-12-1-1111111111-2222222222-3333333333-4444444444"


def test_win_entra_id_account_accepted(win):
    """An Entra ID (Azure AD) account has an S-1-12-1-* SID, not S-1-5-21-*."""
    whoami = win.sysroot / "System32" / "whoami.exe"
    whoami.write_text(WHOAMI_STUB.replace(USER_SID, ENTRA_SID), encoding="utf-8")
    win.dir.mkdir()
    win.acl(f"D:PAI(A;OICI;FA;;;{ENTRA_SID})(A;OICI;FA;;;SY)")
    rc, _, err = win.lib()
    assert rc == 0, err
    win.acl(GOOD_SDDL)  # the S-1-5-21 user is someone else for this account
    rc, _, err = win.lib()
    assert rc == 1 and "права доступа не закрыты" in err


FOREIGN_UID = 'id() { if [ "${1:-}" = -u ]; then echo 4242; else command id "$@"; fi; }; '


def test_win_owner_uid_not_checked(win):
    """On Git Bash the mapped owner uid is not evidence (admin dirs belong to Administrators): the ACL decides."""
    win.dir.mkdir()
    rc, _, err = win.lib(prefix=FOREIGN_UID)
    assert rc == 0, err
    win.acl(f"D:AI(A;OICI;FA;;;{USER_SID})(A;OICIID;FA;;;BU)")
    rc, _, err = win.lib(prefix=FOREIGN_UID)
    assert rc == 1 and "права доступа не закрыты" in err


def test_owner_uid_still_checked_off_windows(win, tmp_path):
    """Everywhere else the owner uid check stays."""
    win.env["FAKE_UNAME"] = "Linux"
    dry_dir = tmp_path / "td"
    dry_dir.mkdir(mode=0o700)
    (dry_dir / ".iwe-dry-run-test-mode").write_text("1", encoding="utf-8")
    win.env.update(IWE_DRY_RUN_DIR=str(dry_dir), IWE_DRY_RUN_SENTINEL=str(dry_dir / "flag"))
    rc, _, err = win.lib(prefix=FOREIGN_UID)
    assert rc == 1 and "expected 4242" in err


# --- review-02 (#1454): helper trust against computed names and rebinding ----

_ABS_LOADEXT = f"{IWE_ROOT}/.claude/scripts/load-extensions.sh"
_ABS_BLEED = f"{IWE_ROOT}/FMT-exocortex-template/scripts/memory-bleed.sh"
_CHAIN = TestIwePathsChainWhitelist.CHAIN


@pytest.mark.parametrize(
    "command",
    [
        # H-a: a computed variable name reaches every helper form
        "a=BASH; export ${a}_ENV=/tmp/evil; bash .claude/scripts/load-extensions.sh day-close before",
        f"a=BASH; export ${{a}}_ENV=/tmp/evil; bash {_ABS_LOADEXT} day-close before",
        f"a=BASH; declare -x ${{a}}_ENV=/tmp/evil; bash {_ABS_LOADEXT}",
        f"a=BASH; typeset -x ${{a}}_ENV=/tmp/evil; bash {_ABS_LOADEXT}",
        f"a=BASH; printf -v ${{a}}_ENV /tmp/evil; export ${{a}}_ENV; bash {_ABS_PREPARE}",
        f"a=SHELL; b=OPTS; export $a$b=xtrace PS4='$(x)'; bash {_ABS_LOADEXT}",
        f"a=PYTHON; export ${{a}}PATH=/tmp/evil; python3 {_PY_HELPER}",
        f"a=BASH; export ${{a}}_ENV=/tmp/evil; bash {_ABS_BLEED} --hot-only",
        'a=BASH; export ${a}_ENV=/tmp/evil; bash "$IWE_SCRIPTS/memory-bleed.sh" --hot-only',
        f"a=BASH; export ${{a}}_ENV=/tmp/evil; {_ABS_PREPARE}",
        f"a=BASH; export ${{a}}_ENV=/tmp/evil; {_CHAIN}",
        # H-b: builtins that rebind a command word
        'hash -p /tmp/evil bash; bash "$IWE_SCRIPTS/memory-bleed.sh" --hot-only',
        "hash -p /tmp/evil bash; bash .claude/scripts/load-extensions.sh day-close before",
        "hash -p /tmp/evil python3; python3 -c 'print(1)'",
        "\\hash -p /tmp/evil git; git status",
        '"hash" -p /tmp/evil git; git status',
        "command hash -p /tmp/evil ls; ls",
        "enable -f /tmp/evil.so bash; bash .claude/scripts/load-extensions.sh",
        "enable -n echo; echo x",
        # generalised: definitions, aliases, traps, shell options, PATH, HOME
        "bash() { /tmp/evil \"$@\"; }; bash .claude/scripts/load-extensions.sh",
        f"function python3 {{ /tmp/evil; }}; python3 {_PY_HELPER}",
        f"shopt -s expand_aliases; alias bash=/tmp/evil; bash {_ABS_LOADEXT}",
        f"trap 'touch /tmp/x' DEBUG; bash {_ABS_LOADEXT}",
        f"set -o allexport; bash {_ABS_LOADEXT}",
        "PATH=/tmp/evil:$PATH git status",
        "PATH+=:/tmp/evil; ls",
        "export PATH=/tmp/evil; python3 -c 'print(1)'",
        f"HOME=/tmp/evil python3 {_PY_HELPER}",
        f"HOME=/tmp/evil bash {_ABS_LOADEXT}",
        f"PYTHONUSERBASE=/tmp/evil python3 {_PY_HELPER}",
        # M-a: an assignment still blocks
        "export PYTHONPATH=/tmp/evil; ls",
        "env PYTHONPATH=/tmp/evil ls",
        "x=1 BASH_ENV=/tmp/evil ls",
    ],
)
def test_review2_helper_trust_blocked(isolated_gate, command):
    r = isolated_gate(command)
    assert r.returncode == 2, f"{command!r} passed the gate: {r.stderr}"


@pytest.mark.parametrize(
    "command",
    [
        "grep -r PYTHONPATH .",
        "grep -rn BASH_ENV docs",
        "git hash-object README.md",
        f"bash {_ABS_LOADEXT} day-close before",
        'bash "$IWE_SCRIPTS/memory-bleed.sh" --hot-only',
    ],
)
def test_review2_reads_and_helpers_still_pass(isolated_gate, command):
    r = isolated_gate(command)
    assert r.returncode == 0, f"{command!r} blocked: {r.stderr}"


def test_review2_workspace_path_with_regex_metacharacters(tmp_path):
    """The workspace path is escaped before it goes into sed: `+` and `(` neither break nor widen the match."""
    ws = tmp_path / "ws+(x)"
    (ws / ".claude" / "hooks").mkdir(parents=True)
    (ws / ".claude" / "lib").mkdir()
    for name in ("dry-run-gate.sh", "dry-run-cmd-parse.pl"):
        shutil.copy2(HOOK.parent / name, ws / ".claude" / "hooks" / name)
    shutil.copy2(DRY_RUN_LIB, ws / ".claude" / "lib" / "dry-run-dir.sh")
    dry_dir = tmp_path / "dry-dir"
    dry_dir.mkdir(mode=0o700)
    (dry_dir / ".iwe-dry-run-test-mode").write_text("1", encoding="utf-8")
    flag = dry_dir / "flag"
    flag.write_text(json.dumps({"initiator": "pytest", "created_at": "test"}), encoding="utf-8")
    env = dict(os.environ, IWE_DRY_RUN_DIR=str(dry_dir), IWE_DRY_RUN_SENTINEL=str(flag))

    def run(command):
        payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
        return subprocess.run(["bash", str(ws / ".claude" / "hooks" / "dry-run-gate.sh")], input=payload,
                              capture_output=True, text=True, timeout=10, env=env)

    real = ws.resolve()
    good = "python3 ${IWE_TEMPLATE:-%s/FMT-exocortex-template}/.claude/scripts/memory-drift-scan.py" % real
    r = run(good)
    assert r.returncode == 0, r.stderr
    # Unescaped, "ws+(x)" is the ERE ws+(x) and would also approve ".../wssx/...".
    widened = good.replace(str(real), str(real.parent / "wssx"))
    assert run(widened).returncode == 2
