#!/usr/bin/env python3
"""Tests for day-open-week-sync-patch.py (template release 0.43): the day
table is rebuilt from the week plan; nothing the model put in the table
disappears silently; every mismatch is a visible line in the plan."""

import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "day-open-week-sync-patch.py"
BUDGET = ROOT / "scripts" / "day-open-budget-patch.py"
SEED_SCRIPT = ROOT / "seed" / "strategy" / "scripts" / "day-open-week-sync-patch.py"

WEEKPLAN = """<details open>
<summary><b>План на неделю W44</b></summary>

| 🚦 | # | РП | h | Источник | P | Статус | Результат недели |
|----|---|-----|---|----------|---|--------|------------------|
| 🟡 | 581 | **MCP Open Aisystant** | 25 | В1 · O26 | P3 | in_progress | — |
| 🟡 | 561 | **Конвейер закрытия** | 10 | Н1 · O23 | P1 | in_progress | — |

</details>
"""

DAYPLAN = """---
week: W44
---
<details>
<summary><b>🚨 Срочное</b></summary>

— нет срочного (зелёный день).

</details>

<details open>
<summary><b>План на сегодня</b></summary>

| 🚦 | ТВС | # | РП | h | Статус |
|----|-----|---|-----|---|--------|
| 🔴 | С | 561 | **Конвейер закрытия** | 16 | in_progress |
| 🔴 | С | 530 | **Конвейер параллельных сессий** | 12h | in_progress |

**Carry-over из Day Close вчера (2026-10-26):**
  - РП-581 — план фаз
  - РП-7 — остатки issue
  *Закрыто: 2026-10-26 20:55*

</details>
"""

# 28.10 shape: the LLM fill wrote «Н» (not in the В/Т/С legend) on every row.
DAYPLAN_OFF_LEGEND = (DAYPLAN
                      .replace("| 🔴 | С | 561 |", "| 🔴 | Н | 561 |")
                      .replace("| 🔴 | С | 530 |", "| 🔴 | Т | 530 |"))
assert "| 🔴 | Н | 561 |" in DAYPLAN_OFF_LEGEND and "| 🔴 | Т | 530 |" in DAYPLAN_OFF_LEGEND

ATTENTION = "\n<details>\n<summary><b>Требует внимания</b></summary>\n\n— нет сигналов, требующих внимания.\n\n</details>\n"
WEEKPLAN_NAME = "WeekPlan W44 2026-10-26.md"


def replaced(text: str, old: str, new: str) -> str:
    """str.replace that fails loudly when the fixture drifted and `old` is gone."""
    assert old in text, f"fixture drift: {old!r} not found"
    return text.replace(old, new)


def plan_rows(text: str) -> dict:
    rows = {}
    for line in text.splitlines():
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) == 6 and cells[2].isdigit():
            rows[cells[2]] = cells
    return rows


def code_block_after(path: Path, marker: str) -> str:
    """The first ```markdown block after `marker` in a template document."""
    text = path.read_text(encoding="utf-8")
    start = text.index("```markdown", text.index(marker)) + len("```markdown\n")
    return text[start:text.index("\n```", start)]


class PatchCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.dayplan = self.tmp / "DayPlan.md"
        self.priorities = self.tmp / "priorities.yaml"
        self.priorities.write_text("today:\n  - WP-561\n  - WP-530\n", encoding="utf-8")
        self.weekplan = self.tmp / WEEKPLAN_NAME
        self.config = self.tmp / "day-rhythm-config.yaml"
        card = self.tmp / "inbox" / "WP-7"
        card.mkdir(parents=True)
        (card / "WP-7.md").write_text("---\ntitle: 'Платформа: техдолг'\n---\n", encoding="utf-8")

    def tearDown(self):
        self._tmp.cleanup()

    def run_patch(self, weekplan_text: str | None = WEEKPLAN, dayplan_text: str | None = DAYPLAN,
                  script: Path = SCRIPT) -> str:
        if dayplan_text is not None:
            self.dayplan.write_text(dayplan_text, encoding="utf-8")
        weekplan_arg = ""
        if weekplan_text is not None:
            self.weekplan.write_text(weekplan_text, encoding="utf-8")
            weekplan_arg = str(self.weekplan)
        self.result = subprocess.run(
            [sys.executable, str(script), "--dayplan", str(self.dayplan), "--priorities", str(self.priorities),
             "--weekplan", weekplan_arg, "--inbox", str(self.tmp / "inbox"),
             "--day-rhythm-config", str(self.config)],
            check=True, capture_output=True, text=True,
        )
        return self.dayplan.read_text(encoding="utf-8")

    def rerun(self, priorities: str | None = None) -> str:
        if priorities is not None:
            self.priorities.write_text(priorities, encoding="utf-8")
        return self.run_patch(self.weekplan.read_text(encoding="utf-8"), None)


