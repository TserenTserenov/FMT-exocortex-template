"""Обход concept_list: страницы, контрольные коды, сверка полноты, повтор обхода."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "fetch-glossary-concepts.py"


def load():
    spec = importlib.util.spec_from_file_location("fetch_glossary_concepts", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MOD = load()
VERSION = "name-en-publishable/1"


def concept(id_, code, name_en, publishable, **extra):
    return {
        "id": id_,
        "code": code,
        "name": f"Понятие {id_}",
        "level": "pack",
        "domain": "DP",
        "status": "active",
        "name_en": name_en,
        "name_en_status_raw": "ok",
        "name_en_publishable": publishable,
        "name_en_publishable_rules_version": VERSION,
        **extra,
    }


def control_rows():
    return [
        concept(1, "ZP.1", "Axiomaticity", True),
        concept(2, "U.Entity", "Entity", True),
        concept(3, "ECO.FM.001", "ECO.FM.001", True),
        concept(4, "MIM.M.024", None, False),
    ]


def stats_for(rows, **override):
    stats = {
        "concepts": len(rows) + 2,
        "hidden_by_closed_sources_count": 2,
        "name_en_publishable_count": sum(r["name_en_publishable"] for r in rows) + 1,
        "name_en_publishable_hidden_count": 1,
    }
    stats.update(override)
    return stats


class FakeGateway:
    """Шлюз в памяти: отдаёт страницы по after_id и счётчики graph_stats."""

    def __init__(self, rows, stats_sequence):
        self.rows = rows
        self.stats_sequence = list(stats_sequence)
        self.list_calls = 0

    def __call__(self, payload):
        name = payload["params"]["name"]
        args = payload["params"]["arguments"]
        if name == "graph_stats":
            body = self.stats_sequence.pop(0) if len(self.stats_sequence) > 1 else self.stats_sequence[0]
        else:
            self.list_calls += 1
            limit = args["limit"]
            rest = [r for r in self.rows if r["id"] > args["after_id"]]
            page = rest[:limit]
            body = {
                "as_of": "2026-11-01T20:00:00.000Z",
                "rows": page,
                "next_after_id": page[-1]["id"] if len(rest) > limit else None,
            }
        return {"result": {"content": [{"text": json.dumps(body)}]}}


def test_payload_walks_all_pages_and_renames_name_to_name_ru(monkeypatch):
    monkeypatch.setattr(MOD, "PAGE_LIMIT", 2)
    rows = control_rows() + [concept(5, "DP.M.1", "Method", True)]
    gateway = FakeGateway(rows, [stats_for(rows)])
    result = MOD.fetch_payload(gateway)
    assert gateway.list_calls == 3
    assert [r["code"] for r in result["rows"]] == ["ZP.1", "U.Entity", "ECO.FM.001", "MIM.M.024", "DP.M.1"]
    assert result["rows"][0]["name_ru"] == "Понятие 1"
    assert all("name" not in r for r in result["rows"])
    assert result["as_of"] == "2026-11-01T20:00:00.000Z"


def test_missing_row_gives_incomplete_snapshot_after_all_attempts():
    rows = control_rows()
    gateway = FakeGateway(rows, [stats_for(rows, concepts=len(rows) + 3)])
    with pytest.raises(MOD.FetchError, match="неполный"):
        MOD.fetch_payload(gateway)
    assert gateway.list_calls == MOD.MAX_ATTEMPTS


def test_walk_is_repeated_when_graph_changed_between_attempts(monkeypatch):
    rows = control_rows()
    good = stats_for(rows)
    bad = stats_for(rows, concepts=good["concepts"] + 1)
    # попытка 1: до обхода счётчик устарел; попытка 2: до и после совпадают
    gateway = FakeGateway(rows, [bad, bad, good, good])
    result = MOD.fetch_payload(gateway)
    assert len(result["rows"]) == len(rows)
    assert gateway.list_calls == 2


def test_changed_control_row_stops_without_payload():
    rows = control_rows()
    rows[0] = concept(1, "ZP.1", "Axiom", True)
    with pytest.raises(MOD.FetchError, match="ZP.1"):
        MOD.fetch_payload(FakeGateway(rows, [stats_for(rows)]))


def test_control_visible_in_graph_but_absent_in_etalon_stops():
    rows = control_rows() + [concept(9, "ECO.PRIN.001", "Principle", True)]
    with pytest.raises(MOD.FetchError, match="ECO.PRIN.001"):
        MOD.fetch_payload(FakeGateway(rows, [stats_for(rows)]))


def test_unexpected_rules_version_stops():
    rows = control_rows()
    rows[1] = concept(2, "U.Entity", "Entity", True, name_en_publishable_rules_version="name-en-publishable/2")
    with pytest.raises(MOD.FetchError, match="версии правил"):
        MOD.fetch_payload(FakeGateway(rows, [stats_for(rows)]))


def test_gateway_error_is_reported_with_tool_name():
    def failing(payload):
        return {"error": {"message": "concept_list requires a platform service credential"}}

    with pytest.raises(MOD.FetchError, match="graph_stats: concept_list requires"):
        MOD.fetch_payload(failing)


def test_cli_without_secret_writes_nothing(tmp_path: Path, monkeypatch, capsys):
    monkeypatch.delenv(MOD.SECRET_ENV, raising=False)
    out = tmp_path / "payload.json"
    assert MOD.main(["--output", str(out)]) == 2
    assert not out.exists()
    assert MOD.SECRET_ENV in capsys.readouterr().err
