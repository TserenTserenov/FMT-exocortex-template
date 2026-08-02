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

import subprocess
import sys
from pathlib import Path

SEED_STRATEGY = Path(__file__).parent.parent.parent / "seed" / "strategy"
INSTALL_HOOKS = SEED_STRATEGY / "scripts" / "install-hooks.sh"
CANONICAL_PRE_PUSH = SEED_STRATEGY / ".githooks" / "pre-push"


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
