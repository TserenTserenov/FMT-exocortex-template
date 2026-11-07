"""Tests for scripts/glossary_supplier.py (WP-617 Ф4): daily snapshot refresh and local-glossary rules."""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

import pytest
import yaml

SCRIPTS = Path(__file__).parent.parent
REPO = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))

import glossary_supplier as SUP  # noqa: E402
from glossary_source import load_glossary  # noqa: E402

ALLOWLIST = REPO / "translation" / "glossary-snapshot-allowlist.yaml"
LOCAL_HEADER = "term_ru,term_en,context,notes,tier\n"
STATS = {
    "concepts": 10,
    "hidden_by_closed_sources_count": 1,
    "name_en_publishable_count": 6,
    "name_en_publishable_hidden_count": 0,
}


def concept(code, name_ru, name_en, level="pack", domain="DP"):
    return {
        "code": code,
        "name_ru": name_ru,
        "level": level,
        "domain": domain,
        "status": "active",
        "name_en": name_en,
        "name_en_status_raw": "ok",
        "name_en_publishable": True,
        "name_en_publishable_rules_version": "name-en-publishable/1",
    }


def payload(*rows, stats=STATS):
    canary = concept("GUIDE.33", "жизненное мастерство", "Life mastery", level="guide", domain=None)
    return {"as_of": "2026-11-08T02:00:00Z", "graph_stats": stats, "rows": [canary, *rows]}


BASE_ROWS = (
    concept("DP.M.1", "Метод", "Method"),
    concept("DP.M.2", "Практика", "Practice"),
    concept("ZP.1", "Аксиоматичность", "Axiomaticity", level="zp", domain=None),
)


@pytest.fixture
def root(tmp_path: Path) -> Path:
    """A template-like tree whose snapshot was produced from BASE_ROWS."""
    (tmp_path / "translation").mkdir()
    manifest = {
        "glossary": {
            "snapshot": "translation/glossary-snapshot.csv",
            "local": "translation/glossary-local.csv",
            "tier_by_level": {"zp": 1, "fpf": 1, "pack": 2},
        }
    }
    (tmp_path / "translation-manifest.yaml").write_text(yaml.safe_dump(manifest), encoding="utf-8")
    shutil.copy(ALLOWLIST, tmp_path / "allowlist.yaml")
    snapshot = tmp_path / "translation" / "glossary-snapshot.csv"
    SUP.EXPORTER.export_snapshot(payload(*BASE_ROWS), SUP.EXPORTER.load_allowlist(ALLOWLIST), ALLOWLIST, snapshot)
    (tmp_path / "translation" / "glossary-local.csv").write_text(
        LOCAL_HEADER + 'Пак,Pack,,"note, with comma",1\nНапарник,Peer,,,1\n', encoding="utf-8"
    )
    return tmp_path


def run(root: Path, *rows, stats=STATS) -> SUP.Refresh:
    return SUP.refresh(root, payload(*rows, stats=stats), root / "allowlist.yaml")


def files(root: Path) -> dict[str, bytes]:
    return {p.name: p.read_bytes() for p in (root / "translation").iterdir()}


def snapshot_terms(root: Path) -> dict[str, str]:
    return {r["code"]: r["term_en"] for r in SUP.read_rows(root / "translation" / "glossary-snapshot.csv")}


def test_unchanged_graph_writes_nothing_even_with_a_new_as_of(root):
    before = files(root)
    result = run(root, *BASE_ROWS)
    assert result.changed is False
    assert files(root) == before


def test_renamed_english_name_is_a_change_and_reaches_the_body(root):
    result = run(root, concept("DP.M.1", "Метод", "Way of working"), *BASE_ROWS[1:])
    assert result.changed is True
    assert snapshot_terms(root)["DP.M.1"] == "Way of working"
    assert "## Изменились (1)" in result.body
    assert "Way of working" in result.body
    meta = json.loads((root / "translation" / "glossary-snapshot.meta.json").read_text(encoding="utf-8"))
    assert meta["graph_stats"] == STATS


