"""
Интеграционные тесты для skill-promote.sh.

Каждый тест работает в минимальной временной копии FMT, чтобы не портить
реальное шаблонное репо и не ждать копирования всего дерева.
"""

import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

FMT_ROOT = Path(__file__).parent.parent.parent.resolve()
REQUIRED_SCRIPTS = [
    "skill-promote.sh",
    "validate-skill.sh",
    "validate-fmt-scripts.sh",
    "generate-skills-catalog.sh",
    "changelog-append.sh",
    "promote-common.sh",
]

SKILL_MD_TEMPLATE = """---
name: {name}
description: "Тестовый скилл для skill-promote.sh"
version: 0.1.0
layer: L3
status: experimental
triggers:
  slash: [/{name}]
---

# {name}

Этот скилл использует путь /Users/testuser/IWE/scripts/helper.sh
и ссылается на репо DS-strategy.

```bash
bash /Users/testuser/IWE/scripts/helper.sh
```

Also $HOME/IWE/scripts/another.sh.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
"""

SHELL_HELPER = """#!/usr/bin/env bash
# Test helper
bash /Users/testuser/IWE/scripts/helper.sh
"""

CHANGELOG_HEADER = """# Changelog

All notable changes to this project will be documented in this file.

## [0.0.0] — 2026-01-01

- Initial release
"""


def make_minimal_fmt(tmp_path: Path) -> Path:
    """Создаёт минимальную копию FMT только с нужными скриптами."""
    tmp_fmt = tmp_path / "fmt"
    scripts_dir = tmp_fmt / "scripts"
    scripts_dir.mkdir(parents=True)
    for script in REQUIRED_SCRIPTS:
        src = FMT_ROOT / "scripts" / script
        dst = scripts_dir / script
        shutil.copy2(src, dst)
    (tmp_fmt / ".claude" / "skills").mkdir(parents=True)
    (tmp_fmt / "CHANGELOG.md").write_text(CHANGELOG_HEADER, encoding="utf-8")
    # Инициализируем git, чтобы git status warning работал
    subprocess.run(["git", "init", "-q", str(tmp_fmt)], check=True)
    return tmp_fmt


def make_test_skill(tmp_path: Path, name: str = "test-skill") -> Path:
    """Создаёт тестовый скилл с мусорным файлом .DS_Store."""
    skill_dir = tmp_path / name
    skill_dir.mkdir(parents=True)
    (skill_dir / "SKILL.md").write_text(SKILL_MD_TEMPLATE.format(name=name), encoding="utf-8")
    (skill_dir / "helper.sh").write_text(SHELL_HELPER, encoding="utf-8")
    (skill_dir / "helper.sh").chmod(0o755)
    (skill_dir / ".DS_Store").write_text("junk", encoding="utf-8")
    return skill_dir


def run_promote(
    skill_src: Path,
    tmp_fmt: Path,
    dry_run: bool = False,
    explicit_template: bool = True,
) -> subprocess.CompletedProcess:
    """Запускает skill-promote.sh в изолированном окружении."""
    env = os.environ.copy()
    tmp_iwe = tmp_fmt.parent / "iwe"
    tmp_iwe.mkdir(parents=True, exist_ok=True)
    (tmp_iwe / ".claude" / "skills").mkdir(parents=True, exist_ok=True)
    env["IWE_WORKSPACE"] = str(tmp_iwe)
    if explicit_template:
        env["IWE_TEMPLATE"] = str(tmp_fmt)
        expected_changelog_target = tmp_fmt
    else:
        env.pop("IWE_TEMPLATE", None)
        fallback_template = tmp_iwe / "FMT-exocortex-template"
        if not fallback_template.exists():
            fallback_template.symlink_to(tmp_fmt, target_is_directory=True)
        expected_changelog_target = fallback_template
    env["EXPECTED_CHANGELOG_TARGET"] = str(expected_changelog_target)
    # Pin HOME so the personal-path substitution ($HOME/IWE -> ${IWE:-$HOME/IWE}) has a
    # deterministic match for the /Users/testuser/IWE paths the fixtures hard-code,
    # independent of the runner's real HOME (/home/runner in CI, /Users/<dev> locally).
    env["HOME"] = "/Users/testuser"
    args = ["bash", str(tmp_fmt / "scripts" / "skill-promote.sh"), str(skill_src)]
    if dry_run:
        args.append("--dry-run")
    return subprocess.run(args, env=env, capture_output=True, text=True, timeout=60)


