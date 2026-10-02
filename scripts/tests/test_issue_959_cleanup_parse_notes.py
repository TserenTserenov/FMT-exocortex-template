"""
Regression test for issue #959: cleanup-processed-notes.py must not swallow the
first notes of a fleeting-notes.md that has no frontmatter, and must not crash
when archive/notes/ does not exist yet.

Defect (roles/strategist/scripts/cleanup-processed-notes.py):
  1. parse_notes() treated the first `---` of the file as the start of YAML
     frontmatter and the second one as its end. A box without frontmatter
     ("# Fleeting Notes", a blockquote, then `---` between notes) therefore
     lost its first two notes into the header: should_keep() never saw them,
     so processed notes in those two positions were never archived.
  2. A box without any `---` was not treated as a header at all: the whole
     file (title included) became one note block, got archived and the file
     was emptied.
  3. ARCHIVE.write_text() raised FileNotFoundError when archive/notes/ was
     missing (installations assembled before the directory existed).

The pure splitter is exercised through importlib (the file name contains a
hyphen); the end-to-end cases run the real script as a subprocess against a
throwaway governance repo directory (IWE_CLEANUP_REPO_DIR) and a temporary HOME.
"""

import importlib.util
import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "roles" / "strategist" / "scripts" / "cleanup-processed-notes.py"

# The timestamp format below is the one the issue reproduces with; it does not
# match extract_note_date(), so the "younger than 24h" guard never applies and
# the result depends only on the keep/archive rules and not on today's date.
HEADER_NO_FRONTMATTER = "# Fleeting Notes\n\n> описание\n\n---\n"
HEADER_WITH_FRONTMATTER = "---\ntitle: Fleeting\n---\n\n# Fleeting Notes\n\n> описание\n\n---\n"

NOTE_A = "Заметка A (нежирная, старше 24ч)\n<sub>10.09.2026, 15:32</sub>"
NOTE_B = "Заметка B (нежирная, старше 24ч)\n<sub>10.09.2026, 15:36</sub>"
NOTE_C = "Заметка C (нежирная, старше 24ч)\n<sub>10.09.2026, 18:30</sub>"
NOTE_BOLD = "**Новая жирная заметка**\n<sub>30.09.2026, 09:00</sub>"


def _box(header: str, *notes: str) -> str:
    """Assemble a fleeting-notes.md: header, then every note followed by a rule."""
    return header + "".join(f"\n{note}\n\n---\n" for note in notes)


def _load_module(monkeypatch, tmp_path):
    """Import the hyphen-named script with a harmless environment."""
    monkeypatch.delenv("IWE_CLEANUP_ISOLATED", raising=False)
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("IWE_CLEANUP_REPO_DIR", str(tmp_path / "ws"))
    spec = importlib.util.spec_from_file_location("cleanup_processed_notes_under_test", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def cleanup_module(monkeypatch, tmp_path):
    return _load_module(monkeypatch, tmp_path)


def _workspace(tmp_path: Path, fleeting: str, archive_dir: bool = True) -> Path:
    ws = tmp_path / "ws"
    (ws / "inbox").mkdir(parents=True)
    (ws / "inbox" / "fleeting-notes.md").write_text(fleeting, encoding="utf-8")
    if archive_dir:
        (ws / "archive" / "notes").mkdir(parents=True)
    return ws


def _run_cleanup(tmp_path: Path) -> subprocess.CompletedProcess:
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(tmp_path / "home"),
        "IWE_CLEANUP_REPO_DIR": str(tmp_path / "ws"),
    }
    return subprocess.run(
        [sys.executable, str(SCRIPT)], capture_output=True, text=True, env=env, check=False
    )


def _archive_text(ws: Path) -> str:
    archive = ws / "archive" / "notes" / "Notes-Archive.md"
    return archive.read_text(encoding="utf-8") if archive.exists() else ""


def _fleeting_text(ws: Path) -> str:
    return (ws / "inbox" / "fleeting-notes.md").read_text(encoding="utf-8")


# --- parse_notes: the pure splitter -----------------------------------------------------


def test_no_frontmatter_header_ends_at_first_rule(cleanup_module):
    header, blocks = cleanup_module.parse_notes(_box(HEADER_NO_FRONTMATTER, NOTE_A, NOTE_B, NOTE_C))

    assert header == "# Fleeting Notes\n\n> описание\n\n---"
    assert len(blocks) == 3
    assert [b.split("\n")[0] for b in blocks] == [
        "Заметка A (нежирная, старше 24ч)",
        "Заметка B (нежирная, старше 24ч)",
        "Заметка C (нежирная, старше 24ч)",
    ]


