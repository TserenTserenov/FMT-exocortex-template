"""
Регрессионный тест install-hooks.sh (issue #342).

Скрипт раньше только бэкапил и делал исполняемым то, что уже лежало в
.githooks/ целевого репо, но нигде не копировал сам файл pre-push — на
установке, где .githooks/ существует, но содержит только pre-commit
(типичный случай для репо, заведённых до появления force-push guard'а,
WP-436), скрипт отчитывался "✅ Hooks wired", а pre-push так и оставался
отсутствующим. Фикс копирует недостающие хуки из канонического
seed/strategy/.githooks/ и падает с ⚠️/exit 1, если источник не найден —
вместо ложноположительного "готово".

Тест гоняет РЕАЛЬНЫЙ install-hooks.sh end-to-end на временном git-репо.
"""

import shlex
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent.parent
SEED_STRATEGY = ROOT / "seed" / "strategy"
INSTALL_HOOKS = SEED_STRATEGY / "scripts" / "install-hooks.sh"
ROOT_INSTALL_HOOKS = ROOT / "scripts" / "install-hooks.sh"
CANONICAL_PRE_PUSH = SEED_STRATEGY / ".githooks" / "pre-push"
UPDATE_SH = ROOT / "update.sh"


def _init_repo(path: Path) -> None:
    path.mkdir(parents=True)
    subprocess.run(["git", "init", "-q"], cwd=path, check=True)


