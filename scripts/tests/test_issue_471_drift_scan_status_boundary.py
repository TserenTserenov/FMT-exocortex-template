"""Regression coverage for issue #471."""

from __future__ import annotations

import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MEMORY_DRIFT_SCAN = ROOT / ".claude" / "scripts" / "memory-drift-scan.py"


def load_memory_drift_scan():
    spec = importlib.util.spec_from_file_location("memory_drift_scan", MEMORY_DRIFT_SCAN)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_status_word_in_explanation_does_not_outrank_leading_marker(tmp_path: Path):
    memory = tmp_path / "MEMORY.md"
    governance = tmp_path / "DS-strategy"
    card = governance / "inbox" / "WP-27" / "WP-27.md"
    card.parent.mkdir(parents=True)
    card.write_text("---\nstatus: in_progress\n---\n", encoding="utf-8")
    # The real cell from issue #471: "закрыт" describes the week-instance of
    # the slot, not the slot's own (still in_progress) state.
    memory.write_text(
        "| # | Работа | Статус |\n|---|---|---|\n"
        "| 27 | Слот | 🔄 слот живёт дальше, инстанс W33 закрыт 11.08 |\n",
        encoding="utf-8",
    )

    module = load_memory_drift_scan()
    assert module.scan(memory, governance) == []


def test_status_word_before_explanation_separator_still_wins(tmp_path: Path):
    module = load_memory_drift_scan()
    # Same class as the existing "⏸ ЗАБЛОКИРОВАН — ждёт решения" case: a
    # declarative status word before the separator must still outrank the
    # leading marker (⏳ alone would say "pending", not "blocked").
    assert module.normalize_status("⏳ ЗАБЛОКИРОВАН: ждёт вердикта") == "blocked"
