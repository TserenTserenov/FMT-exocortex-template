"""day_open_attention.py -- shared «Требует внимания» header regex for the
day-open patches that write their findings into the DayPlan.

Tolerant of surrounding whitespace, unlike an exact string: an exact string
silently stops matching the moment the header's whitespace drifts, and the
patch then loses its finding without ever failing Day Open.
"""

import re

ATTENTION_HEADER_RE = re.compile(r"(<summary><b>Требует внимания</b></summary>\s*\n)")
