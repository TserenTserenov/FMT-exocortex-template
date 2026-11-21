#!/usr/bin/env python3
"""Proactive sweep for stale WP cards past the archive-trigger (WP-545 Ф3,
pair-session with codex, 2026-08-21).

The reactive mechanism (memory/protocol-close.md § 5c) only proposes
archival when an agent happens to touch a specific card during Close. This
script closes the other half: Week Close runs it unconditionally over every
card, so a card nobody has touched in weeks still surfaces (precedent:
WP-7, archival mechanism existed but went unused for two months).

Trigger (memory/protocol-close.md § 5c, unchanged, not reinvented here):
  created > 14 calendar days old AND card body > 400 lines.
Suppression: `archive_declined: YYYY-MM-DD` in frontmatter -- not
resurfaced until 14 days after that date.
Candidacy criterion is filesystem fact, not frontmatter claim: a card is a
candidate only if `inbox/WP-N/WP-N-archive.md` does NOT exist on disk.
The `archive:` frontmatter field is diagnostic-only (surfaced as a
mismatch when it disagrees with the file), never load-bearing for the
decision -- found live during this session: `archive:` is set on 3 real
cards whose -archive.md file does not exist (WP-151, WP-415, WP-5).

Scope: only the canonical `inbox/WP-{N}/WP-{N}.md` card, matched by an
explicit numeric-N regex -- NOT a wide `inbox/WP-*/WP-*.md` glob, which
this session confirmed pulls in 42 non-card files (findings templates,
metrics logs, F-phase drafts, -archive.md itself) alongside the 104 real
cards.

Modes: none -- single scan, `--format md` (WeekReport-ready) or `--format
json` (for the reflex wrapper feeding process-runner.py).

Platform placement (WP-545 Ф3, consensus with codex, 21.08): this script
lives in FMT-exocortex-template/scripts/ (the shared, non-repo-specific
utility layer -- same tier as the sibling pending-phases-sweep.sh, not
inside any single governance-repo checkout), so the inbox path is derived
from the same IWE_WORKSPACE/IWE_GOVERNANCE_REPO env convention that sibling
already uses, not a path relative to this file's own location.
"""

import argparse
import datetime as dt
import json
import os
import re
import sys
from pathlib import Path

DEFAULT_WORKSPACE = Path(os.environ.get("IWE_WORKSPACE", os.path.expanduser("~/IWE")))
DEFAULT_GOV_REPO = os.environ.get("IWE_GOVERNANCE_REPO", "DS-strategy")
DEFAULT_INBOX = DEFAULT_WORKSPACE / DEFAULT_GOV_REPO / "inbox"

AGE_THRESHOLD_DAYS = 14
LINE_THRESHOLD = 400
DECLINE_COOLDOWN_DAYS = 14

CARD_RE = re.compile(r"^WP-(\d+)$")


class CardCheck:
    def __init__(self, wp_id, path, age_days, line_count, has_archive_file,
                 has_archive_field, declined_until):
        self.wp_id = wp_id
        self.path = path
        self.age_days = age_days
        self.line_count = line_count
        self.has_archive_file = has_archive_file
        self.has_archive_field = has_archive_field
        self.declined_until = declined_until  # date|None -- suppressed through this date

    @property
    def field_mismatch(self):
        return self.has_archive_field != self.has_archive_file

    def is_candidate(self, on_date):
        if self.has_archive_file:
            return False
        if self.age_days is None or self.line_count is None:
            return False
        if not (self.age_days > AGE_THRESHOLD_DAYS and self.line_count > LINE_THRESHOLD):
            return False
        if self.declined_until and on_date <= self.declined_until:
            return False
        return True


def parse_frontmatter(text):
    """Return dict of raw frontmatter lines (key: value), or None if no
    frontmatter block. Deliberately not a full YAML parser -- these three
    fields (created, archive, archive_declined) are always scalar single
    lines in every card this repo has produced; a malformed value surfaces
    as an error entry, not a crash or a silent skip."""
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---", 3)
    if end == -1:
        return None
    fm = {}
    for line in text[4:end].split("\n"):
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        fm[key.strip()] = value.strip().strip('"')
    return fm


def discover_cards(inbox_dir):
    """Yield (wp_id, path) for every canonical inbox/WP-{N}/WP-{N}.md card."""
    if not inbox_dir.is_dir():
        return
    for child in sorted(inbox_dir.iterdir()):
        if not child.is_dir():
            continue
        m = CARD_RE.match(child.name)
        if not m:
            continue
        card_path = child / f"{child.name}.md"
        if card_path.is_file():
            yield child.name, card_path