def test_frontmatter_box_keeps_working_as_before(cleanup_module):
    header, blocks = cleanup_module.parse_notes(_box(HEADER_WITH_FRONTMATTER, NOTE_A, NOTE_BOLD))

    assert header == HEADER_WITH_FRONTMATTER.rstrip("\n")
    assert len(blocks) == 2
    assert blocks[0].startswith("Заметка A")
    assert blocks[1].startswith("**Новая жирная заметка**")


def test_box_without_any_rule_is_all_header(cleanup_module):
    content = "# Fleeting Notes\n\n> описание\n\nСырая заметка без разделителя\n"

    header, blocks = cleanup_module.parse_notes(content)

    assert header == content
    assert blocks == []


def test_frontmatter_without_header_rule_is_all_header(cleanup_module):
    content = "---\ntitle: Fleeting\n---\n\n# Fleeting Notes\n\n> описание\n"

    header, blocks = cleanup_module.parse_notes(content)

    assert header == content
    assert blocks == []


# --- main(): the real script, end to end ------------------------------------------------


def test_all_old_notes_are_archived_without_frontmatter(tmp_path):
    ws = _workspace(tmp_path, _box(HEADER_NO_FRONTMATTER, NOTE_A, NOTE_B, NOTE_C))

    result = _run_cleanup(tmp_path)

    assert result.returncode == 0, result.stderr
    assert "Cleaned: 3 archived, 0 kept" in result.stdout
    archive = _archive_text(ws)
    for title in ("Заметка A", "Заметка B", "Заметка C"):
        assert title in archive
    fleeting = _fleeting_text(ws)
    assert "# Fleeting Notes" in fleeting and "> описание" in fleeting
    for title in ("Заметка A", "Заметка B", "Заметка C"):
        assert title not in fleeting


def test_live_case_eight_notes_seven_processed(tmp_path):
    # The case from the issue: 8 notes, 7 of them processed. The old splitter saw 6 blocks
    # and would have archived 5, leaving the two oldest in the box for good.
    processed = [f"Обработанная заметка {n}\n<sub>1{n}.09.2026, 10:00</sub>" for n in range(1, 8)]
    ws = _workspace(tmp_path, _box(HEADER_NO_FRONTMATTER, *processed, NOTE_BOLD))

    result = _run_cleanup(tmp_path)

    assert result.returncode == 0, result.stderr
    assert "Cleaned: 7 archived, 1 kept" in result.stdout
    archive = _archive_text(ws)
    fleeting = _fleeting_text(ws)
    for n in range(1, 8):
        assert f"Обработанная заметка {n}" in archive
        assert f"Обработанная заметка {n}" not in fleeting
    assert "**Новая жирная заметка**" in fleeting
    assert "**Новая жирная заметка**" not in archive


def test_frontmatter_box_archives_plain_and_keeps_bold(tmp_path):
    ws = _workspace(tmp_path, _box(HEADER_WITH_FRONTMATTER, NOTE_BOLD, NOTE_A))

    result = _run_cleanup(tmp_path)

    assert result.returncode == 0, result.stderr
    assert "Cleaned: 1 archived, 1 kept" in result.stdout
    fleeting = _fleeting_text(ws)
    assert fleeting.startswith("---\ntitle: Fleeting\n---")
    assert "**Новая жирная заметка**" in fleeting
    assert "Заметка A" not in fleeting
    assert "Заметка A" in _archive_text(ws)


def test_box_without_any_rule_is_left_untouched(tmp_path):
    content = "# Fleeting Notes\n\n> описание\n\nСырая заметка без разделителя\n"
    ws = _workspace(tmp_path, content)

    result = _run_cleanup(tmp_path)

    assert result.returncode == 0, result.stderr
    assert "nothing to clean" in result.stdout
    assert _fleeting_text(ws) == content
    assert _archive_text(ws) == ""


@pytest.mark.parametrize(
    "header", [HEADER_WITH_FRONTMATTER, HEADER_NO_FRONTMATTER], ids=["with-frontmatter", "no-frontmatter"]
)
def test_missing_archive_directory_is_created(tmp_path, header):
    # With frontmatter the old splitter was already correct, so this case isolates the
    # missing mkdir; the frontmatter-less variant covers both defects together.
    ws = _workspace(tmp_path, _box(header, NOTE_A, NOTE_BOLD), archive_dir=False)
    assert not (ws / "archive").exists()

    result = _run_cleanup(tmp_path)

    assert result.returncode == 0, result.stderr
    assert "Traceback" not in result.stderr
    assert "Заметка A" in _archive_text(ws)
    assert "Заметка A" not in _fleeting_text(ws)
    assert "**Новая жирная заметка**" in _fleeting_text(ws)
