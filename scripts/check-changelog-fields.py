#!/usr/bin/env python3
"""Check the four handoff fields of CHANGELOG entries (WP-529 Phase 252).

An entry is handed over from the Developer to the Release Lead only when, under
its top-level bullet, it carries three labelled sub-bullets with four fields:

    - [behavior] What the user gets (WP-529 Ф252, #1510).
      - Цель: 77 · Результат: Ц77-03
      - Как проверить: bash scripts/tests/test_check_changelog_fields.sh
      - Как откатить: git revert of merge #1510

"Цель" is one or more need numbers from the needs list (77 or 77, 84).
"Результат" is one or more result codes (Ц77-03) or "служебное — <reason>".

Usage:
    check-changelog-fields.py [--ref REF | --file PATH] [--section NAME] [--only-added BASE]

    --ref REF         read CHANGELOG.md at a git revision (default: HEAD)
    --file PATH       read a CHANGELOG file from disk instead
    --section NAME    "Unreleased" (default) or a version such as 0.42.0
    --only-added BASE check only entries whose top line is absent from the same
                      section at BASE (the Changelog Gate mode for a PR)

Exit: 0 - all checked entries have the fields; 1 - violations (listed on
stdout); 2 - invocation or read error.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass, field

LABEL_GOAL = "Цель:"
LABEL_CHECK = "Как проверить:"
LABEL_ROLLBACK = "Как откатить:"
FIELD_LABELS = (LABEL_GOAL, LABEL_CHECK, LABEL_ROLLBACK)

SUBITEM = re.compile(r"^\s+[-*]\s+(.*)$")
GOAL_LINE = re.compile(r"^Цель:\s*(?P<goal>.*?)\s*·\s*Результат:\s*(?P<result>.*)$")
NEED_LIST = re.compile(r"^\d+(\s*,\s*\d+)*$")
RESULT_CODES = re.compile(r"^Ц\d+-\d+(\s*,\s*Ц\d+-\d+)*$")
SERVICE_RESULT = re.compile(r"^служебное\s*[—-]\s*\S")


@dataclass
class Entry:
    top: str
    subitems: list[str] = field(default_factory=list)


def section_lines(text: str, section: str) -> list[str]:
    """Lines between "## [<section>]" and the next "## [" header."""
    header = re.compile(r"^## \[" + re.escape(section) + r"\]")
    lines: list[str] = []
    inside = False
    for line in text.splitlines():
        if line.startswith("## ["):
            if inside:
                break
            inside = bool(header.match(line))
            continue
        if inside:
            lines.append(line)
    return lines


def parse_entries(lines: list[str]) -> list[Entry]:
    entries: list[Entry] = []
    current: Entry | None = None
    for line in lines:
        if re.match(r"^[-*]\s+", line):
            current = Entry(top=line.strip())
            entries.append(current)
        elif line.startswith("#"):
            current = None  # a subsection heading closes the previous entry
        elif current is not None and (match := SUBITEM.match(line)):
            current.subitems.append(match.group(1).strip())
    return entries


def field_problems(entry: Entry) -> list[str]:
    by_label = {label: [s for s in entry.subitems if s.startswith(label)] for label in FIELD_LABELS}
    problems: list[str] = []

    goal_lines = by_label[LABEL_GOAL]
    if not goal_lines:
        problems += ["нет поля «Цель»", "нет поля «Результат»"]
    elif len(goal_lines) > 1:
        problems.append(f"строка «Цель: … · Результат: …» указана {len(goal_lines)} раза")
    else:
        match = GOAL_LINE.match(goal_lines[0])
        if not match:
            problems.append("строка цели не в виде «Цель: <номер> · Результат: <код>»")
        else:
            if not NEED_LIST.match(match.group("goal")):
                problems.append(f"«Цель» — не номер потребности: «{match.group('goal')}»")
            result = match.group("result")
            if not (RESULT_CODES.match(result) or SERVICE_RESULT.match(result)):
                problems.append(f"«Результат» — не код Ц и не «служебное — причина»: «{result}»")

    for label, name in ((LABEL_CHECK, "Как проверить"), (LABEL_ROLLBACK, "Как откатить")):
        lines = by_label[label]
        if not lines:
            problems.append(f"нет поля «{name}»")
        elif len(lines) > 1:
            problems.append(f"поле «{name}» указано {len(lines)} раза")
        elif not lines[0][len(label):].strip():
            problems.append(f"поле «{name}» пустое")
    return problems


def read_changelog(ref: str | None, path: str | None) -> str:
    if path:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    result = subprocess.run(
        ["git", "show", f"{ref}:CHANGELOG.md"], capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        raise OSError(f"git show {ref}:CHANGELOG.md: {result.stderr.strip()}")
    return result.stdout


def short(text: str, limit: int = 90) -> str:
    return text if len(text) <= limit else text[: limit - 1] + "…"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--ref", default=None)
    source.add_argument("--file", default=None)
    parser.add_argument("--section", default="Unreleased")
    parser.add_argument("--only-added", dest="base", default=None)
    args = parser.parse_args(argv)
    if args.base and args.file:
        parser.error("--only-added works with --ref, not --file")

    ref = args.ref or ("HEAD" if not args.file else None)
    try:
        entries = parse_entries(section_lines(read_changelog(ref, args.file), args.section))
        if args.base:
            known = {e.top for e in parse_entries(section_lines(read_changelog(args.base, None), args.section))}
            entries = [e for e in entries if e.top not in known]
    except OSError as error:
        print(f"check-changelog-fields: {error}", file=sys.stderr)
        return 2

    failed = 0
    for entry in entries:
        problems = field_problems(entry)
        if problems:
            failed += 1
            print(f"FAIL: {short(entry.top)}")
            for problem in problems:
                print(f"      - {problem}")

    scope = "новых записей" if args.base else "записей"
    if failed:
        print(f"Без полей передачи: {failed} из {len(entries)} {scope} раздела [{args.section}]")
        return 1
    print(f"OK: у всех {len(entries)} {scope} раздела [{args.section}] есть четыре поля")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
