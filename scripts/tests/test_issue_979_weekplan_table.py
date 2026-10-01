"""
Regression for issue #979: create-wp.sh must put the new WP row into the plan
table of the WeekPlan, not into the first table that merely has «РП» and
«Статус» in its header.

After a day close a WeekPlan may start with an «Итоги дня» block holding
`| РП | Что сделано | Статус |`; the old writer took that table, so the rows of
new WPs landed in the summary of the past day, with dashes in every column the
summary does not share with the plan. The writer now remembers the nearest
`<summary>` / markdown heading above each table, skips tables under
«Итог / Сводк / Summary», prefers a section titled «План», falls back to the only
remaining candidate and otherwise refuses to guess (warning, nothing written).

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


def _weekplan(tmp_path: Path, body: str) -> Path:
    path = tmp_path / "WeekPlan W40.md"
    path.write_text("# WeekPlan W40\n\n" + body, encoding="utf-8")
    return path


def _first_row_below(weekplan: Path, header_fragment: str) -> str:
    """First data row of the table whose header line contains header_fragment."""
    lines = weekplan.read_text(encoding="utf-8").splitlines()
    header = next(i for i, ln in enumerate(lines) if header_fragment in ln)
    return lines[header + 2]


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
        "<details><summary><b>Стратегическая сверка</b></summary>\n\n"
        "| ID | Результат | Бюджет | Статус | P | Связанные РП |\n"
        "|----|-----------|--------|--------|---|--------------|\n"
        "| R1 | ... | ... | ... | P3 | WP-7 |\n"
        "\n</details>\n",
    )

    result = _add_to_weekplan(weekplan)

    assert result.returncode == 0, result.stderr
    assert "добавлена" in result.stdout
    assert _first_row_below(weekplan, "| Дедлайн | Репо |") == (
        "| 🟡 | 16 | **Новый РП** — [описание] | 3 | pending | — | — |"
    )
    assert _first_row_below(weekplan, "Связанные РП") == "| R1 | ... | ... | ... | P3 | WP-7 |"


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
