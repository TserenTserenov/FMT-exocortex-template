#!/usr/bin/env python3
# SNAPSHOT — synced manually via script-promote.sh from FMT-exocortex-template/scripts/. Do not edit here directly.
"""Rebuild the DayPlan task table from the week plan (template release 0.43).

WHY: the morning plan table was written by the LLM fill, which dropped
carry-over WPs, took hours from WP cards instead of the week plan, and put
marks that the week plan did not have. The pool table of the week plan
(lib/week_pool.py) is the canon; this patch runs after the LLM fill and before
the budget patch and rebuilds the table from it, with no LLM call.

Rows, in order: rows without a WP number (self-development) as written; on a
real emergency, the WPs named in «🚨 Срочное» («С», red 🚦); WPs of
priorities.yaml `today`; yesterday's carry-over. Each of these takes title,
hours, 🚦 and status from the pool; ТВС is «В» for a branch direction (В*) and
«Т» otherwise, but only when the pool carries direction tokens at all —
otherwise the draft's ТВС stays. A 🔴 of the pool is kept as is: in the
template it means "critical priority", not an incident.

Then every other row of the draft stays (nothing disappears silently):
- a WP from mandatory_daily_wps (day-rhythm-config.yaml) without any mark;
- any other WP with a visible mark — «вне плана недели» when the pool does not
  have it, «не в приоритетах дня» when the pool has it but today's priorities
  and carry-over do not — and a line in «Требует внимания».

Contract: fail loud, never fail closed. The DayPlan is always kept:
- the week plan file is missing or unreadable, or this script itself fails ->
  a red line in «🚨 Срочное»;
- the week plan has no pool table this script can read -> a line in «Требует
  внимания»; the model's table stays as it is;
- other mismatches (WP outside the pool, missing columns, a draft week plan,
  empty priorities) -> a line in «Требует внимания».
This script's own red lines do not count as a real emergency, and a successful
rerun removes them (an emptied block gets «нет срочного» back).

Stdout carries one line for the pipeline: `hours-scope=week` when the «h»
column now holds week-plan hours, `hours-scope=day` otherwise (the budget
patch reads it). Exit code is always 0; findings go to stderr and into the
plan. Every edit is idempotent.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from collections.abc import Callable
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from compact_dashboard import compact_rows, replace_today_block  # noqa: E402 — lib path set above
from day_open_attention import ATTENTION_HEADER_RE  # noqa: E402
from plan_table import detect_columns, row_wp_number  # noqa: E402
from week_pool import BRANCH_TOKENS, PoolRow, extract_pool_rows, split_row  # noqa: E402
from wp_inbox import wp_card_paths  # noqa: E402

try:
    import yaml
    YAML_ERRORS: tuple = (yaml.YAMLError,)
except ImportError:  # reported when a YAML input actually has to be read
    yaml = None
    YAML_ERRORS = ()

PLAN_SUMMARY = "<summary><b>План на сегодня</b></summary>"
# The emergency template titles the block «🚨 Срочное — [что сломалось]».
URGENT_SUMMARY_RE = re.compile(r"<summary><b>🚨 Срочное[^<]*</b></summary>")
NO_URGENT = "— нет срочного (зелёный день)."
NO_URGENT_RE = re.compile(r"^—\s*нет срочного.*$", re.M)
HTML_COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
NO_ATTENTION = "— нет сигналов, требующих внимания."
NO_ATTENTION_RE = re.compile(r"^—\s*нет сигналов, требующих внимания.*\n?", re.M)
WEEK_UNREAD = "План недели не прочитан"
SYNC_FAILED = "Сверка плана дня с планом недели упала"
OWN_URGENT_LINES = tuple(f"- 🔴 {m}" for m in (WEEK_UNREAD, SYNC_FAILED))
# flag_urgent either prepends "\n\n<line>" or puts <line> where «нет срочного» was.
OWN_URGENT_RE = re.compile(r"(\n\n)?(?:" + "|".join(map(re.escape, OWN_URGENT_LINES)) + r")[^\n]*")
CARRY_HEADER = "**Carry-over из Day Close вчера"
# A carry-over item as the LLM writes it: «- WP-1», «1. WP-1», «- **РП-1**»,
# «- [WP-1](…)», «- WP-484/WP-561» (all ids of the leading group count).
LIST_ITEM_RE = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+(.*)$")
LEADING_IDS_RE = re.compile(r"^[*_\[`\s]*((?:(?:РП|WP)-?\d+[\]*_`\s/,]*)+)")
ID_RE = re.compile(r"(?:РП|WP)-?(\d+)")
PRIORITY_ID_RE = re.compile(r"^\s*(?:(?:WP|РП)-?(\d+)\b|(\d+)\s*$)", re.IGNORECASE)
CARD_NUM_RE = re.compile(r"^WP-(\d+)(?!\d)")
DEFERRED_MARK = "(отложено"  # the LLM keeps an item not taken into the table, marked so
OUT_OF_WEEK = "вне плана недели"
NOT_TODAY = "не в приоритетах дня"
NO_HOURS = "часы не заданы"
# A mark this script appended to a «РП» cell; stripped before the title is reused.
OWN_MARK_RE = re.compile(r"\s·\s(?:" + re.escape(OUT_OF_WEEK) + "|" + re.escape(NOT_TODAY) + r").*$")
# The scaffold's sample row (a leftover from a model reply or an older fill):
# «NNN» or a PENDING marker in its «#» or «РП» cell.
PLACEHOLDER_CELL_RE = re.compile(r"^\W*NNN\W*$|<!--\s*PENDING")
OWN_ATTENTION_PREFIX = "- ⚠️ Сверка плана дня с неделей: "
# A finding about rows a rerun no longer sees: it stays on rerun.
STICKY_MARKS = ("оставлено по одной: ",)
OWN_ATTENTION_LINE_RE = re.compile(r"(\n\n)(" + re.escape(OWN_ATTENTION_PREFIX) + r"[^\n]*)")
DRAFT_STATUS_RE = re.compile(r"^status:\s*['\"]?draft['\"]?\s*$", re.M)


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--dayplan", required=True, type=Path)
    p.add_argument("--priorities", required=True, type=Path,
                   help="priorities.yaml; a missing file means no priorities today")
    p.add_argument("--weekplan", default="",
                   help="WeekPlan file resolved by the caller; empty = not found (red line)")
    p.add_argument("--inbox", type=Path, required=True,
                   help="inbox/ with WP cards (inbox/WP-N/WP-N.md or flat inbox/WP-N*.md)")
    p.add_argument("--day-rhythm-config", type=Path, default=None,
                   help="day-rhythm-config.yaml with mandatory_daily_wps (optional)")
    return p.parse_args()


def load_yaml(path: Path, what: str):
    if yaml is None:
        raise RuntimeError(f"нет модуля yaml для чтения {what}")
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def today_priorities(path: Path) -> list:
    """Entries of priorities.yaml `today`; a missing file is an empty list. A
    broken file raises: the caller turns it into a red line, not a silently
    empty list."""
    if not path.is_file():
        return []
    data = load_yaml(path, "priorities.yaml")
    if data is None:
        return []
    if not isinstance(data, dict):
        raise ValueError("priorities.yaml: ожидался словарь с ключом today")
    items = data.get("today")
    if items is None:
        return []
    if not isinstance(items, list):
        raise ValueError("priorities.yaml: today должен быть списком")
    return items


def priority_wp(item) -> str | None:
    """WP number of one `today` entry: «WP-484», «WP-484: подпись» (unquoted it
    parses as a one-key dict), a bare number. Free text names no WP."""
    label = str(next(iter(item), "") if isinstance(item, dict) else item)
    m = PRIORITY_ID_RE.match(label)
    return str(int(m.group(1) or m.group(2))) if m else None


def mandatory_wps(path: Path | None) -> tuple[list[str], list[str]]:
    """(WP numbers of mandatory_daily_wps, visible findings). An unreadable
    config is a finding, not a failure: the rows it would protect stay anyway,
    only with a mark."""
    if path is None or not path.is_file():
        return [], []
    try:
        data = load_yaml(path, "day-rhythm-config.yaml") or {}
    except (OSError, RuntimeError, ValueError, *YAML_ERRORS) as exc:
        print(f"week-sync-patch: day-rhythm-config: {exc}", file=sys.stderr)
        return [], ["список обязательных ежедневных РП не прочитан — их строки помечены как остальные"]
    items = data.get("mandatory_daily_wps") if isinstance(data, dict) else None
    nums = []
    for item in items or []:
        if isinstance(item, dict) and str(item.get("wp", "")).strip().isdigit():
            nums.append(str(int(str(item["wp"]).strip())))
    return nums, []


def carry_over_wps(dayplan_text: str) -> tuple[list[str], list[str]]:
    """(WP numbers, items that name no WP) of yesterday's carry-over block.
    The block is copied from the scaffold; an item marked «(отложено …)» was
    deliberately left out of the table and is not carried into it."""
    start = dayplan_text.find(CARRY_HEADER)
    if start < 0:
        return [], []
    end = dayplan_text.find("</details>", start)
    nums, unclear = [], []
    for line in dayplan_text[start:end if end >= 0 else len(dayplan_text)].splitlines()[1:]:
        item = LIST_ITEM_RE.match(line)
        if item is None or DEFERRED_MARK in line:
            continue
        ids = LEADING_IDS_RE.match(item.group(1))
        if ids is None:
            unclear.append(item.group(1).strip())
            continue
        nums += [str(int(n)) for n in ID_RE.findall(ids.group(1))]
    return nums, unclear


def plan_table_span(lines: list[str]) -> tuple[int, int] | None:
    """[first, last] line indexes of the first table inside «План на сегодня»."""
    in_section, first = False, None
    for i, line in enumerate(lines):
        if PLAN_SUMMARY in line:
            in_section = True
            continue
        if not in_section:
            continue
        if line.startswith("|"):
            first = i if first is None else first
        elif first is not None or "</details>" in line:
            break
    if first is None:
        return None
    last = first
    while last + 1 < len(lines) and lines[last + 1].startswith("|"):
        last += 1
    return first, last


def cell(row: str | None, idx: int | None) -> str:
    """Stripped cell `idx` of a table row; "" for no row, no column or a short row."""
    if row is None:
        return ""
    cells = split_row(row)
    return cells[idx].strip() if idx is not None and idx < len(cells) else ""


def format_hours(hours: float | None) -> str:
    # «0», not «?»: the budget patch skips the whole table on an unreadable cell.
    return "0" if hours is None else f"{hours:g}"


class Cards:
    """Card titles by WP number, folder and flat cards alike (lib/wp_inbox.py)."""

    def __init__(self, inbox_dir: Path):
        self._paths = None
        self._inbox = inbox_dir

    def _index(self) -> dict[str, Path]:
        if self._paths is None:
            self._paths = {}
            for path in sorted(wp_card_paths(str(self._inbox))):
                m = CARD_NUM_RE.match(Path(path).name)
                if m:
                    self._paths.setdefault(str(int(m.group(1))), Path(path))
        return self._paths

    def title(self, wp_num: str) -> str | None:
        """`title:` from the card frontmatter, or None if the card is missing."""
        card = self._index().get(wp_num)
        if card is None:
            return None
        try:
            head = card.read_text(encoding="utf-8")[:4000]
        except OSError as exc:
            print(f"week-sync-patch: card WP-{wp_num} unreadable: {exc}", file=sys.stderr)
            return None
        m = re.search(r"""^title:\s*["']?(.+?)["']?\s*$""", head, re.M)
        return m.group(1) if m else None


class RowBuilder:
    """Builds one table row from the pool, keeping the draft row's other cells."""

    def __init__(self, header: dict, n_cells: int, pool: dict, emergency: bool, urgent: list[str],
                 title_of: Callable[[str], str | None]):
        self.header, self.n_cells, self.pool = header, n_cells, pool
        self.emergency, self.urgent, self.title_of = emergency, urgent, title_of
        self.has_directions = any(r.direction for r in pool.values())

    def draft_title(self, draft: str | None) -> str:
        return OWN_MARK_RE.sub("", cell(draft, self.header.get("РП")))

    def tvs(self, pool_row: PoolRow | None, draft: str | None) -> str:
        if self.has_directions:
            return "В" if pool_row is not None and pool_row.direction in BRANCH_TOKENS else "Т"
        return cell(draft, self.header.get("ТВС")) or "Т"

    def build(self, wp_num: str, draft: str | None, mark: str | None = None) -> str:
        pool_row = self.pool.get(wp_num)
        if pool_row is not None:
            name = f"**{pool_row.title}**" + ("" if pool_row.hours is not None else f" · {NO_HOURS}")
            if mark:
                name += f" · {mark}"
        else:
            title = self.title_of(wp_num) or self.draft_title(draft) or f"WP-{wp_num}"
            name = f"{title} · {OUT_OF_WEEK}, {NO_HOURS}"
        values = {
            "🚦": (pool_row.light if pool_row is not None and pool_row.light else "")
                  or cell(draft, self.header.get("🚦")) or "🟡",
            "ТВС": self.tvs(pool_row, draft),
            "#": wp_num,
            "РП": name,
            "h": format_hours(pool_row.hours if pool_row else None),
            "Статус": (pool_row.status if pool_row is not None else "")
                      or cell(draft, self.header.get("Статус")) or "—",
        }
        if self.emergency and wp_num in self.urgent:
            values["ТВС"], values["🚦"] = "С", "🔴"
        cells = split_row(draft) if draft else []
        cells = (cells + [""] * self.n_cells)[:self.n_cells]
        for column, value in values.items():
            if column in self.header and self.header[column] < self.n_cells:
                cells[self.header[column]] = f" {value} "
        return "|".join(cells)


def urgent_block(dayplan_text: str) -> tuple[int, int] | None:
    m = URGENT_SUMMARY_RE.search(dayplan_text)
    if m is None:
        return None
    end = dayplan_text.find("</details>", m.end())
    return m.end(), end if end >= 0 else len(dayplan_text)


def urgent_items(block: str) -> list[str]:
    """Lines of an «Срочное» block that are not comments, blank lines or this
    script's own diagnostics."""
    return [line for line in HTML_COMMENT_RE.sub("", block).splitlines()
            if line.strip() and not line.strip().startswith(OWN_URGENT_LINES)]


def has_real_emergency(dayplan_text: str) -> bool:
    span = urgent_block(dayplan_text)
    if span is None:
        return False
    block = dayplan_text[span[0]:span[1]]
    return not NO_URGENT_RE.search(block) and bool(urgent_items(block))


def urgent_wps(dayplan_text: str) -> list[str]:
    """WP numbers named in a real «Срочное» block, in order of appearance."""
    if not has_real_emergency(dayplan_text):
        return []
    span = urgent_block(dayplan_text)
    block = dayplan_text[span[0]:span[1]]
    return list(dict.fromkeys(str(int(n)) for line in urgent_items(block) for n in ID_RE.findall(line)))


def clear_own_urgent(dayplan_text: str) -> str:
    """Undo flag_urgent: a line it prepended goes away with its blank line; a
    line that replaced «нет срочного» gets «нет срочного» back in its place."""
    span = urgent_block(dayplan_text)
    if span is None:
        return dayplan_text
    head, end = span
    block = dayplan_text[head:end]
    if not OWN_URGENT_RE.search(block):
        return dayplan_text
    without_own = OWN_URGENT_RE.sub("", block)
    if urgent_items(without_own) or NO_URGENT_RE.search(without_own):
        block = without_own
    else:
        block = OWN_URGENT_RE.sub(lambda m: (m.group(1) or "") + NO_URGENT, block, count=1)
        block = OWN_URGENT_RE.sub("", block)
    return dayplan_text[:head] + block + dayplan_text[end:]


def insert_under_plan_header(dayplan_text: str, line: str) -> str:
    at = dayplan_text.find(PLAN_SUMMARY)
    if at < 0:
        return line + "\n\n" + dayplan_text
    at += len(PLAN_SUMMARY)
    return dayplan_text[:at] + "\n\n" + line + dayplan_text[at:]


def is_stale_finding(line: str) -> bool:
    """A line of this script that the current run recomputes."""
    return line.startswith(OWN_ATTENTION_PREFIX) and not any(mark in line for mark in STICKY_MARKS)


def clear_own_attention(dayplan_text: str) -> str:
    """Drop this script's lines from a previous run, so a rerun after fixed
    inputs does not keep stale findings; a block left with no items gets its
    «нет сигналов» placeholder back. Without the block the lines sit under the
    plan header, each inserted as "\\n\\n<line>", and go away the same way."""
    m = ATTENTION_HEADER_RE.search(dayplan_text)
    if m is None:
        return OWN_ATTENTION_LINE_RE.sub(
            lambda found: "" if is_stale_finding(found.group(2)) else found.group(0), dayplan_text)
    end = dayplan_text.find("</details>", m.end())
    end = end if end >= 0 else len(dayplan_text)
    kept = [line for line in dayplan_text[m.end():end].split("\n") if not is_stale_finding(line)]
    block = "\n".join(kept)
    if block == dayplan_text[m.end():end]:
        return dayplan_text
    if not any(line.strip().startswith("- ") for line in kept) and not NO_ATTENTION_RE.search(block):
        # Keep a blank suffix before </details>: dropping it made a rerun differ.
        remainder = block if not block.strip() else block.lstrip("\n")
        block = NO_ATTENTION + "\n" + remainder
    return dayplan_text[:m.end()] + block + dayplan_text[end:]


def note_attention(dayplan_text: str, message: str) -> str:
    """Put a line into «Требует внимания» (dropping its «нет сигналов»
    placeholder); without that block, right under the «План на сегодня» header."""
    line = f"{OWN_ATTENTION_PREFIX}{message}"
    if line in dayplan_text:
        return dayplan_text
    patched, n = ATTENTION_HEADER_RE.subn(lambda m: m.group(1) + line + "\n", dayplan_text, count=1)
    if n == 0:
        return insert_under_plan_header(dayplan_text, line)
    return NO_ATTENTION_RE.sub("", patched, count=1)


def flag_urgent(dayplan_text: str, message: str) -> str:
    """Put a red line into «Срочное» (or, without that block, right under the
    «План на сегодня» header). A line already present is not added again."""
    line = f"- 🔴 {message}"
    if line in dayplan_text:
        return dayplan_text
    span = urgent_block(dayplan_text)
    if span is None:
        return insert_under_plan_header(dayplan_text, line)
    head, end = span
    block = dayplan_text[head:end]
    if NO_URGENT_RE.search(block):
        block = NO_URGENT_RE.sub(line, block, count=1)
    else:
        block = f"\n\n{line}" + block
    return dayplan_text[:head] + block + dayplan_text[end:]


def wp_list(nums: list[str]) -> str:
    return ", ".join(f"WP-{n}" for n in nums)


def rebuild_table(lines: list[str], span: tuple[int, int], builder: RowBuilder,
                  wanted: list[str], mandatory: list[str]) -> tuple[list[str], list[str]]:
    """Replace the WP rows of the table: rows without a WP number stay on top,
    then `wanted` (urgent WPs first on an emergency) built from the pool, then
    the draft's other WP rows — mandatory ones unmarked, the rest marked. Edits
    `lines` in place; returns (stderr findings, findings visible in the plan)."""
    first, last = span
    header = builder.header
    num_col, title_col = detect_columns(lines[first:last + 1])
    missing = [name for name in ("РП", "h", "ТВС", "🚦") if name not in header]
    visible = [f"в таблице дня нет колонок {', '.join(f'«{n}»' for n in missing)} — "
               "их значения не сверены"] if missing else []

    other_rows, draft_rows, duplicated, findings = [], {}, [], []
    for row in lines[first + 2:last + 1]:
        if any(PLACEHOLDER_CELL_RE.search(cell(row, header.get(c))) for c in ("#", "РП")):
            findings.append(f"removed the scaffold sample row: {row.strip()}")
            continue
        wp_num = row_wp_number(row, num_col, title_col)
        if wp_num is None:
            other_rows.append(row)
        elif wp_num in draft_rows:
            duplicated.append(wp_num)
        else:
            draft_rows[wp_num] = row
    if duplicated:
        visible.append(f"в заготовке плана повторены строки дел — оставлено по одной: {wp_list(duplicated)}")

    order = list(dict.fromkeys((builder.urgent if builder.emergency else []) + wanted))
    if not wanted:
        order = list(dict.fromkeys(order + list(draft_rows)))
        visible.append("приоритеты дня и вчерашний перенос пусты — состав таблицы взят из заготовки плана")
    built = [builder.build(n, draft_rows.get(n)) for n in order]

    marked = []
    for n, row in draft_rows.items():
        if n in order:
            continue
        if n in mandatory:
            # A mandatory daily WP outside the pool keeps the row as the model wrote it.
            built.append(builder.build(n, row) if n in builder.pool else row)
        else:
            built.append(builder.build(n, row, mark=NOT_TODAY))
            marked.append(n)
    if marked:
        visible.append("в таблице дела вне приоритетов дня и вчерашнего переноса — оставлены с пометкой: "
                       + wp_list(marked))
    lines[first + 2:last + 1] = other_rows + built
    added = [n for n in order if n not in draft_rows]
    if added:
        findings.append(f"added from priorities and carry-over: {wp_list(added)}")
    return findings, visible


def is_draft(weekplan_text: str) -> bool:
    """`status: draft` in the week plan's frontmatter (session-prep writes a
    draft; the strategy session sets `confirmed`)."""
    if not weekplan_text.startswith("---\n"):
        return False
    end = weekplan_text.find("\n---", 3)
    return end > 0 and DRAFT_STATUS_RE.search(weekplan_text[4:end]) is not None


def read_weekplan(path_arg: str) -> tuple[Path | None, str | None, str | None]:
    """(path, text, reason it could not be read)."""
    if not path_arg:
        return None, None, "файл плана недели не найден"
    path = Path(path_arg)
    try:
        return path, path.read_text(encoding="utf-8"), None
    except FileNotFoundError:
        return path, None, "файл плана недели не найден"
    except (OSError, UnicodeDecodeError) as exc:
        print(f"week-sync-patch: week plan unreadable: {exc}", file=sys.stderr)
        return path, None, "файл плана недели не читается"


def sync(args) -> tuple[list[str], str]:
    """Patch the DayPlan; returns (stderr findings, hours scope of the «h» column)."""
    text = args.dayplan.read_text(encoding="utf-8")
    weekplan, week_text, unread = read_weekplan(args.weekplan)
    if unread:
        args.dayplan.write_text(flag_urgent(clear_own_attention(text),
                                            f"{WEEK_UNREAD} ({unread}): часы и пометки в таблице дня "
                                            "не сверены с неделей."), encoding="utf-8")
        return [f"week plan unreadable: {unread}"], "day"

    text = clear_own_attention(clear_own_urgent(text))
    pool_rows = extract_pool_rows(week_text)
    if not pool_rows:
        message = (f"в плане недели ({weekplan.name}) не найдена таблица дел — раздел «План на неделю» "
                   "с колонками «#» и «h» и номерами дел; таблица дня оставлена как её составила модель, "
                   "часы с неделей не сверены")
        args.dayplan.write_text(note_attention(text, message), encoding="utf-8")
        return ["week plan has no pool table"], "day"

    lines = text.split("\n")
    span = plan_table_span(lines)
    if span is None:
        message = "таблица «План на сегодня» не найдена — сверка с неделей не выполнена"
        args.dayplan.write_text(note_attention(text, message), encoding="utf-8")
        return [message], "day"
    header = {c.strip(): i for i, c in enumerate(split_row(lines[span[0]]))}
    if "#" not in header:
        # Built rows carry the WP number only in «#»; without it a rerun could
        # not recognise them and would add every WP again.
        message = "у таблицы дня нет колонки «#» — таблица не пересобрана программой"
        args.dayplan.write_text(note_attention(text, message), encoding="utf-8")
        return [message], "day"

    pool = {str(int(r.wp.split("-")[1])): r for r in pool_rows}
    cards = Cards(args.inbox)
    carried, unclear = carry_over_wps(text)
    emergency = has_real_emergency(text)
    urgent = urgent_wps(text)
    today = list(dict.fromkeys(n for n in map(priority_wp, today_priorities(args.priorities)) if n))
    mandatory, visible = mandatory_wps(args.day_rhythm_config)
    builder = RowBuilder(header, len(split_row(lines[span[0]])), pool, emergency, urgent, cards.title)
    findings, table_visible = rebuild_table(lines, span, builder, list(dict.fromkeys(today + carried)),
                                            mandatory)
    visible += table_visible
    if is_draft(week_text):
        visible.append(f"план недели ({weekplan.name}) ещё черновик (status: draft) — часы и пометки "
                       "взяты из черновика")
    if not today and carried:
        visible.append("приоритеты дня не заданы — таблица собрана из вчерашнего переноса")
    if emergency and not urgent:
        visible.append("в «Срочное» нет номера дела — метка «С» никому не поставлена")
    unknown = [n for n in urgent if n not in pool and cards.title(n) is None]
    if unknown:
        visible.append(f"в «Срочное» названо дело без карточки и без места в плане недели: {wp_list(unknown)}")
    if unclear:
        findings.append("carry-over items without a WP number: " + "; ".join(unclear))

    table = plan_table_span(lines)
    table_lines = lines[table[0]:table[1] + 1] if table is not None else []
    patched = replace_today_block("\n".join(lines), compact_rows(table_lines))
    for message in visible:
        patched = note_attention(patched, message)
    args.dayplan.write_text(patched, encoding="utf-8")
    return findings + visible + [f"aligned with {weekplan.name}"], "week"


def main() -> int:
    args = parse_args()
    scope = "day"
    try:
        findings, scope = sync(args)
    except Exception as exc:  # fail loud, never fail closed: the plan must still publish
        print(f"week-sync-patch: failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        try:
            text = args.dayplan.read_text(encoding="utf-8")
            args.dayplan.write_text(flag_urgent(text, f"{SYNC_FAILED} "
                                                      f"({type(exc).__name__}): таблица дня не сверена."),
                                    encoding="utf-8")
        except OSError as write_exc:
            print(f"week-sync-patch: cannot flag the DayPlan either: {write_exc}", file=sys.stderr)
        findings = []
    for f in findings:
        print(f"week-sync-patch: {f}", file=sys.stderr)
    print(f"hours-scope={scope}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