class WeekSyncPatchTest(PatchCase):
    def test_aligns_table_with_week_pool(self):
        out = self.run_patch()
        rows = plan_rows(out)
        self.assertEqual(rows["561"][4], "10")             # hours from the pool, not the card
        self.assertEqual(rows["561"][:2], ["🟡", "Т"])     # no emergency -> not «С»; pool light
        self.assertIn("вне плана недели", rows["530"][3])  # not in the pool -> marked
        self.assertEqual(rows["581"][1:5], ["В", "581", "**MCP Open Aisystant**", "25"])
        self.assertEqual(rows["7"][3], "Платформа: техдолг · вне плана недели, часы не заданы")
        self.assertEqual(rows["7"][4], "0")                # never «?»: the budget patch must not skip
        self.assertEqual(self.result.stdout.strip(), "hours-scope=week")

    def test_off_legend_tvs_normalized_and_model_light_kept_outside_pool(self):
        rows = plan_rows(self.run_patch(WEEKPLAN, DAYPLAN_OFF_LEGEND))
        self.assertEqual(rows["561"][:2], ["🟡", "Т"])     # «Н» is not in the legend; pool light
        self.assertEqual(rows["530"][:2], ["🔴", "Т"])     # no pool light -> the model's light stays

    def test_red_in_week_plan_is_never_downgraded(self):
        weekplan = replaced(WEEKPLAN, "| 🟡 | 561 |", "| 🔴 | 561 |")
        rows = plan_rows(self.run_patch(weekplan))
        self.assertEqual(rows["561"][:2], ["🔴", "Т"])     # critical priority, no emergency needed

    def test_emergency_template_header_is_recognized(self):
        emergency = replaced(replaced(DAYPLAN, "<summary><b>🚨 Срочное</b></summary>",
                                      "<summary><b>🚨 Срочное — упал smoke</b></summary>"),
                             "— нет срочного (зелёный день).", "- 🔴 упал smoke WP-561")
        rows = plan_rows(self.run_patch(WEEKPLAN, emergency))
        self.assertEqual(rows["561"][:2], ["🔴", "С"])

    def test_empty_and_off_legend_tvs_on_branch_row_become_v(self):
        text = replaced(DAYPLAN, "| 🔴 | С | 530 |",
                        "| 🟡 |  | 581 | **MCP Open Aisystant** | 25 | in_progress |\n| 🔴 | Н | 530 |")
        rows = plan_rows(self.run_patch(WEEKPLAN, text))
        self.assertEqual(rows["581"][:2], ["🟡", "В"])     # empty ТВС, pool direction В1
        self.assertEqual(rows["530"][1], "Т")

    def test_emergency_marks_every_wp_named_in_urgent_block(self):
        emergency = replaced(DAYPLAN, "— нет срочного (зелёный день).", "- 🔴 упал smoke РП-561 и WP-530")
        out = self.run_patch(WEEKPLAN, emergency)
        self.assertIn("| 🔴 | С | 561 |", out)
        self.assertIn("| 🔴 | С | 530 |", out)
        self.assertIn("| 🟡 | В | 581 |", out)                # not named -> stays an ordinary row

    def test_urgent_block_ids_are_normalized_like_pool_keys(self):
        emergency = replaced(DAYPLAN, "— нет срочного (зелёный день).", "- 🔴 упал smoke WP-0561")
        out = self.run_patch(WEEKPLAN, emergency)
        self.assertIn("| 🔴 | С | 561 |", out)
        self.assertNotIn("| 0561 |", out)

    def test_emergency_without_wp_number_marks_nobody_and_says_so(self):
        emergency = replaced(DAYPLAN, "— нет срочного (зелёный день).", "- 🔴 упал smoke")
        out = self.run_patch(WEEKPLAN, emergency + ATTENTION)
        self.assertNotIn("| С |", out)
        self.assertIn("в «Срочное» нет номера дела — метка «С» никому не поставлена", out)

    def test_urgent_wp_without_card_and_pool_row_is_named(self):
        emergency = replaced(DAYPLAN, "— нет срочного (зелёный день).", "- 🔴 упал smoke WP-999")
        out = self.run_patch(WEEKPLAN, emergency + ATTENTION)
        self.assertIn("в «Срочное» названо дело без карточки и без места в плане недели: WP-999", out)
        self.assertIn("| 🔴 | С | 999 |", out)

    def test_non_wp_rows_untouched(self):
        self_dev = "| 🔴 | Н | N | **Саморазвитие** | 1-2 | pending |"
        text = replaced(replaced(DAYPLAN, "| 🔴 | С | 561 |", "| ⚫ | Н | 561 |"),
                        "| 🔴 | С | 530 |", f"{self_dev}\n| 🟢 | В | 530 |")
        out = self.run_patch(WEEKPLAN, text)
        rows = plan_rows(out)
        self.assertEqual(rows["561"][:2], ["🟡", "Т"])     # 🚦/ТВС come from the pool, not the model
        self.assertEqual(rows["530"][:2], ["🟢", "Т"])     # not in the pool -> the model's light
        self.assertIn(self_dev, out)                       # no WP number -> kept as written

    def test_missing_columns_are_visible(self):
        text = DAYPLAN_OFF_LEGEND
        for old, new in (("| 🚦 | ТВС | # | РП | h | Статус |", "| ТВС | # | РП | h | Статус |"),
                         ("|----|-----|---|-----|---|--------|", "|-----|---|-----|---|--------|"),
                         ("| 🔴 | Н | 561 |", "| Н | 561 |"), ("| 🔴 | Т | 530 |", "| Т | 530 |")):
            text = replaced(text, old, new)
        out = self.run_patch(WEEKPLAN, text + ATTENTION)
        self.assertIn("- ⚠️ Сверка плана дня с неделей: в таблице дня нет колонок «🚦»", out)
        self.assertNotIn("нет сигналов, требующих внимания", out)   # no self-contradiction
        self.assertIn("| Т | 561 |", out)                  # the rest of the alignment still runs

    def test_missing_attention_block_still_visible(self):
        text = replaced(DAYPLAN_OFF_LEGEND, "| 🚦 | ТВС | # | РП | h | Статус |",
                        "| 🚦 | ТВС | # | РП | ч | Статус |")
        out = self.run_patch(WEEKPLAN, text)
        self.assertIn("- ⚠️ Сверка плана дня с неделей: в таблице дня нет колонок «h»", out)

    def test_rerun_after_normalization_changes_nothing(self):
        once = self.run_patch(WEEKPLAN, DAYPLAN_OFF_LEGEND + ATTENTION)
        self.assertEqual(self.rerun(), once)

    def test_own_red_line_cleared_after_recovery(self):
        self.run_patch(None)                              # degraded run: own 🔴 replaces «нет срочного»
        out = self.run_patch(WEEKPLAN, None)
        self.assertEqual(plan_rows(out)["561"][:2], ["🟡", "Т"])   # own line is not an emergency
        self.assertNotIn("План недели не прочитан", out)
        self.assertIn("— нет срочного (зелёный день).", out)

    def test_degraded_then_recovered_restores_urgent_block_exactly(self):
        emergency = replaced(replaced(DAYPLAN, "<summary><b>🚨 Срочное</b></summary>",
                                      "<summary><b>🚨 Срочное — упал smoke</b></summary>"),
                             "— нет срочного (зелёный день).", "| Что | Система |\n|---|---|\n| smoke | close |")
        commented = replaced(DAYPLAN, "— нет срочного (зелёный день).",
                             "<!-- note -->\n— нет срочного (зелёный день).")
        for start in (emergency, commented):
            with self.subTest(block=start[:200]):
                clean = self.run_patch(WEEKPLAN, start)
                self.run_patch(None, None)                # degraded run
                self.assertEqual(self.run_patch(WEEKPLAN, None), clean)

    def test_other_model_rows_stay_marked_at_the_end(self):
        text = replaced(DAYPLAN, "| 🔴 | С | 561 |", "| 🔴 | С | 999 | **Лишнее** | 5 | pending |\n| 🔴 | С | 561 |")
        out = self.run_patch(WEEKPLAN, text + ATTENTION)
        order = [line.split("|")[3].strip() for line in out.splitlines()
                 if line.startswith("|") and line.split("|")[3].strip().isdigit()]
        self.assertEqual(order, ["561", "530", "581", "7", "999"])   # priorities, carry-over, the rest
        self.assertEqual(plan_rows(out)["999"][3], "**Лишнее** · вне плана недели, часы не заданы")
        self.assertIn("оставлены с пометкой: WP-999", out)

    def test_pool_row_outside_priorities_stays_marked_not_today(self):
        weekplan = replaced(WEEKPLAN, "| 🟡 | 561 |",
                            "| 🟢 | 484 | **Автогенератор** | 6 | В2 · O1 | P2 | pending | — |\n| 🟡 | 561 |")
        text = replaced(DAYPLAN, "| 🔴 | С | 530 |", "| 🔴 | С | 484 | **Автогенератор** | 3 | x |\n| 🔴 | С | 530 |")
        rows = plan_rows(self.run_patch(weekplan, text + ATTENTION))
        self.assertEqual(rows["484"][:5], ["🟢", "В", "484", "**Автогенератор** · не в приоритетах дня", "6"])

    def test_mandatory_daily_rows_stay_unmarked(self):
        self.config.write_text("mandatory_daily_wps:\n  - wp: 999\n    min_minutes: 30\n"
                               "  - wp: 484\n  - category: content\n    min_count: 1\n", encoding="utf-8")
        weekplan = replaced(WEEKPLAN, "| 🟡 | 561 |",
                            "| 🟢 | 484 | **Автогенератор** | 6 | В2 · O1 | P2 | pending | — |\n| 🟡 | 561 |")
        mandatory = "| 🟢 | Т | 999 | **Техдолг** | 1 | pending |"
        text = replaced(DAYPLAN, "| 🔴 | С | 530 |",
                        f"{mandatory}\n| 🔴 | С | 484 | **Автогенератор** | 3 | x |\n| 🔴 | С | 530 |")
        out = self.run_patch(weekplan, text + ATTENTION)
        self.assertIn(mandatory, out)                      # outside the pool: as the model wrote it
        self.assertEqual(plan_rows(out)["484"][3:5], ["**Автогенератор**", "6"])   # in the pool: no mark
        self.assertNotIn("оставлены с пометкой", out)
        self.assertEqual(self.rerun(), out)

    def test_pool_light_is_used(self):
        weekplan = replaced(WEEKPLAN, "| 🟡 | 561 |", "| 🟢 | 561 |")
        rows = plan_rows(self.run_patch(weekplan))
        self.assertEqual(rows["561"][0], "🟢")

    def test_empty_priorities_keep_model_set(self):
        self.priorities.write_text("today: []\n", encoding="utf-8")
        out = self.run_patch(WEEKPLAN, replaced(DAYPLAN, "**Carry-over из Day Close вчера", "**Перенос") + ATTENTION)
        self.assertEqual(sorted(plan_rows(out)), ["530", "561"])
        self.assertNotIn("оставлены с пометкой", out)
        self.assertIn("состав таблицы взят из заготовки плана", out)

    def test_missing_priorities_file_is_not_an_error(self):
        self.priorities.unlink()
        out = self.run_patch(WEEKPLAN, DAYPLAN + ATTENTION)
        self.assertNotIn("🔴 Сверка", out)
        self.assertEqual(sorted(plan_rows(out)), ["530", "561", "581", "7"])
        self.assertIn("приоритеты дня не заданы — таблица собрана из вчерашнего переноса", out)
        self.assertIn("оставлены с пометкой: WP-561, WP-530", out)

    def test_only_the_today_key_is_read(self):
        self.priorities.write_text("phys_hours: 8\nweek:\n  - WP-484\ntoday:\n  - WP-561\n", encoding="utf-8")
        out = self.run_patch(WEEKPLAN, DAYPLAN + ATTENTION)
        self.assertNotIn("484", plan_rows(out))
        self.assertEqual(plan_rows(out)["561"][3], "**Конвейер закрытия**")

    def test_compact_dashboard_follows_rebuilt_table(self):
        dash = ("\n---COMPACT-DASHBOARD---\n**Сегодня (топ-7 по приоритету):**\n"
                "| 🔴 | Н 561 |\n| 🔴 | Н 999 |\n\n**Календарь:** —\n---END-COMPACT-DASHBOARD---\n")
        out = self.run_patch(WEEKPLAN, DAYPLAN_OFF_LEGEND + dash)
        block = out.split("---COMPACT-DASHBOARD---")[1].split("**Календарь:**")[0]
        self.assertIn("| 🟡 | 561 **Конвейер закрытия** |", block)
        self.assertNotIn("Н 561", block)
        self.assertNotIn("999", block)

    def test_table_without_number_column_is_left_alone(self):
        text = DAYPLAN
        for old, new in (("| 🚦 | ТВС | # | РП | h | Статус |", "| 🚦 | ТВС | РП | h | Статус |"),
                         ("|----|-----|---|-----|---|--------|", "|----|-----|-----|---|--------|"),
                         ("| 🔴 | С | 561 | **Конвейер закрытия** |", "| 🔴 | С | **WP-561 Конвейер закрытия** |"),
                         ("| 🔴 | С | 530 | **Конвейер параллельных сессий** |", "| 🔴 | С | **WP-530 сессии** |")):
            text = replaced(text, old, new)
        out = self.run_patch(WEEKPLAN, text + ATTENTION)
        self.assertIn("| 🔴 | С | **WP-561 Конвейер закрытия** |", out)   # untouched
        self.assertIn("нет колонки «#» — таблица не пересобрана", out)
        self.assertEqual(self.result.stdout.strip(), "hours-scope=day")

    def test_flat_card_title_is_found(self):
        (self.tmp / "inbox" / "WP-12-old.md").write_text("---\ntitle: Плоская карточка\n---\n", encoding="utf-8")
        self.priorities.write_text("today:\n  - WP-12\n", encoding="utf-8")
        rows = plan_rows(self.run_patch())
        self.assertEqual(rows["12"][3], "Плоская карточка · вне плана недели, часы не заданы")

    def test_duplicate_model_rows_are_named(self):
        text = replaced(DAYPLAN, "| 🔴 | С | 530 |", "| 🔴 | С | 561 | **дубль** | 1 | x |\n| 🔴 | С | 530 |")
        out = self.run_patch(WEEKPLAN, text + ATTENTION)
        self.assertEqual(sum(1 for line in out.splitlines() if line.startswith("|") and "| 561 |" in line), 1)
        self.assertIn("повторены строки дел — оставлено по одной: WP-561", out)

    def test_carry_over_formats_seen_in_archive(self):
        carry = ("  1. WP-581 — план фаз\n  - **РП-7** — остатки\n  - WP-561/WP-530 — такт\n"
                 "  - WP-999 — не взят (отложено: бюджет)\n")
        text = replaced(DAYPLAN, "  - РП-581 — план фаз\n  - РП-7 — остатки issue\n", carry)
        rows = plan_rows(self.run_patch(WEEKPLAN, text))
        self.assertEqual(sorted(rows), ["530", "561", "581", "7"])   # 999 is deferred

    def test_unreadable_carry_item_keeps_model_rows(self):
        text = replaced(replaced(DAYPLAN, "  - РП-7 — остатки issue\n", "  - доделать отчёт по пилоту\n"),
                        "| 🔴 | С | 530 |", "| 🔴 | С | 999 | **Модельное** | 2 | x |\n| 🔴 | С | 530 |")
        out = self.run_patch(WEEKPLAN, text + ATTENTION)
        self.assertIn("вне плана недели", plan_rows(out)["999"][3])
        self.assertIn("without a WP number: доделать отчёт по пилоту", self.result.stderr)

    def test_urgent_row_outside_priorities_survives_emergency(self):
        text = DAYPLAN
        for old, new in (("— нет срочного (зелёный день).", "- 🔴 упал smoke WP-999"),
                         ("| 🔴 | С | 561 |", "| 🟡 | Т | 561 |"),
                         ("| 🔴 | С | 530 |", "| 🔴 | С | 999 | **Аварийное** | 2 | x |\n| 🟡 | Т | 530 |")):
            text = replaced(text, old, new)
        out = self.run_patch(WEEKPLAN, text)
        first = next(line for line in out.splitlines() if line.startswith("| ") and "| 999 |" in line)
        self.assertTrue(first.startswith("| 🔴 | С | 999 |"))
        self.assertLess(out.index("| 999 |"), out.index("| 561 |"))   # urgent rows go first

    def test_russian_wp_id_and_placeholder_row(self):
        text = replaced(replaced(DAYPLAN, "| 🔴 | С | 561 |", "| 🔴 | С | РП-561 |"),
                        "| 🔴 | С | 530 |", "| 🔴 | С | NNN | **<!-- PENDING -->** | X | pending |\n| 🔴 | С | 530 |")
        out = self.run_patch(WEEKPLAN, text)
        self.assertNotIn("NNN", out)
        self.assertEqual(sum(1 for line in out.splitlines() if "561" in line and line.startswith("|")), 1)

    def test_free_text_priority_is_not_a_wp(self):
        self.run_patch()
        out = self.rerun("today:\n  - WP-561\n  - созвон в 15:00\n  - WP-530\n")
        self.assertNotIn("15", plan_rows(out))

    def test_stale_attention_lines_are_replaced_on_rerun(self):
        text = replaced(DAYPLAN, "| 🔴 | С | 530 |", "| 🔴 | С | 999 | **Лишнее** | 1 | x |\n| 🔴 | С | 530 |")
        self.run_patch(WEEKPLAN, text + ATTENTION)
        out = self.rerun("today:\n  - WP-561\n  - WP-530\n  - WP-999\n")
        self.assertNotIn("оставлены с пометкой", out)
        self.assertEqual(plan_rows(out)["999"][3], "**Лишнее** · вне плана недели, часы не заданы")
        self.assertIn("— нет сигналов, требующих внимания.", out)

    def test_priorities_with_title_suffix_and_dict_form(self):
        self.run_patch()
        out = self.rerun('today:\n  - "WP-561: Конвейер закрытия"\n  - WP-530: сессии\n  - 484\n')
        self.assertEqual(sorted(plan_rows(out)), ["484", "530", "561", "581", "7"])

    def test_rerun_keeps_marked_rows_identical(self):
        text = replaced(DAYPLAN, "| 🔴 | С | 530 |", "| 🔴 | С | 999 | **Лишнее** | 1 | x |\n| 🔴 | С | 530 |")
        once = self.run_patch(WEEKPLAN, text + ATTENTION)
        self.assertIn("оставлены с пометкой: WP-999", once)
        self.assertEqual(self.rerun(), once)

    def test_findings_without_attention_block_do_not_grow(self):
        text = replaced(DAYPLAN, "| 🚦 | ТВС | # | РП | h | Статус |", "| 🚦 | ТВС | # | РП | ч | Статус |")
        once = self.run_patch(WEEKPLAN, text)
        self.assertEqual(self.rerun(), once)

    def test_row_with_x_hours_is_not_a_placeholder(self):
        meeting = "| 🟡 | Т | — | **Встреча X** | X | pending |"
        text = replaced(DAYPLAN, "| 🔴 | С | 530 |", f"{meeting}\n| 🔴 | С | 530 |")
        self.assertIn(meeting, self.run_patch(WEEKPLAN, text))

    def test_budget_patch_counts_week_hours_after_sync(self):
        text = self.run_patch()
        self.dayplan.write_text(text.replace("</details>\n", "\n**Портфель в работе:** 47h\n\n</details>\n", 2),
                                encoding="utf-8")
        self.priorities.write_text("phys_hours: 8\ntoday:\n  - WP-561\n", encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(BUDGET), "--dayplan", str(self.dayplan),
             "--priorities", str(self.priorities), "--hours-scope", "week"],
            capture_output=True, text=True, check=True,
        )
        out = self.dayplan.read_text(encoding="utf-8")
        self.assertNotIn("не распознаны", out + result.stderr)
        self.assertIn("**Портфель в работе:** ~35h РП / ~56h физ в неделю", out)   # 10+25, 8 h x 7 days
        self.assertIn("сумма оценок РП на сегодня: ~10h", out)   # WP-561 found by its bare «#» number

    def test_degraded_rerun_adds_one_red_line(self):
        self.run_patch(None)
        out = self.run_patch(None, None)
        self.assertEqual(out.count("- 🔴 План недели не прочитан"), 1)
        self.assertEqual(self.result.stdout.strip(), "hours-scope=day")

    def test_broken_priorities_is_loud_and_exits_zero(self):
        self.priorities.write_text("today: [WP-561\n", encoding="utf-8")
        out = self.run_patch()
        self.assertEqual(self.result.returncode, 0)
        self.assertIn("- 🔴 Сверка плана дня с планом недели упала", out)
        self.assertEqual(plan_rows(out)["561"][4], "16")  # the model's table is published as is

    def test_rerun_changes_nothing(self):
        once = self.run_patch()
        self.assertEqual(self.rerun(), once)

    def test_missing_week_plan_is_loud_and_keeps_table(self):
        text = self.run_patch(None)
        self.assertIn("- 🔴 План недели не прочитан", text)
        self.assertNotIn("нет срочного", text)
        self.assertEqual(plan_rows(text)["561"][4], "16")  # table untouched

    def test_draft_week_plan_is_named(self):
        out = self.run_patch("---\ntype: week-plan\nstatus: draft\n---\n" + WEEKPLAN, DAYPLAN + ATTENTION)
        self.assertIn(f"план недели ({WEEKPLAN_NAME}) ещё черновик (status: draft)", out)
        self.assertEqual(plan_rows(out)["561"][4], "10")

    def test_seed_snapshot_behaves_the_same(self):
        main = self.run_patch(WEEKPLAN, DAYPLAN + ATTENTION)
        self.assertEqual(self.run_patch(WEEKPLAN, DAYPLAN + ATTENTION, script=SEED_SCRIPT), main)


