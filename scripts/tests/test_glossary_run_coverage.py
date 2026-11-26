"""Run-level public coverage from the same walk that produced the candidate snapshot."""

import hashlib
import json

import pytest
import yaml
from test_glossary_supplier import ALLOWLIST, BASE_ROWS, SUP, concept, payload

pytest_plugins = ("test_glossary_supplier",)


def run_cli(tree, walk, run_id=123, attempt=2):
    walk_path = tree / "walk.json"
    walk_path.write_text(json.dumps(walk), encoding="utf-8")
    report_path = tree / f"coverage-{run_id}-{attempt}.json"
    argv = [
        "--root",
        str(tree),
        "refresh",
        "--input",
        str(walk_path),
        "--allowlist",
        str(ALLOWLIST),
        "--body-out",
        str(tree / "pr.md"),
        "--coverage-out",
        str(report_path),
        "--run-id",
        str(run_id),
        "--run-attempt",
        str(attempt),
    ]
    return SUP.main(argv), report_path


def test_unchanged_run_binds_current_walk_even_for_legacy_published_snapshot(
    root, capsys
):
    # This fixture deliberately uses a legacy translation manifest without expected_public_codes.
    meta_path = root / "translation/glossary-snapshot.meta.json"
    meta = json.loads(meta_path.read_text())
    del meta["input_sha256"]
    meta_path.write_text(json.dumps(meta))
    before = meta_path.read_bytes()
    walk = payload(
        *BASE_ROWS,
        concept(
            "PRIVATE-ONLY",
            "Private Russian name",
            "Private English name",
            level="guide",
        ),
    )
    walk["as_of"] = "2026-11-22T09:32:01.120Z"

    status, output = run_cli(root, walk)
    assert status == 0 and "changed=false" in capsys.readouterr().out
    assert meta_path.read_bytes() == before
    text = output.read_text()
    report = json.loads(text)
    assert set(report) == {
        "schema",
        "run_id",
        "run_attempt",
        "as_of",
        "input_sha256",
        "snapshot_sha256",
        "rows",
    }
    assert (report["schema"], report["run_id"], report["run_attempt"]) == (
        "glossary-run-coverage/1",
        123,
        2,
    )
    assert report["as_of"] == walk["as_of"]
    assert report["input_sha256"] == SUP.EXPORTER.input_digest(walk["rows"])
    assert report["snapshot_sha256"] == meta["output_sha256"]
    assert all(set(r) == {"code", "outcome", "reason"} for r in report["rows"])
    assert {r["code"] for r in report["rows"]} == {r["code"] for r in BASE_ROWS}
    assert not any(
        value in text
        for value in (
            "PRIVATE-ONLY",
            "Private Russian name",
            "Private English name",
            "AR.D.005",
        )
    )

    walk["rows"][-1]["name_ru"] = "another unpublished value"
    status, retry = run_cli(root, walk, attempt=3)
    assert status == 0
    retry_report = json.loads(retry.read_text())
    assert (
        retry_report["run_attempt"] == 3
        and retry_report["input_sha256"] != report["input_sha256"]
    )
    assert retry_report["rows"] == report["rows"]


def test_configured_public_reference_stays_in_report_after_disappearing_from_both_snapshots(
    root,
):
    manifest_path = root / "translation-manifest.yaml"
    manifest = yaml.safe_load(manifest_path.read_text())
    published_manifest = yaml.safe_load(
        (SUP.SCRIPTS.parent / "translation-manifest.yaml").read_text()
    )
    configured = published_manifest["glossary"]["expected_public_codes"]
    assert "ZP.1" in configured and "GUIDE.33" in configured
    manifest["glossary"]["expected_public_codes"] = configured
    manifest_path.write_text(yaml.safe_dump(manifest))
    walk = payload(*[r for r in BASE_ROWS if r["code"] != "ZP.1"])
    for run_id in (123, 124):
        status, output = run_cli(root, walk, run_id=run_id)
        assert status == 0
        rows = json.loads(output.read_text())["rows"]
        assert {
            "code": "ZP.1",
            "outcome": "absent_from_input",
            "reason": "code_not_returned",
        } in rows
        assert {
            "code": "GUIDE.33",
            "outcome": "excluded_by_policy",
            "reason": "level",
        } in rows
        assert not any(r["code"] == "AR.D.005" for r in rows)
        assert "ZP.1" not in (root / "translation/glossary-snapshot.csv").read_text()


