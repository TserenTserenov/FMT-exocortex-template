"""Regression coverage for issue #890: generate-executor-catalog.py accepted
routing entries whose declared executor could never actually run — a
script_path missing entirely, one pointing at a file that does not exist
(the reported setup-wakatime case), or a deterministic:true claim on an
executor that necessarily calls a model.
"""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import subprocess

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "scripts" / "generate-executor-catalog.py"


def load_generator():
    spec = importlib.util.spec_from_file_location("generate_executor_catalog", GENERATOR)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gen = load_generator()


def make_skill(skills_dir: Path, name: str, routing_yaml: str) -> Path:
    skill_dir = skills_dir / name
    skill_dir.mkdir(parents=True)
    (skill_dir / "SKILL.md").write_text(
        "---\n"
        f"name: {name}\n"
        "description: fixture skill for issue #890\n"
        f"{routing_yaml}"
        "---\n\n# fixture\n",
        encoding="utf-8",
    )
    return skill_dir


def test_script_executor_without_script_path_is_rejected(tmp_path: Path):
    skills_dir = tmp_path / ".claude" / "skills"
    make_skill(
        skills_dir,
        "no-path",
        "routing:\n  executor: script\n  deterministic: true\n",
    )
    entry = gen.process_skill(skills_dir / "no-path")
    errors = gen.validate_entry(entry, tmp_path)
    assert any("requires routing.script_path" in e for e in errors)


def test_script_path_pointing_nowhere_is_rejected(tmp_path: Path):
    # Same shape as the reported setup-wakatime entry: executor:script,
    # deterministic:true, script_path naming a file that was never shipped.
    skills_dir = tmp_path / ".claude" / "skills"
    make_skill(
        skills_dir,
        "setup-wakatime",
        "routing:\n"
        "  executor: script\n"
        "  deterministic: true\n"
        "  script_path: .claude/skills/setup-wakatime/setup.sh\n",
    )
    entry = gen.process_skill(skills_dir / "setup-wakatime")
    errors = gen.validate_entry(entry, tmp_path)
    assert any("does not exist" in e for e in errors)


def test_script_path_pointing_at_a_real_file_is_accepted(tmp_path: Path):
    skills_dir = tmp_path / ".claude" / "skills"
    make_skill(
        skills_dir,
        "real-script",
        "routing:\n"
        "  executor: script\n"
        "  deterministic: true\n"
        "  script_path: .claude/skills/real-script/run.sh\n",
    )
    (skills_dir / "real-script" / "run.sh").write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    entry = gen.process_skill(skills_dir / "real-script")
    errors = gen.validate_entry(entry, tmp_path)
    assert errors == []


def test_workspace_script_root_accepts_installed_script(tmp_path: Path, monkeypatch):
    workspace = tmp_path / "workspace"
    script = workspace / "scripts" / "lesson-close.sh"
    script.parent.mkdir(parents=True)
    script.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    skills_dir = workspace / ".claude" / "skills"
    make_skill(
        skills_dir,
        "lesson-close",
        "routing:\n  executor: script\n  deterministic: true\n"
        "  script_root: workspace\n  script_path: scripts/lesson-close.sh\n",
    )
    monkeypatch.setenv("IWE_ROOT", str(workspace))
    entry = gen.process_skill(skills_dir / "lesson-close")
    assert gen.validate_entry(entry, ROOT) == []


@pytest.mark.parametrize("script_path", ["../outside.sh", "scripts/../outside.sh", "/tmp/outside.sh"])
def test_workspace_script_root_rejects_paths_outside_scripts(tmp_path: Path, monkeypatch, script_path: str):
    monkeypatch.setenv("IWE_ROOT", str(tmp_path))
    entry = {
        "name": "lesson-close",
        "routing": {
            "executor": "script",
            "deterministic": True,
            "script_root": "workspace",
            "script_path": script_path,
        },
    }
    assert any("must stay under scripts/" in e for e in gen.validate_entry(entry, ROOT))


def test_workspace_script_root_rejects_symlink_escape(tmp_path: Path, monkeypatch):
    workspace = tmp_path / "workspace"
    script = workspace / "scripts" / "escape.sh"
    script.parent.mkdir(parents=True)
    outside = tmp_path / "outside.sh"
    outside.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    script.symlink_to(outside)
    monkeypatch.setenv("IWE_ROOT", str(workspace))
    entry = {
        "name": "escape",
        "routing": {
            "executor": "script",
            "deterministic": True,
            "script_root": "workspace",
            "script_path": "scripts/escape.sh",
        },
    }
    assert any("escapes workspace" in e for e in gen.validate_entry(entry, ROOT))


