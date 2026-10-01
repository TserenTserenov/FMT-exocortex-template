"""Regression for issue #954: wp-list.py keyed cards and registry rows by the number "as written".

create-wp.sh names the card folder zero-padded (inbox/WP-009/WP-009.md) while the registry
cell is whatever the registry's author typed ("9", "009", "WP-009", struck through). The
card key "009" never equalled the registry key "9", so a struck row left registry_done=false
and the same WP written in two spellings was listed twice. The key must be the integer; the
file name keeps its own digits.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
WP_LIST = ROOT / "scripts" / "wp-list.py"
GOV = "DS-strategy"


def card(path: Path, wp: str, status: str = "in_progress") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"---\nwp: {wp}\nstatus: {status}\n---\n# card\n", encoding="utf-8")


def registry(root: Path, *first_cells: str) -> None:
    docs = root / GOV / "docs"
    docs.mkdir(parents=True, exist_ok=True)
    rows = "\n".join(f"| {cell} | P2 | Demo | x | repo | 1h |" for cell in first_cells)
    (docs / "WP-REGISTRY.md").write_text(
        "| # | P | Название | Ст | Репо | Бюджет |\n|---|---|---|---|---|---|\n" + rows + "\n",
        encoding="utf-8",
    )


def list_cards(root: Path, tmp_path: Path, source: str = "inbox") -> list[dict]:
    env = {**os.environ, "HOME": str(tmp_path / "home")}
    result = subprocess.run(
        [sys.executable, str(WP_LIST), "--list-cards", "--source", source,
         "--fields", "wp,status,status_raw,registry_done,card",
         "--format", "json", "--governance-repo", GOV, "--iwe-root", str(root)],
        capture_output=True, text=True, check=False, env=env,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return json.loads(result.stdout)


@pytest.mark.parametrize(
    "cell",
    ["~~9~~", "~~009~~", "~~WP-9~~", "~~WP-009~~", "~~wp-009~~", "~~WP-009~~ ", "~~**WP-009**~~"],
)
def test_struck_row_marks_a_padded_card_done_in_any_spelling(tmp_path: Path, cell: str):
    card(tmp_path / GOV / "inbox" / "WP-009" / "WP-009.md", "9")
    registry(tmp_path, cell)

    (row,) = list_cards(tmp_path, tmp_path)

    assert row["registry_done"] == "true", row
    assert row["status"] == "done"           # the registry wins over the stale frontmatter
    assert row["status_raw"] == "in_progress"


@pytest.mark.parametrize("cell", ["~~9~~", "~~009~~", "~~WP-009~~"])
def test_struck_row_marks_a_legacy_unpadded_card_done(tmp_path: Path, cell: str):
    card(tmp_path / GOV / "inbox" / "WP-9" / "WP-9.md", "9")
    registry(tmp_path, cell)

    (row,) = list_cards(tmp_path, tmp_path)

    assert row["registry_done"] == "true", row


def test_a_row_that_is_not_struck_stays_open(tmp_path: Path):
    card(tmp_path / GOV / "inbox" / "WP-009" / "WP-009.md", "9")
    registry(tmp_path, "WP-009")

    (row,) = list_cards(tmp_path, tmp_path)

    assert row["registry_done"] == "false"
    assert row["status"] == "in_progress"


def test_neighbouring_numbers_do_not_leak(tmp_path: Path):
    card(tmp_path / GOV / "inbox" / "WP-044" / "WP-044.md", "44")
    registry(tmp_path, "~~440~~", "~~0440~~", "~~4~~", "~~WP-144~~")

    (row,) = list_cards(tmp_path, tmp_path)

    assert row["registry_done"] == "false", row


def test_the_card_path_keeps_the_folder_own_digits(tmp_path: Path):
    padded = tmp_path / GOV / "inbox" / "WP-009" / "WP-009.md"
    card(padded, "9")
    registry(tmp_path, "9")

    (row,) = list_cards(tmp_path, tmp_path)

    assert row["card"] == str(padded)
    assert row["wp"] == "009"                # the output spelling is unchanged for consumers


def test_two_spellings_of_one_wp_are_one_row_and_the_padded_folder_wins(tmp_path: Path):
    padded = tmp_path / GOV / "inbox" / "WP-009" / "WP-009.md"
    legacy = tmp_path / GOV / "inbox" / "WP-9" / "WP-9.md"
    card(padded, "9")
    card(legacy, "9")
    card(tmp_path / GOV / "inbox" / "WP-9-flat-slug.md", "9")
    registry(tmp_path, "9")

    rows = list_cards(tmp_path, tmp_path)

    assert len(rows) == 1, rows
    assert rows[0]["card"] == str(padded)


def test_a_folder_card_wins_over_a_flat_file_of_the_other_spelling(tmp_path: Path):
    folder = tmp_path / GOV / "inbox" / "WP-9" / "WP-9.md"
    card(folder, "9")
    card(tmp_path / GOV / "inbox" / "WP-009-flat.md", "9")
    registry(tmp_path, "9")

    rows = list_cards(tmp_path, tmp_path)

    assert [r["card"] for r in rows] == [str(folder)]


def test_inbox_and_archive_spellings_collide_into_one_row_archive_wins(tmp_path: Path):
    card(tmp_path / GOV / "inbox" / "WP-009" / "WP-009.md", "9")
    archived = tmp_path / GOV / "archive" / "wp-contexts" / "WP-9" / "WP-9.md"
    card(archived, "9", status="done")
    registry(tmp_path, "9")

    rows = list_cards(tmp_path, tmp_path, source="all")

    assert len(rows) == 1, rows
    assert rows[0]["card"] == str(archived)


def test_rows_are_sorted_by_the_number_not_the_spelling(tmp_path: Path):
    card(tmp_path / GOV / "inbox" / "WP-010" / "WP-010.md", "10")
    card(tmp_path / GOV / "inbox" / "WP-9" / "WP-9.md", "9")
    card(tmp_path / GOV / "inbox" / "WP-100" / "WP-100.md", "100")
    registry(tmp_path, "9")

    rows = list_cards(tmp_path, tmp_path)

    assert [r["wp"] for r in rows] == ["9", "010", "100"]
