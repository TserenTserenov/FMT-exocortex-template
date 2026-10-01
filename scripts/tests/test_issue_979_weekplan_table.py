"""
Regression for issue #979: create-wp.sh must put the new WP row into the plan
table of the WeekPlan, not into the first table that merely has «РП» and
«Статус» in its header.

After a day close a WeekPlan may start with an «Итоги дня» block holding
`| РП | Что сделано | Статус |`; the old writer took that table, so the rows of
new WPs landed in the summary of the past day, with dashes in every column the
summary does not share with the plan. The writer now gives every table the chain
of its ancestors (the `<summary>` of each enclosing `<details>` plus the markdown
headings in scope), skips a table when any ancestor is a facts section
(«Итоги / Сводка / Summary», whole words), prefers the table whose «План»
ancestor is the nearest one (the word must start with «План»/«Plan»; the first
table on a tie), falls back to the only remaining candidate and otherwise
refuses to guess (warning, nothing written). A `<summary>` may span several
lines and belongs to the block that opened it: one that is never closed swallows
its block, and a nested `<details>` cannot take the open state over; a second
`<summary>` in one block makes its name untrustworthy and leaves all its tables
to the pilot. The document is read in five stages and an earlier one takes its
lines first: code, then HTML comments, then tags, then headings, then table rows
(one pair of tests per pair of stages: the earlier stage takes the line, and a
control where it does not). Code comes before everything: fenced and indented
(4+ columns beyond the list item, a tab counts to 4) code blocks are not markup,
and a `<!--` in them, like one in an inline code span, opens no comment; an
indented line is code only after a blank line, a heading, a closing fence or
another code line, and an indented list is not code.
Only an unindented heading is a section title. A heading with anything in front
of its hashes (indentation, a list marker, a quote mark) sits in a container whose
end a line-based reading cannot tell for sure (lazy continuation, tabs, numbering):
it changes no section and opens an ambiguity zone, in which no table is picked up
to the next unindented heading. A heading is told from a table row by its shape,
not by a pipe in its text: `### Итоги | факт` is a heading, and `# | РП | Статус`
is a heading, not a table header (an ATX heading wins over a table row in CommonMark
and GFM). The content of an HTML comment (`<!--` .. `-->`, one line or many) is not
read at all: no heading, tag, table or zone comes out of it (a comment around a
table cell leaves the row a row, an unclosed one swallows the rest of the file).
A tag in an inline code span is text. A quote is a container of
its own: its tags change nothing outside it. A table is a candidate only when its
header has the exact cell «РП» and a cell starting with the word «Статус» («Статус
(на 3 июля)» counts and is filled with «pending» like the plain column, «Связанные
РП» does not); the new row keeps the indentation of its table.

The same fix replaces the literal `|---` separator lookup in the WeekPlan and
REGISTRY writers (`| --- |` made the REGISTRY step fail and roll the whole WP
back; the WeekPlan step silently found no table), the way #901 did for Strategy.md.

The tests run the python blocks extracted from the REAL create-wp.sh (the same
technique as test_create_wp_weekplan_writer.py) plus one end-to-end run of the
script, so nothing here re-implements the logic under test.
"""

import re
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
CREATE_WP = ROOT / "scripts" / "create-wp.sh"
SEED_WEEKPLAN = ROOT / "seed" / "strategy" / "current" / "WeekPlan W1.md"


def _heredoc_after(marker_pattern: str) -> str:
    """Source of the first <<'PYEOF' block after the create-wp.sh section marker."""
    text = CREATE_WP.read_text(encoding="utf-8")
    marker = re.search(marker_pattern, text, flags=re.MULTILINE)
    assert marker, f"create-wp.sh has no section matching {marker_pattern!r}"
    start = text.index("<<'PYEOF'\n", marker.end()) + len("<<'PYEOF'\n")
    return text[start:text.index("\nPYEOF", start)]


WEEKPLAN_WRITER_SRC = _heredoc_after(r"^# --- Шаг \d+: WeekPlan ---$")
REGISTRY_WRITER_SRC = _heredoc_after(r"^# --- Шаг \d+: WP-REGISTRY\.md ---$")


def _run_block(src: str, *args) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-", *map(str, args)], input=src, capture_output=True, text=True
    )


def _add_to_weekplan(path: Path, num="16", title="Новый РП", priority="P2", budget="3h"):
    return _run_block(WEEKPLAN_WRITER_SRC, path, num, title, priority, budget)


def _add_to_registry(path: Path, num="16"):
    # argv: registry, number, priority, title, repo, budget, governance repo, stake, padded id
    return _run_block(
        REGISTRY_WRITER_SRC, path, num, "P2", "Новый РП", "", "3h", "DS-strategy", "—", f"{int(num):03d}"
    )


PLAN_HEADER = "| 🚦 | # | РП | h | Источник | P | Статус | Результат |\n"
PLAN_SEPARATOR = "|----|---|-----|---|----------|---|--------|-----------|\n"
OLD_ROW = "| 🟡 | 7 | **Старый** — [описание] | 2 | — | P2 | in_progress | [заполнить] |\n"
NEW_ROW = "| 🟡 | 16 | **Новый РП** — [описание] | 3 | — | P2 | pending | [заполнить] |"

DAY_SUMMARY_TABLE = (
    "| РП | Что сделано | Статус |\n"
    "|----|-------------|--------|\n"
    "| #5 | вчера | done |\n"
)
DAY_SUMMARY = (
    "<details open>\n<summary><b>Итоги дня 2026-09-29</b></summary>\n\n"
    + DAY_SUMMARY_TABLE
    + "\n</details>\n\n"
)
PLAN_SECTION = (
    "<details open>\n<summary><b>План на неделю W40</b></summary>\n\n"
    + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW
    + "\n</details>\n"
)
SPARE_TABLE = "| # | РП | Статус |\n|---|----|--------|\n| 1 | **Запас** | pending |\n"
# The «Стратегическая сверка» table of the day-open template: «РП» only as part of «Связанные РП».
SVERKA_TABLE = (
    "| ID | Результат | Бюджет | Статус | P | Связанные РП |\n"
    "|----|-----------|--------|--------|---|--------------|\n"
    "| R1 | ... | ... | ... | P3 | WP-7 |\n"
)
SVERKA_ROW = "| R1 | ... | ... | ... | P3 | WP-7 |"


def _weekplan(tmp_path: Path, body: str, title: str = "WeekPlan W40") -> Path:
    path = tmp_path / "WeekPlan W40.md"
    path.write_text(f"# {title}\n\n" + body, encoding="utf-8")
    return path


def _first_row_below(weekplan: Path, header_fragment: str) -> str:
    """First data row of the table whose header line contains header_fragment."""
    lines = weekplan.read_text(encoding="utf-8").splitlines()
    header = next(i for i, ln in enumerate(lines) if header_fragment in ln)
    return lines[header + 2]


def _cells(row: str) -> list:
    return [c.strip() for c in row.strip().strip("|").split("|")]


def _new_row_by_column(weekplan: Path, header: str, separator: str) -> dict:
    """The row written under this header/separator pair, keyed by the header's column names."""
    lines = weekplan.read_text(encoding="utf-8").splitlines()
    return dict(zip(_cells(header), _cells(lines[lines.index(separator) + 1])))


def test_row_goes_to_plan_table_not_day_summary(tmp_path):
    weekplan = _weekplan(tmp_path, DAY_SUMMARY + PLAN_SECTION)

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавлена" in result.stdout
    out = weekplan.read_text(encoding="utf-8")
    summary_part, plan_part = out.split("План на неделю W40")
    assert "Новый РП" not in summary_part, "the row leaked into the day summary"
    assert DAY_SUMMARY_TABLE in summary_part, "the day summary must stay untouched"
    # directly under the separator, above the existing rows
    assert plan_part.index(NEW_ROW) < plan_part.index(OLD_ROW.strip())


def test_summary_only_warns_and_writes_nothing(tmp_path):
    weekplan = _weekplan(tmp_path, DAY_SUMMARY)
    original = weekplan.read_text(encoding="utf-8")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0
    assert "добавить вручную" in result.stderr
    assert "добавлена" not in result.stdout
    assert weekplan.read_text(encoding="utf-8") == original


