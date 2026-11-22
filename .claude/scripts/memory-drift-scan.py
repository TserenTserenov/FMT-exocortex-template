#!/usr/bin/env python3
"""Detector of status drift between MEMORY.md and WP-context.

Rule: day-close/SKILL.md step 4b «Memory Drift Scan» (issue #326).
The previous implementation was purely lexical (grep by words «waiting/blocker/
blocked/halted») and missed discrepancies, where the status in MEMORY.md
was stale, but the line text does not contain trigger words (for example, the line
remained `pending`, even though WP-context already `done`).

This script adds a SECOND, structural check: compares the value of
the status column in the table «WP of the current week» / «Current work»
MEMORY.md with the field `status` in the frontmatter of the corresponding WP-context
file. The lexical check (textual blockers without a status change)
day-close runs separately, this script does not replace it.

Status column format: header «Status» (default, text values
pending/in_progress/done) or abbreviated «st» (custom
customization, emoji-values — see. `_EMOJI_TO_STATUS`).

Usage:
    memory-drift-scan.py [--memory PATH] [--governance-repo PATH]

--memory: path to MEMORY.md (default: ~/IWE/memory/MEMORY.md)
--governance-repo: root governance-repo, where to search for inbox/WP-N/
    (default: ~/IWE/DS-strategy, overridden by $IWE_GOVERNANCE_REPO)

Exit code:
    0 — no drift found
    1 — drift detected (output — markdown-list, day-close inserts
        into the report without additional parsing)
    2 — startup error (MEMORY.md not found)
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("pyyaml not found. Install it: pip3 install --user pyyaml")

# WP table row: `| 1 | Name | Budget | Status | ... |` — we take
# the first numeric cell (WP number) and the cell under the column header «Status».
_TABLE_ROW = re.compile(r"^\|\s*(\d+)\s*\|(.+)\|\s*$")

# Status column header: the default template uses the full word
# «Status» with text values (pending/in_progress/done); also observed
# and the abbreviated custom column «st» with emoji-values —
# both variants are recognized by the header alias.
_STATUS_HEADER_ALIASES = {"Status", "st"}

# Emoji → canonical text status (see. .claude/rules/formatting.md
# «Emoji-statuses»). List best-effort best-effort based on observed usage in
# MEMORY.md users, not closed -- extend as new ones are encountered — expand as new
# values. Emojis without an entry in the mapping are compared as-is (literally)
# and, most likely, will not match any textual `status:` — that is the same
# behavior, that would occur without the mapping at all, not a regression.
_EMOJI_TO_STATUS = {
    "🔄": "in_progress",
    "⏳": "pending",
    "🏭": "in_progress",
    "🧪": "in_progress",
    "🚧": "blocked",
    "⚠️": "blocked",
    "⏸": "paused",
    "✅": "done",
    "📦": "done",
    "↗": "done",
    "❌": "cancelled",
}


_TEXT_STATUS_PATTERNS = (
    ("in_progress", re.compile(r"\bin[ _-]?progress\b", re.IGNORECASE)),
    ("in_progress", re.compile(r"\bactive\b", re.IGNORECASE)),
    ("in_progress", re.compile(r"\b(?:in[ _-]?progress|active)\b", re.IGNORECASE)),
    ("blocked", re.compile(r"\bblocked\b", re.IGNORECASE)),
    ("blocked", re.compile(r"\b(?:blocked|blocker)\b", re.IGNORECASE)),
    ("paused", re.compile(r"\b(?:paused|paused|on[ _-]?pause)\b", re.IGNORECASE)),
    ("done", re.compile(r"\b(?:done|closed|complete(?:d)?)\b", re.IGNORECASE)),
    ("done", re.compile(r"\b(?:ready|done|complet(?:ed|ed)|closed)\b", re.IGNORECASE)),
    ("cancelled", re.compile(r"\b(?:cancelled|canceled|cancelled|canceled)\b", re.IGNORECASE)),
    ("pending", re.compile(r"\bpending\b", re.IGNORECASE)),
    ("pending", re.compile(r"\b(?:waiting|not[ _-]?started)\b", re.IGNORECASE)),
)

# «awaiting» on its own describes both active work (🔄 awaiting review), and a blockage
# (⏸ awaiting an external decision). Use it only when an explicit status and icon are
# absent; otherwise it overrides more precise evidence.
_FALLBACK_TEXT_STATUS_PATTERNS = (
    ("pending", re.compile(r"\bawaiting\b", re.IGNORECASE)),
)


def normalize_status(raw: str) -> str:
    """Extract the canonical state from a status cell or frontmatter value.

    A table cell may include a visual status plus an explanation (for example,
    ``🔄 — waiting for review``). The explanation is not a state and must not
    create a false drift against the card's ``status: in_progress``.
    """
    cleaned = re.sub(r"[*~`_]", "", raw).strip()
    # A status cell may contain a visual category and an explicit text state.
    # Text wins: some existing MEMORY.md rows use ⏸ for a temporarily paused
    # plan while explicitly saying "blocked" to match `status: blocked`.
    # Treating the marker as authoritative would invent a drift where the
    # sources agree. A bare ⏸ remains the distinct `paused` state below.
    #
    # issue #471: "text wins" must not reach into the free-form explanation
    # after the leading marker — a status word appearing there describes a
    # sub-event ("...instance W33 closed 11.08"), not the card's own state.
    # Only the declaring part of the cell, before the first explanation
    # separator, is searched; the emoji fallback below still covers the
    # explanation itself if nothing declarative comes before it.
    lead_segment = re.split(r"[.,:—-]", cleaned, maxsplit=1)[0]
    for status, pattern in _TEXT_STATUS_PATTERNS:
        if pattern.search(lead_segment):
            return status
    for emoji, status in _EMOJI_TO_STATUS.items():
        if emoji in cleaned:
            return status
    for status, pattern in _FALLBACK_TEXT_STATUS_PATTERNS:
        if pattern.search(cleaned):
            return status
    return cleaned


def find_status_column(header_line: str) -> int | None:
    """Index of the status column (by header aliases) in the pipe-delimited `|` row."""
    cells = [c.strip() for c in header_line.strip().strip("|").split("|")]
    for idx, name in enumerate(cells):
        if name in _STATUS_HEADER_ALIASES:
            return idx
    return None


def parse_memory_table(memory_path: Path) -> dict[int, str]:
    """Returns {number_WP: normalized_status_from_MEMORY.md} for the active WP table."""
    lines = memory_path.read_text(encoding="utf-8").splitlines()
    status_col = None
    result: dict[int, str] = {}
    for i, line in enumerate(lines):
        if line.strip().startswith("|") and status_col is None:
            candidate_col = find_status_column(line)
            if candidate_col is not None:
                status_col = candidate_col
            continue
        if status_col is None:
            continue
        if line.strip().startswith("|---"):
            continue
        m = _TABLE_ROW.match(line)
        if not m:
            # Empty line or end of table — reset the column, look for the next table.
            if not line.strip().startswith("|"):
                status_col = None
            continue
        wp_num = int(m.group(1))
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if status_col >= len(cells):
            continue
        result[wp_num] = normalize_status(cells[status_col])
    return result


def find_wp_context(governance_repo: Path, wp_num: int) -> Path | None:
    """Searches for inbox/WP-N/WP-N.md, fallback archive/wp-contexts/WP-N*.md.

    The number may be written with leading zeros (WP-038): issue #1154.
    """
    active = governance_repo / "inbox" / f"WP-{wp_num}" / f"WP-{wp_num}.md"
    if active.is_file():
        return active
    padded = re.compile(rf"WP-0*{wp_num}")
    inbox_dir = governance_repo / "inbox"
    if inbox_dir.is_dir():
        for folder in sorted(inbox_dir.iterdir()):
            if folder.is_dir() and padded.fullmatch(folder.name):
                card = folder / f"{folder.name}.md"
                if card.is_file():
                    return card
    archive_dir = governance_repo / "archive" / "wp-contexts"
    if archive_dir.is_dir():
        padded_archive = re.compile(rf"WP-0*{wp_num}-.*\.md")
        matches = sorted(f for f in archive_dir.iterdir() if padded_archive.fullmatch(f.name))
        if matches:
            return matches[0]
    return None


def read_context_status(context_path: Path) -> str | None:
    """Extracts `status:` from YAML frontmatter WP-context file."""
    text = context_path.read_text(encoding="utf-8")
    if not text.startswith("---"):
        return None
    end = text.find("\n---", 3)
    if end == -1:
        return None
    try:
        frontmatter = yaml.safe_load(text[3:end])
    except yaml.YAMLError as exc:
        print(f"WARN: invalid YAML frontmatter, skipping: {context_path} ({exc})", file=sys.stderr)
        return None
    if not isinstance(frontmatter, dict):
        return None
    status = frontmatter.get("status")
    return str(status) if status is not None else None


def scan(
    memory_path: Path,
    governance_repo: Path,
    unresolved: list[int] | None = None,
) -> list[str]:
    """Returns a list of markdown-lines with detected drifts.

    WPs, whose card was not found, are appended to `unresolved` (if the list was provided):
    «could not be verified» is not the same as, as «no discrepancies found» (issue #1154).
    """
    memory_statuses = parse_memory_table(memory_path)
    drifts: list[str] = []
    for wp_num, memory_status in sorted(memory_statuses.items()):
        context_path = find_wp_context(governance_repo, wp_num)
        if context_path is None:
            if unresolved is not None:
                unresolved.append(wp_num)
            continue
        context_status = read_context_status(context_path)
        if context_status is None:
            continue
        context_status = normalize_status(context_status)
        if context_status != memory_status:
            drifts.append(
                f"- WP-{wp_num}: MEMORY.md=`{memory_status}` vs "
                f"WP-context=`{context_status}` "
                f"({context_path.relative_to(governance_repo)})"
            )
    return drifts


def _default_workspace() -> Path:
    """Resolve the workspace root the same way the shell tooling does
    (iwe-env-bootstrap.sh): explicit env var wins, ~/IWE is only a last
    resort. Without this, an install at a non-default path always fails
    with "MEMORY.md not found" (issue #638)."""
    for var in ("IWE_WORKSPACE", "IWE_ROOT", "WORKSPACE_DIR"):
        value = os.environ.get(var)
        if value:
            return Path(value)
    return Path.home() / "IWE"


def main() -> int:
    workspace = _default_workspace()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--memory",
        type=Path,
        default=workspace / "memory" / "MEMORY.md",
    )
    parser.add_argument(
        "--governance-repo",
        type=Path,
        default=workspace / os.environ.get("IWE_GOVERNANCE_REPO", "DS-strategy"),
    )
    args = parser.parse_args()

    if not args.memory.is_file():
        print(f"FAIL: MEMORY.md not found: {args.memory}", file=sys.stderr)
        return 2

    unresolved: list[int] = []
    drifts = scan(args.memory, args.governance_repo, unresolved)
    if unresolved:
        total = len(parse_memory_table(args.memory))
        names = ", ".join(f"WP-{n}" for n in unresolved)
        print(
            f"Drift-scan: could not verify {len(unresolved)} of {total} WPs "
            f"(WP-context not found): {names}"
        )
    if not drifts:
        suffix = " among verified" if unresolved else ""
        print(f"Drift-scan (structural): 0 discrepancies{suffix}")
        return 0

    print(f"Drift-scan (structural): {len(drifts)} discrepancies")
    for line in drifts:
        print(line)
    return 1


if __name__ == "__main__":
    sys.exit(main())
