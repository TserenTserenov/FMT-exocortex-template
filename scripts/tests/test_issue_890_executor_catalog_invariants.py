"""Regression coverage for issue #890: generate-executor-catalog.py accepted
routing entries whose declared executor could never actually run — a
script_path missing entirely, one pointing at a file that does not exist
(the reported setup-wakatime case), or a deterministic:true claim on an
executor that necessarily calls a model.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

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
