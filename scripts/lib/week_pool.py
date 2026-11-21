"""The one reader of the WeekPlan pool table (the week's list of WPs with hours).

WHY (template release 0.43, ported from the author's lib/week_pool.py): the
morning day plan took hours and marks from wherever the model looked -- WP
cards, guesses -- instead of the week plan the user approved. The pool table
in the «План на неделю» section is the canon; day-open-week-sync-patch.py
rebuilds the day table from it with no LLM call.

Supported shape (the main template, `.claude/skills/day-open/templates.md`):
a «План на неделю» section -- `<summary><b>План на неделю …</b></summary>` or
a markdown heading `## План на неделю …` -- holding a table whose header has
the cells «#» and «h». «РП», «🚦», «Статус» and «Источник» are optional; the
direction token is the text before the first ` · ` of «Источник» and counts
only when it is one of DIRECTION_TOKENS (the template's `R{N} / S-НЭП-X /
carry` sources carry no direction, so the day table keeps its own ТВС marks).
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Optional

from plan_hours import parse_hours_cell

BRANCH_TOKENS = ("В1", "В2", "В3", "В4", "В5")
FOUNDATION_TOKENS = ("Н1", "Н2", "Н3", "Н4")
DIRECTION_TOKENS = BRANCH_TOKENS + FOUNDATION_TOKENS
SOURCE_SEP = " · "

POOL_HEADING_RE = re.compile(r"<summary><b>План на неделю|^#{1,4}\s+План на неделю", re.M)
# The section ends at its own </details> or at the next markdown heading of
# level 1-2 (the plain-heading variant of the template has no <details>).
SECTION_END_RE = re.compile(r"</details>|^#{1,2}\s", re.M)
WP_CELL_RE = re.compile(r"^\s*(?:WP-|РП-)?(\d+)\s*$", re.I)
BOLD_TITLE_RE = re.compile(r"\*\*(.+?)\*\*")


@dataclass
class PoolRow:
    wp: str
    title: str
    hours: Optional[float]
    source: str
    status: str
    light: str = ""  # 🚦 cell of the pool row; empty when the table has no such column

    @property
    def direction(self) -> Optional[str]:
        token = self.source.split(SOURCE_SEP, 1)[0].strip()
        return token if token in DIRECTION_TOKENS else None


def split_row(line: str) -> list[str]:
    """Raw cells of a markdown table line, like str.split("|"), except that an
    escaped `\\|` and a `|` inside a link `[text](target)` do not split."""
    cells, buf = [], []
    in_text = in_target = False
    prev = ""
    for ch in line:
        if ch == "[" and not in_target:
            in_text = True
        elif ch == "]" and in_text:
            in_text = False
        elif ch == "(" and prev == "]":
            in_target = True
        elif ch == ")" and in_target:
            in_target = False
        if ch == "|" and prev != "\\" and not in_text and not in_target:
            cells.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
        prev = ch
    cells.append("".join(buf))
    return cells


def _cells(line: str) -> list[str]:
    return [c.strip() for c in split_row(line.strip().strip("|"))]


def _pool_block(weekplan_text: str) -> str:
    start = POOL_HEADING_RE.search(weekplan_text)
    if start is None:
        return ""
    body_from = weekplan_text.find("\n", start.start())
    body_from = len(weekplan_text) if body_from < 0 else body_from
    end = SECTION_END_RE.search(weekplan_text, body_from)
    return weekplan_text[start.start():end.start() if end else len(weekplan_text)]


def extract_pool_rows(weekplan_text: str) -> list[PoolRow]:
    """Rows of the pool table inside the «План на неделю» section. Columns are
    found by header name, not position, so an added column does not shift them."""
    header = None
    rows = []
    for line in _pool_block(weekplan_text).splitlines():
        if not line.startswith("|"):
            if header is not None and rows:
                break
            continue
        cells = _cells(line)
        if header is None:
            if "#" in cells and "h" in cells:
                header = {name: i for i, name in enumerate(cells)}
            continue
        if all(re.fullmatch(r":?-+:?", c) for c in cells if c):
            continue
        # A short row keeps its WP visible: missing cells read as empty.
        cells += [""] * (len(header) - len(cells))
        num = WP_CELL_RE.match(cells[header["#"]])
        if not num:
            continue
        title_cell = cells[header["РП"]] if "РП" in header else ""
        title = BOLD_TITLE_RE.search(title_cell)
        rows.append(PoolRow(
            wp=f"WP-{int(num.group(1))}",
            title=title.group(1) if title else title_cell,
            hours=parse_hours_cell(cells[header["h"]]),
            source=cells[header["Источник"]] if "Источник" in header else "",
            status=cells[header["Статус"]] if "Статус" in header else "",
            light=cells[header["🚦"]] if "🚦" in header else "",
        ))
    return rows
