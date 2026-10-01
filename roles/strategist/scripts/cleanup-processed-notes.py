#!/usr/bin/env python3
"""
Deterministic cleanup of processed notes from fleeting-notes.md.

Template owner's decision (July 2026): Note-Review classifies and proposes, it
never decides on the pilot's behalf. The prompt (note-review.md step 4)
therefore no longer strips bold after classification — processed notes get
"**Title** ✅предложено" instead, staying bold and visible every day until
the pilot removes them himself. This script still exists as a safety net
for any note that reaches this file without bold at all (an older format, or
a model that dropped the bold) — it must never silently sweep up a note the
pilot hasn't explicitly closed, so a note that carries the ✅предложено mark
is kept even when its bold is gone.

This script runs AFTER note-review and deterministically:
1. Parses fleeting-notes.md into header + note blocks
2. Archives non-bold, non-🔄, non-✅предложено blocks to Notes-Archive.md
3. Removes them from fleeting-notes.md
4. Stages changes for git commit

Keep rules (they look at the FIRST line of a note block, its title):
  - **bold** title        → note not yet closed by pilot (new or ✅предложено), KEEP
  - 🔄 in title           → needs review, KEEP
  - ✅предложено in title → proposal written, the decision is the pilot's, KEEP
                            (any mix of case, a space after ✅ allowed, anywhere in
                            the line, with or without bold). The same rule is
                            applied by the canary in strategist.sh and by the Day
                            Open scanner; a first line that is a quote, a heading,
                            a timestamp, a list item or a note the pilot struck
                            through (~~) is no note title and carries no mark
  - everything else       → already stripped of bold by something else, ARCHIVE
"""

import os
import re
import sys
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Optional

GOVERNANCE_REPO = os.environ.get('IWE_GOVERNANCE_REPO', 'DS-strategy')
# WP-530 Ф72: an isolated run points the script at its throwaway copy of the governance repo.
_REPO_DIR_OVERRIDE = os.environ.get('IWE_CLEANUP_REPO_DIR')
_CANON_DIR = Path.home() / "IWE" / GOVERNANCE_REPO
# IWE_CLEANUP_ISOLATED=1 (set by strategist.sh in an isolated run) forbids the silent fallback to
# the canonical checkout: the directory must be given and must be a linked git worktree, not the canon.
_ISOLATED = os.environ.get('IWE_CLEANUP_ISOLATED') == '1'
if _ISOLATED:
    _repo = Path(_REPO_DIR_OVERRIDE) if _REPO_DIR_OVERRIDE else None
    _problem = None
    if _repo is None:
        _problem = "IWE_CLEANUP_REPO_DIR is not set"
    elif not _repo.is_dir():
        _problem = f"{_repo} is not a directory"
    elif not (_repo / ".git").is_file():
        _problem = f"{_repo} is not a linked git worktree (.git is not a file)"
    elif _repo.resolve() == _CANON_DIR.resolve():
        _problem = f"{_repo} is the canonical checkout"
    if _problem:
        print(f"ERROR: isolated cleanup refused: {_problem}", file=sys.stderr)
        sys.exit(2)
WORKSPACE = Path(_REPO_DIR_OVERRIDE) if _REPO_DIR_OVERRIDE else _CANON_DIR
FLEETING = WORKSPACE / "inbox" / "fleeting-notes.md"
ARCHIVE = WORKSPACE / "archive" / "notes" / "Notes-Archive.md"

# The mark Note-Review puts on a proposed note. A model does not copy it letter for letter:
# "✅ предложено", "✅Предложено" and "✅пРедложено" occur, the bold may be dropped and a tail may follow (#961).
PROPOSED_MARK_RE = re.compile(r"✅\s*предложено", re.IGNORECASE)
# A first line that is not the title of a note: a quote, a heading, a timestamp, a note the pilot struck through,
# a bulleted or numbered list item. The mark on such a line says nothing about a note (day-open-scaffold.sh and the
# canary in strategist.sh draw the same line).
NOT_A_TITLE_RE = re.compile(r"^(?:[>#<]|~~|[-+*]\s|\d+[.)]\s)")


