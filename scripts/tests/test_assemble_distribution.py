"""Tests for assemble_distribution: manifest-driven English tree assembly."""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))
import assemble_distribution as ad  # noqa: E402


def make_source(tmp_path, files, manifest_paths):
    for name, content in files.items():
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    (tmp_path / "translation-manifest.yaml").write_text(
        "categories:\n  I:\n    files:\n      - params.yaml.example\n      - .claude/skills/**/SKILL.md\n", encoding="utf-8")
    manifest = {"files": [{"path": p, "sha256": "0"} for p in manifest_paths]}
    (tmp_path / "update-manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return tmp_path


def test_set_drops_guide_kit_and_adds_page_files(tmp_path):
    src = make_source(
        tmp_path / "src",
        {"README.md": "x", "LICENSE": "x", "scripts/a.sh": "x", "guide-kit/g.py": "x"},
        ["scripts/a.sh", "guide-kit/g.py"],
    )
    assert ad.distribution_set(src) == {"scripts/a.sh", "README.md", "LICENSE"}


def test_set_ships_only_the_english_language_catalog(tmp_path):
    catalogs = [".claude/lib/locale/en.json", ".claude/lib/locale/ru.json"]
    src = make_source(tmp_path / "src", {c: "{}" for c in catalogs}, catalogs)
    assert ad.distribution_set(src) == {".claude/lib/locale/en.json"}


def test_code_copied_markdown_kept_and_extras_removed(tmp_path):
    src = make_source(tmp_path / "src", {"scripts/a.sh": "echo hi\n", "docs/a.md": "RU"}, ["scripts/a.sh", "docs/a.md"])
    out = tmp_path / "out"
    (out / "docs").mkdir(parents=True)
    (out / "docs/a.md").write_text("translated", encoding="utf-8")
    (out / "seed/SPF").mkdir(parents=True)
    (out / "seed/SPF/old.md").write_text("stale", encoding="utf-8")
    (out / "CONTRIBUTING.md").write_text("generated", encoding="utf-8")

    report = ad.assemble(src, out)

    assert (out / "scripts/a.sh").read_text(encoding="utf-8") == "echo hi\n"
    assert (out / "docs/a.md").read_text(encoding="utf-8") == "translated"
    assert not (out / "seed/SPF/old.md").exists()
    assert (out / "CONTRIBUTING.md").exists()
    assert report["removed"] == ["seed/SPF/old.md"]
    assert report["missing_translation"] == [] and report["cyrillic"] == []


def test_missing_translation_and_cyrillic_are_reported(tmp_path):
    src = make_source(tmp_path / "src", {"scripts/a.sh": "# \u043f\u0440\u0438\u0432\u0435\u0442\n", "docs/b.md": "RU"}, ["scripts/a.sh", "docs/b.md"])
    out = tmp_path / "out"
    out.mkdir()

    report = ad.assemble(src, out)

    assert report["missing_translation"] == ["docs/b.md"]
    assert report["cyrillic"] == ["scripts/a.sh"]


def test_check_mode_writes_nothing(tmp_path):
    src = make_source(tmp_path / "src", {"scripts/a.sh": "x"}, ["scripts/a.sh"])
    out = tmp_path / "out"
    out.mkdir()
    ad.assemble(src, out, write=False)
    assert list(out.iterdir()) == []


def test_adapted_files_are_not_copied_from_source(tmp_path):
    src = make_source(
        tmp_path / "src",
        {"params.yaml.example": "ru", ".claude/skills/x/SKILL.md": "ru", "scripts/a.sh": "code"},
        [".claude/skills/x/SKILL.md", "scripts/a.sh"],
    )
    out = tmp_path / "out"
    out.mkdir()
    (out / "params.yaml.example").write_text("en", encoding="utf-8")

    report = ad.assemble(src, out)

    assert (out / "params.yaml.example").read_text(encoding="utf-8") == "en"
    assert report["missing_translation"] == [".claude/skills/x/SKILL.md"]
    assert report["copied"] == ["scripts/a.sh"]
