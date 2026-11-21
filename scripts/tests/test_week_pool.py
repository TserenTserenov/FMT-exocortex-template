#!/usr/bin/env python3
"""Tests for lib/week_pool.py: the pool table of the WeekPlan is read only
from the «План на неделю» section, columns found by header name.

The fixture has an unrelated appendix table whose numbers (WP-17, WP-22) a
plain regex scan would wrongly count as pool rows.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

from week_pool import extract_pool_rows  # noqa: E402

WEEKPLAN = """# WeekPlan W44

<details open>
<summary><b>План на неделю W44</b></summary>

| 🚦 | # | РП | h | Источник | P | Статус | Результат недели |
|----|---|-----|---|----------|---|--------|------------------|
| 🟡 | 581 | **MCP Open Aisystant** | 6 | В1 · O26 · перенос | P3 | in_progress | — |
| 🔴 | 529 | **Конвейер доставки шаблона** | ~4h | R2 | P1 | in_progress | — |
| 🟢 | 561 | **Конвейер закрытия** | 10 | Н1 · O23 | P1 | pending | — |

**Сводка:** 3 РП.

</details>

<details>
<summary><b>Незавершённые фазы</b></summary>

| 🟢 | 17 | старая строка приложения | 1 |
| 🟢 | 22 | ещё одна | 2 |

</details>
"""


class ExtractPoolRowsTest(unittest.TestCase):
    def test_reads_only_the_pool_table(self):
        rows = extract_pool_rows(WEEKPLAN)
        self.assertEqual([r.wp for r in rows], ["WP-581", "WP-529", "WP-561"])
        self.assertEqual([r.hours for r in rows], [6.0, 4.0, 10.0])
        self.assertEqual([r.direction for r in rows], ["В1", None, "Н1"])   # «R2» is not a direction
        self.assertEqual([r.light for r in rows], ["🟡", "🔴", "🟢"])
        self.assertEqual(rows[0].title, "MCP Open Aisystant")
        self.assertEqual(rows[2].status, "pending")

    def test_short_row_is_kept_with_unreadable_hours(self):
        text = WEEKPLAN.replace("| 🟢 | 561 | **Конвейер закрытия** | 10 | Н1 · O23 | P1 | pending | — |",
                                "| 🟢 | 561 | **Конвейер закрытия** |")
        rows = extract_pool_rows(text)
        self.assertEqual(rows[-1].wp, "WP-561")
        self.assertIsNone(rows[-1].hours)

    def test_pipe_inside_link_or_escaped_does_not_shift_columns(self):
        text = WEEKPLAN.replace("**MCP Open Aisystant**", "**MCP \\| Open** [a|b](u)")
        row = extract_pool_rows(text)[0]
        self.assertEqual((row.hours, row.direction), (6.0, "В1"))

    def test_no_pool_section_gives_no_rows(self):
        self.assertEqual(extract_pool_rows("# пусто\n| # | h |\n|---|---|\n| 1 | 2 |\n"), [])

    def test_table_without_hours_column_gives_no_rows(self):
        text = "## План на неделю W1\n\n| # | РП | Бюджет | Статус |\n|---|---|---|---|\n| 5 | **X** | 3h | pending |\n"
        self.assertEqual(extract_pool_rows(text), [])

    def test_markdown_heading_section_without_source_column(self):
        text = ("## План на неделю W2\n\n| 🚦 | # | РП | h | Статус |\n|---|---|---|---|---|\n"
                "| 🟡 | WP-7 | **Техдолг** | 2-4 | in_progress |\n\n## Приоритеты месяца\n\n"
                "| 🟢 | # | РП | h |\n|---|---|---|---|\n| 🟢 | 99 | **Чужое** | 1 |\n")
        rows = extract_pool_rows(text)
        self.assertEqual([(r.wp, r.hours, r.source, r.direction) for r in rows], [("WP-7", 3.0, "", None)])


if __name__ == "__main__":
    unittest.main()
