"""CLI-level exit-code / error_class contract for residency-gate.py (issue #521A).

Subprocess-level tests, not unit tests against the library: the contract this
guards is what a HOOK SCRIPT observes (exit code + JSON envelope on stdout) —
exactly the layer that used to fabricate "consent denied" for a crash
(issue #521, ModuleNotFoundError on `import yaml`).

Contract: 0 allowed / 1 policy_denial / 2 invalid_manifest / 3 dependency_error
/ 4 runtime_error. `error_class` is absent for policy_denial (the baseline the
other three classes must stay distinguishable from).
"""

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

GATE_PY = Path(__file__).parent.parent / "residency-gate.py"


def _run(args, env=None):
    return subprocess.run(
        [sys.executable, str(GATE_PY), *args],
        capture_output=True,
        text=True,
        timeout=10,
        env=env,
    )


@pytest.fixture
def fake_home(tmp_path, monkeypatch):
    home = tmp_path / "home"
    (home / "IWE" / "current").mkdir(parents=True)
    monkeypatch.setenv("HOME", str(home))
    return home


@pytest.fixture
def yaml_shadowed_env(tmp_path):
    """An env whose PYTHONPATH shadows the real `yaml` package with a stub
    that raises ImportError — the same failure mode a genuinely missing
    PyYAML produces, without needing to uninstall it from the test runner."""
    stub_dir = tmp_path / "stub-site"
    stub_dir.mkdir()
    (stub_dir / "yaml.py").write_text("raise ImportError(\"No module named 'yaml'\")\n")
    home = tmp_path / "home"
    (home / "IWE" / "current").mkdir(parents=True)
    env = dict(os.environ)
    env["HOME"] = str(home)
    env["PYTHONPATH"] = str(stub_dir) + os.pathsep + env.get("PYTHONPATH", "")
    return env


def test_policy_denial_exit_code(fake_home, tmp_path):
    """A genuine consent refusal (never asked) is exit 1, no error_class."""
    manifest = tmp_path / "SKILL.md"
    manifest.write_text(
        "---\nname: test\n---\n\n"
        "data_needs:\n"
        "  - type: 2.1, flow: inbound, name: sample-data, schema_version: 1\n"
    )
    result = _run(["check-activation", "pytest-fn", str(manifest)])
    assert result.returncode == 1, result.stdout + result.stderr
    payload = json.loads(result.stdout)
    assert payload["allowed"] is False
    assert "error_class" not in payload


def test_invalid_manifest_exit_code(fake_home, tmp_path):
    """A broken declaration (missing schema_version) is exit 2,
    error_class=invalid_manifest — distinct from a policy denial."""
    manifest = tmp_path / "SKILL.md"
    manifest.write_text(
        "---\nname: test\n---\n\n"
        "data_needs:\n"
        "  - type: 2.1, flow: inbound, name: broken\n"  # no schema_version
    )
    result = _run(["check-activation", "pytest-fn", str(manifest)])
    assert result.returncode == 2, result.stdout + result.stderr
    payload = json.loads(result.stdout)
    assert payload["allowed"] is False
    assert payload["error_class"] == "invalid_manifest"
    assert "debug_trace" not in payload


def test_dependency_error_exit_code(yaml_shadowed_env):
    """A missing PyYAML (issue #521's actual trigger) is exit 3,
    error_class=dependency_error — not a fabricated policy denial."""
    result = _run(["check-activation", "pytest-fn", "/nonexistent.md"], env=yaml_shadowed_env)
    assert result.returncode == 3, result.stdout + result.stderr
    payload = json.loads(result.stdout)
    assert payload["allowed"] is False
    assert payload["error_class"] == "dependency_error"
    assert "yaml" in payload["error"]
    assert "debug_trace" not in payload


def test_dependency_error_debug_trace_opt_in(yaml_shadowed_env):
    """RESIDENCY_GATE_DEBUG=1 adds a full traceback; absent by default
    (issue #521A consensus: `error` alone covers the common case)."""
    yaml_shadowed_env["RESIDENCY_GATE_DEBUG"] = "1"
    result = _run(["check-activation", "pytest-fn", "/nonexistent.md"], env=yaml_shadowed_env)
    assert result.returncode == 3, result.stdout + result.stderr
    payload = json.loads(result.stdout)
    assert "debug_trace" in payload
    assert "Traceback" in payload["debug_trace"]
