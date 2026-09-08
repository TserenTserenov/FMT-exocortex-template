"""Regression coverage for issue #531 status-cell classification."""

from __future__ import annotations

import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".claude" / "scripts" / "check-index-health.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("check_index_health", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _findings(
    tmp_path: Path,
    row: str,
    *,
    header: str = "| # | Название | Статус | Цель |",
    skip: bool = False,
) -> list[tuple[int, str]]:
    registry = tmp_path / "WP-REGISTRY.md"
    prefix = "<!-- index-health: skip -->\n" if skip else ""
    registry.write_text(
        prefix
        + header
        + "\n"
        + "|---|---|---|---|\n"
        + row
        + "\n",
        encoding="utf-8",
    )
    return _load_module().check_file(registry)["done_no_strike"]


def test_checkmarks_inside_active_phase_description_are_not_done(tmp_path: Path):
    row = "| 27 | Методика | 🔄 радар (Ф1 ✅ 9 мая; Ф2 ✅; Ф3 ✅) | O1 |"
    assert _findings(tmp_path, row) == []


def test_unstruck_done_status_is_reported(tmp_path: Path):
    assert _findings(tmp_path, "| 53 | Карточки | ✅ закрыт | O3 |") == [(3, "53")]


def test_bold_done_status_in_a_reordered_column_is_reported(tmp_path: Path):
    row = "| 54 | Карточки | O3 | **✅** закрыт |"
    header = "| # | Название | Цель | Ст |"
    assert _findings(tmp_path, row, header=header) == [(3, "54")]


def test_earlier_risk_emoji_does_not_override_later_done_status(tmp_path: Path):
    row = "| 541 | 🟢 низкий риск | **✅** закрыт | O3 |"
    assert _findings(tmp_path, row) == [(3, "541")]


def test_struck_done_wp_is_not_reported(tmp_path: Path):
    assert _findings(tmp_path, "| ~~55~~ | Карточки | ✅ закрыт | O3 |") == []


def test_struck_status_cell_still_requires_struck_wp_number(tmp_path: Path):
    row = "| 551 | Карточки | ~~✅ закрыт~~ | O3 |"
    assert _findings(tmp_path, row) == [(3, "551")]


def test_semantic_done_check_survives_index_health_skip(tmp_path: Path):
    finding = _findings(tmp_path, "| 56 | Карточки | ✅ закрыт | O3 |", skip=True)
    assert finding == [(4, "56")]
