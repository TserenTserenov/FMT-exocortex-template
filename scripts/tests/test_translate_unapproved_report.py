"""WP-620 Ф4: an unapproved English name never appears in a translation silently.

Two sources of unapproved names are reported per file:
* a local-glossary candidate whose Russian form occurs in the source;
* a name the model chose for a system term outside the glossary (declared by
  the model in an <unlisted_terms> block).
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest
import yaml

SCRIPTS = Path(__file__).parent.parent
sys.path.insert(0, str(SCRIPTS))
import translate
from glossary_source import load_glossary

SNAPSHOT_HEADER = "code,term_ru,term_en,level,domain,name_en_status_raw,rules_version\n"
LOCAL_HEADER = "term_ru,term_en,context,notes,tier\n"


def test_glossary_marks_only_local_candidates_as_unapproved(tmp_path):
    (tmp_path / "snap.csv").write_text(
        SNAPSHOT_HEADER + "DP.TERM.1,Беспокойство,Worry,pack,DP,ok,r/1\n",
        encoding="utf-8",
    )
    (tmp_path / "local.csv").write_text(
        LOCAL_HEADER + "Ближайшее действие,Nearest action,,,2\n", encoding="utf-8"
    )
    manifest = {
        "glossary": {
            "snapshot": "snap.csv",
            "local": "local.csv",
            "tier_by_level": {"pack": 2},
        }
    }

    g = load_glossary(manifest, tmp_path)

    assert g.unapproved_mapping() == {"Ближайшее действие": "Nearest action"}
    assert g.as_mapping()["Беспокойство"] == "Worry"


def test_unlisted_terms_are_parsed_and_kept_out_of_the_document():
    response = (
        "<body>\nThe DEP table lists worries.\n</body>\n"
        "<unlisted_terms>\n- Таблица НЭП → DEP table\nordinary line\nWorry → Worry\n</unlisted_terms>"
    )

    pairs = translate.parse_unlisted_terms(response)
    _, body = translate._parse_translation_response(
        response, fm_values={}, translate_keys=[]
    )

    assert pairs == [
        ("Таблица НЭП", "DEP table")
    ]  # non-Russian left side is not a term
    assert "unlisted_terms" not in body
    assert body == "The DEP table lists worries.\n"


def test_unlisted_block_is_stripped_even_without_body_markers():
    response = (
        "Plain translated text.\n<unlisted_terms>\nСила → Strength\n</unlisted_terms>"
    )

    _, body = translate._parse_translation_response(
        response, fm_values={}, translate_keys=[]
    )

    assert body.strip() == "Plain translated text."


def test_report_names_local_candidates_and_model_choices_but_not_glossary_terms():
    source = "Запишите ближайшее действие. Беспокойство и сила.\n`ближайшее действие в коде`\n"
    items = translate.unapproved_report_items(
        "docs/a.md",
        source,
        glossary={"Беспокойство": "Worry", "Ближайшее действие": "Nearest action"},
        unapproved={"Ближайшее действие": "Nearest action"},
        unlisted=[
            ("Беспокойство", "Worry"),
            ("Сила", "Strength"),
            ("сила", "Strength"),
        ],
    )

    assert items == [
        {
            "file": "docs/a.md",
            "term_ru": "Ближайшее действие",
            "term_en": "Nearest action",
            "source": "local-glossary",
        },
        {
            "file": "docs/a.md",
            "term_ru": "Сила",
            "term_en": "Strength",
            "source": "model",
        },
    ]


def test_local_candidate_only_in_code_is_not_reported():
    items = translate.unapproved_report_items(
        "a.md",
        "Текст.\n`Ближайшее действие`\n",
        glossary={},
        unapproved={"Ближайшее действие": "Nearest action"},
        unlisted=[],
    )
    assert items == []


def test_system_prompt_asks_for_unlisted_terms(tmp_path):
    style = tmp_path / "style.md"
    style.write_text("Plain English.\n", encoding="utf-8")

    prompt = translate._build_system_prompt(
        style, glossary={}, manifest={"exclusions": {}}
    )

    assert "<unlisted_terms>" in prompt


def _git(cwd: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True
    ).stdout.strip()


@pytest.fixture
def repo(tmp_path):
    root = tmp_path / "src"
    root.mkdir()
    _git(root, "init", "-q")
    _git(root, "config", "user.email", "t@example.com")
    _git(root, "config", "user.name", "t")
    (root / "README.md").write_text("Ближайшее действие и сила.\n", encoding="utf-8")
    _git(root, "add", "README.md")
    _git(root, "commit", "-qm", "init")
    return root


def test_delta_writes_the_report_into_the_state_file(monkeypatch, repo, tmp_path):
    def fake_translate_file(_file_path, *_args, unlisted=None, **_kwargs):
        unlisted.append(("Сила", "Strength"))
        return ("Nearest action and strength.\n", [])

    monkeypatch.setattr(translate, "translate_file", fake_translate_file)
    monkeypatch.setattr(translate, "_find_repo_root", lambda _cwd: repo)
    monkeypatch.setattr(translate, "_make_client", lambda: None)
    monkeypatch.delenv("GITHUB_STEP_SUMMARY", raising=False)

    out = tmp_path / "en-out"
    args = translate.argparse.Namespace(
        output_dir=str(out),
        state_file=None,
        style=str(tmp_path / "none.md"),
        model="stub",
        files=[],
    )
    rc = translate.run_delta(
        args,
        {"categories": {"D": {"files": ["README.md"]}}},
        glossary={"Ближайшее действие": "Nearest action"},
        unapproved={"Ближайшее действие": "Nearest action"},
    )

    assert rc == 0
    state = yaml.safe_load(
        (out / ".translation-state.yaml").read_text(encoding="utf-8")
    )
    assert {(t["term_ru"], t["source"]) for t in state["unapproved_terms"]} == {
        ("Ближайшее действие", "local-glossary"),
        ("Сила", "model"),
    }


def test_report_goes_to_the_github_job_summary(monkeypatch, tmp_path):
    summary = tmp_path / "summary.md"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))

    translate.print_unapproved_report(
        [{"file": "a.md", "term_ru": "Сила", "term_en": "Strength", "source": "model"}]
    )

    text = summary.read_text(encoding="utf-8")
    assert "| Сила | Strength | model | a.md |" in text


def test_unclosed_or_self_closed_block_never_reaches_the_document():
    cut = "<body>\nHello.\n<unlisted_terms>\nПак → Pack\n</body>"
    no_markers = "Hello.\n<unlisted_terms>\nПак → Pack"
    empty = "Hello.\n<unlisted_terms/>"

    assert translate._parse_translation_response(cut, {}, [])[1] == "Hello.\n"
    assert (
        translate._parse_translation_response(no_markers, {}, [])[1].strip() == "Hello."
    )
    assert translate._parse_translation_response(empty, {}, [])[1].strip() == "Hello."
    assert translate.parse_unlisted_terms(no_markers) == [("Пак", "Pack")]


def test_quoted_pairs_are_unwrapped_before_the_glossary_check():
    response = "<unlisted_terms>\n`Пак → Pack`\n«Сила» → “Strength”\n</unlisted_terms>"

    assert translate.parse_unlisted_terms(response) == [
        ("Пак", "Pack"),
        ("Сила", "Strength"),
    ]


def test_local_candidate_only_in_untranslated_frontmatter_is_not_reported(tmp_path):
    src = tmp_path / "a.md"
    src.write_text(
        "---\naliases: Ближайшее действие\ntitle: Заголовок\n---\nТекст.\n",
        encoding="utf-8",
    )

    text = translate._translatable_text(src, ["title"])

    assert (
        translate.local_terms_used(text, {"Ближайшее действие": "Nearest action"}) == []
    )
    assert "Заголовок" in text
