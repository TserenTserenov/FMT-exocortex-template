"""WP-53: the `dsh` executor in the dispatcher and its `final` run event.

The dispatcher gained a third runtime (DeepSeek Harness, `dsh headless --json`)
and a configurable default runtime. Two classes of defects are covered:

  1. Usage gate: `dsh` reports the answer in a `final` event, not in Claude's
     `result` shape. A completed reason accepts the text, a failed reason marks
     the run failed, a missing reason is still not an error, and only the `dsh`
     provider reacts to `final` at all.
  2. Default runtime: a typo in IWE_DISPATCHER_DEFAULT_EXECUTOR
     (`deepseek` instead of `dsh`) must fall back to `claude` at load time with a
     warning, instead of raising KeyError later in resolve_executor().

No processes are started and no network is touched.
"""

import importlib.util
import json
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).parent.parent
DISPATCHER = SCRIPTS / "iwe-agent-dispatcher.py"
GATE = SCRIPTS / "gate_launch_usage.py"


def load(path: Path, name: str):
    """Load a module from a path; the dispatcher's file name is not an identifier."""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def gate():
    return load(GATE, "gate_launch_usage_wp53")


@pytest.fixture
def dispatcher_factory(monkeypatch):
    """Fresh dispatcher module so module-level DEFAULT_EXECUTOR is re-read."""

    counter = {"n": 0}

    def factory(default_executor=None):
        if default_executor is None:
            monkeypatch.delenv("IWE_DISPATCHER_DEFAULT_EXECUTOR", raising=False)
        else:
            monkeypatch.setenv("IWE_DISPATCHER_DEFAULT_EXECUTOR", default_executor)
        counter["n"] += 1
        return load(DISPATCHER, f"iwe_agent_dispatcher_wp53_{counter['n']}")

    return factory


def observe(gate_module, provider, event):
    usage = gate_module.LaunchUsage(provider)
    usage.observe_line(json.dumps(event).encode())
    return usage


# --- usage gate: the `final` event -------------------------------------------


@pytest.mark.parametrize(
    "reason, expected_error",
    [
        ({"kind": "completed"}, False),
        ({"kind": "failed", "message": "boom"}, True),
        ({"kind": "timeout"}, True),
        (None, False),
    ],
)
def test_final_event_sets_result_and_error(gate, reason, expected_error):
    event = {"type": "final", "text": "готовый ответ"}
    if reason is not None:
        event["reason"] = reason

    usage = observe(gate, "dsh", event)

    assert usage.result == "готовый ответ"
    assert usage.result_error is expected_error


def test_final_event_without_text_is_not_accepted_as_result(gate):
    usage = observe(gate, "dsh", {"type": "final", "reason": {"kind": "completed"}})

    assert usage.result is None


def test_final_event_is_ignored_for_other_providers(gate):
    usage = observe(gate, "claude", {"type": "final", "text": "чужой формат"})

    assert usage.result is None
    assert usage.result_error is False


# --- default runtime ---------------------------------------------------------


def test_default_executor_is_claude_without_environment(dispatcher_factory):
    assert dispatcher_factory().DEFAULT_EXECUTOR == "claude"


def test_default_executor_reads_environment(dispatcher_factory):
    assert dispatcher_factory("dsh").DEFAULT_EXECUTOR == "dsh"


@pytest.mark.parametrize("raw", ["deepseek", "cli", "DSH2"])
def test_unknown_default_executor_falls_back_to_claude(dispatcher_factory, capsys, raw):
    module = dispatcher_factory(raw)

    assert module.DEFAULT_EXECUTOR == "claude"
    assert "WARN" in capsys.readouterr().out


@pytest.mark.parametrize("raw", ["", "   "])
def test_blank_default_executor_means_unset(dispatcher_factory, capsys, raw):
    module = dispatcher_factory(raw)

    assert module.DEFAULT_EXECUTOR == "claude"
    assert "WARN" not in capsys.readouterr().out


def test_unknown_task_executor_never_raises_with_valid_default(dispatcher_factory):
    module = dispatcher_factory("dsh")

    executor = module.resolve_executor("deepseek")

    assert executor.name == "dsh"


def test_unknown_task_executor_uses_validated_default(dispatcher_factory):
    module = dispatcher_factory("deepseek")

    assert module.resolve_executor(None).name == "claude"


# --- dsh executor ------------------------------------------------------------


def test_build_cmd_asks_for_json_events(dispatcher_factory, monkeypatch):
    monkeypatch.setenv("IWE_DSH_BIN", "/opt/bin/dsh")
    executor = dispatcher_factory().DshExecutor()

    assert executor.build_cmd("задача", "ignored-model") == [
        "/opt/bin/dsh",
        "headless",
        "--json",
        "задача",
    ]
    assert executor.supports_heartbeat is False


def test_env_overrides_keeps_existing_environment(dispatcher_factory, monkeypatch):
    monkeypatch.setenv("DEEPSEEK_API_KEY", "from-env")
    executor = dispatcher_factory().DshExecutor()

    assert executor.env_overrides() == {}


def test_env_overrides_reads_secret_file(dispatcher_factory, monkeypatch, tmp_path):
    monkeypatch.delenv("DEEPSEEK_API_KEY", raising=False)
    monkeypatch.setenv("IWE_ROOT", str(tmp_path))
    secret = tmp_path / ".secrets" / "deepseek-api-key"
    secret.parent.mkdir(parents=True)
    secret.write_text("  file-key\n", encoding="utf-8")
    executor = dispatcher_factory().DshExecutor()

    assert executor.env_overrides() == {"DEEPSEEK_API_KEY": "file-key"}


@pytest.mark.parametrize("content", [None, "", "   \n"])
def test_env_overrides_ignores_missing_or_empty_secret(
    dispatcher_factory, monkeypatch, tmp_path, content
):
    monkeypatch.delenv("DEEPSEEK_API_KEY", raising=False)
    monkeypatch.setenv("IWE_ROOT", str(tmp_path))
    if content is not None:
        secret = tmp_path / ".secrets" / "deepseek-api-key"
        secret.parent.mkdir(parents=True)
        secret.write_text(content, encoding="utf-8")
    executor = dispatcher_factory().DshExecutor()

    assert executor.env_overrides() == {}