def test_added_and_removed_concepts_are_listed(root):
    result = run(root, *BASE_ROWS[:2], concept("DP.M.3", "Роль", "Role"))
    assert "## Появились (1)" in result.body and "`DP.M.3`" in result.body
    assert "## Исчезли (1)" in result.body and "`ZP.1`" in result.body


def test_local_row_now_served_by_graph_is_removed_other_lines_kept_byte_for_byte(root):
    local = root / "translation" / "glossary-local.csv"
    local.write_text(local.read_text(encoding="utf-8") + "Роль,Role,,,3\n", encoding="utf-8")
    result = run(root, *BASE_ROWS, concept("DP.M.3", "Роль", "Role"))
    assert result.changed is True
    assert local.read_text(encoding="utf-8") == LOCAL_HEADER + 'Пак,Pack,,"note, with comma",1\nНапарник,Peer,,,1\n'
    assert "## Убрано из ручного словаря (1)" in result.body
    load_glossary(yaml.safe_load((root / "translation-manifest.yaml").read_text(encoding="utf-8")), root)


def test_stricter_local_row_with_same_name_stays(root):
    result = run(root, *BASE_ROWS, concept("DP.M.4", "Пак", "Pack"))
    assert "Пак,Pack" in (root / "translation" / "glossary-local.csv").read_text(encoding="utf-8")
    assert snapshot_terms(root)["DP.M.4"] == "Pack"
    assert "Убрано из ручного словаря" not in result.body


def test_conflicting_english_name_keeps_local_row_and_leaves_concept_out(root):
    result = run(root, *BASE_ROWS, concept("DP.M.5", "Напарник", "Partner"))
    assert result.changed is True
    assert "DP.M.5" not in snapshot_terms(root)
    assert "Напарник,Peer" in (root / "translation" / "glossary-local.csv").read_text(encoding="utf-8")
    meta = json.loads((root / "translation" / "glossary-snapshot.meta.json").read_text(encoding="utf-8"))
    assert meta["conflict_local"] == [
        {"code": "DP.M.5", "term_ru": "Напарник", "term_en_graph": "Partner", "term_en_local": "Peer"}
    ]
    assert meta["excluded"]["conflict-local"] == 1
    assert "## Требует решения" in result.body
    # The rest of the update is not held back: translation still loads.
    load_glossary(yaml.safe_load((root / "translation-manifest.yaml").read_text(encoding="utf-8")), root)


def test_same_conflict_next_day_is_not_a_new_change(root):
    run(root, *BASE_ROWS, concept("DP.M.5", "Напарник", "Partner"))
    assert run(root, *BASE_ROWS, concept("DP.M.5", "Напарник", "Partner")).changed is False


def test_resolved_conflict_brings_the_concept_back(root):
    run(root, *BASE_ROWS, concept("DP.M.5", "Напарник", "Partner"))
    result = run(root, *BASE_ROWS, concept("DP.M.5", "Напарник", "Peer"))
    assert result.changed is True
    assert snapshot_terms(root)["DP.M.5"] == "Peer"
    assert "conflict_local" not in json.loads(
        (root / "translation" / "glossary-snapshot.meta.json").read_text(encoding="utf-8")
    )


def test_failed_filter_writes_nothing(root):
    before = files(root)
    bad = payload(*BASE_ROWS)
    bad["rows"] = bad["rows"][1:]  # no canary on input
    with pytest.raises(SUP.EXPORTER.SnapshotError, match="канарейки"):
        SUP.refresh(root, bad, root / "allowlist.yaml")
    assert files(root) == before


CHANGELOG = "# Changelog\n\n## [Unreleased]\n\n### Changed\n\n- [behavior] Other entry (#1).\n\n## [0.40.0]\n\n### Changed\n\n- old\n"


