"""Compact Dashboard «Сегодня» block rebuilt from the final «План на сегодня» table.

WHY (ported in template release 0.43): day-open-llm-fill.py renders this block
right after the LLM fill, before step 4.45 rebuilds the table, so the block
would keep the model's rows. day-open-week-sync-patch.py calls this after the
rebuild; columns are found by header name, not position.
"""

from __future__ import annotations

from week_pool import split_row

DASH_START = "---COMPACT-DASHBOARD---"
DASH_END = "---END-COMPACT-DASHBOARD---"
TODAY_LABEL = "**Сегодня (топ-7 по приоритету):**"
TOP_N = 7
SHORT_TITLE_MAX = 60


def _at(cells: list[str], idx: int | None) -> str:
    return cells[idx] if idx is not None and idx < len(cells) else ""


def compact_rows(table_lines: list[str]) -> list[str]:
    """`| 🚦 | # title |` for the first TOP_N body rows of a plan table
    (header row, separator row, then body)."""
    if len(table_lines) < 3:
        return []
    header = {c.strip(): i for i, c in enumerate(split_row(table_lines[0]))}
    light_col, num_col, title_col = header.get("🚦"), header.get("#"), header.get("РП")
    if title_col is None:
        return []
    out = []
    for row in table_lines[2:2 + TOP_N]:
        cells = [c.strip() for c in split_row(row)]
        short = _at(cells, title_col).split(" — ")[0].strip()
        if len(short) > SHORT_TITLE_MAX:
            short = short[:SHORT_TITLE_MAX - 3] + "…"
        label = " ".join(p for p in (_at(cells, num_col), short) if p)
        out.append(f"| {_at(cells, light_col)} | {label} |")
    return out


def replace_today_block(text: str, rows: list[str]) -> str:
    """Swap the «Сегодня» rows inside the Compact Dashboard; unchanged text
    when there is no dashboard, no «Сегодня» label, or no rows."""
    if not rows:
        return text
    lines = text.split("\n")
    out, in_dash, skipping = [], False, False
    for line in lines:
        stripped = line.strip()
        if DASH_START in line:
            in_dash = True
        elif DASH_END in line:
            in_dash = skipping = False
        elif in_dash and stripped.startswith("**Сегодня"):
            out.append(TODAY_LABEL)
            out.extend(rows)
            skipping = True
            continue
        elif skipping:
            if stripped.startswith("|"):
                continue
            skipping = False
        out.append(line)
    return "\n".join(out)
