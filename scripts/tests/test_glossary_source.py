"""Tests for scripts/glossary_source.py (WP-617 Ф3): graph snapshot + local queue."""

from __future__ import annotations

import ast
import sys
from pathlib import Path

import pytest
import yaml

SCRIPTS = Path(__file__).parent.parent
REPO = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))

from glossary_source import GlossaryError, load_glossary  # noqa: E402

SNAPSHOT_HEADER = "code,term_ru,term_en,level,domain,name_en_status_raw,rules_version\n"
LOCAL_HEADER = "term_ru,term_en,context,notes,tier\n"
TIERS = {"zp": 1, "fpf": 1, "pack": 2}


def _load(tmp_path: Path, snapshot_rows: list[str], local_rows: list[str], tiers=TIERS):
    (tmp_path / "snap.csv").write_text(SNAPSHOT_HEADER + "".join(snapshot_rows), encoding="utf-8")
    (tmp_path / "local.csv").write_text(LOCAL_HEADER + "".join(local_rows), encoding="utf-8")
    manifest = {"glossary": {"snapshot": "snap.csv", "local": "local.csv", "tier_by_level": tiers}}
    return load_glossary(manifest, tmp_path)


def _by_ru(glossary):
    return {t.term_ru: t for t in glossary.terms}


def test_graph_and_local_terms_are_merged_with_tiers(tmp_path):
    g = _load(
        tmp_path,
        ["ZP.1,Аксиоматичность,Axiomaticity,zp,ZP,ok,r/1\n", "DP.X.1,Практика,Practice,pack,DP,ok,r/1\n"],
        ["Пак,Pack,,,1\n", "Скилл,Skill,,,\n"],
    )
    terms = _by_ru(g)
    assert (terms["Аксиоматичность"].term_en, terms["Аксиоматичность"].tier) == ("Axiomaticity", 1)
    assert (terms["Практика"].term_en, terms["Практика"].tier) == ("Practice", 2)
    assert (terms["Пак"].term_en, terms["Пак"].tier) == ("Pack", 1)
    assert terms["Скилл"].tier == 3  # blank local tier keeps the old delivery_checks default
    assert g.as_mapping()["Практика"] == "Practice"


def test_snapshot_rows_without_cyrillic_are_skipped_and_counted(tmp_path):
    g = _load(tmp_path, ["DP.A.1,AIST Bot,AIST Bot,pack,DP,ok,r/1\n", "DP.A.2,Бот,Bot,pack,DP,ok,r/1\n"], [])
    assert list(_by_ru(g)) == ["Бот"]
    assert g.notes == ["snapshot: 1 rows skipped, term_ru has no Cyrillic (graph data defect)"]


def test_duplicate_names_collapse_when_english_agrees(tmp_path):
    g = _load(
        tmp_path,
        ["DP.M.1,Карта,Map,pack,DP,ok,r/1\n", "ZP.M.1,карта ,Map,zp,ZP,ok,r/1\n"],
        [],
    )
    assert len(g.terms) == 1
    assert g.terms[0].tier == 1  # the strictest level among the duplicates wins


def test_duplicate_names_with_conflicting_english_are_dropped(tmp_path):
    g = _load(tmp_path, ["DP.M.1,Карта,Map,pack,DP,ok,r/1\n", "ECO.M.1,Карта,Chart,pack,ECO,ok,r/1\n"], [])
    assert g.terms == []
    assert "conflicting English names" in g.notes[0]


def test_local_row_cannot_revive_a_term_the_graph_dropped_as_conflicting(tmp_path):
    with pytest.raises(GlossaryError, match="conflicting English names"):
        _load(
            tmp_path,
            ["DP.M.1,Карта,Map,pack,DP,ok,r/1\n", "ECO.M.1,Карта,Chart,pack,ECO,ok,r/1\n"],
            ["Карта,Map,,,1\n"],
        )


def test_unknown_level_fails_closed(tmp_path):
    with pytest.raises(GlossaryError, match="level 'guide'"):
        _load(tmp_path, ["GUIDE.1,Шаг,Step,guide,GUIDE,ok,r/1\n"], [])


def test_local_row_duplicating_graph_term_is_an_error(tmp_path):
    with pytest.raises(GlossaryError, match="remove it from the local glossary"):
        _load(tmp_path, ["DP.X.1,Практика,Practice,pack,DP,ok,r/1\n"], ["Практика,Practice,,,2\n"])


def test_local_row_may_only_raise_the_tier_of_a_graph_term(tmp_path):
    g = _load(tmp_path, ["DP.X.1,Практика,Practice,pack,DP,ok,r/1\n"], ["практика,Practice,,,1\n"])
    term = _by_ru(g)["Практика"]
    assert (term.term_en, term.tier) == ("Practice", 1)
    assert g.notes == ["tier map gap: «Практика» kept at tier 1 by the local glossary"]


def test_local_row_with_different_english_is_an_error(tmp_path):
    with pytest.raises(GlossaryError, match="differs from graph"):
        _load(tmp_path, ["DP.X.1,Практика,Practice,pack,DP,ok,r/1\n"], ["Практика,Practise,,,1\n"])


def test_duplicate_local_row_is_an_error(tmp_path):
    with pytest.raises(GlossaryError, match="twice"):
        _load(tmp_path, [], ["Пак,Pack,,,1\n", "пак,Pack,,,1\n"])


def test_missing_manifest_block_and_missing_file_fail(tmp_path):
    with pytest.raises(GlossaryError, match="required"):
        load_glossary({}, tmp_path)
    manifest = {"glossary": {"snapshot": "nope.csv", "local": "nope2.csv", "tier_by_level": TIERS}}
    with pytest.raises(GlossaryError, match="not found"):
        load_glossary(manifest, tmp_path)


def test_template_glossary_loads_and_keeps_strict_local_terms():
    manifest = yaml.safe_load((REPO / "translation-manifest.yaml").read_text(encoding="utf-8"))
    terms = _by_ru(load_glossary(manifest, REPO))
    assert terms["Пак"].tier == 1  # tier-1 local terms survive the switch to the snapshot
    assert terms["Практика"].term_en == "Practice"  # removed from local, now served by the graph


# Contract for the live graph lookup (decision D', WP-617 Ф4): never in publication.

LIVE_LOOKUP_MARKERS = ("GLOSSARY_LIVE_LOOKUP", "knowledge-mcp")


def test_publication_job_never_reaches_the_graph():
    workflow = yaml.safe_load((REPO / ".github/workflows/translate-sync.yml").read_text(encoding="utf-8"))
    publish_job = yaml.safe_dump(workflow["jobs"]["publish-to-iwesys"], allow_unicode=True)
    for marker in LIVE_LOOKUP_MARKERS:
        assert marker not in publish_job


def test_translation_engine_reads_terms_from_files_only():
    for name in ("translate.py", "glossary_source.py", "delivery_checks.py"):
        assert not any(m in (SCRIPTS / name).read_text(encoding="utf-8") for m in LIVE_LOOKUP_MARKERS), name
    tree = ast.parse((SCRIPTS / "glossary_source.py").read_text(encoding="utf-8"))
    imported = {
        alias.name.split(".")[0]
        for node in ast.walk(tree)
        if isinstance(node, (ast.Import, ast.ImportFrom))
        for alias in (node.names if isinstance(node, ast.Import) else [ast.alias(node.module or "")])
    }
    assert not imported & {"urllib", "http", "socket", "requests", "httpx"}