def test_changelog_entry_goes_first_under_unreleased_changed_and_is_idempotent():
    once = SUP.add_changelog_entry(CHANGELOG, 1500)
    lines = once.splitlines()
    assert lines[lines.index("### Changed") + 2].endswith("(`translation/glossary-snapshot.csv`; WP-617, #1500).")
    assert SUP.add_changelog_entry(once, 1500) == once
    assert once.count("WP-617, #1500") == 1


def test_changelog_creates_changed_subsection_when_missing():
    text = SUP.add_changelog_entry("## [Unreleased]\n\n## [0.40.0]\n", 7)
    assert text.startswith("## [Unreleased]\n\n### Changed\n\n- [optional]")
    assert "WP-617, #7)" in text.split("## [0.40.0]")[0]


def test_changelog_without_unreleased_fails():
    with pytest.raises(SUP.SupplierError):
        SUP.add_changelog_entry("## [0.40.0]\n", 7)


# Findings of the cold review, peer-session 2026-11-07-07.


def test_same_russian_name_in_two_concepts_keeps_the_local_row_while_one_conflicts(root):
    local = root / "translation" / "glossary-local.csv"
    local.write_text(local.read_text(encoding="utf-8") + "Модель,Model,,,3\n", encoding="utf-8")
    result = run(root, *BASE_ROWS, concept("DP.X.1", "Модель", "Model"), concept("DP.X.2", "Модель", "Mold"))
    assert [c["code"] for c in result.conflicts] == ["DP.X.2"]
    assert "Модель,Model" in local.read_text(encoding="utf-8")
    assert "Убрано из ручного словаря" not in result.body
    assert {"DP.X.1", "DP.X.2"}.isdisjoint(snapshot_terms(root))  # the whole name waits for the pilot
    terms = load_glossary(yaml.safe_load((root / "translation-manifest.yaml").read_text(encoding="utf-8")), root)
    assert terms.as_mapping()["Модель"] == "Model"


def test_row_removal_keeps_records_with_line_breaks_inside_quotes():
    text = LOCAL_HEADER + 'Пак,Pack,,"a\nb",3\nРоль,Role,,"x y",3\nМетод,Method,,,3\n'
    assert SUP.without_local_rows(text, ["Роль"]) == LOCAL_HEADER + 'Пак,Pack,,"a\nb",3\nМетод,Method,,,3\n'
    assert SUP.without_local_rows(text, ["Пак"]) == LOCAL_HEADER + 'Роль,Role,,"x y",3\nМетод,Method,,,3\n'


def test_local_row_without_english_is_not_a_conflict():
    included = [{"code": "DP.M.1", "term_ru": "Метод", "term_en": "Method"}]
    assert SUP.local_conflicts(included, [{"term_ru": "Метод", "term_en": ""}, {"term_ru": "Метод"}]) == []


def test_glossary_that_would_not_load_writes_nothing(root):
    before = files(root)
    manifest_path = root / "translation-manifest.yaml"
    manifest = yaml.safe_load(manifest_path.read_text(encoding="utf-8"))
    manifest["glossary"]["tier_by_level"].pop("zp")  # the loader refuses a level without a tier
    manifest_path.write_text(yaml.safe_dump(manifest), encoding="utf-8")
    with pytest.raises(SUP.GlossaryError):
        run(root, concept("DP.M.1", "Метод", "Way of working"), *BASE_ROWS[1:])
    assert files(root) == before


def test_conflict_is_announced_once_per_open_request(root):
    first = run(root, *BASE_ROWS, concept("DP.M.5", "Напарник", "Partner"))
    assert first.announce is True
    open_request_meta = json.loads((root / "translation" / "glossary-snapshot.meta.json").read_text(encoding="utf-8"))
    # Next day: a new term arrives, the conflict is the same one the open request already showed the pilot.
    again = SUP.refresh(
        root, payload(*BASE_ROWS, concept("DP.M.5", "Напарник", "Partner"), concept("DP.M.6", "Роль", "Role")),
        root / "allowlist.yaml", open_request_meta,
    )
    assert again.changed is True and again.announce is False
