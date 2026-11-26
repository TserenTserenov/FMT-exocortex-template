"""Tests for scripts/close_verify_fallback.py (WP-592 Ф7).

Every outcome of the fallback has its own exit code; the tests drive the real
program with fake `<verifier>-peer-adapter.sh` scripts and check the observable
exit code and output, never a bare "did not crash".
"""
from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "close_verify_fallback.py"

PASS_REPLY = json.dumps({"verdict": "pass", "items": [{"check": "Осталось not a template", "status": "pass", "note": "ok"}]})
FAIL_REPLY = json.dumps({"verdict": "fail", "items": [
    {"check": "Осталось not a template", "status": "fail", "note": "generic phrase"},
    {"check": "files listed", "status": "pass", "note": "ok"}]})


def fake_adapter(directory: Path, verifier: str, body: str) -> None:
    path = directory / f"{verifier}-peer-adapter.sh"
    path.write_text("#!/usr/bin/env bash\n" + body + "\n", encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


def reply_adapter(reply: str) -> str:
    # The adapter must see the projection on stdin and the plain-mode flag.
    return (
        'test "$IWE_PEER_PLAIN" = 1 || { echo "plain flag missing" >&2; exit 1; }\n'
        'grep -q "Checklist" || { echo "projection missing" >&2; exit 1; }\n'
        f"cat <<'REPLY'\n{reply}\nREPLY"
    )


@pytest.fixture()
def workdir(tmp_path: Path) -> Path:
    (tmp_path / "checklist.md").write_text("- Осталось not a template\n- files listed\n", encoding="utf-8")
    (tmp_path / "files.txt").write_text("DS-my-strategy/inbox/WP-1/WP-1.md\n", encoding="utf-8")
    (tmp_path / "summary.md").write_text("Closed the session, card updated.\n", encoding="utf-8")
    (tmp_path / "adapters").mkdir()
    return tmp_path


def run(workdir: Path, verifier: str = "kimi", extra: list[str] | None = None) -> subprocess.CompletedProcess:
    cmd = [sys.executable, str(SCRIPT), "--verifier", verifier,
           "--checklist", str(workdir / "checklist.md"),
           "--files", str(workdir / "files.txt"),
           "--summary", str(workdir / "summary.md"), *(extra or [])]
    env = dict(os.environ, IWE_CLOSE_VERIFY_ADAPTER_DIR=str(workdir / "adapters"))
    return subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=60)


def test_pass_exit_0_and_json_on_stdout(workdir: Path) -> None:
    fake_adapter(workdir / "adapters", "kimi", reply_adapter(PASS_REPLY))
    result = run(workdir)
    assert result.returncode == 0, result.stderr
    out = json.loads(result.stdout)
    assert out["verdict"] == "pass" and out["verifier"] == "kimi"


def test_fail_exit_10_lists_failed_item(workdir: Path) -> None:
    fake_adapter(workdir / "adapters", "kimi", reply_adapter(FAIL_REPLY))
    result = run(workdir)
    assert result.returncode == 10, result.stderr
    failed = [i for i in json.loads(result.stdout)["items"] if i["status"] == "fail"]
    assert failed[0]["note"] == "generic phrase"


def test_json_inside_code_fence_is_accepted(workdir: Path) -> None:
    fake_adapter(workdir / "adapters", "kimi", reply_adapter("```json\n" + PASS_REPLY + "\n```"))
    assert run(workdir).returncode == 0


def test_missing_adapter_exit_20(workdir: Path) -> None:
    result = run(workdir, verifier="codex")
    assert result.returncode == 20
    assert "adapter not found" in result.stderr


def test_unknown_adapter_failure_exit_20(workdir: Path) -> None:
    fake_adapter(workdir / "adapters", "kimi", 'echo "something broke" >&2; exit 1')
    result = run(workdir)
    assert result.returncode == 20
    assert "something broke" in result.stderr


def test_network_disabled_exit_23(workdir: Path) -> None:
    fake_adapter(workdir / "adapters", "kimi",
                 'echo "ERROR: network is disabled in this sandbox (CODEX_SANDBOX_NETWORK_DISABLED=1)" >&2; exit 1')
    assert run(workdir).returncode == 23


def test_auth_error_code_6_exit_23(workdir: Path) -> None:
    fake_adapter(workdir / "adapters", "kimi", "exit 6")
    assert run(workdir).returncode == 23


def test_timeout_exit_23(workdir: Path) -> None:
    fake_adapter(workdir / "adapters", "kimi", "sleep 5")
    assert run(workdir, extra=["--timeout", "1"]).returncode == 23


def test_secret_in_input_exit_21_and_adapter_not_called(workdir: Path) -> None:
    marker = workdir / "adapter-was-called"
    fake_adapter(workdir / "adapters", "kimi", f"touch {marker}\n" + reply_adapter(PASS_REPLY))
    fake_secret = "sk-" + "abcdefghijklmnopqrstuvwxyz1234"  # built at runtime: no secret-looking literal in the repo
    (workdir / "summary.md").write_text(f"token {fake_secret} leaked\n", encoding="utf-8")
    result = run(workdir)
    assert result.returncode == 21
    assert not marker.exists(), "the projection with a secret must never reach the adapter"


def test_adapter_filter_refusal_code_3_exit_21(workdir: Path) -> None:
    fake_adapter(workdir / "adapters", "kimi", "exit 3")
    assert run(workdir).returncode == 21


@pytest.mark.parametrize("reply", [
    "I think everything is fine.",
    "",
    '{"verdict": "maybe", "items": []}',
    '{"verdict": "pass", "items": []}',
    json.dumps({"verdict": "pass", "items": [{"check": "x", "status": "fail", "note": "n"}]}),
    json.dumps({"verdict": "fail", "items": [{"check": "x", "status": "pass", "note": "n"}]}),
])
def test_bad_reply_exit_22(workdir: Path, reply: str) -> None:
    fake_adapter(workdir / "adapters", "kimi", f"cat <<'REPLY'\n{reply}\nREPLY")
    assert run(workdir).returncode == 22


def test_independence_marker(workdir: Path) -> None:
    fake_adapter(workdir / "adapters", "kimi", reply_adapter(PASS_REPLY))
    assert json.loads(run(workdir, extra=["--closer", "claude"]).stdout)["independence"] == "independent"
    assert json.loads(run(workdir, extra=["--closer", "kimi"]).stdout)["independence"] == "weak"
    assert json.loads(run(workdir).stdout)["independence"] == "unknown"


def test_empty_input_file_is_usage_error(workdir: Path) -> None:
    (workdir / "files.txt").write_text("", encoding="utf-8")
    fake_adapter(workdir / "adapters", "kimi", reply_adapter(PASS_REPLY))
    result = run(workdir)
    assert result.returncode == 2
    assert "files file is empty" in result.stderr


def test_projection_has_no_diff_text_only_given_inputs(workdir: Path) -> None:
    # The adapter echoes the projection back inside a valid reply note.
    body = (
        'P=$(cat)\n'
        'printf \'{"verdict":"pass","items":[{"check":"echo","status":"pass","note":"%s"}]}\' '
        '"$(printf "%s" "$P" | grep -c "^## ")"'
    )
    fake_adapter(workdir / "adapters", "kimi", body)
    (workdir / "remaining.md").write_text("Next: finish phase 7\n", encoding="utf-8")
    result = run(workdir, extra=["--remaining", str(workdir / "remaining.md")])
    assert result.returncode == 0, result.stderr
    # four sections: Checklist, Changed files, Summary, Remaining
    assert json.loads(result.stdout)["items"][0]["note"] == "4"
