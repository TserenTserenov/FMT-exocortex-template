"""WP-620 Ф2 scenario 2 (Д2): an English method card is checked against the
approved-terms table of the pack; forbidden alternatives make the card not ready."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "check-card-terms.py"
spec = importlib.util.spec_from_file_location("check_card_terms", SCRIPT)
cct = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = cct  # dataclasses resolve their module by name
spec.loader.exec_module(cct)

TABLE = """# Card

| Термин (RU) | Term (EN) | Не использовать / альтернативы | Где употребляется | Утвердил |
|-------------|-----------|-------------------------------|-------------------|----------|
| Беспокойство | Worry | Concern, Anxiety — не основные | DP.METHOD.053 | пилот, 2026-11-09 |
| Общая цель (A) | Objective | common goal — только пояснение | X.M.2 | пилот, 2026-11-09 |
| Действие (D, D') | Prerequisite | Prerequisite action — допустимо в пояснении; не голое «action» | X.M.2 | пилот, 2026-11-09 |
| Состояние пилота | Practitioner State | не «Pilot State» в публичных текстах | DP.ROLE.012 | пилот, 2026-11-09 |
| Новый термин | Fresh term | — | X | — |
"""

CARD_HEADER = '---\n{\n  "aliases": ["Concern unpacking"]\n}\n---\n'


def _write(tmp_path: Path, name: str, text: str) -> Path:
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    return path


def test_forbidden_cell_rules():
    assert cct.parse_forbidden("Concern, Anxiety — не основные") == (
        ["Concern", "Anxiety"],
        [],
    )
    assert cct.parse_forbidden("common goal — только пояснение") == ([], [])
    assert cct.parse_forbidden(
        "Prerequisite action — допустимо в пояснении; не голое «action»"
    ) == ([], ["action"])
    assert cct.parse_forbidden("не «Pilot State» в публичных текстах") == (
        ["Pilot State"],
        [],
    )
    assert cct.parse_forbidden("—") == ([], [])


def test_card_with_old_word_is_named_and_the_approved_name_is_suggested(tmp_path):
    rows = cct.parse_tables(TABLE)
    card = CARD_HEADER + "# Title\nA person with a concern.\nThe Pilot State card.\n"

    findings = cct.check_card(card, rows)

    assert [(f.line, f.found, f.use_instead) for f in findings] == [
        (7, "concern", "Worry"),
        (8, "Pilot State", "Practitioner State"),
    ]


def test_fixed_card_is_clean_and_frontmatter_aliases_are_not_checked(tmp_path):
    rows = cct.parse_tables(TABLE)
    card = (
        CARD_HEADER
        + "# Title\nA person with a worry; the common goal (Objective) and the action.\n"
    )

    assert cct.check_card(card, rows) == []


def test_name_without_approver_is_reported(tmp_path):
    rows = cct.parse_tables(TABLE)
    card = CARD_HEADER + "Uses a fresh term here.\n"

    findings = cct.check_card(card, rows)

    assert [(f.kind, f.term_ru) for f in findings] == [("unapproved", "Новый термин")]


def test_cli_exit_codes(tmp_path, capsys):
    table = _write(tmp_path, "pack.md", TABLE)
    bad = _write(tmp_path, "bad.md", CARD_HEADER + "Concern here.\n")
    good = _write(tmp_path, "good.md", CARD_HEADER + "Worry here.\n")

    assert cct.main([str(bad), "--terms", str(table)]) == 1
    assert "утверждено «Worry»" in capsys.readouterr().out
    assert cct.main([str(good), "--terms", str(table)]) == 0
    assert cct.main([str(good), "--terms", str(tmp_path / "missing.md")]) == 2
    no_table = _write(tmp_path, "plain.md", "# no table\n")
    assert cct.main([str(good), "--terms", str(no_table)]) == 2


def test_escaped_pipe_stays_in_its_cell():
    table = (
        "| Термин (RU) | Term (EN) | Не использовать / альтернативы | Где | Утвердил |\n"
        "|---|---|---|---|---|\n"
        "| Пак | Pack \\| P | Packet, Bundle — не основные | X | пилот |\n"
    )
    (row,) = cct.parse_tables(table)

    assert (row.term_en, row.forbidden, row.approved_by) == (
        "Pack | P",
        ("Packet", "Bundle"),
        "пилот",
    )


def test_row_with_empty_english_name_does_not_fail_every_card():
    table = "| Термин (RU) | Term (EN) | Не использовать / альтернативы | Где | Утвердил |\n|---|---|---|---|---|\n| Пусто | — | — | X | — |\n"

    assert cct.check_card("Pack is a Package.\n", cct.parse_tables(table)) == []


def test_table_without_approver_column_is_not_all_unapproved():
    table = "| Термин (RU) | Term (EN) | Не использовать / альтернативы |\n|---|---|---|\n| Беспокойство | Worry | Concern — не основное |\n"

    assert cct.check_card("A worry.\n", cct.parse_tables(table)) == []


def test_plural_of_a_forbidden_word_is_found():
    rows = cct.parse_tables(TABLE)

    findings = cct.check_card("Two concerns here.\n", rows)

    assert [f.found for f in findings] == ["concerns"]
