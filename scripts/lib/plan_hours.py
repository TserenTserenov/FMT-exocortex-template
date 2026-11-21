"""One parser for the «h» cell of the DayPlan plan table.

Ported into the template with day-open-week-sync-patch.py (release 0.43), which reads the
«h» cells of the week plan with it. A plain `^(\\d+(?:\\.\\d+)?)h?$` rejected `~3h`, the range
`1-2` and the multi-phase record `~3h Ф1 + ~25h Ф2 MVP + ~17h Ф3`.

Grammar (anything else is NOT parsed; callers keep a visible finding: a guessed sum is worse
than a loud skip):

    cell   := term ( '+' term )*
    term   := '~'? number 'h'? ( ('-'|'–'|'—') number 'h'? )? ( phase )*
    phase  := 'Ф' digits ( '.' digits )* | 'MVP'      # a phase marker, nothing else
    number := digits ( ('.'|',') digits )?            # ASCII digits

A range is its midpoint, a multi-term record is the sum of its terms. The number is the estimate
written in the cell, not a plan for the day: callers word their output accordingly. Any other
word next to the number («done», «факт», «2 дня», «x2») can change what the number means, so the
cell is not parsed.
"""

import re
from typing import Optional

MAX_CELL_CHARS = 200  # a real estimate is a few dozen characters; longer cells are prose

_NUM = r"[0-9]+(?:[.,][0-9]+)?"
_PHASE = r"(?:Ф[0-9]+(?:\.[0-9]+)*|(?i:MVP))"
_TERM_RE = re.compile(
    rf"^~?\s*(?P<a>{_NUM})\s*[hH]?"
    rf"(?:\s*[-–—]\s*(?P<b>{_NUM})\s*[hH]?)?"
    rf"(?:\s+{_PHASE}(?:\s+{_PHASE})*)?$"
)


def _to_float(raw: str) -> float:
    return float(raw.replace(",", "."))


def _parse_term(term: str) -> Optional[float]:
    m = _TERM_RE.match(term.strip())
    if m is None:
        return None
    a = _to_float(m.group("a"))
    b_raw = m.group("b")
    if b_raw is None:
        return a
    b = _to_float(b_raw)
    if b < a:  # «8-6» is a typo, not an estimate
        return None
    return (a + b) / 2.0


def parse_hours_cell(cell: str) -> Optional[float]:
    """Hours of one «h» cell, or None when the cell is not a recognised estimate."""
    text = cell.strip()
    if len(text) > MAX_CELL_CHARS:
        return None
    values = [_parse_term(term) for term in text.split("+")]
    if any(value is None for value in values):
        return None
    return sum(values)
