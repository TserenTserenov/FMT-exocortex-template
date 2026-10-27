"""Tests for normalize_en_phase_labels: Ф21 -> F21 before the Cyrillic gate.

Regression 2026-10-27: Translate Sync was red on main because the English
draft of docs/BRANCH-PROTECTION-EMERGENCY.md kept "Ф21" (three lines) and the
gate rejects the Cyrillic letter Ф.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))
import normalize_en_phase_labels as nl  # noqa: E402

CYRILLIC = re.compile("[А-Яа-яЁё]")


def test_phase_label_with_digits_becomes_latin_f():
    assert nl.normalize("WP-529 Ф21 is open") == "WP-529 F21 is open"


def test_range_and_punctuation_forms():
    assert nl.normalize("(Ф21), Ф21–Ф23, «Ф7»") == "(F21), F21–F23, «F7»"


def test_letter_f_without_digit_is_left_alone():
    # Ordinary words must stay visible to the gate instead of being mangled.
    assert nl.normalize("Фаза и ФР") == "Фаза и ФР"


def test_letter_inside_a_word_is_left_alone():
    assert nl.normalize("аФ21") == "аФ21"


def test_label_glued_to_latin_letter_or_digit_is_rewritten():
    assert nl.normalize("WP-529Ф21 and 9Ф21") == "WP-529F21 and 9F21"


def test_lowercase_and_spaced_forms_stay_visible_to_the_gate():
    # Documented limit: these are not labels in this repository.
    assert nl.normalize("ф21 and Ф 21") == "ф21 and Ф 21"


def test_already_latin_label_is_unchanged():
    assert nl.normalize("F21 and Ф") == "F21 and Ф"


def test_tree_rewrite_changes_only_files_with_labels(tmp_path):
    (tmp_path / "docs").mkdir()
    dirty = tmp_path / "docs" / "a.md"
    clean = tmp_path / "b.md"
    dirty.write_text("> WP-529 Ф21. Write this on a calm day.\n", encoding="utf-8")
    clean.write_text("No labels here.\n", encoding="utf-8")

    changed = nl.normalize_tree(tmp_path)

    assert changed == [dirty]
    assert dirty.read_text(encoding="utf-8") == "> WP-529 F21. Write this on a calm day.\n"
    assert clean.read_text(encoding="utf-8") == "No labels here.\n"
    assert not CYRILLIC.search(dirty.read_text(encoding="utf-8"))


def test_main_rejects_missing_directory(tmp_path, capsys):
    assert nl.main(["x", str(tmp_path / "missing")]) == 1
    assert "not a directory" in capsys.readouterr().err
