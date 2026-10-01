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
lines, and one that is never closed swallows its block. Fenced and indented
(4+ columns, a tab counts to 4) code blocks are not markup. A table is a
candidate only when its header has the exact cell «РП» and a cell starting with
the word «Статус» («Статус (на 3 июля)» counts and is filled with «pending» like
the plain column, «Связанные РП» does not).

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


def test_header_row_starting_with_hash_is_not_a_section_title(tmp_path):
    # `# | ...` reads like a markdown heading, but it is a table header row: its
    # «Итог» column must not make the writer treat the table as a facts section.
    weekplan = _weekplan(
        tmp_path,
        "# | РП | Статус | Итог недели\n|---|----|--------|------------|\n| 7 | **Старый** | pending | — |\n",
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавлена" in result.stdout


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
    assert "Новый РП" in weekplan.read_text(encoding="utf-8")


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