def check_card(wp_id, path, on_date):
    """Return (CardCheck|None, error: str|None). error is set only for a
    card whose content/frontmatter is unparsable -- that card is excluded
    from candidates but reported by id, never dropped silently. This
    includes invalid UTF-8 bytes (cold-review finding, 21.08): one
    corrupted card must not abort the whole sweep and lose every other
    card's candidacy for the week."""
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        return (None, f"{wp_id}: не читается как UTF-8 ({exc})")
    fm = parse_frontmatter(text)
    if fm is None:
        return (None, f"{wp_id}: нет frontmatter-блока")

    created_raw = fm.get("created")
    if not created_raw:
        return (None, f"{wp_id}: нет поля created")
    try:
        created = dt.date.fromisoformat(created_raw)
    except ValueError:
        return (None, f"{wp_id}: created не ISO-дата: {created_raw!r}")
    age_days = (on_date - created).days

    line_count = text.count("\n") + 1

    archive_path = path.parent / f"{wp_id}-archive.md"
    has_archive_file = archive_path.is_file()
    has_archive_field = "archive" in fm

    declined_until = None
    declined_raw = fm.get("archive_declined")
    if declined_raw:
        try:
            declined_date = dt.date.fromisoformat(declined_raw)
            declined_until = declined_date + dt.timedelta(days=DECLINE_COOLDOWN_DAYS)
        except ValueError:
            return (None, f"{wp_id}: archive_declined не ISO-дата: {declined_raw!r}")

    return (CardCheck(wp_id, path, age_days, line_count, has_archive_file,
                       has_archive_field, declined_until), None)


def sweep(inbox_dir, on_date):
    """Return (candidates, suppressed_cooldown, suppressed_archive_exists,
    field_mismatches, errors, total_checked) -- lists of CardCheck or
    (wp_id, detail) error tuples, plus a total count that includes cards
    below-threshold (young/short, healthy, no list membership) so the
    summary line doesn't silently undercount them."""
    candidates, cooldown, has_archive, mismatches, errors = [], [], [], [], []
    total_checked = 0
    for wp_id, path in discover_cards(inbox_dir):
        total_checked += 1
        check, error = check_card(wp_id, path, on_date)
        if error:
            errors.append(error)
            continue
        if check.field_mismatch:
            mismatches.append(check)
        if check.has_archive_file:
            has_archive.append(check)
            continue
        if check.is_candidate(on_date):
            candidates.append(check)
        elif check.declined_until and on_date <= check.declined_until and \
                check.age_days is not None and check.age_days > AGE_THRESHOLD_DAYS and \
                check.line_count > LINE_THRESHOLD:
            cooldown.append(check)
    return candidates, cooldown, has_archive, mismatches, errors, total_checked


def render_md(candidates, cooldown, mismatches, errors, on_date):
    lines = []
    if not candidates:
        lines.append("Кандидатов на архивацию карточек нет.")
    else:
        lines.append(f"Кандидаты на архивацию карточек ({len(candidates)}):")
        lines.append("")
        for i, c in enumerate(candidates, 1):
            lines.append(f"{i}. {c.wp_id} ({c.age_days} дней, {c.line_count} строк)")
            lines.append(f"   {c.path}")
    if cooldown:
        lines.append("")
        names = ", ".join(f"{c.wp_id} (до {c.declined_until.isoformat()})" for c in cooldown)
        lines.append(f"Отложено по отказу пилота ({len(cooldown)}): {names}")
    if mismatches:
        lines.append("")
        lines.append(f"Расхождение archive:-поле vs файл ({len(mismatches)}, диагностика, "
                      "не влияет на кандидатов):")
        for c in mismatches:
            state = "поле есть, файла нет" if c.has_archive_field else "файл есть, поля нет"
            lines.append(f"  {c.wp_id}: {state}")
    if errors:
        lines.append("")
        lines.append(f"Пропущено из-за ошибки метаданных ({len(errors)}):")
        for e in errors:
            lines.append(f"  {e}")
    return "\n".join(lines)


def render_json(candidates, cooldown, has_archive, mismatches, errors, on_date, total_checked):
    return json.dumps({
        "date": on_date.isoformat(),
        "candidates": [
            {"id": c.wp_id, "path": str(c.path), "age_days": c.age_days,
             "line_count": c.line_count}
            for c in candidates
        ],
        "suppressed": {
            "cooldown": [
                {"id": c.wp_id, "until": c.declined_until.isoformat()} for c in cooldown
            ],
            "archive_exists": [c.wp_id for c in has_archive],
        },
        "field_mismatches": [
            {"id": c.wp_id, "has_field": c.has_archive_field,
             "has_file": c.has_archive_file}
            for c in mismatches
        ],
        "errors": errors,
        "count": len(candidates),
        "total_checked": total_checked,
    }, ensure_ascii=False)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--inbox", type=Path, default=DEFAULT_INBOX)
    ap.add_argument("--date", default=dt.date.today().isoformat())
    ap.add_argument("--format", choices=["md", "json"], default="md")
    args = ap.parse_args()

    try:
        on_date = dt.date.fromisoformat(args.date)
    except ValueError:
        print(f"ошибка: --date не ISO-дата: {args.date!r}", file=sys.stderr)
        sys.exit(2)

    candidates, cooldown, has_archive, mismatches, errors, total_checked = sweep(args.inbox, on_date)

    if args.format == "json":
        print(render_json(candidates, cooldown, has_archive, mismatches, errors, on_date,
                           total_checked))
    else:
        print(render_md(candidates, cooldown, mismatches, errors, on_date))
        print(f"\nВсего карточек проверено: {total_checked}; "
              f"уже архивировано: {len(has_archive)}; ошибок метаданных: {len(errors)}.",
              file=sys.stderr)

    sys.exit(0)


if __name__ == "__main__":
    main()