def parse_notes(content: str) -> tuple[str, list[str]]:
    """Split fleeting-notes.md into header and note blocks.

    Header = everything up to and including the first `---` after the
    blockquote section. Note blocks are separated by `---`.

    YAML frontmatter exists only when `---` is the very first line of the
    file; its closing `---` is then skipped and the header ends at the next
    one. Without frontmatter the header ends at the first `---`. A file with
    no header-closing `---` has no note blocks (the whole file is header), so
    nothing is archived and the file is never emptied (#959).
    """
    lines = content.split("\n")

    # Find end of header: the header-closing `---`; frontmatter fences are not it
    has_frontmatter = lines[0].strip() == "---"
    rules_to_skip = 2 if has_frontmatter else 0
    header_end = None

    for i, line in enumerate(lines):
        if line.strip() != "---":
            continue
        if rules_to_skip:
            rules_to_skip -= 1
            continue
        header_end = i + 1
        break

    if header_end is None:
        return content, []

    header = "\n".join(lines[:header_end])
    rest = "\n".join(lines[header_end:]).strip()

    if not rest:
        return header, []

    # Split remaining content by --- separator
    raw_blocks = re.split(r"\n---\n", rest)
    blocks = [b.strip() for b in raw_blocks if b.strip()]

    return header, blocks


def extract_note_date(block: str) -> Optional[datetime]:
    """Extract date from <sub>DD мес, HH:MM</sub> line in a note block."""
    MONTHS_RU = {
        "янв": 1, "фев": 2, "мар": 3, "апр": 4, "май": 5, "мая": 5,
        "июн": 6, "июл": 7, "авг": 8, "сен": 9, "окт": 10, "ноя": 11, "дек": 12,
    }
    match = re.search(r"<sub>(\d{1,2})\s+(\w{3}),?\s*(\d{1,2}):(\d{2})</sub>", block)
    if not match:
        return None
    day, month_str, hour, minute = match.groups()
    month = MONTHS_RU.get(month_str.lower())
    if not month:
        return None
    year = date.today().year
    try:
        return datetime(year, month, int(day), int(hour), int(minute))
    except ValueError:
        return None


def should_keep(block: str) -> bool:
    """Return True if note should stay in fleeting-notes.md."""
    first_line = block.split("\n")[0].strip()
    # Bold title = new note
    if first_line.startswith("**"):
        return True
    # 🔄 marker = needs review
    if "🔄" in first_line:
        return True
    # ✅предложено = a proposal is written and the decision is the pilot's, even if the bold is gone;
    # a line that is no note title (a quote, a struck-through note, a list item...) is not a marked note
    if PROPOSED_MARK_RE.search(first_line) and not NOT_A_TITLE_RE.match(first_line):
        return True
    # Protection: don't archive notes younger than 24h.
    # Catch-up note-review may strip bold without real processing (bug 21 Mar 2026).
    note_dt = extract_note_date(block)
    if note_dt and (datetime.now() - note_dt) < timedelta(hours=24):
        return True
    return False


def format_archive_entry(block: str, today: str) -> str:
    """Format a note block for Notes-Archive.md."""
    return f"{block}\n**Категория:** auto-cleanup\n"


def main():
    if not FLEETING.exists():
        print("fleeting-notes.md not found, nothing to do")
        return 0

    content = FLEETING.read_text(encoding="utf-8")
    header, blocks = parse_notes(content)

    if not blocks:
        print("No note blocks found, nothing to clean")
        return 0

    keep = []
    archive = []

    for block in blocks:
        if should_keep(block):
            keep.append(block)
        else:
            archive.append(block)

    if not archive:
        print("No processed notes to archive")
        return 0

    today = date.today().isoformat()

    # Append to archive
    archive_content = ARCHIVE.read_text(encoding="utf-8") if ARCHIVE.exists() else ""
    archive_section = f"\n## {today} — Auto-cleanup\n\n"
    for block in archive:
        archive_section += f"{block}\n**Категория:** auto-cleanup\n\n---\n\n"

    # Append at end of archive file
    if archive_content and not archive_content.endswith("\n"):
        archive_content += "\n"
    archive_content += archive_section.rstrip() + "\n"
    # Installations assembled before archive/notes/ existed do not have the directory (#959)
    ARCHIVE.parent.mkdir(parents=True, exist_ok=True)
    ARCHIVE.write_text(archive_content, encoding="utf-8")

    # Rewrite fleeting-notes.md with only kept blocks
    if keep:
        kept_section = "\n\n" + "\n\n---\n\n".join(keep) + "\n\n---\n"
    else:
        kept_section = "\n"

    FLEETING.write_text(header + kept_section, encoding="utf-8")

    print(f"Cleaned: {len(archive)} archived, {len(keep)} kept")
    return len(archive)


if __name__ == "__main__":
    archived = main()
    sys.exit(0)
