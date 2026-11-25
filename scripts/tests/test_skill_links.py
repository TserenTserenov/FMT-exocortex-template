"""Link contract of scripts/skill_links.py (WP-592 Ф7, DRR-f7-skills-delivery-links)."""
from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "skill_links.py"
SPEC = importlib.util.spec_from_file_location("skill_links", SCRIPT)
skill_links = importlib.util.module_from_spec(SPEC)
sys.modules["skill_links"] = skill_links  # dataclasses resolve field types through sys.modules
SPEC.loader.exec_module(skill_links)


def make_skill(ws: Path, name: str, runs_on: str = "[claude, kimi, codex]", audience: str = "user") -> None:
    skill = ws / ".claude" / "skills" / name
    skill.mkdir(parents=True, exist_ok=True)
    (skill / "SKILL.md").write_text(
        f"---\nname: {name}\naudience: {audience}\nruns_on: {runs_on}\n---\n\nBody.\n", encoding="utf-8")
    (skill / "ref.txt").write_text("resource", encoding="utf-8")


@pytest.fixture
def ws(tmp_path: Path) -> Path:
    make_skill(tmp_path, "think")
    make_skill(tmp_path, "wp-new")
    make_skill(tmp_path, "day-close", runs_on="[claude, kimi]")
    make_skill(tmp_path, "author-mode", audience="author")
    return tmp_path


def links(ws: Path) -> dict[str, str]:
    folder = ws / ".agents" / "skills"
    return {p.name: os.readlink(p) for p in folder.iterdir() if p.is_symlink()} if folder.is_dir() else {}


def test_links_only_skills_codex_can_run_with_relative_targets(ws: Path) -> None:
    report = skill_links.sync(ws, "codex")
    assert report.created == ["think", "wp-new"]
    assert links(ws) == {"think": "../../.claude/skills/think", "wp-new": "../../.claude/skills/wp-new"}
    # the agent reads the skill and its resources through the link
    assert (ws / ".agents" / "skills" / "think" / "ref.txt").read_text() == "resource"


def test_second_run_changes_nothing(ws: Path) -> None:
    skill_links.sync(ws, "codex")
    report = skill_links.sync(ws, "codex")
    assert report.created == [] and report.removed == [] and sorted(report.kept) == ["think", "wp-new"]


def test_foreign_directory_with_skill_name_is_left_untouched(ws: Path) -> None:
    own = ws / ".agents" / "skills" / "think"
    own.mkdir(parents=True)
    (own / "SKILL.md").write_text("user's own copy", encoding="utf-8")
    report = skill_links.sync(ws, "codex")
    assert (own / "SKILL.md").read_text() == "user's own copy"
    assert not own.is_symlink()
    assert any(c.startswith("think:") for c in report.conflicts)
    assert report.created == ["wp-new"]


def test_foreign_symlink_elsewhere_is_left_untouched(ws: Path, tmp_path_factory: pytest.TempPathFactory) -> None:
    elsewhere = tmp_path_factory.mktemp("elsewhere")
    folder = ws / ".agents" / "skills"
    folder.mkdir(parents=True)
    (folder / "think").symlink_to(elsewhere, target_is_directory=True)
    (folder / "unrelated").symlink_to(elsewhere, target_is_directory=True)
    report = skill_links.sync(ws, "codex")
    assert os.readlink(folder / "think") == str(elsewhere)
    assert os.readlink(folder / "unrelated") == str(elsewhere)
    assert [c for c in report.conflicts if c.startswith("think:")]
    assert "unrelated" not in report.removed


def test_link_removed_when_skill_leaves_selection(ws: Path) -> None:
    skill_links.sync(ws, "codex")
    make_skill(ws, "wp-new", runs_on="[claude, kimi]")  # fallback lost: codex no longer runs it
    report = skill_links.sync(ws, "codex")
    assert report.removed == ["wp-new"]
    assert links(ws) == {"think": "../../.claude/skills/think"}


def test_dangling_own_link_removed_when_skill_deleted(ws: Path) -> None:
    skill_links.sync(ws, "codex")
    (ws / ".claude" / "skills" / "wp-new" / "SKILL.md").unlink()
    (ws / ".claude" / "skills" / "wp-new" / "ref.txt").unlink()
    (ws / ".claude" / "skills" / "wp-new").rmdir()
    report = skill_links.sync(ws, "codex")
    assert report.removed == ["wp-new"]
    assert not (ws / ".agents" / "skills" / "wp-new").is_symlink()


def test_dry_run_changes_nothing(ws: Path) -> None:
    report = skill_links.sync(ws, "codex", dry_run=True)
    assert report.created == ["think", "wp-new"]
    assert not (ws / ".agents").exists()


