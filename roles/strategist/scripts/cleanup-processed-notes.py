#!/usr/bin/env python3
"""
Deterministic cleanup of processed notes from fleeting-notes.md.

Safety net for Note-Review Step 10: LLM often copies notes to archive
but forgets to delete from source (tool-use hallucination).

This script runs AFTER note-review and deterministically:
1. Parses fleeting-notes.md into header + note blocks
2. Archives non-bold, non-🔄 blocks to Notes-Archive.md
3. Removes them from fleeting-notes.md
4. Stages changes for git commit

Keep rules:
  - **bold** title  → new note, KEEP
  - 🔄 in title    → needs review, KEEP
  - everything else → processed, ARCHIVE
"""

import re
import sys
from datetime import date
from pathlib import Path

WORKSPACE = Path.home() / "Github" / "DS-strategy"
FLEETING = WORKSPACE / "inbox" / "fleeting-notes.md"
ARCHIVE = WORKSPACE / "archive" / "notes" / "Notes-Archive.md"


def parse_notes(content: str) -> tuple[str, list[str]]:
    """Split fleeting-notes.md into header and note blocks.

    Header = everything up to and including the first `---` after the
    blockquote section. Note blocks are separated by `---`.
    """
    lines = content.split("\n")

    # Find end of header: skip frontmatter, title, blockquote, then first ---
    in_frontmatter = False
    past_frontmatter = False
    header_end = 0

    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped == "---" and not past_frontmatter:
            if not in_frontmatter:
                in_frontmatter = True
            else:
                past_frontmatter = True
            continue
        if past_frontmatter and stripped == "---":
            header_end = i + 1
            break

    header = "\n".join(lines[:header_end])
    rest = "\n".join(lines[header_end:]).strip()

    if not rest:
        return header, []

    # Split remaining content by --- separator
    raw_blocks = re.split(r"\n---\n", rest)
    blocks = [b.strip() for b in raw_blocks if b.strip()]

    return header, blocks


def should_keep(block: str) -> bool:
    """Return True if note should stay in fleeting-notes.md."""
    first_line = block.split("\n")[0].strip()
    # Bold title = new note
    if first_line.startswith("**"):
        return True
    # 🔄 marker = needs review
    if "🔄" in first_line:
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
