#!/usr/bin/env python3
# see WP-620 Ф2 scenario 2 / Д2 (Translator promise approved by the pilot 2026-11-10)
"""Check an English method card against the approved-terms tables of the pack.

The pack keeps approved English names in tables with the header
``| Термин (RU) | Term (EN) | Не использовать / альтернативы | … | Утвердил |``
(for example in the platform ontology card of a pack). The third column
names alternatives that must not be used. This script is deterministic (no
model): it reports every forbidden alternative found in the card body, with the
approved name to use instead, and every term whose row has no approver.

Rules for the «Не использовать» cell:
* text before the first « — » is a comma/semicolon list of alternatives;
  if the text after « — » allows them in an explanation («пояснение»), that
  list is not forbidden;
* every «quoted» Latin phrase anywhere in the cell is forbidden, unless the
  cell restricts it to a bare use («голое …») — that cannot be told apart from
  a legitimate use by text matching, so it is listed as not checkable.

Only the card body is checked (after the frontmatter): aliases in the
frontmatter are search keys, not prose.

Usage:
    python3 scripts/check-card-terms.py CARD.md --terms PACK_FILE.md [--terms …]
Exit: 0 — no findings; 1 — findings (the card is not ready); 2 — usage error.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

HEADER_RE = re.compile(r"^\|\s*Термин \(RU\)\s*\|\s*Term \(EN\)\s*\|\s*Не использовать")
CYRILLIC_RE = re.compile(r"[А-Яа-яЁё]")
LATIN_RE = re.compile(r"[A-Za-z]")
QUOTED_RE = re.compile(r"«([^»]+)»")
EM_DASH = " — "


@dataclass(frozen=True)
class TermRow:
    term_ru: str
    term_en: str
    forbidden: tuple[str, ...]
    not_checkable: tuple[str, ...]
    approved_by: str | None


@dataclass(frozen=True)
class Finding:
    line: int
    found: str
    term_ru: str
    use_instead: str
    kind: str  # "forbidden" | "unapproved"


def _cells(line: str) -> list[str]:
    """Table cells; an escaped pipe (\\|) stays inside its cell."""
    inner = line.strip().removeprefix("|").removesuffix("|")
    return [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", inner)]


def _is_latin_phrase(text: str) -> bool:
    return bool(LATIN_RE.search(text)) and not CYRILLIC_RE.search(text)


def parse_forbidden(cell: str) -> tuple[list[str], list[str]]:
    """«Не использовать» cell → (forbidden phrases, phrases not checkable by text)."""
    if cell in ("", "—", "-"):
        return [], []
    forbidden: list[str] = []
    not_checkable: list[str] = []
    head, _, comment = cell.partition(EM_DASH)
    if "пояснени" not in comment:
        for item in re.split(r"[,;]", head):
            item = item.strip().removeprefix("не ").strip("«» ")
            if _is_latin_phrase(item):
                forbidden.append(item)
    for m in QUOTED_RE.finditer(cell):
        phrase = m.group(1).strip()
        if not _is_latin_phrase(phrase):
            continue
        before = cell[: m.start()].rstrip()
        target = not_checkable if re.search(r"голо(е|й|ая)$", before) else forbidden
        if phrase not in target:
            target.append(phrase)
    return [f for f in forbidden if f not in not_checkable], not_checkable


def parse_tables(text: str) -> list[TermRow]:
    rows: list[TermRow] = []
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        if not HEADER_RE.match(lines[i]):
            i += 1
            continue
        header = _cells(lines[i])
        approver_col = next(
            (n for n, h in enumerate(header) if h.startswith("Утвердил")), None
        )
        i += 2  # header and the |---| separator
        while i < len(lines) and lines[i].lstrip().startswith("|"):
            cells = _cells(lines[i])
            if len(cells) >= 3:
                forbidden, not_checkable = parse_forbidden(cells[2])
                approved_by = (
                    cells[approver_col]
                    if approver_col is not None and approver_col < len(cells)
                    else None
                )
                rows.append(
                    TermRow(
                        cells[0],
                        cells[1],
                        tuple(forbidden),
                        tuple(not_checkable),
                        approved_by,
                    )
                )
            i += 1
    return rows


def card_body(text: str) -> tuple[str, int]:
    """Body after the frontmatter and the 1-based line number where it starts."""
    lines = text.splitlines()
    if lines and lines[0].strip() == "---":
        for n in range(1, len(lines)):
            if lines[n].strip() == "---":
                return "\n".join(lines[n + 1 :]), n + 2
    return text, 1


def _phrase_re(phrase: str) -> re.Pattern[str]:
    """Whole-word, case-insensitive; a plural ending (-s, -es) also matches."""
    return re.compile(
        r"(?<![A-Za-z])" + re.escape(phrase) + r"(?:e?s)?(?![A-Za-z])", re.IGNORECASE
    )


def check_card(card_text: str, rows: list[TermRow]) -> list[Finding]:
    body, first_line = card_body(card_text)
    findings: list[Finding] = []
    for offset, line in enumerate(body.splitlines()):
        for row in rows:
            for phrase in row.forbidden:
                for m in _phrase_re(phrase).finditer(line):
                    findings.append(
                        Finding(
                            first_line + offset,
                            m.group(0),
                            row.term_ru,
                            row.term_en,
                            "forbidden",
                        )
                    )
            # No approver column at all (None) means unknown, not unapproved; an empty
            # English name cannot be searched for.
            if (
                row.approved_by in ("", "—", "-")
                and _is_latin_phrase(row.term_en)
                and _phrase_re(row.term_en).search(line)
            ):
                findings.append(
                    Finding(
                        first_line + offset, row.term_en, row.term_ru, "", "unapproved"
                    )
                )
    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Check an English method card against approved pack terms."
    )
    parser.add_argument("card", help="English method card (Markdown)")
    parser.add_argument(
        "--terms",
        action="append",
        required=True,
        help="pack file with an approved-terms table",
    )
    args = parser.parse_args(argv)

    rows: list[TermRow] = []
    for path in args.terms:
        p = Path(path)
        if not p.is_file():
            print(f"ERROR: нет файла таблицы терминов: {p}", file=sys.stderr)
            return 2
        rows += parse_tables(p.read_text(encoding="utf-8"))
    if not rows:
        print(
            "ERROR: в указанных файлах нет таблицы утверждённых терминов",
            file=sys.stderr,
        )
        return 2
    card = Path(args.card)
    if not card.is_file():
        print(f"ERROR: нет файла карточки: {card}", file=sys.stderr)
        return 2

    findings = check_card(card.read_text(encoding="utf-8"), rows)
    print(f"Терминов в таблицах: {len(rows)}; находок: {len(findings)}")
    for f in findings:
        if f.kind == "forbidden":
            print(
                f"  строка {f.line}: «{f.found}» не использовать для «{f.term_ru}» — утверждено «{f.use_instead}»"
            )
        else:
            print(
                f"  строка {f.line}: «{f.found}» ({f.term_ru}) — имя не утверждено пилотом"
            )
    for row in rows:
        for phrase in row.not_checkable:
            print(
                f"  не проверяется текстом: «{phrase}» для «{row.term_ru}» (запрет только голого употребления)"
            )
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
