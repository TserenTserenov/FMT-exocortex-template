"""
Тесты режима --mode=delta (WP-415 Ф-В2): выбор файлов по дельте от last_synced_sha.

Реальный вызов LLM (translate_file) подменяется стабом — эти тесты проверяют
только логику выбора файлов и запись .translation-state.yaml, не перевод.
"""

import subprocess
import sys
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).parent.parent))
import translate  # noqa: E402
from delivery_checks import GlossaryTerm, check_content, check_formal  # noqa: E402


def _git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args], cwd=repo, capture_output=True, text=True, check=True
    )
    return result.stdout.strip()


@pytest.fixture
def repo(tmp_path):
    """A minimal git repo with one category-D doc file, two commits."""
    root = tmp_path / "repo"
    root.mkdir()
    _git(root, "init", "-q")
    _git(root, "config", "user.email", "test@example.com")
    _git(root, "config", "user.name", "Test")

    (root / "README.md").write_text("Первая версия.\n", encoding="utf-8")
    (root / "docs").mkdir()
    (root / "docs" / "guide.md").write_text("Гайд v1.\n", encoding="utf-8")
    _git(root, "add", ".")
    _git(root, "commit", "-q", "-m", "initial")
    first_sha = _git(root, "rev-parse", "HEAD")

    (root / "README.md").write_text("Вторая версия.\n", encoding="utf-8")
    _git(root, "add", "README.md")
    _git(root, "commit", "-q", "-m", "update readme only")

    return root, first_sha


MANIFEST = {"categories": {"D": {"files": ["README.md", "docs/"]}}}


def test_system_prompt_requires_cyrillic_free_published_output(tmp_path):
    style = tmp_path / "en-doc-style.md"
    style.write_text("Use plain English.\n", encoding="utf-8")

    prompt = translate._build_system_prompt(style, glossary={}, manifest={"exclusions": {}})

    assert "must contain no Cyrillic characters" in prompt


def _stub_args(repo_root: Path, output_dir: Path, state_file: Path | None) -> translate.argparse.Namespace:
    return translate.argparse.Namespace(
        output_dir=str(output_dir),
        state_file=str(state_file) if state_file else None,
        style=str(repo_root / "translation" / "en-doc-style.md"),
        model="stub-model",
        files=[],
    )


def test_first_run_without_state_translates_full_category_d_set(monkeypatch, repo):
    root, _ = repo
    translated_files = []

    def fake_translate_file(file_path, *_args, **_kwargs):
        translated_files.append(file_path)
        return ("stub output\n", [])

    monkeypatch.setattr(translate, "translate_file", fake_translate_file)
    monkeypatch.setattr(translate, "_find_repo_root", lambda _cwd: root)
    monkeypatch.setattr(translate, "_make_client", lambda: None)

    args = _stub_args(root, root / "en-out", state_file=None)
    exit_code = translate.run_delta(args, MANIFEST, glossary={})

    assert exit_code == 0
    assert {p.name for p in translated_files} == {"README.md", "guide.md"}

    state = yaml.safe_load((root / "en-out" / ".translation-state.yaml").read_text())
    assert state["last_synced_sha"] == _git(root, "rev-parse", "HEAD")
    assert set(state["files_translated"]) == {"README.md", "docs/guide.md"}


def test_second_run_with_state_translates_only_changed_file(monkeypatch, repo):
    root, first_sha = repo
    translated_files = []

    def fake_translate_file(file_path, *_args, **_kwargs):
        translated_files.append(file_path)
        return ("stub output\n", [])

    monkeypatch.setattr(translate, "translate_file", fake_translate_file)
    monkeypatch.setattr(translate, "_find_repo_root", lambda _cwd: root)
    monkeypatch.setattr(translate, "_make_client", lambda: None)

    state_file = root / "state" / ".translation-state.yaml"
    state_file.parent.mkdir(parents=True)
    state_file.write_text(yaml.dump({"last_synced_sha": first_sha}), encoding="utf-8")

    args = _stub_args(root, root / "en-out", state_file=state_file)
    exit_code = translate.run_delta(args, MANIFEST, glossary={})

    assert exit_code == 0
    assert [p.name for p in translated_files] == ["README.md"]  # guide.md unchanged, skipped


def test_no_changes_writes_state_without_translating(monkeypatch, repo):
    root, _ = repo
    translated_files = []

    monkeypatch.setattr(
        translate, "translate_file", lambda *a, **k: translated_files.append(a) or ("x", [])
    )
    monkeypatch.setattr(translate, "_find_repo_root", lambda _cwd: root)

    head_sha = _git(root, "rev-parse", "HEAD")
    state_file = root / "state" / ".translation-state.yaml"
    state_file.parent.mkdir(parents=True)
    state_file.write_text(yaml.dump({"last_synced_sha": head_sha}), encoding="utf-8")

    args = _stub_args(root, root / "en-out", state_file=state_file)
    exit_code = translate.run_delta(args, MANIFEST, glossary={})

    assert exit_code == 0
    assert translated_files == []
    state = yaml.safe_load((root / "en-out" / ".translation-state.yaml").read_text())
    assert state["files_translated"] == []


def test_delta_output_passes_delivery_checks(monkeypatch, repo):
    """End-to-end seam: run_delta's output layout must be exactly what
    delivery_checks.check_formal/check_content expect, given a real
    (source, output) path pair read from files_translated in the state file.
    """
    root, _ = repo

    def fake_translate_file(_file_path, *_args, **_kwargs):
        return ("Translated body without leftover glossary terms.\n", [])

    monkeypatch.setattr(translate, "translate_file", fake_translate_file)
    monkeypatch.setattr(translate, "_find_repo_root", lambda _cwd: root)
    monkeypatch.setattr(translate, "_make_client", lambda: None)

    output_dir = root / "en-out"
    args = _stub_args(root, output_dir, state_file=None)
    exit_code = translate.run_delta(args, MANIFEST, glossary={})
    assert exit_code == 0

    state = yaml.safe_load((output_dir / ".translation-state.yaml").read_text())
    glossary_terms = [GlossaryTerm("Первая версия", tier=1)]

    for rel in state["files_translated"]:
        source_path = root / rel
        output_path = output_dir / rel

        formal_violations = check_formal(source_path, output_path)
        assert formal_violations == []

        content_report = check_content(output_path.read_text(encoding="utf-8"), glossary_terms)
        assert content_report.passed
