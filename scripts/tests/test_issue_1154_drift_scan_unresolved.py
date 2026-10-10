"""issue #1154: memory-drift-scan.py skipped a WP whose context card it could not find
and still printed «0 расхождений». A zero-padded card (inbox/WP-038/WP-038.md) was
never found, and nothing told the pilot that the WP had not been checked.

Run: python3 -I scripts/tests/test_issue_1154_drift_scan_unresolved.py
"""
import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".claude" / "scripts" / "memory-drift-scan.py"
spec = importlib.util.spec_from_file_location("memory_drift_scan", SCRIPT)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

MEMORY = """# Memory

| # | РП | Статус |
|---|----|--------|
| 38 | Padded card | in_progress |
| 7 | Plain card | in_progress |
| 99 | No card at all | in_progress |
"""


def card(status: str) -> str:
    return f"---\nstatus: {status}\n---\n# card\n"


def build(base: Path) -> tuple[Path, Path]:
    memory = base / "MEMORY.md"
    memory.write_text(MEMORY, encoding="utf-8")
    gov = base / "gov"
    (gov / "inbox" / "WP-038").mkdir(parents=True)
    (gov / "inbox" / "WP-038" / "WP-038.md").write_text(card("done"), encoding="utf-8")
    (gov / "inbox" / "WP-7").mkdir(parents=True)
    (gov / "inbox" / "WP-7" / "WP-7.md").write_text(card("in_progress"), encoding="utf-8")
    return memory, gov


def test_zero_padded_card_is_found_and_drift_reported():
    with tempfile.TemporaryDirectory() as tmp:
        memory, gov = build(Path(tmp))
        unresolved: list[int] = []
        drifts = mod.scan(memory, gov, unresolved)
        assert len(drifts) == 1 and "РП-38" in drifts[0], drifts
        assert "done" in drifts[0], drifts


def test_missing_card_is_reported_not_silently_skipped():
    with tempfile.TemporaryDirectory() as tmp:
        memory, gov = build(Path(tmp))
        unresolved: list[int] = []
        mod.scan(memory, gov, unresolved)
        assert unresolved == [99], unresolved


def test_shorter_number_does_not_match_longer_one():
    with tempfile.TemporaryDirectory() as tmp:
        gov = Path(tmp) / "gov"
        (gov / "inbox" / "WP-17").mkdir(parents=True)
        (gov / "inbox" / "WP-17" / "WP-17.md").write_text(card("done"), encoding="utf-8")
        assert mod.find_wp_context(gov, 7) is None


def test_cli_prints_explicit_unresolved_line():
    with tempfile.TemporaryDirectory() as tmp:
        memory, gov = build(Path(tmp))
        out = subprocess.run(
            [sys.executable, str(SCRIPT), "--memory", str(memory), "--governance-repo", str(gov)],
            capture_output=True, text=True, check=False,
        ).stdout
        assert "не удалось проверить 1 из 3 РП" in out, out
        assert "РП-99" in out, out


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print(f"  ✅ {name}")