@pytest.fixture
def isolated_env(tmp_path: Path):
    """Возвращает (skill_src, tmp_fmt)."""
    tmp_fmt = make_minimal_fmt(tmp_path)
    skill_src = make_test_skill(tmp_path / "skills")
    return skill_src, tmp_fmt


def test_dry_run_shows_substitutions_and_layer_l1(isolated_env):
    skill_src, tmp_fmt = isolated_env
    result = run_promote(skill_src, tmp_fmt, dry_run=True)
    assert result.returncode == 0, result.stderr
    assert "layer: L1" in result.stdout
    assert "${IWE:-$HOME/IWE}/scripts/helper.sh" in result.stdout
    assert not (tmp_fmt / ".claude" / "skills" / "test-skill").exists()


def test_real_promote_cleans_and_validates(isolated_env):
    skill_src, tmp_fmt = isolated_env
    result = run_promote(skill_src, tmp_fmt)
    assert result.returncode == 0, result.stderr + result.stdout

    dest = tmp_fmt / ".claude" / "skills" / "test-skill"
    assert dest.exists()
    assert (dest / "SKILL.md").exists()
    assert not (dest / ".DS_Store").exists()
    assert os.access(dest / "helper.sh", os.X_OK)

    skill_text = (dest / "SKILL.md").read_text(encoding="utf-8")
    assert "layer: L1" in skill_text
    assert "/Users/testuser/IWE" not in skill_text
    assert "${IWE:-$HOME/IWE}/scripts/helper.sh" in skill_text

    assert "validate-fmt-scripts:" in result.stdout
    assert "нарушений нет" in result.stdout
    assert (tmp_fmt / ".claude" / "skills-catalog.yaml").exists()
    catalog = (tmp_fmt / ".claude" / "skills-catalog.yaml").read_text(encoding="utf-8")
    assert "test-skill" in catalog


def test_real_promote_is_idempotent_and_creates_backup(isolated_env):
    skill_src, tmp_fmt = isolated_env
    r1 = run_promote(skill_src, tmp_fmt)
    assert r1.returncode == 0, r1.stderr + r1.stdout

    r2 = run_promote(skill_src, tmp_fmt)
    assert r2.returncode == 0, r2.stderr + r2.stdout
    assert "Резервная копия" in r2.stdout

    status_file = tmp_fmt / "promotion-status.yaml"
    status_text = status_file.read_text(encoding="utf-8")
    count = status_text.count("artifact_path: .claude/skills/test-skill")
    assert count == 1


def test_git_status_warning_when_dirty(isolated_env):
    skill_src, tmp_fmt = isolated_env
    (tmp_fmt / "dirty-marker.txt").write_text("x", encoding="utf-8")
    result = run_promote(skill_src, tmp_fmt)
    assert result.returncode == 0, result.stderr + result.stdout
    assert "FMT-репо имеет незакоммиченные изменения" in result.stdout


def test_real_promote_passes_fallback_target_explicitly_to_changelog(isolated_env):
    skill_src, tmp_fmt = isolated_env
    (tmp_fmt / "scripts" / "changelog-append.sh").write_text(
        """#!/usr/bin/env bash
if [[ "${IWE_TEMPLATE:-}" != "${EXPECTED_CHANGELOG_TARGET:-}" ]]; then
    echo "wrong changelog target: ${IWE_TEMPLATE:-unset}" >&2
    exit 91
fi
echo "TARGET_HANDOFF_OK"
""",
        encoding="utf-8",
    )

    result = run_promote(skill_src, tmp_fmt, explicit_template=False)

    assert result.returncode == 0, result.stderr + result.stdout
    assert "TARGET_HANDOFF_OK" in result.stdout


