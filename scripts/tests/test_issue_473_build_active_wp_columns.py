"""Regression coverage for issue #473 (build-active-wp.py half)."""

from __future__ import annotations

import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "build-active-wp.py"


def load_module():
    spec = importlib.util.spec_from_file_location("build_active_wp", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The real registry that triggered this issue: 8 columns, different order and
# names than the schema the parser used to hardcode ("Ст"/"Репо"/"Бюджет" at
# fixed positions 3/4/5).
REORDERED_REGISTRY = """\
| # | Название | Статус | Цель | Создан | P | Репо | Бюджет |
|---|---|---|---|---|---|---|---|
| 47 | Тест Б | ✅ | цель | 01.01 | P1 | repo/ | 4h |
| 49 | Тест В | ⏳ | открыт как спин-офф WP-47 | 02.01 | P2 | repo2/ | 3h |
"""

# A second, independently real registry (this repo's own): 7 columns, an
# extra "Ставка" inserted between Репо and Бюджет — the schema is not just
# reordered, it varies in column count too.
EXTRA_COLUMN_REGISTRY = """\
| # | P | Название | Ст | Репо | Ставка | Бюджет |
|---|---|---|---|---|---|---|
| 541 | P2 | Тест А | ⏳ | governance-repo/inbox/WP-541/ | Оснащённость | 2h |
"""


def test_reordered_schema_reads_correct_columns():
    module = load_module()
    rows, problems = module.parse_registry(REORDERED_REGISTRY)
    assert problems == []
    assert rows[0]["name"] == "Тест Б"
    assert rows[0]["status"] == "✅"
    assert rows[0]["budget"] == "4h"
    # WP-49's own status must not be contaminated by "WP-47" appearing in its
    # own explanation text (a different failure mode than the substring bug
    # in wp-sync-bundle.sh, but the same "read your own cell" invariant).
    assert rows[1]["status"] == "⏳"


def test_extra_column_schema_keeps_budget():
    module = load_module()
    rows, problems = module.parse_registry(EXTRA_COLUMN_REGISTRY)
    assert problems == []
    assert rows[0]["budget"] == "2h", "Бюджет must survive a 7-column registry, not just the hardcoded 6"
    out = module.render(rows)
    assert "2h" in out, "issue #473: parts[:7] truncation used to drop the trailing Бюджет cell"


def test_new_statuses_recognized():
    module = load_module()
    text = (
        "| # | Название | Статус | Репо | Бюджет |\n"
        "|---|---|---|---|---|\n"
        "| 26 | Снят | ⏹ | repo/ | 1h |\n"
        "| 25 | Спринт | 🔁 | repo/ | 1h |\n"
    )
    rows, problems = module.parse_registry(text)
    assert problems == [], f"⏹/🔁 must be known statuses, not PARSE-WARN: {problems}"
    assert rows[0]["status"] == "⏹" and rows[0]["status"] in module.CLOSED_STATUSES
    assert rows[1]["status"] == "🔁" and rows[1]["status"] in module.CLOSED_STATUSES


def test_missing_header_fails_loudly_not_silently():
    module = load_module()
    text = "| 47 | Тест | ✅ | repo/ | 4h |\n"  # no "| # | ..." header row at all
    try:
        module.parse_registry(text)
        assert False, "missing header must raise, not silently guess column positions"
    except ValueError as exc:
        assert "status" in str(exc) or "name" in str(exc)


def test_header_lookalike_without_separator_is_not_mistaken_for_real_header():
    # Codex code review (turn 3, this same session): find_header_columns()
    # takes the FIRST "| # | ... |"-shaped line — a legend/details block
    # could in principle contain one before the real table header. A real
    # markdown table header is always followed by a "|---|---|" separator;
    # anything else is not accepted as the header.
    module = load_module()
    text = (
        "> см. легенду ниже\n"
        "| # | Что-то не то | Тут нет разделителя следующей строкой |\n"
        "не разделитель, обычный текст\n"
        "\n"
        "| # | Название | Статус | Репо | Бюджет |\n"
        "|---|---|---|---|---|\n"
        "| 47 | Тест | ✅ | repo/ | 4h |\n"
    )
    rows, problems = module.parse_registry(text)
    assert problems == []
    assert rows[0]["name"] == "Тест"
    assert rows[0]["status"] == "✅"