class TemplateWeekPlanFormatsTest(PatchCase):
    """The WeekPlan shapes the template itself ships."""

    def test_main_template_format_is_read(self):
        sample = code_block_after(ROOT / ".claude/skills/day-open/templates.md", "## Шаблон WeekPlan")
        row = next(line for line in sample.splitlines() if line.startswith("| 🔴 | ... |"))
        weekplan = sample.replace(row, "\n".join((
            "| 🔴 | 561 | **Конвейер закрытия** — описание | ~10h | R1 | P1 | in_progress | Итог |",
            "| 🟢 | 581 | **MCP Open Aisystant** | 25 | carry | P3 | in_progress | Итог |",
        )))
        out = self.run_patch(weekplan, DAYPLAN + ATTENTION)
        rows = plan_rows(out)
        self.assertEqual(rows["561"][:5], ["🔴", "С", "561", "**Конвейер закрытия**", "10"])  # 🔴 kept, ТВС kept
        self.assertEqual(rows["530"][:2], ["🔴", "С"])     # no direction tokens -> the model's ТВС stays
        self.assertEqual(rows["581"][:2], ["🟢", "Т"])     # added row: pool light, «Т» by default
        self.assertNotIn("не найдена таблица дел", out)

    def test_heading_format_without_source_column_is_read(self):
        sample = code_block_after(ROOT / "memory/templates-dayplan.md", "## Шаблон WeekPlan")
        row = next(line for line in sample.splitlines() if line.startswith("| 🔴 | ... |"))
        weekplan = sample.replace(row, "| 🟡 | 561 | **Конвейер закрытия** | 10 | in_progress | R1 | Итог |")
        rows = plan_rows(self.run_patch(weekplan, DAYPLAN + ATTENTION))
        self.assertEqual(rows["561"][:5], ["🟡", "С", "561", "**Конвейер закрытия**", "10"])

    def test_session_prep_draft_without_hours_column_keeps_model_table(self):
        sample = code_block_after(ROOT / "roles/strategist/prompts/session-prep.md", "**Формат WeekPlan:**")
        self.assertIn("| # | РП | Бюджет | Статус |", sample)
        out = self.run_patch(sample, DAYPLAN + ATTENTION)
        self.assertIn("не найдена таблица дел", out)       # a yellow line, not a red one
        self.assertNotIn("- 🔴", out)
        self.assertEqual(plan_rows(out)["561"][:5], ["🔴", "С", "561", "**Конвейер закрытия**", "16"])
        self.assertEqual(self.result.stdout.strip(), "hours-scope=day")

    def test_seed_first_week_plan_keeps_model_table(self):
        seed = (ROOT / "seed/strategy/current/WeekPlan W1.md").read_text(encoding="utf-8")
        out = self.run_patch(seed, DAYPLAN + ATTENTION)
        self.assertIn("не найдена таблица дел", out)
        self.assertEqual(plan_rows(out)["530"][4], "12h")
        self.assertEqual(self.rerun(), out)


class PipelineWiringTest(unittest.TestCase):
    def test_step_runs_between_ledger_render_and_budget_in_both_pipelines(self):
        for pipeline in (ROOT / "scripts/day-open-pipeline.sh",
                         ROOT / "seed/strategy/scripts/day-open-pipeline.sh"):
            text = pipeline.read_text(encoding="utf-8")
            with self.subTest(pipeline=str(pipeline)):
                ledger = text.index('echo "=== 4.3. Ledger render ==="')
                week = text.index("day-open-week-sync-patch.py")
                budget = text.index('echo "=== 4.5. Budget patch ==="')
                self.assertLess(ledger, week)
                self.assertLess(week, budget)
                self.assertRegex(text, re.compile(r'--hours-scope "\$BUDGET_HOURS_SCOPE"'))


if __name__ == "__main__":
    unittest.main()