def test_agent_folder_that_is_a_file_is_a_conflict(ws: Path) -> None:
    (ws / ".agents").mkdir()
    (ws / ".agents" / "skills").write_text("not a dir", encoding="utf-8")
    report = skill_links.sync(ws, "codex")
    assert report.created == [] and len(report.conflicts) == 1
    assert (ws / ".agents" / "skills").read_text() == "not a dir"


def test_symlink_failure_is_refused_without_copy(ws: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    def no_symlinks(self, target, target_is_directory=False):
        raise OSError(1, "Operation not permitted")
    monkeypatch.setattr(Path, "symlink_to", no_symlinks)
    report = skill_links.sync(ws, "codex")
    assert report.created == []
    assert sorted(r.split(":", 1)[0] for r in report.refused) == ["think", "wp-new"]
    assert list((ws / ".agents" / "skills").iterdir()) == []  # nothing copied


def test_cli_reports_and_exits_zero_on_conflict(ws: Path) -> None:
    (ws / ".agents" / "skills" / "think").mkdir(parents=True)
    out = subprocess.run([sys.executable, str(SCRIPT), "--workspace", str(ws)], capture_output=True, text=True)
    assert out.returncode == 0
    assert "CONFLICT: think:" in out.stdout and "link: wp-new" in out.stdout
    assert "skill links: 1 new, 0 kept, 0 removed, 1 conflicts, 0 refused" in out.stdout


def test_cli_without_skills_dir_fails(tmp_path: Path) -> None:
    out = subprocess.run([sys.executable, str(SCRIPT), "--workspace", str(tmp_path)], capture_output=True, text=True)
    assert out.returncode == 2 and ".claude/skills not found" in out.stderr


# --- regressions from the review of 2026-11-25 ---------------------------------

def test_skill_folder_pointing_outside_is_refused_and_stays_stable(ws: Path, tmp_path_factory: pytest.TempPathFactory) -> None:
    outside = tmp_path_factory.mktemp("outside-skill")
    (outside / "SKILL.md").write_text("---\nname: outer\naudience: user\nruns_on: [codex]\n---\n", encoding="utf-8")
    (ws / ".claude" / "skills" / "outer").symlink_to(outside, target_is_directory=True)
    first = skill_links.sync(ws, "codex")
    second = skill_links.sync(ws, "codex")
    for report in (first, second):
        assert [r for r in report.refused if r.startswith("outer:")]
        assert not [c for c in report.conflicts if c.startswith("outer:")]
    assert "outer" not in links(ws)


def test_skill_alias_inside_skills_folder_is_kept_on_rerun(ws: Path) -> None:
    (ws / ".claude" / "skills" / "think-alias").symlink_to("think", target_is_directory=True)
    skill_links.sync(ws, "codex")
    report = skill_links.sync(ws, "codex")
    assert "think-alias" in report.kept and report.removed == []


def test_unhashable_runs_on_skips_only_that_skill(ws: Path) -> None:
    make_skill(ws, "broken", runs_on="[[codex]]")
    report = skill_links.sync(ws, "codex")
    assert report.created == ["think", "wp-new"]


def test_dot_agents_as_symlink_is_a_conflict_and_nothing_is_written(ws: Path, tmp_path_factory: pytest.TempPathFactory) -> None:
    shared = tmp_path_factory.mktemp("shared")
    (ws / ".agents").symlink_to(shared, target_is_directory=True)
    report = skill_links.sync(ws, "codex")
    assert report.created == [] and len(report.conflicts) == 1
    assert list(shared.iterdir()) == []


def test_agent_skills_folder_as_symlink_is_a_conflict(ws: Path, tmp_path_factory: pytest.TempPathFactory) -> None:
    shared = tmp_path_factory.mktemp("shared-skills")
    (ws / ".agents").mkdir()
    (ws / ".agents" / "skills").symlink_to(shared, target_is_directory=True)
    report = skill_links.sync(ws, "codex")
    assert report.created == [] and len(report.conflicts) == 1
    assert list(shared.iterdir()) == []


def test_rerun_with_conflict_is_stable(ws: Path) -> None:
    (ws / ".agents" / "skills" / "think").mkdir(parents=True)
    skill_links.sync(ws, "codex")
    report = skill_links.sync(ws, "codex")
    assert report.created == [] and report.kept == ["wp-new"]
    assert [c for c in report.conflicts if c.startswith("think:")]


def test_cli_dry_run_prints_would_link(ws: Path) -> None:
    out = subprocess.run([sys.executable, str(SCRIPT), "--workspace", str(ws), "--dry-run"], capture_output=True, text=True)
    assert out.returncode == 0 and "would link: think" in out.stdout
    assert not (ws / ".agents").exists()


def test_relative_workspace_argument(ws: Path) -> None:
    out = subprocess.run([sys.executable, str(SCRIPT), "--workspace", "."], capture_output=True, text=True, cwd=ws)
    assert out.returncode == 0 and "skill links: 2 new" in out.stdout
    assert links(ws)["think"] == "../../.claude/skills/think"
