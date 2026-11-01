"""Выгрузка публичного снимка терминов: белый список, канарейка, схема, валидатор."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "export-glossary-snapshot.py"
ALLOWLIST = ROOT / "translation" / "glossary-snapshot-allowlist.yaml"


def load():
    spec = importlib.util.spec_from_file_location("export_glossary_snapshot", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MOD = load()


def row(**overrides):
    base = {
        "code": "DP.METHOD.049",
        "name_ru": "Метод",
        "level": "pack",
        "domain": "DP",
        "status": "active",
        "name_en": "Method",
        "name_en_status_raw": "ok",
        "name_en_publishable": True,
        "name_en_publishable_rules_version": "1",
    }
    base.update(overrides)
    return base


def canary_row():
    return row(code="VR.FM.002", name_ru="Ложная уверенность", name_en="False Confidence", domain="VR")


def payload(*rows, as_of="2026-10-31T00:00:00Z"):
    return {"as_of": as_of, "rows": list(rows)}


def test_public_row_is_included_and_closed_levels_are_not(tmp_path: Path):
    allowlist = MOD.load_allowlist(ALLOWLIST)
    included, excluded, as_of = MOD.build_rows(
        payload(
            row(),
            canary_row(),
            row(code="ZP.1", name_ru="Знание", name_en="Knowledge", level="zp", domain=None),
            row(code="U.Method", name_ru="Метод", name_en="Method", level="fpf", domain=None),
            row(code="GUIDE.1", name_ru="Черновик", name_en="Draft", level="guide", domain="DP"),
            row(code="DP.HIDDEN.1", name_en="Hidden", name_en_status_raw="pending", name_en_publishable=False),
            row(code="LS.GENRE.1", name_ru="Пост", name_en="Post", domain="LS"),
            row(code="XX.SECRET.1", name_ru="Секрет", name_en="Secret", domain="XX"),
        ),
        allowlist,
    )
    assert as_of == "2026-10-31T00:00:00Z"
    assert [item["code"] for item in included] == ["DP.METHOD.049", "LS.GENRE.1", "U.Method", "ZP.1"]
    assert excluded["level"] == 1
    assert excluded["not-publishable"] == 1
    assert excluded["domain"] == 2
    assert "VR.FM.002" not in [item["code"] for item in included]
    out = tmp_path / "glossary-snapshot.csv"
    meta = MOD.export_snapshot(payload(row(), canary_row()), allowlist, ALLOWLIST, out)
    assert meta["schema"] == "glossary-snapshot/1"
    assert meta["rules_version"] == "1"
    assert out.exists()
    assert out.with_suffix(".meta.json").exists()
    text = out.read_text(encoding="utf-8")
    assert "Method" in text
    assert "VR.FM.002" not in text


def _run_cli(source: Path, allowlist: Path, out: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--input",
            str(source),
            "--allowlist",
            str(allowlist),
            "--output",
            str(out),
        ],
        capture_output=True,
        text=True,
    )


def test_canary_missing_from_input_writes_nothing(tmp_path: Path):
    allowlist = MOD.load_allowlist(ALLOWLIST)
    source = tmp_path / "in.json"
    source.write_text(json.dumps(payload(row())), encoding="utf-8")
    out = tmp_path / "glossary-snapshot.csv"
    result = _run_cli(source, ALLOWLIST, out)
    assert result.returncode == 2
    assert "нет на входе" in result.stderr
    assert not out.exists()
    assert not out.with_suffix(".meta.json").exists()
    with pytest.raises(MOD.SnapshotError, match="нет на входе"):
        MOD.build_rows(json.loads(source.read_text(encoding="utf-8")), allowlist)


def test_canary_that_reaches_snapshot_writes_nothing(tmp_path: Path):
    allowlist = MOD.load_allowlist(ALLOWLIST)
    leaked = dict(allowlist)
    leaked["pack_domains"] = list(allowlist["pack_domains"]) + ["VR"]
    body = payload(row(), canary_row())
    with pytest.raises(MOD.SnapshotError, match="попала в снимок"):
        MOD.build_rows(body, leaked)
    allowlist_path = tmp_path / "allowlist.yaml"
    text = ALLOWLIST.read_text(encoding="utf-8").replace("  - PD\n", "  - PD\n  - VR\n")
    allowlist_path.write_text(text, encoding="utf-8")
    source = tmp_path / "in.json"
    source.write_text(json.dumps(body), encoding="utf-8")
    out = tmp_path / "glossary-snapshot.csv"
    result = _run_cli(source, allowlist_path, out)
    assert result.returncode == 2
    assert "попала в снимок" in result.stderr
    assert not out.exists()
    assert not out.with_suffix(".meta.json").exists()


def test_publishable_flag_must_match_ok_status():
    allowlist = MOD.load_allowlist(ALLOWLIST)
    with pytest.raises(MOD.SnapshotError, match="publishable-contradiction"):
        MOD.build_rows(
            payload(row(name_en_status_raw="pending", name_en_publishable=True), canary_row()),
            allowlist,
        )


def test_english_name_equal_to_code_is_dropped_and_snapshot_is_written(tmp_path: Path):
    allowlist = MOD.load_allowlist(ALLOWLIST)
    body = payload(
        row(),
        row(code="ECO.FM.001", name_ru="Ошибка", name_en="ECO.FM.001", domain="ECO"),
        canary_row(),
    )
    included, excluded, _ = MOD.build_rows(body, allowlist)
    assert [item["code"] for item in included] == ["DP.METHOD.049"]
    assert excluded["equals-code"] == 1
    source = tmp_path / "in.json"
    source.write_text(json.dumps(body), encoding="utf-8")
    out = tmp_path / "glossary-snapshot.csv"
    result = _run_cli(source, ALLOWLIST, out)
    assert result.returncode == 0, result.stderr
    text = out.read_text(encoding="utf-8")
    assert "Method" in text
    assert "ECO.FM.001" not in text
    assert out.with_suffix(".meta.json").exists()


def test_english_name_that_looks_like_a_code_is_dropped():
    allowlist = MOD.load_allowlist(ALLOWLIST)
    included, excluded, _ = MOD.build_rows(
        payload(
            row(code="U.Entity", name_ru="Сущность", name_en="Entity", level="fpf", domain=None),
            row(code="DP.SC.045", name_ru="Анализ", name_en="TOC"),
            row(code="DP.METHOD.050", name_ru="Другой", name_en="LS.BC.001"),
            canary_row(),
        ),
        allowlist,
    )
    assert [item["code"] for item in included] == ["DP.SC.045", "U.Entity"]
    assert excluded["looks-like-code"] == 1


def test_cyrillic_english_name_aborts():
    allowlist = MOD.load_allowlist(ALLOWLIST)
    with pytest.raises(MOD.SnapshotError, match="cyrillic"):
        MOD.build_rows(payload(row(name_en="Метод"), canary_row()), allowlist)


def test_two_rules_versions_abort():
    allowlist = MOD.load_allowlist(ALLOWLIST)
    with pytest.raises(MOD.SnapshotError, match="несколько версий"):
        MOD.build_rows(
            payload(
                row(),
                canary_row(),
                row(code="DP.METHOD.050", name_ru="Другой", name_en="Other", name_en_publishable_rules_version="2"),
            ),
            allowlist,
        )


def test_conflicting_names_abort():
    allowlist = MOD.load_allowlist(ALLOWLIST)
    with pytest.raises(MOD.SnapshotError, match="противоречивые"):
        MOD.build_rows(
            payload(row(name_en="Method"), row(name_en="Procedure"), canary_row()),
            allowlist,
        )


def test_identical_duplicate_is_kept_once():
    allowlist = MOD.load_allowlist(ALLOWLIST)
    included, _, _ = MOD.build_rows(payload(row(), row(), canary_row()), allowlist)
    assert len(included) == 1
