"""WP-522 (М15, пир-сессия 2026-08-31-30): тесты хука
_post_m15_practiced_fact в iwe_checklist_memory.py — вызывается после
успешной записи косяка агента, best-effort (не должен мешать record_fault)."""
import importlib.util
import subprocess
import sys
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).parent / "iwe_checklist_memory.py"
SPEC = importlib.util.spec_from_file_location("iwe_checklist_memory_m15", SCRIPT)
mod = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = mod
SPEC.loader.exec_module(mod)


def _paths(governance: Path) -> "mod.ProfilePaths":
    workspace = governance.parent
    return mod.ProfilePaths(
        workspace=workspace,
        governance=governance,
        profile=workspace / "profile",
        database=workspace / "db.sqlite3",
        ignore=workspace / "ignore",
        audit=workspace / "audit.log",
        export=workspace / "export.md",
    )


def test_writer_missing_is_silent_noop(tmp_path):
    governance = tmp_path / "governance-repo"
    governance.mkdir()
    with mock.patch("subprocess.run") as run:
        mod._post_m15_practiced_fact(_paths(governance), "агент пропустил чеклист")
    run.assert_not_called()


def test_writer_present_is_called_with_correct_args(tmp_path):
    governance = tmp_path / "governance-repo"
    (governance / "scripts").mkdir(parents=True)
    writer = governance / "scripts" / "post-culture-fact.py"
    writer.write_text("# stub\n")
    with mock.patch("subprocess.run") as run:
        mod._post_m15_practiced_fact(_paths(governance), "агент пропустил чеклист")
    run.assert_called_once()
    call_args = run.call_args[0][0]
    assert call_args[0] == sys.executable
    assert call_args[1] == str(writer)
    assert "--element" in call_args and call_args[call_args.index("--element") + 1] == "M15"
    assert "--mode" in call_args and call_args[call_args.index("--mode") + 1] == "record"
    assert "--evidence" in call_args and call_args[call_args.index("--evidence") + 1] == "агент пропустил чеклист"


def test_subprocess_failure_is_caught_and_logged(tmp_path, capsys):
    governance = tmp_path / "governance-repo"
    (governance / "scripts").mkdir(parents=True)
    (governance / "scripts" / "post-culture-fact.py").write_text("# stub\n")
    with mock.patch("subprocess.run", side_effect=OSError("no such executable")):
        mod._post_m15_practiced_fact(_paths(governance), "x")
    assert "M15" in capsys.readouterr().err


def test_subprocess_timeout_is_caught_and_logged_without_leaking_fault_text(tmp_path, capsys):
    # Код-ревью 31.08 (Critical): str(TimeoutExpired) включает полный cmd —
    # значит и сам текст --evidence (fault может нести чувствительные детали
    # инцидента). Реалистичный argv с фактическим fault — тест обязан
    # поймать утечку, если она вернётся, не только формально пройти.
    governance = tmp_path / "governance-repo"
    (governance / "scripts").mkdir(parents=True)
    writer = governance / "scripts" / "post-culture-fact.py"
    writer.write_text("# stub\n")
    sensitive_fault = "утечка токена в логах SENSITIVE_DETAIL_XYZ"
    real_argv = [sys.executable, str(writer), "--element", "M15", "--mode", "record", "--evidence", sensitive_fault]
    with mock.patch("subprocess.run", side_effect=subprocess.TimeoutExpired(cmd=real_argv, timeout=3)):
        mod._post_m15_practiced_fact(_paths(governance), sensitive_fault)
    err = capsys.readouterr().err
    assert "M15" in err
    assert sensitive_fault not in err
    assert "SENSITIVE_DETAIL_XYZ" not in err