def test_changed_run_covers_lost_and_new_candidates_and_consumer_validation(root):
    walk = payload(
        BASE_ROWS[0],
        BASE_ROWS[2],
        concept("DP.NEW", "Бот", "Bot"),
        concept("DP.ASCII", "AIST Bot", "AIST Bot"),
        concept("DP.UNPUBLISHED", "Private", "Private", level="guide"),
    )
    status, output = run_cli(root, walk)
    assert status == 0
    report = json.loads(output.read_text())
    rows = {r["code"]: (r["outcome"], r["reason"]) for r in report["rows"]}
    assert rows["DP.MAP.2"] == ("absent_from_input", "code_not_returned")
    assert rows["DP.NEW"] == ("available", "consumer_match")
    assert rows["DP.ASCII"] == ("failed_validation", "no_cyrillic")
    assert "DP.UNPUBLISHED" not in rows
    snapshot = root / "translation/glossary-snapshot.csv"
    assert (
        report["snapshot_sha256"] == hashlib.sha256(snapshot.read_bytes()).hexdigest()
    )


def test_known_local_conflict_is_reported_even_without_a_saved_walk(root):
    local = root / "translation/glossary-local.csv"
    with local.open("a", encoding="utf-8") as stream:
        stream.write("Метод,Previously approved,,,2\n")
    status, output = run_cli(root, payload(*BASE_ROWS))
    assert status == 0
    assert {
        "code": "DP.MAP.1",
        "outcome": "excluded_by_policy",
        "reason": "conflict_local",
    } in json.loads(output.read_text())["rows"]
    [row] = SUP.coverage_rows(root, ["DP.MAP.1"], None, ALLOWLIST)
    assert (row["result"], row["reason"]) == (
        "исключено политикой",
        "конфликт с ручным словарём",
    )
    assert (row["term_ru"], row["term_en"]) == ("", "")


@pytest.mark.parametrize("bad_field", ["as_of", "canary", "run_id"])
def test_invalid_run_leaves_no_report(root, bad_field):
    walk = payload(*BASE_ROWS)
    if bad_field == "as_of":
        walk["as_of"] = "raw input is not an as_of timestamp"
    if bad_field == "canary":
        walk["rows"] = list(BASE_ROWS)
    status, output = run_cli(root, walk, run_id=0 if bad_field == "run_id" else 123)
    assert status != 0
    assert not output.exists()


def test_public_run_failure_does_not_log_private_input(root, capsys):
    invalid = concept(
        "PRIVATE-ROW-UNPUBLISHED", "Private name", "Private name", level="guide"
    )
    del invalid["name_en_status_raw"]
    status, output = run_cli(root, payload(*BASE_ROWS, invalid))
    streams = capsys.readouterr()
    assert status != 0 and not output.exists()
    assert streams.out == ""
    assert (
        streams.err
        == "glossary-supplier: refresh failed; no run coverage can be published\n"
    )


def test_passport_conflict_is_checked_against_walk_and_local_glossary_before_selecting_codes(
    root,
):
    path = root / "translation/glossary-snapshot.meta.json"
    meta = json.loads(path.read_text())
    meta["conflict_local"] = [
        {
            "code": "DP.MISSING",
            "term_ru": "Отсутствует",
            "term_en_graph": "Missing",
            "term_en_local": "Gone",
        }
    ]
    path.write_text(json.dumps(meta))
    for expected in (["DP.MISSING"], ["DP.MAP.1"]):
        with pytest.raises(SUP.SupplierError, match="do not reproduce the conflict"):
            SUP.coverage_rows(root, expected, payload(*BASE_ROWS), ALLOWLIST)
