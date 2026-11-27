"""Row/column helpers for the DayPlan «План на сегодня» table (day-open-week-sync-patch.py)."""

import re

_EDGE_MARKUP_RE = re.compile(r"^[\s*_`]+|[\s*_`]+$")  # markup around a cell, never inside an id
# «РП-N» is the Russian spelling of the same id (the LLM fill writes both).
_TITLE_ID_RE = re.compile(r"(?:WP|РП)-([0-9]+)(?!\w)", re.IGNORECASE)
_TITLE_PREFIX_RE = re.compile(r"(?:WP|РП)-", re.IGNORECASE)
_NUM_CELL_RE = re.compile(r"(?:(?:WP|РП)-)?([0-9]+)", re.IGNORECASE)


def detect_columns(plan_table):
    """Index of the "#" and "РП" header cells in `plan_table` (a list of table lines), or (None, None).

    Header-based, not a hardcoded position: the column set of this table has changed several
    times as the day-open prompt evolved.
    """
    for row in plan_table:
        cells = row.split("|")
        num_col = next((i for i, c in enumerate(cells) if c.strip() == "#"), None)
        title_col = next((i for i, c in enumerate(cells) if c.strip() == "РП"), None)
        if num_col is not None and title_col is not None:
            return num_col, title_col
    return None, None


def row_wp_number(row, num_col, title_col):
    """The WP number a plan row stands for, as a string, or None.

    An explicit `WP-N` at the start of the «РП» title wins (then «#» is only a running index);
    a title that starts with `WP-` but not with a clean id (`WP- без номера`, `WP-578a`) is
    ambiguous, so the row stands for nobody. Otherwise the number in «#» (bare `578` or
    `WP-578`, markup ignored). A `WP-N` in the middle of a description does not count: it would
    claim someone else's hours.
    """
    cells = row.split("|")
    if title_col is not None and len(cells) > title_col:
        title = _EDGE_MARKUP_RE.sub("", cells[title_col])
        title_id = _TITLE_ID_RE.match(title)
        if title_id:
            return str(int(title_id.group(1)))
        if _TITLE_PREFIX_RE.match(title):
            return None
    if num_col is not None and len(cells) > num_col:
        num_id = _NUM_CELL_RE.fullmatch(_EDGE_MARKUP_RE.sub("", cells[num_col]))
        if num_id:
            return str(int(num_id.group(1)))
    return None