def test_markdown_headings_decide_like_summary_tags(tmp_path):
    weekplan = _weekplan(
        tmp_path,
        "## Итоги дня\n\n" + DAY_SUMMARY_TABLE + "\n## План недели\n\n"
        + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW,
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    summary_part, plan_part = weekplan.read_text(encoding="utf-8").split("## План недели")
    assert "Новый РП" not in summary_part
    assert NEW_ROW in plan_part


def test_plan_table_after_a_closed_summary_block_is_the_only_candidate(tmp_path):
    # No heading of its own: after </details> the day summary no longer applies.
    weekplan = _weekplan(tmp_path, DAY_SUMMARY + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW)

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    out = weekplan.read_text(encoding="utf-8")
    assert NEW_ROW in out.split("</details>")[-1]
    assert "Новый РП" not in out.split("</details>")[0]


@pytest.mark.parametrize("last_cell", ["Итог недели", "Результат"], ids=["facts-word", "neutral"])
def test_a_header_row_that_starts_with_a_hash_is_a_heading_not_a_table(tmp_path, last_cell):
    # `# | ...` is an ATX heading in CommonMark and GFM, whatever its text holds (an ATX heading
    # wins over a table row), so what follows it is no table. It used to be read as a table
    # header because of the pipe; a header with a leading pipe, `| # | РП | ...`, is a table.
    _assert_refused(
        tmp_path,
        f"# | РП | Статус | {last_cell}\n|---|----|--------|------------|\n| 7 | **Старый** | pending | — |\n",
    )


def test_plan_section_wins_over_another_candidate(tmp_path):
    spare = "<details><summary>Резерв</summary>\n\n" + SPARE_TABLE + "\n</details>\n\n"
    weekplan = _weekplan(tmp_path, spare + PLAN_SECTION)

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    head, tail = weekplan.read_text(encoding="utf-8").split("План на неделю W40")
    assert "Новый РП" in tail and "Новый РП" not in head


def test_first_of_two_plan_sections_wins(tmp_path):
    second = PLAN_SECTION.replace("W40", "W41").replace("**Старый**", "**Следующий**")
    weekplan = _weekplan(tmp_path, PLAN_SECTION + "\n" + second)

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    head, tail = weekplan.read_text(encoding="utf-8").split("План на неделю W41")
    assert NEW_ROW in head and "Новый РП" not in tail


def test_plan_section_with_a_subheading_and_a_second_table(tmp_path):
    # W18 form: «План» sits in the <summary>, a ### sub-heading stands above the table
    # and another block holds a second РП/Статус table (column «Связанные РП»).
    weekplan = _weekplan(
        tmp_path,
        "<details open>\n<summary><b>План на неделю W18</b></summary>\n\n"
        "### ТОС недели W18 + запрос недели\n\n"
        "| 🚦 | # | РП | h | Статус | Дедлайн | Репо |\n"
        "|----|---|----|---|--------|---------|------|\n"
        "| 🟡 | 7 | **Основной** | 2 | pending | — | — |\n"
        "\n</details>\n\n"
        "<details><summary><b>Стратегическая сверка</b></summary>\n\n" + SVERKA_TABLE + "\n</details>\n",
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавлена" in result.stdout
    assert _first_row_below(weekplan, "| Дедлайн | Репо |") == (
        "| 🟡 | 16 | **Новый РП** — [описание] | 3 | pending | — | — |"
    )
    assert _first_row_below(weekplan, "Связанные РП") == SVERKA_ROW


def test_plan_section_with_several_subsection_tables_takes_the_first(tmp_path):
    # W09 form: one «План на неделю» section with a РП/Статус table per ### sub-section,
    # followed by a day block that says «План» but is a facts section («ИТОГИ»).
    weekplan = _weekplan(
        tmp_path,
        "## План на неделю W09\n\n"
        "### Главные дела недели\n\n"
        "| # | РП | Бюджет | Статус | Дедлайн | Репо |\n"
        "|---|----|--------|--------|---------|------|\n"
        "| 3 | **Главное** | 4h | pending | — | — |\n\n"
        "### Остальные РП\n\n"
        "| # | РП | Бюджет | Статус | Репо |\n"
        "|---|----|--------|--------|------|\n"
        "| 4 | **Прочее** | 1h | pending | — |\n\n"
        "## План на понедельник (16 фев) — ИТОГИ\n\n" + DAY_SUMMARY_TABLE,
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Бюджет | Статус | Дедлайн | Репо |") == (
        "| 16 | **Новый РП** — [описание] | — | pending | — | — |"
    )
    assert _first_row_below(weekplan, "| Бюджет | Статус | Репо |") == "| 4 | **Прочее** | 1h | pending | — |"
    assert _first_row_below(weekplan, "Что сделано") == "| #5 | вчера | done |"


def test_facts_section_nested_under_a_heading_stays_excluded(tmp_path):
    # «Итоги» above, «Закрытые РП» below it: the facts verdict belongs to the whole chain.
    weekplan = _weekplan(
        tmp_path,
        "## Итоги дня 2026-09-29\n\n### Закрытые РП\n\n" + DAY_SUMMARY_TABLE
        + "\n## Задачи недели\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW,
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    head, tail = weekplan.read_text(encoding="utf-8").split("## Задачи недели")
    assert "Новый РП" not in head
    assert NEW_ROW in tail


@pytest.mark.parametrize(
    "title, is_facts",
    [
        ("Итоги дня 2026-09-29", True),
        ("Итоги недели", True),
        ("Итог дня", True),
        ("Сводка недели", True),
        ("Summary", True),
        ("Итоговая таблица недели (плановые РП)", False),
        ("Итого за неделю", False),
        ("Сводный список РП", False),
    ],
)
def test_only_facts_titles_exclude_a_table(tmp_path, title, is_facts):
    weekplan = _weekplan(tmp_path, f"## {title}\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW)

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert ("добавлена" in result.stdout) is (not is_facts), result.stdout + result.stderr


def test_headings_before_a_details_block_do_not_apply_inside_it(tmp_path):
    # W23 form: a flat «## Итоги» section, then independent <details> blocks.
    weekplan = _weekplan(tmp_path, "## Итоги W23\n\nтекст\n\n" + PLAN_SECTION)

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert NEW_ROW in weekplan.read_text(encoding="utf-8")


def test_headings_inside_a_details_block_do_not_leak_out_of_it(tmp_path):
    notes = "<details><summary>Заметки</summary>\n\n### Итоги прошлой недели\n\nтекст\n\n</details>\n\n"
    weekplan = _weekplan(tmp_path, notes + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW)

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавлена" in result.stdout


def test_code_fence_inside_the_plan_block_is_not_markup(tmp_path):
    # A shell comment «# Итоги дня…» inside a fenced block is code, not a heading. Taken for
    # one, it made the plan block a facts section and left only the «Связанные РП» table as
    # a candidate, which then received a nameless row.
    weekplan = _weekplan(
        tmp_path,
        "<details open><summary><b>План на неделю W40</b></summary>\n\n"
        "```bash\n# Итоги дня: запустить закрытие\necho done\n```\n\n"
        + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW
        + "\n</details>\n\n"
        "<details><summary>Стратегическая сверка</summary>\n\n" + SVERKA_TABLE + "\n</details>\n",
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW
    assert _first_row_below(weekplan, "Связанные РП") == SVERKA_ROW


@pytest.mark.parametrize(
    "opening, inner, closing",
    [
        ("```", "~~~", "```"),
        ("~~~", "```", "~~~"),
        ("````", "```", "````"),
        ("```python", "# комментарий", "```"),
        ("```", "```text", "```"),
    ],
    ids=[
        "tildes-inside-backticks",
        "backticks-inside-tildes",
        "shorter-inside-longer",
        "info-string",
        "info-string-line-inside",
    ],
)
def test_a_table_inside_a_fenced_block_is_not_a_candidate(tmp_path, opening, inner, closing):
    # The example table sits in the same «План» section as the real one and comes first: it
    # must stay hidden until a fence of the same kind and at least the same length closes.
    example = f"{opening}\n{inner}\n| РП | Статус |\n|----|--------|\n| 1 | пример |\n{closing}\n"
    weekplan = _weekplan(
        tmp_path, "## План недели\n\n" + example + "\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW
    assert _first_row_below(weekplan, "| РП | Статус |") == "| 1 | пример |"


def test_triple_backticks_inside_a_line_do_not_open_a_fence(tmp_path):
    weekplan = _weekplan(
        tmp_path, "```код``` в тексте\n\n## План недели\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert NEW_ROW in weekplan.read_text(encoding="utf-8")


@pytest.mark.parametrize(
    "summary",
    [
        "<summary>\nИтоги дня\n</summary>",
        "<summary>Итоги дня\n</summary>",
        "<summary>\nИтоги дня</summary>",
        "<summary><b>Итоги\nдня 2026-09-29</b></summary>",
    ],
    ids=["tags-on-own-lines", "close-on-its-own-line", "open-on-its-own-line", "title-broken-in-two"],
)
def test_summary_over_several_lines_still_marks_a_facts_section(tmp_path, summary):
    # The summary used to be searched inside ONE line: the block stayed without a title and
    # its day-summary table became the only candidate.
    weekplan = _weekplan(tmp_path, f"<details>\n{summary}\n\n" + DAY_SUMMARY_TABLE + "\n</details>\n")
    original = weekplan.read_text(encoding="utf-8")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавить вручную" in result.stderr
    assert "добавлена" not in result.stdout
    assert weekplan.read_text(encoding="utf-8") == original


def test_plan_title_over_several_lines_counts_as_plan(tmp_path):
    spare = "<details><summary>Резерв</summary>\n\n" + SPARE_TABLE + "\n</details>\n\n"
    plan = (
        "<details open>\n<summary>\n<b>План на неделю W40</b>\n</summary>\n\n"
        + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW + "\n</details>\n"
    )
    weekplan = _weekplan(tmp_path, spare + plan)

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    head, tail = weekplan.read_text(encoding="utf-8").split("План на неделю W40")
    assert NEW_ROW in tail and "Новый РП" not in head


def test_unclosed_summary_leaves_no_candidate_in_its_block(tmp_path):
    # A typo in the closing tag: the title never ends, so nothing in the block can be trusted.
    weekplan = _weekplan(
        tmp_path,
        "<details open>\n<summary>План на неделю W40\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW
        + "\n</details>\n",
    )
    original = weekplan.read_text(encoding="utf-8")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавить вручную" in result.stderr
    assert "добавлена" not in result.stdout
    assert weekplan.read_text(encoding="utf-8") == original


def test_damage_of_an_unclosed_summary_ends_with_its_block(tmp_path):
    # The broken block is skipped, the plain table after its </details> is the only candidate.
    weekplan = _weekplan(
        tmp_path,
        "<details>\n<summary>Итоги дня\n\n" + DAY_SUMMARY_TABLE + "\n</details>\n\n"
        + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW,
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    head, tail = weekplan.read_text(encoding="utf-8").split("</details>")
    assert NEW_ROW in tail and "Новый РП" not in head
    assert DAY_SUMMARY_TABLE in head


@pytest.mark.parametrize(
    "stray", ["<summary>Итоги дня</summary>", "<summary>Итоги дня"], ids=["closed", "unclosed"]
)
def test_summary_outside_details_is_plain_text(tmp_path, stray):
    # No <details> around it: not a section title, and an unclosed one swallows nothing.
    weekplan = _weekplan(tmp_path, stray + "\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW)

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert NEW_ROW in weekplan.read_text(encoding="utf-8")


@pytest.mark.parametrize(
    "body",
    [
        # the reviewer's input: the inner block closes, the table sits in the outer one
        "<details>\n<summary>Итоги дня\n<details><summary>Резерв</summary>\n</details>\n"
        "| РП | Статус |\n|---|---|\n</details>\n",
        # the table sits in the inner block, under a closed «Резерв» summary
        "<details>\n<summary>План недели\n<details><summary>Резерв</summary>\n\n" + SPARE_TABLE
        + "\n</details>\n</details>\n",
        # the inner <summary> is not closed either
        "<details>\n<summary>План недели\n<details>\n<summary>Резерв\n\n" + SPARE_TABLE
        + "\n</details>\n</details>\n",
    ],
    ids=["table-in-the-outer-block", "table-in-the-inner-block", "inner-summary-unclosed-too"],
)
def test_a_nested_block_does_not_close_an_open_summary(tmp_path, body):
    # The open <summary> state belongs to the block that opened it: the inner block's own
    # <summary> used to overwrite it, the outer block stayed without a title and its table
    # became the only candidate.
    weekplan = _weekplan(tmp_path, body)
    original = weekplan.read_text(encoding="utf-8")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавить вручную" in result.stderr
    assert "добавлена" not in result.stdout
    assert weekplan.read_text(encoding="utf-8") == original


@pytest.mark.parametrize("summary_first", [True, False], ids=["summary-first", "summary-last"])
def test_a_summary_block_nested_in_the_plan_block_stays_excluded(tmp_path, summary_first):
    # Proper nesting «План → Итоги»: the day summary is excluded, the plan table is written.
    inner = "<details>\n<summary>Итоги дня 2026-09-29</summary>\n\n" + DAY_SUMMARY_TABLE + "\n</details>\n"
    plan_table = PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW
    content = inner + "\n" + plan_table if summary_first else plan_table + "\n" + inner
    weekplan = _weekplan(
        tmp_path, "<details open>\n<summary><b>План на неделю W40</b></summary>\n\n" + content + "\n</details>\n"
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW
    assert _first_row_below(weekplan, "Что сделано") == "| #5 | вчера | done |"


def test_an_unclosed_inner_summary_leaves_the_outer_plan_usable(tmp_path):
    weekplan = _weekplan(
        tmp_path,
        "<details open>\n<summary><b>План на неделю W40</b></summary>\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW
        + "\n<details>\n<summary>Итоги дня\n\n" + DAY_SUMMARY_TABLE + "\n</details>\n</details>\n",
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW
    assert _first_row_below(weekplan, "Что сделано") == "| #5 | вчера | done |"


@pytest.mark.parametrize(
    "summaries",
    [
        "<summary>Итоги</summary>\n<summary>План</summary>",
        "<summary>Итоги\n<summary>План</summary>",
        "<summary>План</summary>\n<summary>Итоги</summary>",
        "<summary>План недели</summary>\n<summary>Заметки</summary>",
        "<summary>План недели</summary><summary>План недели</summary>",
    ],
    ids=["facts-then-plan", "first-not-closed", "plan-then-facts", "plan-then-notes", "same-line"],
)
def test_a_second_summary_in_one_block_leaves_its_tables_to_the_pilot(tmp_path, summaries):
    # The second <summary> used to rename the block («Итоги» became «План» and the row went to
    # the table). Which of the two names is true cannot be told, so nothing in the block is picked.
    weekplan = _weekplan(tmp_path, f"<details>\n{summaries}\n\n| РП | Статус |\n| --- | --- |\n</details>\n")
    original = weekplan.read_text(encoding="utf-8")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавить вручную" in result.stderr
    assert "добавлена" not in result.stdout
    assert weekplan.read_text(encoding="utf-8") == original


def test_tables_above_the_second_summary_are_left_out_too(tmp_path):
    weekplan = _weekplan(
        tmp_path,
        "<details>\n<summary>План недели</summary>\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW
        + "\n<summary>Заметки</summary>\n</details>\n",
    )
    original = weekplan.read_text(encoding="utf-8")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавить вручную" in result.stderr
    assert weekplan.read_text(encoding="utf-8") == original


def test_an_ambiguous_block_does_not_hide_the_plan_block_elsewhere(tmp_path):
    # The first block would be «План недели» by its last <summary> and win as the first plan.
    ambiguous = (
        "<details>\n<summary>Резерв</summary>\n<summary>План недели</summary>\n\n" + SPARE_TABLE + "\n</details>\n\n"
    )
    weekplan = _weekplan(tmp_path, ambiguous + PLAN_SECTION)

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    head, tail = weekplan.read_text(encoding="utf-8").split("План на неделю W40")
    assert NEW_ROW in tail and "Новый РП" not in head


def test_an_ambiguous_inner_block_does_not_taint_the_outer_one(tmp_path):
    inner = "<details>\n<summary>Резерв</summary>\n<summary>Ещё</summary>\n\n" + SPARE_TABLE + "\n</details>\n"
    weekplan = _weekplan(
        tmp_path,
        "<details open>\n<summary><b>План на неделю W40</b></summary>\n\n" + inner + "\n"
        + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW + "\n</details>\n",
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW
    assert _first_row_below(weekplan, "| # | РП | Статус |") == "| 1 | **Запас** | pending |"


@pytest.mark.parametrize(
    "header_indent, separator_indent",
    [("    ", "    "), ("\t", "\t"), ("      ", "      "), ("  \t", "  \t"), ("    ", ""), ("", "    ")],
    ids=["four-spaces", "tab", "six-spaces", "spaces-then-tab", "only-header", "only-separator"],
)
def test_an_indented_table_is_code_not_a_candidate(tmp_path, header_indent, separator_indent):
    # An example table, indented like a code block, sits above the real one in the same
    # «План» section; the row used to land inside the example, without its indentation.
    example = (
        f"{header_indent}| РП | Статус |\n{separator_indent}|----|--------|\n{header_indent}| 1 | пример |\n"
    )
    weekplan = _weekplan(
        tmp_path, "## План недели\n\n" + example + "\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    out = weekplan.read_text(encoding="utf-8")
    assert example in out, "the example must stay untouched"
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW


def test_only_an_indented_table_leaves_nothing_to_write_into(tmp_path):
    weekplan = _weekplan(
        tmp_path, "## План недели\n\n    | РП | Статус |\n    |----|--------|\n    | 1 | пример |\n"
    )
    original = weekplan.read_text(encoding="utf-8")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавить вручную" in result.stderr
    assert "добавлена" not in result.stdout
    assert weekplan.read_text(encoding="utf-8") == original


def test_a_table_indented_by_three_spaces_is_still_a_table(tmp_path):
    # Up to three spaces of indentation keep a table a table; only four make it code.
    weekplan = _weekplan(tmp_path, "## План недели\n\n   | РП | Статус |\n   |----|--------|\n   | 1 | x |\n")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавлена" in result.stdout
    lines = weekplan.read_text(encoding="utf-8").splitlines()
    # the row keeps the indentation of its table
    assert lines[lines.index("   |----|--------|") + 1] == "   | **Новый РП** — [описание] | pending |"


CODEX_PLAN = "## План\n| РП | Статус |\n|---|---|\n"


@pytest.mark.parametrize(
    "indent", ["    ", "\t", "      ", "  \t"], ids=["four-spaces", "tab", "six-spaces", "spaces-then-tab"]
)
def test_a_tag_line_in_indented_code_is_not_markup(tmp_path, indent):
    # The reviewer's input. Tags used to be handled before the indentation was looked at: the
    # example opened a block named «Итоги» and the real plan table below it was refused as facts.
    example = f"{indent}<details><summary>Итоги</summary>\n"
    weekplan = _weekplan(tmp_path, example + CODEX_PLAN)

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавлена" in result.stdout
    lines = weekplan.read_text(encoding="utf-8").splitlines()
    assert lines[lines.index("|---|---|") + 1] == "| **Новый РП** — [описание] | pending |"
    assert example in weekplan.read_text(encoding="utf-8"), "the example must stay untouched"


@pytest.mark.parametrize(
    "example",
    ["<details><summary>Итоги</summary>", "<summary>Итоги</summary>", "</details>"],
    ids=["details-with-summary", "summary", "closing-details"],
)
@pytest.mark.parametrize("indent", ["    ", "\t"], ids=["four-spaces", "tab"])
def test_example_tags_in_indented_code_do_not_reshape_the_plan_block(tmp_path, indent, example):
    # Taken for markup the example renames the plan block «Итоги» (the row went to «Резерв»)
    # or closes it early (the plan table lost its «План» title and the choice was refused).
    spare = "<details><summary>Резерв</summary>\n\n" + SPARE_TABLE + "\n</details>\n\n"
    plan = (
        "<details open>\n<summary><b>План на неделю W40</b></summary>\n\n"
        f"{indent}{example}\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW + "\n</details>\n"
    )
    weekplan = _weekplan(tmp_path, spare + plan)

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    head, tail = weekplan.read_text(encoding="utf-8").split("План на неделю W40")
    assert NEW_ROW in tail and "Новый РП" not in head


@pytest.mark.parametrize(
    "prefix",
    [
        "## План недели\n    <details><summary>Итоги</summary>\n",
        "\n    Пример разметки:\n    <details><summary>Итоги</summary>\n## План недели\n",
        "```text\nпример\n```\n    <details><summary>Итоги</summary>\n## План недели\n",
        "\n    - <details><summary>Итоги</summary>\n## План недели\n",
    ],
    ids=["right-after-a-heading", "after-another-code-line", "right-after-a-closing-fence", "list-marker-in-code"],
)
def test_where_indented_code_starts_and_continues(tmp_path, prefix):
    # Code opens after a blank line, a heading or a closing fence, goes on over the next
    # indented line, and a bullet in it is no list item.
    weekplan = _weekplan(tmp_path, prefix + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW)

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW


def test_an_indented_tag_under_an_html_line_is_still_a_tag(tmp_path):
    # `<summary>` indented under `<details>` with no blank line between belongs to the same HTML
    # block: it is markup, and the plan block keeps its title (the spare table has none).
    spare = "<details><summary>Резерв</summary>\n\n" + SPARE_TABLE + "\n</details>\n\n"
    plan = (
        "<details open>\n    <summary><b>План на неделю W40</b></summary>\n\n"
        + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW + "\n</details>\n"
    )
    weekplan = _weekplan(tmp_path, spare + plan)

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW
    assert _first_row_below(weekplan, "| # | РП | Статус |") == "| 1 | **Запас** | pending |"


@pytest.mark.parametrize(
    "marker, indent",
    [("-", "    "), ("1.", "    "), ("-", "\t")],
    ids=["bullet-four-spaces", "numbered-four-spaces", "bullet-tab"],
)
def test_a_table_inside_a_list_item_is_a_table_and_its_row_keeps_the_indentation(tmp_path, marker, indent):
    # Four columns from the margin are only two beyond the content of «- Задачи:»: not code.
    table = "".join(indent + ln + "\n" for ln in ["| РП | Статус |", "|----|--------|", "| 1 | x |"])
    weekplan = _weekplan(tmp_path, f"## План недели\n\n{marker} Задачи:\n\n{table}")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавлена" in result.stdout
    lines = weekplan.read_text(encoding="utf-8").splitlines()
    assert lines[lines.index(indent + "|----|--------|") + 1] == indent + "| **Новый РП** — [описание] | pending |"


def test_code_inside_a_list_item_is_still_code(tmp_path):
    # Eight columns are six beyond the content of «- Задачи:»: an indented code block.
    weekplan = _weekplan(
        tmp_path,
        "## План недели\n\n- Задачи:\n\n        | РП | Статус |\n        |----|--------|\n        | 1 | x |\n",
    )
    original = weekplan.read_text(encoding="utf-8")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавить вручную" in result.stderr
    assert weekplan.read_text(encoding="utf-8") == original


def test_a_list_ends_with_the_next_unindented_line(tmp_path):
    # After «- Пункт» and an unindented paragraph the list is over: four columns from the margin
    # are code again, not two beyond a list item.
    example = "    | РП | Статус |\n    |----|--------|\n    | 1 | пример |\n"
    weekplan = _weekplan(
        tmp_path,
        "## План недели\n\n- Пункт\n\nОбычный абзац.\n\n" + example + "\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW,
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert example in weekplan.read_text(encoding="utf-8"), "the example must stay untouched"
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW


def test_an_indented_tag_inside_a_list_item_is_real_markup(tmp_path):
    # Two columns beyond the content of «- Пункт» is no code: the tag opens a block named «Итоги»
    # that is never closed, so the plan table below it is not a safe pick.
    weekplan = _weekplan(
        tmp_path,
        "- Пункт\n\n    <details><summary>Итоги</summary>\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW,
    )
    original = weekplan.read_text(encoding="utf-8")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавить вручную" in result.stderr
    assert weekplan.read_text(encoding="utf-8") == original


def _nested_list(outer, nested):
    """Two nested list items and the indentation of the content of the inner one."""
    pad = " " * (len(outer) + 1)
    return f"{outer} Раздел\n{pad}{nested} Вложенный раздел\n", pad + " " * (len(nested) + 1)


NESTED_LISTS = pytest.mark.parametrize(
    "outer, nested",
    [("-", "-"), ("*", "+"), ("1.", "1."), ("-", "1.")],
    ids=["bullets", "other-bullets", "numbers", "bullet-then-number"],
)


def _assert_refused(tmp_path, body):
    """The writer must say «добавить вручную» and leave a WeekPlan made of `body` alone."""
    weekplan = _weekplan(tmp_path, body)
    original = weekplan.read_text(encoding="utf-8")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавить вручную" in result.stderr
    assert "добавлена" not in result.stdout
    assert weekplan.read_text(encoding="utf-8") == original


def _row_below(weekplan, separator):
    lines = weekplan.read_text(encoding="utf-8").splitlines()
    return lines[lines.index(separator) + 1]


@NESTED_LISTS
def test_a_facts_heading_in_a_nested_list_still_excludes_its_table(tmp_path, outer, nested):
    # A heading inside a list item opens an ambiguity zone: the tables after it, its own included,
    # are not picked until an unindented heading closes the zone.
    items, pad = _nested_list(outer, nested)
    _assert_refused(tmp_path, items + f"{pad}## Итоги\n\n{pad}| РП | Статус |\n{pad}| --- | --- |\n")


@NESTED_LISTS
def test_a_plan_table_under_a_heading_in_a_list_is_left_to_the_pilot(tmp_path, outer, nested):
    # Even a «План» heading does not make the table of its list item a candidate: whether the
    # list item still reaches the table cannot be told from lines alone (it chose this table
    # before the zone, and went wrong on lazy continuations, tabs and numbering).
    items, pad = _nested_list(outer, nested)
    _assert_refused(tmp_path, items + f"{pad}## План\n\n{pad}| РП | Статус |\n{pad}| --- | --- |\n")


def test_a_heading_on_the_line_of_a_list_item_is_a_heading(tmp_path):
    _assert_refused(tmp_path, "- ## Итоги\n\n  | РП | Статус |\n  | --- | --- |\n")


def test_a_heading_in_a_tab_indented_nested_list_is_a_heading(tmp_path):
    _assert_refused(tmp_path, "- Раздел\n\t- Вложенный раздел\n\t\t## Итоги\n\n\t\t| РП | Статус |\n\t\t| --- | --- |\n")


@pytest.mark.parametrize(
    "item, content",
    [("- ## Итоги\n", "  "), ("1. ## Итоги\n", "   ")],
    ids=["bullet", "numbered"],
)
def test_a_lazy_continuation_does_not_end_the_zone_of_a_list_heading(tmp_path, item, content):
    # The reviewer's input: «продолжение» is a lazy continuation of the paragraph in the same list
    # item, but a line-based reading closes the item there, and the table below used to be picked
    # with no ancestor at all (the row went into «Итоги»).
    _assert_refused(
        tmp_path, f"{item}\n{content}Текст\nпродолжение\n\n{content}| РП | Статус |\n{content}| --- | --- |\n"
    )


@pytest.mark.parametrize(
    "item",
    ["- Раздел\n  ## Итоги\n", "- ## Итоги\n"],
    ids=["heading-in-the-item", "heading-on-the-item-line"],
)
def test_a_table_right_after_a_list_with_a_heading_is_left_to_the_pilot(tmp_path, item):
    # No unindented heading between the list and the table: the zone is still open.
    _assert_refused(tmp_path, item + "\n| РП | Статус |\n| --- | --- |\n")


def test_the_zone_of_a_list_heading_covers_the_next_items(tmp_path):
    _assert_refused(tmp_path, "- Первый\n  ## Итоги\n\n- Второй\n\n  | РП | Статус |\n  | --- | --- |\n")


def test_two_headings_in_a_list_item_leave_its_tables_to_the_pilot(tmp_path):
    _assert_refused(tmp_path, "- Раздел\n  ## Итоги\n  ## План\n\n  | РП | Статус |\n  | --- | --- |\n")


def test_a_heading_of_a_list_item_leaves_the_items_nested_in_it_too(tmp_path):
    _assert_refused(tmp_path, "- Раздел\n  ## Итоги\n\n  - Вложенный\n\n    | РП | Статус |\n    | --- | --- |\n")


def test_code_in_a_nested_list_item_is_still_code(tmp_path):
    # Four columns beyond the content of the inner item: an indented code block.
    items, pad = _nested_list("-", "-")
    _assert_refused(tmp_path, items + f"\n{pad}    | РП | Статус |\n{pad}    | --- | --- |\n")


def test_code_may_follow_a_heading_inside_a_nested_list_item(tmp_path):
    # Right after the heading (no blank line) four more columns are code, tag or not. Taken for a
    # real tag, the example would open a block named «Итоги» that never closes, and the plan
    # table below the unindented heading would be refused as facts.
    items, pad = _nested_list("-", "-")
    weekplan = _weekplan(
        tmp_path,
        items + f"{pad}## План\n{pad}    <details><summary>Итоги</summary>\n\n## План недели\n\n"
        + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW,
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW


def test_code_may_follow_a_heading_on_a_list_item_line(tmp_path):
    # «- ## Раздел» is a heading line of its own, whose item content starts after the marker: four
    # more columns right below it are code (the same example tag as above would otherwise name a block).
    weekplan = _weekplan(
        tmp_path,
        "- ## Раздел\n      <details><summary>Итоги</summary>\n\n## План недели\n\n"
        + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW,
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW


def test_a_nested_facts_heading_does_not_reach_the_next_plan_section(tmp_path):
    items, pad = _nested_list("-", "-")
    weekplan = _weekplan(
        tmp_path,
        items + f"{pad}## Итоги\n\n{pad}| РП | Статус |\n{pad}| --- | --- |\n\n## План недели\n\n"
        + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW,
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW
    nested_table = f"{pad}| РП | Статус |\n{pad}| --- | --- |\n\n## План недели"
    assert nested_table in weekplan.read_text(encoding="utf-8"), "the nested table must stay untouched"


@pytest.mark.parametrize("nested_heading", ["#", "##"], ids=["higher-level", "same-level"])
def test_a_heading_in_a_list_item_does_not_replace_the_outer_facts_section(tmp_path, nested_heading):
    # The «План» heading of the list item used to take the place of the outer «Итоги», and the
    # row went into the facts table after the list. It changes no section now.
    items, pad = _nested_list("-", "-")
    _assert_refused(
        tmp_path,
        "## Итоги\n\n" + items + f"{pad}{nested_heading} План\n\n### Выполнено\n\n| РП | Статус |\n| --- | --- |\n",
    )


def test_a_facts_heading_in_a_list_item_does_not_exclude_the_outer_plan_table(tmp_path):
    items, pad = _nested_list("-", "-")
    weekplan = _weekplan(
        tmp_path,
        "## План\n\n" + items + f"{pad}## Итоги\n\n### Выполнено\n\n| РП | Статус |\n| --- | --- |\n",
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _row_below(weekplan, "| --- | --- |") == "| **Новый РП** — [описание] | pending |"


@pytest.mark.parametrize("opener", ["- ## Итоги\n", "> ## Итоги\n"], ids=["list", "quote"])
@pytest.mark.parametrize("closer", ["#", "##", "###", "####"])
def test_an_unindented_heading_of_any_level_closes_the_zone(tmp_path, opener, closer):
    weekplan = _weekplan(
        tmp_path, f"{opener}\n{closer} План\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW


@pytest.mark.parametrize("indent", [" ", "  ", "   "], ids=["one-space", "two-spaces", "three-spaces"])
def test_an_indented_heading_opens_a_zone(tmp_path, indent):
    # An indented heading cannot be told from one inside a list item whose end the reading missed.
    _assert_refused(tmp_path, f"{indent}## Итоги\n\n| РП | Статус |\n| --- | --- |\n")


@pytest.mark.parametrize("indent", [" ", "  ", "   ", "\t"], ids=["one-space", "two-spaces", "three-spaces", "tab"])
def test_an_indented_heading_closes_no_zone(tmp_path, indent):
    _assert_refused(tmp_path, f"- ## Итоги\n\n{indent}## План\n\n| РП | Статус |\n| --- | --- |\n")


def test_an_indented_heading_after_a_lazy_continuation_rewrites_no_section(tmp_path):
    # «  ## План» belongs to the list item, which the line-based reading closed at «продолжение».
    # Taken for an unindented heading it replaced the outer «Итоги», the zone ended, and the row
    # went into the facts table under «### Выполнено».
    _assert_refused(
        tmp_path,
        "## Итоги\n\n- ## Раздел\nпродолжение\n  ## План\n\n### Выполнено\n\n| РП | Статус |\n| --- | --- |\n",
    )


@pytest.mark.parametrize(
    "code",
    ["~~~\n  - ## Итоги\n~~~\n", "\n    ## Итоги\n"],
    ids=["fenced", "indented"],
)
def test_heading_like_text_in_code_opens_no_zone(tmp_path, code):
    weekplan = _weekplan(tmp_path, code + "\n| РП | Статус |\n| --- | --- |\n")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _row_below(weekplan, "| --- | --- |") == "| **Новый РП** — [описание] | pending |"


def test_heading_like_text_in_a_summary_title_opens_no_zone(tmp_path):
    # The lines of a <summary> title are text, not markup.
    weekplan = _weekplan(
        tmp_path,
        "<details open>\n<summary>\n- ## Заметки\n</summary>\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW
        + "\n</details>\n",
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW


def test_an_indented_header_row_that_starts_with_a_hash_is_a_heading(tmp_path):
    # An ATX heading with up to three spaces in front, so no table header, and an indented
    # heading opens a zone.
    _assert_refused(tmp_path, "  # | РП | Статус\n  --- | --- | ---\n  1 | x | y\n")


@pytest.mark.parametrize("indent", [" ", "  ", "   "], ids=["one-space", "two-spaces", "three-spaces"])
def test_an_indented_heading_with_a_pipe_opens_a_zone(tmp_path, indent):
    # The reviewer's input. The pipe in the text made the line a «table row», so the zone was
    # never opened and the row went into the table under «### Итоги | факт».
    _assert_refused(tmp_path, f"## План\n\n{indent}### Итоги | факт\n\n| РП | Статус |\n| --- | --- |\n")


@pytest.mark.parametrize("title", ["Итоги | факт", "факт | Итоги", "|Итоги|"], ids=["before", "after", "between"])
def test_an_unindented_heading_with_a_pipe_excludes_the_table_under_it(tmp_path, title):
    # The whole text of the heading is read, a pipe cuts nothing off.
    _assert_refused(tmp_path, f"## План\n\n### {title}\n\n| РП | Статус |\n| --- | --- |\n")


@pytest.mark.parametrize("title", ["План | неделя W40", "неделя W40 | План"], ids=["before", "after"])
def test_a_plan_heading_with_a_pipe_still_names_the_plan(tmp_path, title):
    weekplan = _weekplan(
        tmp_path,
        "## Резерв\n\n" + SPARE_TABLE + f"\n## {title}\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW,
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW
    assert _first_row_below(weekplan, "| # | РП | Статус |") == "| 1 | **Запас** | pending |"


def test_an_unindented_heading_with_a_pipe_changes_the_sections(tmp_path):
    # It replaces the same-level «Итоги», so the table after it is no longer facts.
    weekplan = _weekplan(tmp_path, "## Итоги\n\n## Заметки | недели\n\n| РП | Статус |\n| --- | --- |\n")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _row_below(weekplan, "| --- | --- |") == "| **Новый РП** — [описание] | pending |"


@pytest.mark.parametrize(
    "opener",
    ["> ## Итоги | факт\n", "- ## Итоги | факт\n", "- Раздел\n  - Вложенный\n    ### Итоги | факт\n"],
    ids=["quote", "list-item", "nested-list"],
)
def test_a_heading_with_a_pipe_in_a_container_opens_a_zone(tmp_path, opener):
    _assert_refused(tmp_path, f"## План\n\n{opener}\n| РП | Статус |\n| --- | --- |\n")


def test_an_unindented_heading_with_a_pipe_closes_a_zone(tmp_path):
    weekplan = _weekplan(tmp_path, "- ## Итоги\n\n## План | неделя\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW)

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW


def test_a_table_header_with_a_leading_pipe_and_a_hash_cell_is_still_a_table(tmp_path):
    weekplan = _weekplan(tmp_path, "| # | РП | Статус |\n| --- | --- | --- |\n| 1 | x | y |\n")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _row_below(weekplan, "| --- | --- | --- |") == "| 16 | **Новый РП** — [описание] | pending |"


@pytest.mark.parametrize("quote", [">", " >", "   >", "> >"], ids=["flush", "one-space", "three-spaces", "nested"])
def test_a_heading_in_a_quote_leaves_the_tables_after_it_to_the_pilot(tmp_path, quote):
    _assert_refused(tmp_path, f"{quote} ## Итоги\n\n| РП | Статус |\n| --- | --- |\n")


@pytest.mark.parametrize("quote", [">", " >", "   >"], ids=["flush", "one-space", "three-spaces"])
def test_a_block_opened_in_a_quote_does_not_reach_the_sections_outside(tmp_path, quote):
    # The reviewer's input. The quote is a container of its own: its <details> used to stay open
    # and the «Итоги» in its summary made the plan table below it facts.
    weekplan = _weekplan(
        tmp_path, f"{quote} <details><summary>Итоги</summary>\n\n## План\n| РП | Статус |\n|---|---|\n"
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавлена" in result.stdout
    lines = weekplan.read_text(encoding="utf-8").splitlines()
    assert lines[lines.index("|---|---|") + 1] == "| **Новый РП** — [описание] | pending |"


def test_four_spaces_before_the_marker_make_no_quote(tmp_path):
    # Right after text, four spaces continue that line: no quote, so the tag is real markup, the
    # block named «Итоги» stays open and the plan table inside it is not a safe pick.
    weekplan = _weekplan(
        tmp_path, "Текст\n    > <details><summary>Итоги</summary>\n\n## План\n| РП | Статус |\n|---|---|\n"
    )
    original = weekplan.read_text(encoding="utf-8")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавить вручную" in result.stderr
    assert weekplan.read_text(encoding="utf-8") == original


def test_a_closing_tag_in_a_quote_does_not_close_the_block_around_it(tmp_path):
    spare = "<details><summary>Резерв</summary>\n\n" + SPARE_TABLE + "\n</details>\n\n"
    plan = (
        "<details open>\n<summary><b>План на неделю W40</b></summary>\n\n> </details>\n\n"
        + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW + "\n</details>\n"
    )
    weekplan = _weekplan(tmp_path, spare + plan)

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW


def test_a_quote_inside_a_list_item_is_a_quote(tmp_path):
    # Four columns from the margin, none beyond the content of the inner item: a quote.
    items, pad = _nested_list("-", "-")
    weekplan = _weekplan(
        tmp_path,
        items + f"{pad}> <details><summary>Итоги</summary>\n\n## План недели\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW,
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW


def test_a_quote_on_the_line_of_a_list_item_is_a_quote(tmp_path):
    weekplan = _weekplan(
        tmp_path,
        "- > <details><summary>Итоги</summary>\n\n## План недели\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW,
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW


def test_a_table_in_a_quote_is_not_a_candidate(tmp_path):
    quoted = "> | РП | Статус |\n> | --- | --- |\n> | 1 | x |\n"
    weekplan = _weekplan(tmp_path, quoted + "\n## План недели\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW)

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert quoted in weekplan.read_text(encoding="utf-8"), "the quoted table must stay untouched"
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW


DAY_OPEN_TEMPLATES = ROOT / ".claude" / "skills" / "day-open" / "templates.md"
PLAN_TABLE_SEPARATOR = "|----|---|-----|---|----------|---|--------|-----------|"


def _day_open_weekplan_template() -> str:
    """The WeekPlan template of the day-open skill: the first fenced block after its heading."""
    lines = DAY_OPEN_TEMPLATES.read_text(encoding="utf-8").splitlines()
    heading = next(i for i, ln in enumerate(lines) if ln.startswith("## Шаблон WeekPlan"))
    opening = next(i for i in range(heading, len(lines)) if lines[i].startswith("```"))
    closing = next(i for i in range(opening + 1, len(lines)) if lines[i].startswith("```"))
    return "\n".join(lines[opening + 1:closing]) + "\n"


def test_a_heading_in_an_html_comment_changes_no_section(tmp_path):
    # The reviewer's input. «## План» inside the comment replaced «## Итоги», both tables were
    # at the same distance from «План», and the first one, the facts table, got the row.
    old_facts = "| РП | Статус |\n| --- | --- |\n| Старый итог | done |\n"
    plan = "| РП | Статус |\n| --- | --- |\n| Плановый | pending |\n"
    weekplan = _weekplan(
        tmp_path, "## Итоги\n\n<!--\n## План\n-->\n\n" + old_facts + "\n## План\n\n" + plan
    )
    original = weekplan.read_text(encoding="utf-8")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    out = weekplan.read_text(encoding="utf-8")
    assert old_facts in out, "the facts table must stay untouched"
    # the file is as it was, plus the one row: the comment lines stay where they are
    expected = original.replace("| Плановый | pending |", "| **Новый РП** — [описание] | pending |\n| Плановый | pending |")
    assert out == expected


@pytest.mark.parametrize(
    "comment",
    [
        "<!--\n## Итоги\n-->",
        "Заметка <!--\n## Итоги\n-->",
        "<!--\n\n## Итоги\n\n-->",
        "<!-- ## Итоги\nещё строка -->",
        "<!--\n## Итоги\n--> хвост",
    ],
    ids=["own-lines", "starts-mid-line", "blank-lines-inside", "heading-on-the-first-line", "text-after-the-end"],
)
def test_a_facts_heading_in_a_comment_does_not_make_a_section(tmp_path, comment):
    # Before the comment was read, «## Итоги» in it replaced «## План» and the plan table was facts.
    weekplan = _weekplan(
        tmp_path, f"## План\n\n{comment}\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW


def test_a_table_inside_a_comment_is_no_candidate(tmp_path):
    # Both tables sit under the same «План»: the commented one comes first and used to win.
    commented = "<!--\n| РП | Статус |\n| --- | --- |\n| Старый | done |\n-->\n"
    weekplan = _weekplan(
        tmp_path, "## План\n\n" + commented + "\n| РП | Статус |\n| --- | --- |\n| Плановый | pending |\n"
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    out = weekplan.read_text(encoding="utf-8")
    assert commented in out, "the commented table must stay untouched"
    assert "| Старый | done |\n-->\n\n| РП | Статус |\n| --- | --- |\n| **Новый РП**" in out


@pytest.mark.parametrize(
    "comment",
    ["<!-- </details> -->", "<!--\n</details>\n-->"],
    ids=["one-line", "own-lines"],
)
def test_a_closing_tag_in_a_comment_does_not_close_the_block(tmp_path, comment):
    spare = "<details><summary>Резерв</summary>\n\n" + SPARE_TABLE + "\n</details>\n\n"
    plan = (
        f"<details open>\n<summary><b>План на неделю W40</b></summary>\n{comment}\n\n"
        + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW + "\n</details>\n"
    )
    weekplan = _weekplan(tmp_path, spare + plan)

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW


def test_an_opening_tag_in_a_comment_opens_no_block(tmp_path):
    weekplan = _weekplan(
        tmp_path,
        "<details open>\n<summary><b>План на неделю W40</b></summary>\n"
        "<!-- <details><summary>Итоги</summary> -->\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW + "\n</details>\n",
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW


def test_an_unclosed_comment_swallows_the_rest_of_the_file(tmp_path):
    _assert_refused(tmp_path, "<!-- незакрытый\n\n## План\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW)


@pytest.mark.parametrize(
    "header, separator, expected",
    [
        ("| РП | Статус | <!-- note --> |", "|---|---|---|", "| **Новый РП** — [описание] | pending | — |"),
        ("| РП | <!-- a | b --> | Статус |", "|---|---|---|", "| **Новый РП** — [описание] | — | pending |"),
        ("| <!-- # --> РП | Статус |", "|---|---|", "| **Новый РП** — [описание] | pending |"),
    ],
    ids=["comment-in-a-cell", "pipe-in-the-comment", "comment-before-a-name"],
)
def test_a_comment_inside_a_table_row_leaves_a_table_row(tmp_path, header, separator, expected):
    weekplan = _weekplan(tmp_path, f"{header}\n{separator}\n")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавлена" in result.stdout
    assert _row_below(weekplan, separator) == expected


def test_a_comment_between_the_header_and_the_separator_makes_no_table(tmp_path):
    # An HTML block between them: not a table in GFM either.
    _assert_refused(tmp_path, "## План\n\n| РП | Статус |\n<!-- c -->\n| --- | --- |\n| 1 | x |\n")


def test_a_comment_that_starts_a_line_is_hidden_with_its_closing_line(tmp_path):
    # An HTML block ends on the line with the `-->`, and what follows it there is part of it.
    _assert_refused(tmp_path, "## План\n\n<!-- c\n--> | РП | Статус |\n| --- | --- |\n| 1 | x |\n")


def test_what_follows_an_inline_comment_is_read(tmp_path):
    weekplan = _weekplan(tmp_path, "## План\n\nтекст <!-- c\n--> | РП | Статус |\n| --- | --- |\n| 1 | x |\n")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _row_below(weekplan, "| --- | --- |") == "| **Новый РП** — [описание] | pending |"


@pytest.mark.parametrize(
    "code",
    [
        "```html\n<!--\n```\n",
        "~~~\n<!-- ## Итоги\n~~~\n",
        "Маркер `<!--` открывает комментарий.\n",
        "Маркер ``<!-- и `код` ``.\n",
    ],
    ids=["fenced", "tilde-fenced", "inline-code", "double-backticks"],
)
def test_a_comment_start_in_code_is_text(tmp_path, code):
    weekplan = _weekplan(tmp_path, f"## План\n\n{code}\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW)

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW


def test_a_fence_in_a_comment_opens_no_code_block(tmp_path):
    # The comment is not scanned for markup, fences included: the table below it is no code.
    weekplan = _weekplan(
        tmp_path, "## План\n\n<!--\n```\n-->\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW


def test_a_comment_in_a_list_item_hides_its_tags(tmp_path):
    weekplan = _weekplan(
        tmp_path,
        "- <!--\n  <details><summary>Итоги</summary>\n  -->\n\n## План недели\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW,
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW


def test_a_comment_in_a_quote_opens_no_zone(tmp_path):
    # The quoted heading used to open a zone and the table after it was left to the pilot.
    weekplan = _weekplan(
        tmp_path, "> <!--\n> ## Заметки\n> -->\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW


def test_comments_in_a_crlf_weekplan_are_hidden_too(tmp_path):
    weekplan = tmp_path / "WeekPlan W40.md"
    body = (
        "# WeekPlan W40\n\n## Итоги\n\n<!--\n## План\n-->\n\n| РП | Статус |\n| --- | --- |\n| Старый итог | done |\n\n"
        "## План\n\n| РП | Статус |\n| --- | --- |\n| Плановый | pending |\n"
    )
    weekplan.write_bytes(body.replace("\n", "\r\n").encode("utf-8"))

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    lines = weekplan.read_bytes().decode("utf-8").split("\n")
    row = next(i for i, ln in enumerate(lines) if "**Новый РП**" in ln)
    assert lines[row + 1].startswith("| Плановый"), "the row went into the plan table"


# --- the order of the stages: code, comments, tags, headings, table rows --------------------------------------
# An earlier stage takes its lines first and a later one reads only what is left (the table is in the comment
# of create-wp.sh above the stages). Every pair of stages has a test in which the earlier stage takes the line
# and a control in which it does not, so the outcome tells which stage got the line. Two tables tell where the
# row went: «A» is the one with the row «Первая», «B» the one with the row «Вторая».

ROW_A = "| Первая | pending |"
ROW_B = "| Вторая | pending |"
TABLE_A = f"| РП | Статус |\n| --- | --- |\n{ROW_A}\n"
TABLE_B = f"| РП | Статус |\n| --- | --- |\n{ROW_B}\n"


def _landing(tmp_path, body):
    """Where the row went: «A», «B», or «none» when the writer refused and left the file alone."""
    weekplan = _weekplan(tmp_path, body)
    original = weekplan.read_text(encoding="utf-8").splitlines()

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    lines = weekplan.read_text(encoding="utf-8").splitlines()
    added = [i for i, ln in enumerate(lines) if "**Новый РП**" in ln]
    if not added:
        assert lines == original and "добавить вручную" in result.stderr
        return "none"
    assert len(added) == 1 and lines[: added[0]] + lines[added[0] + 1 :] == original, "one row, nothing else"
    return {ROW_A: "A", ROW_B: "B"}[lines[added[0] + 1].strip()]  # a table in a list item is indented


CODE_FORMS = ["fenced", "tilde-fenced", "indented", "tab", "list-item", "inline"]
BLOCK_FORMS = CODE_FORMS[:-1]  # the forms a block of several lines can take


def _as_code(form, text):
    """The lines of text as the code stage takes them; «list-item» is four columns beyond «- Пункт»."""
    lines = text.rstrip("\n").split("\n")
    if form == "inline":
        return "Пример: `" + " ".join(lines) + "`\n"
    if form in ("fenced", "tilde-fenced"):
        fence = "```" if form == "fenced" else "~~~"
        return fence + "\n" + "\n".join(lines) + "\n" + fence + "\n"
    prefix = {"indented": "    ", "tab": "\t", "list-item": "      "}[form]
    code = "".join(prefix + ln + "\n" for ln in lines)
    return "- Пункт\n\n" + code if form == "list-item" else code


def _plan_block(example):
    """A «Резерв» block, then the plan block holding the example: tags read from it reshape the plan block."""
    return (
        "<details><summary>Резерв</summary>\n\n" + TABLE_A + "\n</details>\n\n"
        "<details open>\n<summary><b>План на неделю W40</b></summary>\n\n" + example + "\n\n" + TABLE_B
        + "\n</details>\n"
    )


COMMENT_BODY = "<!-- пояснение -->"
CODE_THEN_COMMENT = "## План\n\n{opener}\n\n## Итоги\n\n" + COMMENT_BODY + "\n\n" + TABLE_A + "\n## План\n\n" + TABLE_B


@pytest.mark.parametrize("form", CODE_FORMS)
def test_stage_code_takes_the_line_before_comments(tmp_path, form):
    # The reviewer's input: `<!--` in a code block is text. Read as a comment it swallowed «## Итоги» up to
    # the `-->` of the next comment, both tables got the ancestor «План» and the first one, facts, won.
    body = CODE_THEN_COMMENT.replace("{opener}", _as_code(form, "<!--").rstrip("\n"))
    assert _landing(tmp_path, body) == "B"


@pytest.mark.parametrize(
    "opener",
    ["<!--", "   <!--", "Текст\n    <!--", "- Пункт\n\n    <!--", "- Пункт\n\n\t<!--"],
    ids=["column-zero", "three-spaces", "right-after-a-paragraph", "two-beyond-a-list-item", "tab-in-a-list-item"],
)
def test_stage_comments_read_what_code_leaves(tmp_path, opener):
    # Control: the same `<!--` is no code (a margin of three, a paragraph that goes on, a list item that
    # holds the line) and opens the comment that hides «## Итоги»: the first table is then as good as the second.
    assert _landing(tmp_path, CODE_THEN_COMMENT.replace("{opener}", opener)) == "A"


def test_indented_code_may_follow_a_comment_line(tmp_path):
    # An HTML block ends on the line of its `-->`: the next indented line is code again.
    body = CODE_THEN_COMMENT.replace("{opener}", COMMENT_BODY + "\n    <!--")
    assert _landing(tmp_path, body) == "B"


TAG_EXAMPLES = ["<details><summary>Итоги</summary>", "</details>"]


@pytest.mark.parametrize("example", TAG_EXAMPLES, ids=["opening-tag", "closing-tag"])
@pytest.mark.parametrize("form", CODE_FORMS)
def test_stage_code_takes_the_line_before_tags(tmp_path, form, example):
    # Read as markup the opening tag names a block «Итоги» (the plan table is then facts) and the closing
    # one ends the plan block early (the plan table loses its «План» title): the row left the plan block.
    assert _landing(tmp_path, _plan_block(_as_code(form, example).rstrip("\n"))) == "B"


@pytest.mark.parametrize("example, expected", [(TAG_EXAMPLES[0], "A"), (TAG_EXAMPLES[1], "none")], ids=["opening-tag", "closing-tag"])
def test_stage_tags_read_what_code_leaves(tmp_path, example, expected):
    # Control: the same tag on a line of its own is markup.
    assert _landing(tmp_path, _plan_block(example)) == expected


@pytest.mark.parametrize("form", BLOCK_FORMS)
def test_stage_code_takes_the_line_before_headings(tmp_path, form):
    assert _landing(tmp_path, "## План\n\n" + _as_code(form, "## Итоги") + "\n" + TABLE_A) == "A"


def test_stage_headings_read_what_code_leaves(tmp_path):
    # Control: the heading of the same text, not in code, makes the table below it facts.
    assert _landing(tmp_path, "## План\n\n## Итоги\n\n" + TABLE_A) == "none"


@pytest.mark.parametrize("form", BLOCK_FORMS)
def test_stage_code_takes_the_line_before_table_rows(tmp_path, form):
    assert _landing(tmp_path, "## План\n\n" + _as_code(form, TABLE_A) + "\n" + TABLE_B) == "B"


def test_stage_table_rows_read_what_code_leaves(tmp_path):
    # Control: the table that is no code is the first of two under the same «План»: it wins the tie.
    assert _landing(tmp_path, "## План\n\n" + TABLE_A + "\n" + TABLE_B) == "A"


COMMENT_FORMS = {
    "one-line": "<!-- {} -->",
    "own-lines": "<!--\n{}\n-->",
    "starts-mid-line": "Заметка <!--\n{}\n-->",
    "text-after-the-end": "<!--\n{}\n--> хвост",
}


@pytest.mark.parametrize("example", TAG_EXAMPLES, ids=["opening-tag", "closing-tag"])
@pytest.mark.parametrize("form", COMMENT_FORMS)
def test_stage_comments_take_the_line_before_tags(tmp_path, form, example):
    assert _landing(tmp_path, _plan_block(COMMENT_FORMS[form].replace("{}", example))) == "B"


@pytest.mark.parametrize("example, expected", [(TAG_EXAMPLES[0], "A"), (TAG_EXAMPLES[1], "none")], ids=["opening-tag", "closing-tag"])
def test_stage_tags_read_what_comments_leave(tmp_path, example, expected):
    # Control: without the comment marks the tag is markup. A comment around the tag on the same line
    # leaves the rest of the line alone: «Заметка <!-- x --> <details>...» opens the block.
    assert _landing(tmp_path, _plan_block(example)) == expected
    assert _landing(tmp_path, _plan_block("Заметка <!-- x --> " + example)) == expected


@pytest.mark.parametrize("form", COMMENT_FORMS)
def test_stage_comments_take_the_line_before_headings(tmp_path, form):
    assert _landing(tmp_path, "## План\n\n" + COMMENT_FORMS[form].replace("{}", "## Итоги") + "\n\n" + TABLE_A) == "A"


def test_stage_headings_read_what_comments_leave(tmp_path):
    # Control: a heading with a comment after it on the same line is the heading.
    assert _landing(tmp_path, "## План\n\n## Итоги <!-- x -->\n\n" + TABLE_A) == "none"


@pytest.mark.parametrize("form", ["own-lines", "starts-mid-line"])
def test_stage_comments_take_the_line_before_table_rows(tmp_path, form):
    body = "## План\n\n" + COMMENT_FORMS[form].replace("{}", TABLE_A.rstrip("\n")) + "\n\n" + TABLE_B
    assert _landing(tmp_path, body) == "B"


def test_stage_table_rows_read_what_comments_leave(tmp_path):
    # Control: a comment above the table takes nothing of it: the first of two tables under «План» wins.
    assert _landing(tmp_path, "## План\n\n<!-- x -->\n\n" + TABLE_A + "\n" + TABLE_B) == "A"


def test_a_fence_marker_left_of_a_comment_is_text_not_code(tmp_path):
    # What follows the `-->` is text, not the start of a code block: the stages see one mask. The code
    # stage used to take the marker for a fence of its own, after the comment stage had skipped it.
    assert _landing(tmp_path, "## План\n\nтекст <!--\n--> ```\n\n" + TABLE_A) == "A"


@pytest.mark.parametrize("example", TAG_EXAMPLES, ids=["opening-tag", "closing-tag"])
def test_a_code_span_ends_at_a_run_of_the_same_length(tmp_path, example):
    # One span of two backticks holds a lone backtick and the tag: it ends at the next run of exactly two.
    assert _landing(tmp_path, _plan_block("Пример: ``a `x " + example + " ``")) == "B"


@pytest.mark.parametrize(
    "example, expected", [(TAG_EXAMPLES[0], "A"), (TAG_EXAMPLES[1], "none")], ids=["opening-tag", "closing-tag"]
)
def test_a_lone_backtick_protects_no_tag(tmp_path, example, expected):
    # A backtick with no closing one on its line is plain text: it opens no code span.
    assert _landing(tmp_path, _plan_block("Одиночная ` кавычка " + example)) == expected


def test_a_lone_backtick_protects_no_comment(tmp_path):
    body = "## План\n\nОдиночная ` кавычка <!--\n## Итоги\n-->\n\n" + TABLE_A
    assert _landing(tmp_path, body) == "A"


@pytest.mark.parametrize(
    "summary",
    ["<summary>`План на неделю W40`</summary>", "<summary>`План на неделю W40`\n</summary>"],
    ids=["one-line", "title-then-closing-line"],
)
def test_a_title_in_a_code_span_is_still_the_title(tmp_path, summary):
    # A code span only keeps the tags in it from being read: its text is part of the title.
    spare = "<details><summary>Резерв</summary>\n\n" + TABLE_A + "\n</details>\n\n"
    plan = "<details open>\n" + summary + "\n\n" + TABLE_B + "\n</details>\n"
    assert _landing(tmp_path, spare + plan) == "B"


SUMMARY_TITLE = "<details open>\n<summary>План недели{}\n</summary>\n\n"


def test_stage_tags_take_the_title_lines_before_headings(tmp_path):
    # The lines of a <summary> title are text: the title is «План недели ## Резерв», its table is as near to
    # «План» as the table of the plain «План на неделю» section, and the first one wins.
    body = SUMMARY_TITLE.replace("{}", "\n## Резерв") + TABLE_A + "\n</details>\n\n## План на неделю\n\n" + TABLE_B
    assert _landing(tmp_path, body) == "A"


def test_stage_headings_read_what_tags_leave(tmp_path):
    # Control: the same line after the title is a heading, one step between the table and «План».
    body = SUMMARY_TITLE.replace("{}", "") + "## Резерв\n\n" + TABLE_A + "\n</details>\n\n## План на неделю\n\n" + TABLE_B
    assert _landing(tmp_path, body) == "B"


def _hash_row_table(container, hashed):
    """A table whose header is `# | РП | Статус |` (a heading) when hashed, a header row when not."""
    mark = "# " if hashed else ""
    if container == "list":
        return f"- Пункт\n  {mark}| РП | Статус |\n  | --- | --- |\n  {ROW_A}\n"
    if container == "quote":
        return f"> {mark}| РП | Статус |\n> | --- | --- |\n> | Цитата | pending |\n\n" + TABLE_A
    return f"{mark}| РП | Статус |\n| --- | --- |\n{ROW_A}\n"


@pytest.mark.parametrize("container", ["plain", "list", "quote"])
def test_stage_headings_take_the_line_before_table_rows(tmp_path, container):
    # `# | РП | Статус |` is a heading, not a header row: the table below it is no candidate (in a list item
    # or in a quote the heading opens a zone that covers the tables up to the next unindented heading).
    assert _landing(tmp_path, "## План\n\n" + _hash_row_table(container, True) + "\n## План\n\n" + TABLE_B) == "B"


@pytest.mark.parametrize("container", ["plain", "list", "quote"])
def test_stage_table_rows_read_what_headings_leave(tmp_path, container):
    # Control: without the hash the table is a candidate, the first of two under «План» (in a quote
    # the table after it, the quoted one is no candidate).
    body = "## План\n\n" + _hash_row_table(container, False) + "\n## План\n\n" + TABLE_B
    assert _landing(tmp_path, body) == "A"


@pytest.mark.parametrize(
    "where", ["above", "glued-above", "below", "between-separator-and-row"],
    ids=["above", "glued-above", "below", "between-separator-and-row"],
)
def test_pending_markers_do_not_break_the_seed_template(tmp_path, where):
    seed = SEED_WEEKPLAN.read_text(encoding="utf-8").splitlines()
    header = next(i for i, ln in enumerate(seed) if ln.startswith("| 🚦"))
    marker = "<!-- PENDING: week_context -->"
    if where == "above":
        seed[header:header] = [marker, ""]
    elif where == "glued-above":
        seed.insert(header, marker)
    elif where == "below":
        seed += ["", marker]
    else:
        seed.insert(header + 2, marker)
    weekplan = tmp_path / "WeekPlan W1.md"
    weekplan.write_text("\n".join(seed) + "\n", encoding="utf-8")

    result = _add_to_weekplan(weekplan, num="1", title="Первый РП", priority="P1", budget="2h")

    assert result.returncode == 0, result.stderr
    assert "добавлена" in result.stdout
    lines = weekplan.read_text(encoding="utf-8").splitlines()
    assert lines[lines.index(PLAN_TABLE_SEPARATOR) + 1] == (
        "| 🔴 | 1 | **Первый РП** — [описание] | 2 | — | P1 | pending | [заполнить] |"
    )


@pytest.mark.parametrize(
    "marker",
    [None, "<!-- PENDING: week_context -->", "<!-- PENDING: bottleneck-week\nвторая строка маркера -->"],
    ids=["as-shipped", "one-line-marker", "two-line-marker"],
)
def test_the_day_open_weekplan_template_gets_the_row_in_its_plan_table(tmp_path, marker):
    template = _day_open_weekplan_template()
    if marker:
        # markers of the day-open scaffold in front of the plan table and between the blocks
        template = template.replace("| 🚦 | # | РП | h | Источник |", marker + "\n\n| 🚦 | # | РП | h | Источник |", 1)
        template = template.replace("</details>\n<details>", "</details>\n" + marker + "\n<details>")
    weekplan = tmp_path / "WeekPlan W40.md"
    weekplan.write_text(template, encoding="utf-8")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавлена" in result.stdout
    lines = weekplan.read_text(encoding="utf-8").splitlines()
    assert lines[lines.index(PLAN_TABLE_SEPARATOR) + 1] == NEW_ROW
    # nothing else of the template changed: the file is the template plus the one row
    assert len(lines) == len(template.splitlines()) + 1


def test_unplanned_section_is_not_the_plan(tmp_path):
    # «Внеплановые» contains «план» as a substring, not as a word.
    weekplan = _weekplan(
        tmp_path,
        "## Внеплановые РП\n\n" + SPARE_TABLE + "\n## План недели\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW,
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    head, tail = weekplan.read_text(encoding="utf-8").split("## План недели")
    assert NEW_ROW in tail and "Новый РП" not in head


@pytest.mark.parametrize(
    "title, is_plan",
    [
        ("План недели W40", True),
        ("План на неделю", True),
        ("Плановые РП", True),
        ("Недельный план", True),
        ("Plan", True),
        ("Week Plan", True),
        ("Внеплановые РП", False),
        ("Неплановые задачи", False),
        ("Floorplan", False),
    ],
)
def test_plan_word_starts_a_word(tmp_path, title, is_plan):
    # Two candidates: a «План» title decides, without one there is nothing to prefer.
    other = SPARE_TABLE.replace("Запас", "Другой")
    weekplan = _weekplan(tmp_path, f"## {title}\n\n{SPARE_TABLE}\n## Резерв\n\n{other}")
    original = weekplan.read_text(encoding="utf-8")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    if is_plan:
        assert "добавлена" in result.stdout
        assert _first_row_below(weekplan, "| # | РП | Статус |") == "| 16 | **Новый РП** — [описание] | pending |"
    else:
        assert "добавить вручную" in result.stderr
        assert weekplan.read_text(encoding="utf-8") == original


def test_plan_section_beats_a_document_title_that_says_plan(tmp_path):
    # «# План недели W40» makes every table below a plan table; the table whose OWN section
    # is the plan must still win over «Резерв», which only inherits the word.
    weekplan = _weekplan(
        tmp_path,
        "## Резерв\n\n" + SPARE_TABLE + "\n## План недели\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW,
        title="План недели W40",
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    head, tail = weekplan.read_text(encoding="utf-8").split("## План недели")
    assert NEW_ROW in tail and "Новый РП" not in head


def test_nearest_plan_ancestor_wins_inside_one_block(tmp_path):
    # Both tables sit under the summary «План на неделю»; the second also has a «План» heading
    # of its own, which is nearer, while «Резерв» only inherits the summary.
    weekplan = _weekplan(
        tmp_path,
        "<details open>\n<summary><b>План на неделю W40</b></summary>\n\n"
        "### Резерв\n\n" + SPARE_TABLE + "\n### План на понедельник\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW
        + "\n</details>\n",
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    head, tail = weekplan.read_text(encoding="utf-8").split("### План на понедельник")
    assert NEW_ROW in tail and "Новый РП" not in head


@pytest.mark.parametrize(
    "header",
    [
        "| ID | Результат | Бюджет | Статус | P | Связанные РП |",
        "| # | РП-связки | Статус |",
        "| # | Название | Статус РП |",
        "| # | Название | Статус |",
        "| # | РП | Бюджет |",
        "| # | РП | Текущий Статус |",
        "| # | РП | Статусы |",
    ],
    ids=[
        "related-rp-column",
        "rp-with-suffix",
        "rp-only-inside-another-cell",
        "no-rp-column",
        "no-status-column",
        "status-not-leading",
        "status-longer-word",
    ],
)
def test_header_needs_an_exact_rp_cell_and_a_status_cell(tmp_path, header):
    separator = "|" + "---|" * (header.count("|") - 1) + "\n"
    weekplan = _weekplan(tmp_path, header + "\n" + separator + "| 1 | x | y |\n")
    original = weekplan.read_text(encoding="utf-8")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавить вручную" in result.stderr
    assert "добавлена" not in result.stdout
    assert weekplan.read_text(encoding="utf-8") == original


@pytest.mark.parametrize(
    "header, separator",
    [
        ("|  РП  |  Статус  |", "|------|----------|"),
        ("РП | Статус", "--- | ---"),
        ("| # | РП | Статус |", "|---|----|--------|"),
        # Real plans: the status column often carries a qualifier.
        ("| # | РП | Бюджет | Статус (на 3 июля) | Репо |", "|---|----|--------|---------------------|------|"),
        ("| # | РП | Статус на конец дня |", "|---|----|---------------------|"),
        ("| # | РП | Статус W13 |", "|---|----|------------|"),
    ],
    ids=["padded", "no-outer-pipes", "plain", "status-with-date", "status-end-of-day", "status-with-week"],
)
def test_header_cells_match_after_trimming(tmp_path, header, separator):
    weekplan = _weekplan(tmp_path, header + "\n" + separator + "\n| 1 | x | y |\n")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавлена" in result.stdout
    # The row must carry the VALUES, not just exist: the plan name and «pending» in the status column.
    row = _new_row_by_column(weekplan, header, separator)
    assert row["РП"] == "**Новый РП** — [описание]"
    assert next(value for name, value in row.items() if name.startswith("Статус")) == "pending"


@pytest.mark.parametrize(
    "header, expected",
    [
        ("| РП | Статус (на 3 июля) |", "| **Новый РП** — [описание] | pending |"),
        ("| # | РП | Бюджет | Статус W13 | Репо |", "| 16 | **Новый РП** — [описание] | — | pending | — |"),
        ("| РП | Статус | Статус (на 3 июля) |", "| **Новый РП** — [описание] | pending | pending |"),
        (
            "| 🚦 | # | РП | h | Источник | P | Статус на конец дня | Результат |",
            "| 🟡 | 16 | **Новый РП** — [описание] | 3 | — | P2 | pending | [заполнить] |",
        ),
    ],
    ids=["status-with-date", "status-with-week", "two-status-columns", "full-plan-header"],
)
def test_a_status_column_with_a_qualifier_is_filled_like_a_plain_one(tmp_path, header, expected):
    # Detection and filling share one column-name normalization: a header the detector
    # accepts must not get a dash in its status column.
    separator = "|" + "---|" * (header.count("|") - 1)
    weekplan = _weekplan(tmp_path, header + "\n" + separator + "\n")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавлена" in result.stdout
    lines = weekplan.read_text(encoding="utf-8").splitlines()
    assert lines[lines.index(separator) + 1] == expected


def test_a_table_with_a_related_rp_column_is_no_competitor(tmp_path):
    weekplan = _weekplan(
        tmp_path,
        "## Задачи недели\n\n" + PLAN_HEADER + PLAN_SEPARATOR + OLD_ROW + "\n## Сверка\n\n" + SVERKA_TABLE,
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert _first_row_below(weekplan, "| Источник | P | Статус |") == NEW_ROW
    assert _first_row_below(weekplan, "Связанные РП") == SVERKA_ROW


def test_two_candidates_without_a_plan_section_are_ambiguous(tmp_path):
    weekplan = _weekplan(
        tmp_path, "## Резерв\n\n" + SPARE_TABLE + "\n## Ожидание\n\n" + SPARE_TABLE
    )
    original = weekplan.read_text(encoding="utf-8")

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0
    assert "добавить вручную" in result.stderr
    assert "добавлена" not in result.stdout
    assert weekplan.read_text(encoding="utf-8") == original


@pytest.mark.parametrize(
    "separator",
    [
        "| --- | --- | --- | --- | --- | --- | --- | --- |\n",
        "|:---|---:|:---:|---|---|---|---|---|\n",
        "--- | --- | --- | --- | --- | --- | --- | ---\n",
    ],
    ids=["spaced", "aligned", "no-outer-pipes"],
)
def test_weekplan_separator_row_is_not_a_literal(tmp_path, separator):
    weekplan = _weekplan(tmp_path, PLAN_HEADER + separator + OLD_ROW)

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавлена" in result.stdout
    lines = weekplan.read_text(encoding="utf-8").splitlines()
    assert lines[lines.index(separator.rstrip("\n")) + 1] == NEW_ROW


def test_weekplan_layout_shipped_in_seed(tmp_path):
    weekplan = tmp_path / "WeekPlan W1.md"
    weekplan.write_text(SEED_WEEKPLAN.read_text(encoding="utf-8"), encoding="utf-8")

    result = _add_to_weekplan(weekplan, num="1", title="Первый РП", priority="P1", budget="2h")

    assert result.returncode == 0, result.stderr
    lines = weekplan.read_text(encoding="utf-8").splitlines()
    first_row = lines[[i for i, ln in enumerate(lines) if ln.startswith("|---")][0] + 1]
    assert first_row == "| 🔴 | 1 | **Первый РП** — [описание] | 2 | — | P1 | pending | [заполнить] |"


@pytest.mark.parametrize(
    "separator",
    ["| --- | --- | --- | --- | --- | --- |\n", "|---|---|----------|----|------|--------|\n"],
    ids=["spaced", "compact"],
)
def test_registry_separator_row_is_not_a_literal(tmp_path, separator):
    registry = tmp_path / "WP-REGISTRY.md"
    registry.write_text(
        "# WP-REGISTRY\n\n| # | P | Название | Ст | Репо | Бюджет |\n" + separator
        + "| 8 | P3 | **Существующий РП** | ✅ | — | 5h |\n",
        encoding="utf-8",
    )

    result = _add_to_registry(registry)

    assert result.returncode == 0, result.stderr
    lines = registry.read_text(encoding="utf-8").splitlines()
    assert lines[lines.index(separator.rstrip("\n")) + 1] == (
        "| 16 | P2 | **Новый РП** | ⏳ | DS-strategy/inbox/WP-016/ | 3h |"
    )


def test_create_wp_end_to_end_lands_in_plan_table(tmp_path):
    """The real script: spaced REGISTRY separator, day summary first in the WeekPlan."""
    strategy = tmp_path / "DS-strategy"
    for sub in ("docs", "inbox", "current", "archive/wp-contexts"):
        (strategy / sub).mkdir(parents=True)
    (strategy / "docs" / "WP-REGISTRY.md").write_text(
        "# WP-REGISTRY\n\n| # | P | Название | Ст | Репо | Бюджет |\n"
        "| --- | --- | --- | --- | --- | --- |\n"
        "| 8 | P3 | **Существующий РП** | ✅ | — | 5h |\n",
        encoding="utf-8",
    )
    weekplan = strategy / "current" / "WeekPlan W40.md"
    weekplan.write_text("# WeekPlan W40\n\n" + DAY_SUMMARY + PLAN_SECTION, encoding="utf-8")
    home, tmp = tmp_path / "home", tmp_path / "tmp"
    home.mkdir()
    tmp.mkdir()
    env = {
        "IWE_ROOT": str(tmp_path),
        "HOME": str(home),
        "TMPDIR": str(tmp),
        "PATH": f"{Path(sys.executable).parent}:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
    }

    # --no-artifactor-check: the Artifactor Gate is covered by test_create_wp_artifactor_gate.sh
    result = subprocess.run(
        [
            "bash", str(CREATE_WP), "--title", "Новый РП", "--budget", "3h", "--priority", "P2",
            "--verification-class", "closed-loop", "--no-consent-check", "--no-artifactor-check",
        ],
        capture_output=True, text=True, env=env,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert "WeekPlan: строка WP-9 добавлена" in result.stdout
    summary_part, plan_part = weekplan.read_text(encoding="utf-8").split("План на неделю W40")
    assert "Новый РП" not in summary_part
    assert "| 🟡 | 9 | **Новый РП** — [описание] | 3 | — | P2 | pending | [заполнить] |" in plan_part
    registry = (strategy / "docs" / "WP-REGISTRY.md").read_text(encoding="utf-8")
    assert "| 9 | P2 | **Новый РП** | ⏳ | DS-strategy/inbox/WP-009/ | 3h |" in registry
