#!/usr/bin/env python3
"""Normalize Russian phase labels (Ф21 -> F21) in the English draft tree.

The Cyrillic gate over the published EN tree rejects any Cyrillic character.
Phase labels such as "Ф21" are identifiers, not prose: the translator keeps
them as written, and the gate then fails on the single letter Ф (found
2026-10-27: Translate Sync red on main because docs/BRANCH-PROTECTION-EMERGENCY.md
carries "Ф21" in three lines).

The same holds for the dashed phase form "Ф-H" and for changelog result
codes "Ц77-03" / "ЦNN-NN" (rewritten to G, as the English docs spell them;
found 2026-11-17, WP-529 F274: Translate Sync red on main on
docs/LEARNING-PATH.md and docs/RELEASE-PROCESS.md).

Only the letter Ф directly followed by a digit (or by "-" and a Latin letter
or digit) and not preceded by another
Cyrillic letter is rewritten, so ordinary Russian words that happen to
contain Ф are left to the translator and to the gate. A label glued to a
Latin letter or digit ("WP-529Ф21") is still a label and is rewritten. Known
limits: lowercase "ф21" and "Ф 21" (with a space) are not labels in this
repository and stay visible to the gate; a Ф21 inside a code block or URL is
rewritten too (it would fail the gate there anyway).

Usage: normalize_en_phase_labels.py <en-draft dir>
"""

import re
import sys
from pathlib import Path

# "Ф21" and the dashed form "Ф-H" (a lettered phase, e.g. "WP-283 Ф-H").
PHASE_LABEL = re.compile(r"(?<![А-Яа-яЁё])Ф(?=\d|-[A-Za-z0-9])")
# Changelog result codes "Ц77-03" and the format placeholder "ЦNN-NN";
# the English docs already spell them "G77-03" / "GNN-NN" (Goal).
RESULT_CODE = re.compile(r"(?<![А-Яа-яЁё])Ц(?=\d+-\d+|NN-NN)")


def normalize(text: str) -> str:
    return RESULT_CODE.sub("G", PHASE_LABEL.sub("F", text))


def normalize_tree(root: Path) -> list[Path]:
    """Rewrite every *.md under root in place; return the changed files."""
    changed = []
    for path in sorted(root.rglob("*.md")):
        original = path.read_text(encoding="utf-8")
        cleaned = normalize(original)
        if cleaned != original:
            path.write_text(cleaned, encoding="utf-8")
            changed.append(path)
    return changed


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 1
    root = Path(argv[1])
    if not root.is_dir():
        print(f"not a directory: {root}", file=sys.stderr)
        return 1
    for path in normalize_tree(root):
        print(f"normalized phase labels: {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