def make_changelog_worktrees(tmp_path: Path) -> tuple[Path, Path, Path]:
    """Create a canonical clone and a linked worktree containing the helper."""
    fake_home = tmp_path / "home"
    canonical = fake_home / "IWE" / "FMT-exocortex-template"
    canonical.mkdir(parents=True)
    shutil.copy2(FMT_ROOT / "scripts" / "changelog-append.sh", canonical / "changelog-append.sh")
    (canonical / "CHANGELOG.md").write_text(CHANGELOG_HEADER, encoding="utf-8")
    (canonical / "feature.txt").write_text("candidate\n", encoding="utf-8")

    subprocess.run(["git", "init", "-q", str(canonical)], check=True)
    subprocess.run(["git", "-C", str(canonical), "add", "--", "CHANGELOG.md", "changelog-append.sh", "feature.txt"], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(canonical),
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "-q",
            "-m",
            "feat: changelog target fixture",
        ],
        check=True,
    )

    isolated = tmp_path / "isolated-worktree"
    subprocess.run(
        ["git", "-C", str(canonical), "worktree", "add", "-q", "-b", "isolated-test", str(isolated)],
        check=True,
    )
    return fake_home, canonical, isolated


def run_changelog(script: Path, fake_home: Path, *args: str, target: Path | None = None) -> subprocess.CompletedProcess:
    """Run changelog-append without inheriting an author's checkout variables."""
    env = os.environ.copy()
    env.pop("IWE_TEMPLATE", None)
    env.pop("IWE_WORKSPACE", None)
    env["HOME"] = str(fake_home)
    if target is not None:
        env["IWE_TEMPLATE"] = str(target)
    return subprocess.run(
        ["bash", str(script), *args],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )


def test_changelog_append_write_without_explicit_template_fails_closed(tmp_path):
    fake_home, canonical, isolated = make_changelog_worktrees(tmp_path)
    canonical_before = (canonical / "CHANGELOG.md").read_bytes()
    isolated_before = (isolated / "CHANGELOG.md").read_bytes()

    result = run_changelog(isolated / "changelog-append.sh", fake_home)

    assert result.returncode == 2
    assert "IWE_TEMPLATE=/path/to/FMT" in result.stderr
    assert (canonical / "CHANGELOG.md").read_bytes() == canonical_before
    assert (isolated / "CHANGELOG.md").read_bytes() == isolated_before


def test_changelog_append_dry_run_without_template_warns_and_preserves_files(tmp_path):
    fake_home, canonical, isolated = make_changelog_worktrees(tmp_path)
    canonical_before = (canonical / "CHANGELOG.md").read_bytes()
    isolated_before = (isolated / "CHANGELOG.md").read_bytes()

    result = run_changelog(isolated / "changelog-append.sh", fake_home, "--dry-run")

    assert result.returncode == 0, result.stderr + result.stdout
    assert "dry-run читает fallback" in result.stderr
    assert (canonical / "CHANGELOG.md").read_bytes() == canonical_before
    assert (isolated / "CHANGELOG.md").read_bytes() == isolated_before


def test_changelog_append_explicit_template_updates_only_target(tmp_path):
    fake_home, canonical, isolated = make_changelog_worktrees(tmp_path)
    canonical_before = (canonical / "CHANGELOG.md").read_bytes()
    isolated_before = (isolated / "CHANGELOG.md").read_bytes()

    result = run_changelog(isolated / "changelog-append.sh", fake_home, target=isolated)

    assert result.returncode == 0, result.stderr + result.stdout
    assert (canonical / "CHANGELOG.md").read_bytes() == canonical_before
    assert (isolated / "CHANGELOG.md").read_bytes() != isolated_before
    assert "## [Unreleased]" in (isolated / "CHANGELOG.md").read_text(encoding="utf-8")