def _run_install_hooks(repo: Path, **env_overrides):
    env = {"PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "HOME": str(repo.parent)}
    env.update(env_overrides)
    return subprocess.run(
        ["bash", str(INSTALL_HOOKS), str(repo)],
        capture_output=True,
        text=True,
        env=env,
    )


def _extract_shell_function(name: str) -> str:
    source = UPDATE_SH.read_text(encoding="utf-8")
    start = source.index(f"{name}() {{")
    end = source.index("\n}\n", start) + 2
    return source[start:end]


def _update_backfill_script(
    workspace: Path,
    *,
    effective_governance: str | None = "custom-governance",
) -> str:
    parts = [
        "set -euo pipefail",
        f"SCRIPT_DIR={shlex.quote(str(ROOT))}",
        f"WORKSPACE_DIR={shlex.quote(str(workspace))}",
        "ENV_GOVERNANCE_REPO=",
        _extract_shell_function("effective_governance_repo"),
        _extract_shell_function("atomic_copy_executable"),
        _extract_shell_function("backfill_platform_hooks"),
    ]
    if effective_governance is not None:
        parts.append(f"EFFECTIVE_GOVERNANCE_REPO={shlex.quote(effective_governance)}")
    else:
        parts.extend(["unset EFFECTIVE_GOVERNANCE_REPO", "unset IWE_GOVERNANCE_REPO"])
    parts.append("backfill_platform_hooks")
    return "\n".join(parts)


def test_root_and_seed_installers_are_byte_identical():
    assert ROOT_INSTALL_HOOKS.read_bytes() == INSTALL_HOOKS.read_bytes()


def test_pre_existing_githooks_missing_pre_push_gets_it_copied(tmp_path):
    """Старая установка: .githooks/ есть, только pre-commit — pre-push должен появиться."""
    repo = tmp_path / "repo"
    _init_repo(repo)
    hooks_dir = repo / ".githooks"
    hooks_dir.mkdir()
    (hooks_dir / "pre-commit").write_text("#!/bin/bash\necho stub\n", encoding="utf-8")
    (hooks_dir / "pre-commit").chmod(0o755)

    result = _run_install_hooks(repo, IWE_TEMPLATE=str(Path(__file__).parent.parent.parent))

    assert result.returncode == 0, result.stdout + result.stderr
    pre_push = hooks_dir / "pre-push"
    assert pre_push.is_file(), "pre-push должен быть скопирован из канонического источника"
    assert pre_push.read_text(encoding="utf-8") == CANONICAL_PRE_PUSH.read_text(encoding="utf-8")
    assert pre_push.stat().st_mode & 0o111, "pre-push должен быть исполняемым"


def test_fresh_repo_gets_both_hooks(tmp_path):
    """Совсем свежий репо без .githooks/ вообще — оба хука должны появиться."""
    repo = tmp_path / "repo"
    _init_repo(repo)

    result = _run_install_hooks(repo, IWE_TEMPLATE=str(Path(__file__).parent.parent.parent))

    assert result.returncode == 0, result.stdout + result.stderr
    assert (repo / ".githooks" / "pre-commit").is_file()
    assert (repo / ".githooks" / "pre-push").is_file()


def test_repeated_install_never_overwrites_differing_local_hook(tmp_path):
    """WP-484 (31.08.2026): a hook that exists but differs from canonical is a
    local customization (e.g. a repo-specific composite pre-commit), not
    drift to repair — self-heal must warn and leave it alone, not back it up
    and replace it."""
    repo = tmp_path / "repo"
    _init_repo(repo)
    hooks_dir = repo / ".githooks"
    hooks_dir.mkdir()
    custom_pre_commit = "#!/bin/bash\necho custom\n"
    (hooks_dir / "pre-commit").write_text(custom_pre_commit, encoding="utf-8")

    first = _run_install_hooks(repo, IWE_TEMPLATE=str(ROOT))
    assert first.returncode == 0, first.stdout + first.stderr
    assert (hooks_dir / "pre-commit").read_text(encoding="utf-8") == custom_pre_commit
    assert "отличается от канонического" in first.stdout + first.stderr
    assert not (repo / ".git" / "hook-backups").exists()

    second = _run_install_hooks(repo, IWE_TEMPLATE=str(ROOT))
    assert second.returncode == 0, second.stdout + second.stderr
    assert (hooks_dir / "pre-commit").read_text(encoding="utf-8") == custom_pre_commit


def test_missing_canonical_source_fails_loud_not_silent_success(tmp_path):
    """Источник не найден — скрипт обязан упасть, а не рапортовать ложный успех."""
    repo = tmp_path / "repo"
    _init_repo(repo)
    fake_home = tmp_path / "fakehome"
    fake_home.mkdir()

    result = _run_install_hooks(
        repo, IWE_TEMPLATE="", IWE_ROOT=str(tmp_path / "nonexistent"), HOME=str(fake_home)
    )

    assert result.returncode != 0
    assert "не найден" in result.stdout or "не найден" in result.stderr
    assert "✅" not in result.stdout, "не должен утверждать успех, если хуков всё ещё нет"
    assert subprocess.run(
        ["git", "config", "--get", "core.hooksPath"],
        cwd=repo,
        capture_output=True,
        text=True,
    ).returncode != 0
    assert not (repo / ".githooks").exists()


def test_symlink_hook_file_is_refused_without_external_write_or_config(tmp_path):
    repo = tmp_path / "repo"
    _init_repo(repo)
    hooks_dir = repo / ".githooks"
    hooks_dir.mkdir()
    sentinel = tmp_path / "outside-hook"
    sentinel.write_text("outside sentinel\n", encoding="utf-8")
    (hooks_dir / "pre-commit").symlink_to(sentinel)

    result = _run_install_hooks(repo, IWE_TEMPLATE=str(ROOT))

    assert result.returncode != 0
    assert "symlink" in (result.stdout + result.stderr).lower()
    assert sentinel.read_text(encoding="utf-8") == "outside sentinel\n"
    assert subprocess.run(
        ["git", "config", "--get", "core.hooksPath"], cwd=repo
    ).returncode != 0


def test_second_symlink_hook_is_preflighted_before_first_hook_changes(tmp_path):
    repo = tmp_path / "repo"
    _init_repo(repo)
    hooks_dir = repo / ".githooks"
    hooks_dir.mkdir()
    pre_commit = hooks_dir / "pre-commit"
    pre_commit.write_text("#!/bin/bash\necho custom first hook\n", encoding="utf-8")
    pre_commit.chmod(0o755)
    sentinel = tmp_path / "outside-pre-push"
    sentinel.write_text("outside second-hook sentinel\n", encoding="utf-8")
    (hooks_dir / "pre-push").symlink_to(sentinel)
    pre_commit_before = pre_commit.read_bytes()
    git_config_before = (repo / ".git" / "config").read_bytes()

    result = _run_install_hooks(repo, IWE_TEMPLATE=str(ROOT))

    assert result.returncode != 0
    assert "symlink" in (result.stdout + result.stderr).lower()
    assert pre_commit.read_bytes() == pre_commit_before
    assert sentinel.read_text(encoding="utf-8") == "outside second-hook sentinel\n"
    assert (repo / ".git" / "config").read_bytes() == git_config_before
    assert not (repo / ".git" / "hook-backups").exists()


def test_symlink_hook_directory_is_refused_without_external_write_or_config(tmp_path):
    repo = tmp_path / "repo"
    _init_repo(repo)
    outside = tmp_path / "outside-hooks"
    outside.mkdir()
    sentinel = outside / "sentinel"
    sentinel.write_text("outside directory sentinel\n", encoding="utf-8")
    (repo / ".githooks").symlink_to(outside, target_is_directory=True)

    result = _run_install_hooks(repo, IWE_TEMPLATE=str(ROOT))

    assert result.returncode != 0
    assert "symlink" in (result.stdout + result.stderr).lower()
    assert sentinel.read_text(encoding="utf-8") == "outside directory sentinel\n"
    assert not (outside / "pre-commit").exists()
    assert not (outside / "pre-push").exists()
    assert subprocess.run(
        ["git", "config", "--get", "core.hooksPath"], cwd=repo
    ).returncode != 0


def test_symlink_repository_is_refused_without_external_write_or_config(tmp_path):
    outside_repo = tmp_path / "outside-repo"
    _init_repo(outside_repo)
    sentinel = outside_repo / "sentinel"
    sentinel.write_text("outside repo sentinel\n", encoding="utf-8")
    repo_link = tmp_path / "repo-link"
    repo_link.symlink_to(outside_repo, target_is_directory=True)

    result = _run_install_hooks(repo_link, IWE_TEMPLATE=str(ROOT))

    assert result.returncode != 0
    assert sentinel.read_text(encoding="utf-8") == "outside repo sentinel\n"
    assert not (outside_repo / ".githooks").exists()
    assert subprocess.run(
        ["git", "config", "--get", "core.hooksPath"], cwd=outside_repo
    ).returncode != 0


def test_update_backfill_delivers_installer_and_hooks_idempotently(tmp_path):
    workspace = tmp_path / "IWE-custom"
    governance = workspace / "custom-governance"
    _init_repo(governance)
    target_installer = governance / "scripts" / "install-hooks.sh"
    target_installer.parent.mkdir()
    target_installer.write_text("#!/bin/bash\necho old installer\n", encoding="utf-8")

    script = _update_backfill_script(workspace)

    first = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    assert first.returncode == 0, first.stdout + first.stderr
    assert target_installer.read_text(encoding="utf-8") == INSTALL_HOOKS.read_text(encoding="utf-8")
    for hook_name in ("pre-commit", "pre-push"):
        installed_hook = governance / ".githooks" / hook_name
        canonical_hook = SEED_STRATEGY / ".githooks" / hook_name
        assert installed_hook.read_bytes() == canonical_hook.read_bytes()
        assert installed_hook.stat().st_mode & 0o111
    assert subprocess.run(
        ["git", "config", "--get", "core.hooksPath"],
        cwd=governance,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip() == ".githooks"

    # backup_dir here is update.sh's own -- it backs up the replaced
    # install-hooks.sh installer script (platform code, always kept in sync),
    # unrelated to install-hooks.sh's own hook-content handling below. A
    # stable installer means no new backup on the second, idempotent run.
    backups_after_first = sorted((governance / ".git" / "hook-backups").iterdir())
    second = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    assert second.returncode == 0, second.stdout + second.stderr
    assert sorted((governance / ".git" / "hook-backups").iterdir()) == backups_after_first
    for hook_name in ("pre-commit", "pre-push"):
        installed_hook = governance / ".githooks" / hook_name
        canonical_hook = SEED_STRATEGY / ".githooks" / hook_name
        assert installed_hook.read_bytes() == canonical_hook.read_bytes()
        assert installed_hook.stat().st_mode & 0o111


def test_update_backfill_reports_unsupported_git_worktree(tmp_path):
    main_repo = tmp_path / "main-governance"
    _init_repo(main_repo)
    subprocess.run(["git", "config", "user.name", "Hook test"], cwd=main_repo, check=True)
    subprocess.run(
        ["git", "config", "user.email", "hook-test@example.invalid"],
        cwd=main_repo,
        check=True,
    )
    (main_repo / "tracked.md").write_text("fixture\n", encoding="utf-8")
    subprocess.run(["git", "add", "--", "tracked.md"], cwd=main_repo, check=True)
    subprocess.run(["git", "commit", "-qm", "fixture"], cwd=main_repo, check=True)

    workspace = tmp_path / "IWE-worktree"
    workspace.mkdir()
    governance = workspace / "custom-governance"
    subprocess.run(
        ["git", "worktree", "add", "-q", "-b", "hook-worktree-fixture", str(governance)],
        cwd=main_repo,
        check=True,
    )
    assert (governance / ".git").is_file()

    script = _update_backfill_script(workspace)
    result = subprocess.run(["bash", "-c", script], capture_output=True, text=True)

    assert result.returncode == 0
    assert "обнаружен Git worktree" in result.stderr
    assert "platform hooks не установлены" in result.stderr
    assert not (governance / "scripts" / "install-hooks.sh").exists()


def test_update_backfill_reads_workspace_config_without_export(tmp_path):
    workspace = tmp_path / "IWE-config-only"
    governance = workspace / "configured-governance"
    _init_repo(governance)
    (workspace / ".exocortex.env").write_text(
        "GOVERNANCE_REPO=configured-governance\n", encoding="utf-8"
    )

    result = subprocess.run(
        ["bash", "-c", _update_backfill_script(workspace, effective_governance=None)],
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert (governance / "scripts" / "install-hooks.sh").is_file()
    assert (governance / ".githooks" / "pre-commit").is_file()


def test_update_backfill_refuses_symlink_scripts_parent(tmp_path):
    workspace = tmp_path / "IWE-symlink-parent"
    governance = workspace / "custom-governance"
    _init_repo(governance)
    outside = tmp_path / "outside-scripts"
    outside.mkdir()
    sentinel = outside / "sentinel"
    sentinel.write_text("outside scripts sentinel\n", encoding="utf-8")
    (governance / "scripts").symlink_to(outside, target_is_directory=True)

    result = subprocess.run(
        ["bash", "-c", _update_backfill_script(workspace)],
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
    assert "symlink" in (result.stdout + result.stderr).lower()
    assert sentinel.read_text(encoding="utf-8") == "outside scripts sentinel\n"
    assert not (outside / "install-hooks.sh").exists()
    assert subprocess.run(
        ["git", "config", "--get", "core.hooksPath"], cwd=governance
    ).returncode != 0


def test_update_backfill_refuses_symlink_governance_repo(tmp_path):
    workspace = tmp_path / "IWE-symlink-governance"
    workspace.mkdir()
    outside_repo = tmp_path / "outside-governance"
    _init_repo(outside_repo)
    sentinel = outside_repo / "sentinel"
    sentinel.write_text("outside governance sentinel\n", encoding="utf-8")
    (workspace / "custom-governance").symlink_to(
        outside_repo, target_is_directory=True
    )

    result = subprocess.run(
        ["bash", "-c", _update_backfill_script(workspace)],
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
    assert "symlink" in (result.stdout + result.stderr).lower()
    assert sentinel.read_text(encoding="utf-8") == "outside governance sentinel\n"
    assert not (outside_repo / "scripts").exists()
    assert subprocess.run(
        ["git", "config", "--get", "core.hooksPath"], cwd=outside_repo
    ).returncode != 0


@pytest.mark.parametrize("governance_name", [".git", "template"])
def test_effective_governance_rejects_reserved_or_template_target(
    tmp_path, governance_name
):
    workspace = tmp_path / "IWE-misconfigured"
    template = workspace / "template"
    template.mkdir(parents=True)
    sentinel = template / "sentinel"
    sentinel.write_text("template sentinel\n", encoding="utf-8")
    (workspace / ".exocortex.env").write_text(
        f"GOVERNANCE_REPO={governance_name}\n", encoding="utf-8"
    )
    script = "\n".join(
        [
            "set -euo pipefail",
            f"SCRIPT_DIR={shlex.quote(str(template))}",
            f"WORKSPACE_DIR={shlex.quote(str(workspace))}",
            "ENV_GOVERNANCE_REPO=",
            "unset IWE_GOVERNANCE_REPO",
            _extract_shell_function("effective_governance_repo"),
            "effective_governance_repo",
        ]
    )

    result = subprocess.run(["bash", "-c", script], capture_output=True, text=True)

    assert result.returncode != 0
    assert sentinel.read_text(encoding="utf-8") == "template sentinel\n"


def test_root_and_seed_installers_have_one_implementation():
    root_lines = (ROOT / "scripts" / "install-hooks.sh").read_text(encoding="utf-8").splitlines()
    seed_lines = INSTALL_HOOKS.read_text(encoding="utf-8").splitlines()
    assert seed_lines == root_lines