def test_workspace_script_root_runtime_executes_only_inside_workspace(tmp_path: Path):
    workspace = tmp_path / "workspace"
    script = workspace / "scripts" / "lesson-close.sh"
    script.parent.mkdir(parents=True)
    script.write_text('#!/usr/bin/env bash\nprintf "ran" > "$IWE_TEST_MARKER"\n', encoding="utf-8")
    script.chmod(0o755)
    marker = tmp_path / "marker"
    catalog = tmp_path / "catalog.yaml"
    catalog.write_text(
        yaml.safe_dump({
            "total_entries": 1,
            "entries": [{
                "name": "lesson-close",
                "routing": {
                    "executor": "script",
                    "deterministic": True,
                    "script_root": "workspace",
                    "script_path": "scripts/lesson-close.sh",
                },
            }],
        }),
        encoding="utf-8",
    )
    env = os.environ.copy()
    env.update({
        "IWE_DIR": str(workspace),
        "IWE_TEMPLATE": str(tmp_path / "empty-template"),
        "IWE_EXECUTOR_CATALOG": str(catalog),
        "IWE_ROUTER_AUDIT": str(tmp_path / "audit.log"),
        "IWE_ROUTER_ERRORS": str(tmp_path / "errors.log"),
        "IWE_TEST_MARKER": str(marker),
    })
    router = ROOT / "scripts" / "route-task.sh"
    result = subprocess.run(["bash", str(router), "--skill", "lesson-close"], env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert marker.read_text(encoding="utf-8") == "ran"

    marker.unlink()
    catalog_text = catalog.read_text(encoding="utf-8").replace(
        "script_path: scripts/lesson-close.sh", "script_path: scripts/../lesson-close.sh"
    )
    catalog.write_text(catalog_text, encoding="utf-8")
    result = subprocess.run(["bash", str(router), "--skill", "lesson-close"], env=env, capture_output=True, text=True)
    assert result.returncode == 2
    assert not marker.exists()

    outside = tmp_path / "outside.sh"
    outside.write_text('#!/usr/bin/env bash\nprintf "escaped" > "$IWE_TEST_MARKER"\n', encoding="utf-8")
    outside.chmod(0o755)
    (workspace / "scripts" / "escape.sh").symlink_to(outside)
    catalog.write_text(catalog_text.replace("scripts/../lesson-close.sh", "scripts/escape.sh"), encoding="utf-8")
    result = subprocess.run(["bash", str(router), "--skill", "lesson-close"], env=env, capture_output=True, text=True)
    assert result.returncode == 2
    assert not marker.exists()

    template_script = tmp_path / "empty-template" / "scripts" / "old.sh"
    template_script.parent.mkdir(parents=True)
    template_script.write_text('#!/usr/bin/env bash\nprintf "template" > "$IWE_TEST_MARKER"\n', encoding="utf-8")
    template_script.chmod(0o755)
    catalog.write_text(
        yaml.safe_dump({
            "total_entries": 1,
            "entries": [{
                "name": "lesson-close",
                "routing": {
                    "executor": "script",
                    "deterministic": True,
                    "script_path": "scripts/old.sh",
                },
            }],
        }),
        encoding="utf-8",
    )
    result = subprocess.run(["bash", str(router), "--skill", "lesson-close"], env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert marker.read_text(encoding="utf-8") == "template"


@pytest.mark.parametrize("executor", ["haiku", "sonnet", "opus", "script+judgment"])
def test_deterministic_true_on_a_model_executor_is_rejected(tmp_path: Path, executor: str):
    skills_dir = tmp_path / ".claude" / "skills"
    model_line = "  model: haiku\n" if executor in {"haiku", "sonnet", "opus"} else ""
    routing = f"routing:\n  executor: {executor}\n  deterministic: true\n{model_line}"
    make_skill(skills_dir, f"model-{executor.replace('+', '-')}", routing)
    entry = gen.process_skill(skills_dir / f"model-{executor.replace('+', '-')}")
    errors = gen.validate_entry(entry, tmp_path)
    assert any("inconsistent with executor" in e for e in errors)


def test_deterministic_true_on_script_is_accepted(tmp_path: Path):
    skills_dir = tmp_path / ".claude" / "skills"
    make_skill(
        skills_dir,
        "plain-script",
        "routing:\n"
        "  executor: script\n"
        "  deterministic: true\n"
        "  script_path: .claude/skills/plain-script/run.sh\n",
    )
    (skills_dir / "plain-script" / "run.sh").write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    entry = gen.process_skill(skills_dir / "plain-script")
    assert gen.validate_entry(entry, tmp_path) == []
