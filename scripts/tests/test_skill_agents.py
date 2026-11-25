"""Behaviour of scripts/skill_agents.py: header contract, check and per-agent selection (WP-592 Ф7)."""
from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "skill_agents.py"
SPEC = importlib.util.spec_from_file_location("skill_agents", SCRIPT)
skill_agents = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(skill_agents)


def make_skill(skills_dir: Path, name: str, header: str) -> None:
    skill = skills_dir / name
    skill.mkdir(parents=True)
    (skill / "SKILL.md").write_text(f"---\nname: {name}\n{header}---\n\nBody.\n", encoding="utf-8")


@pytest.fixture
def skills(tmp_path: Path) -> Path:
    make_skill(tmp_path, "shared", "audience: user\nruns_on: [claude, kimi, codex]\n")
    make_skill(tmp_path, "claude-only", "audience: user\nruns_on: [claude]\n")
    make_skill(tmp_path, "author-tool", "audience: author\nruns_on: [claude, kimi, codex]\n")
    make_skill(tmp_path, "no-codex-yet", "audience: user\nruns_on: [claude, kimi]\n")
    make_skill(tmp_path, "_template", "audience: user\nruns_on: [claude, kimi, codex]\n")
    (tmp_path / "not-a-skill").mkdir()
    return tmp_path


def test_select_for_codex_keeps_only_user_skills_codex_can_run(skills: Path) -> None:
    assert skill_agents.select_for("codex", skills) == ["shared"]


def test_select_for_kimi_includes_skills_waiting_for_a_codex_fallback(skills: Path) -> None:
    assert skill_agents.select_for("kimi", skills) == ["no-codex-yet", "shared"]


def test_select_skips_scaffold_and_directories_without_skill_md(skills: Path) -> None:
    names = skill_agents.select_for("claude", skills)
    assert "_template" not in names and "not-a-skill" not in names
    assert names == ["claude-only", "no-codex-yet", "shared"]


def test_check_passes_on_valid_headers(skills: Path) -> None:
    assert skill_agents.check(skills) == []


@pytest.mark.parametrize(
    ("header", "expected"),
    [
        ("runs_on: [claude]\n", "audience must be one of"),
        ("audience: everyone\nruns_on: [claude]\n", "audience must be one of"),
        ("audience: user\n", "runs_on must be a non-empty list"),
        ("audience: user\nruns_on: []\n", "runs_on must be a non-empty list"),
        ("audience: user\nruns_on: claude\n", "runs_on must be a non-empty list"),
        ("audience: user\nruns_on: [claude, cursor]\n", "unknown agents ['cursor']"),
        ("audience: user\nruns_on: [kimi, kimi]\n", "lists an agent twice"),
        ("description: Manager (R31): guides\naudience: user\nruns_on: [kimi]\n", "not valid YAML"),
    ],
)
def test_check_reports_each_header_problem(tmp_path: Path, header: str, expected: str) -> None:
    make_skill(tmp_path, "bad", header)
    problems = skill_agents.check(tmp_path)
    assert len(problems) == 1
    assert problems[0].startswith("bad: ") and expected in problems[0]


def test_skill_with_bad_header_is_never_selected(tmp_path: Path) -> None:
    make_skill(tmp_path, "bad", "audience: user\nruns_on: [codex, cursor]\n")
    assert skill_agents.select_for("codex", tmp_path) == []


def test_unknown_agent_is_rejected(skills: Path) -> None:
    with pytest.raises(ValueError, match="unknown agent"):
        skill_agents.select_for("cursor", skills)


def test_cli_check_exit_codes(skills: Path, tmp_path_factory: pytest.TempPathFactory) -> None:
    ok = subprocess.run([sys.executable, str(SCRIPT), "--check", str(skills)], capture_output=True, text=True)
    assert ok.returncode == 0 and "4 skill headers" in ok.stdout
    broken = tmp_path_factory.mktemp("broken")
    make_skill(broken, "bad", "audience: user\n")
    fail = subprocess.run([sys.executable, str(SCRIPT), "--check", str(broken)], capture_output=True, text=True)
    assert fail.returncode == 1 and "FAIL: bad: runs_on" in fail.stderr


def test_cli_for_prints_one_name_per_line(skills: Path) -> None:
    out = subprocess.run([sys.executable, str(SCRIPT), "--for", "codex", str(skills)], capture_output=True, text=True)
    assert out.returncode == 0 and out.stdout.split() == ["shared"]


def test_every_template_skill_declares_audience_and_runs_on() -> None:
    assert skill_agents.check(ROOT / ".claude" / "skills") == []


def test_template_keeps_codex_away_from_skills_without_fallback() -> None:
    codex = set(skill_agents.select_for("codex", ROOT / ".claude" / "skills"))
    # Closing protocols need an isolated-context checker Codex does not have yet (inventory 25.11).
    assert not codex & {"run-protocol", "day-close", "week-close", "month-close", "verify"}
    assert {"think", "wp-new", "org-dev", "transcribe"} <= codex
