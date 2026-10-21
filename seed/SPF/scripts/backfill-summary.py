#!/usr/bin/env python3
"""
Backfill `summary` field into YAML frontmatter of Pack entity files.

Usage:
    python backfill-summary.py <json-file>

JSON format:
    { "/absolute/path/to/file.md": "Summary text here", ... }

Inserts `summary:` after `status:` line in frontmatter.
If no `status:` line, inserts before closing `---`.
Skips files that already have `summary:` in frontmatter.
"""

import sys
import json
import re
from pathlib import Path


def add_summary(filepath: str, summary: str) -> str:
    """Add summary to frontmatter. Returns status message."""
    path = Path(filepath)
    if not path.exists():
        return f"SKIP (not found): {filepath}"

    content = path.read_text(encoding="utf-8")

    # Check if already has summary in frontmatter
    fm_match = re.match(r"^---\s*\n(.*?)\n---", content, re.DOTALL)
    if not fm_match:
        return f"SKIP (no frontmatter): {filepath}"

    fm_text = fm_match.group(1)
    if "summary:" in fm_text:
        return f"SKIP (already has summary): {filepath}"

    summary_line = f'summary: "{summary}"'

    # Try to insert after status: line
    new_content = re.sub(
        r"^(---\s*\n(?:.*\n)*?)(status:\s*[^\n]+\n)",
        rf"\1\2{summary_line}\n",
        content,
        count=1,
        flags=re.MULTILINE,
    )

    if new_content == content:
        # No status: line found — insert before closing ---
        new_content = re.sub(
            r"\n---",
            f"\n{summary_line}\n---",
            content,
            count=1,
        )

    if new_content == content:
        return f"FAIL (could not insert): {filepath}"

    path.write_text(new_content, encoding="utf-8")
    return f"OK: {filepath}"


def main():
    if len(sys.argv) < 2:
        print("Usage: python backfill-summary.py <json-file>")
        sys.exit(1)

    data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))

    ok = 0
    skip = 0
    fail = 0
    for filepath, summary in data.items():
        result = add_summary(filepath, summary)
        print(result)
        if result.startswith("OK"):
            ok += 1
        elif result.startswith("SKIP"):
            skip += 1
        else:
            fail += 1

    print(f"\nDone: {ok} updated, {skip} skipped, {fail} failed")


if __name__ == "__main__":
    main()
