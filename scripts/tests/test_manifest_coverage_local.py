"""
Тесты update-manifest.local.json (issue #247, хвост про перезапись excluded_paths).

check-manifest-coverage.py запускается как subprocess: файлы репо на stdin,
путь к манифесту аргументом. Проверяем:
  1. Без local-манифеста поведение прежнее — непокрытый файл блокирует (exit 1).
  2. excluded_paths из update-manifest.local.json снимают блок (exit 0).
  3. Сам update-manifest.local.json не требует покрытия.
  4. Битый JSON в local-манифесте — громкая ошибка (exit 2), не тихий пропуск.
"""

import json
import subprocess
from pathlib import Path

CHECKER = Path(__file__).parent.parent / "check-manifest-coverage.py"


def _run(tmp_path: Path, repo_files: list[str], manifest: dict,
         local_manifest: dict | str | None = None) -> subprocess.CompletedProcess:
    manifest_path = tmp_path / "update-manifest.json"
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    if local_manifest is not None:
        raw = (local_manifest if isinstance(local_manifest, str)
               else json.dumps(local_manifest))
        (tmp_path / "update-manifest.local.json").write_text(raw, encoding="utf-8")
    return subprocess.run(
        ["python3", str(CHECKER), str(manifest_path)],
        input="\n".join(repo_files),
        capture_output=True, text=True,
    )


BASE_MANIFEST = {"files": [{"path": "CLAUDE.md"}], "excluded_paths": []}


def test_uncovered_file_blocks_without_local_manifest(tmp_path):
    result = _run(tmp_path, ["CLAUDE.md", "my-fork-script.sh"], BASE_MANIFEST)
    assert result.returncode == 1
    assert "my-fork-script.sh" in result.stderr
    assert "update-manifest.local.json" in result.stderr  # hint mentions the new channel


def test_local_excluded_paths_unblock(tmp_path):
    result = _run(
        tmp_path,
        ["CLAUDE.md", "my-fork-script.sh", "my-folder/note.md"],
        BASE_MANIFEST,
        local_manifest={"excluded_paths": ["my-fork-script.sh", "my-folder/"]},
    )
    assert result.returncode == 0, result.stderr
    assert "excluded=2" in result.stdout


def test_local_manifest_itself_needs_no_coverage(tmp_path):
    result = _run(
        tmp_path,
        ["CLAUDE.md", "update-manifest.local.json"],
        BASE_MANIFEST,
        local_manifest={"excluded_paths": []},
    )
    assert result.returncode == 0, result.stderr


def test_malformed_local_manifest_fails_loudly(tmp_path):
    result = _run(tmp_path, ["CLAUDE.md"], BASE_MANIFEST,
                  local_manifest="{not json")
    assert result.returncode == 2
    assert "update-manifest.local.json" in result.stderr
