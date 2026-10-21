#!/usr/bin/env python3
"""build-active-wp.py — rebuild current/active-wp.md from docs/WP-REGISTRY.md.

Source-of-truth: WP-REGISTRY.md (markdown-table).
Output: current/active-wp.md — open WPs (🔄 ⏳ 🧪 🚧 ⏸) at the top, closed (✅ 📦 ↗️ ❌) below,
both sections sorted by descending WP number.

Usage:
  python3 build-active-wp.py [--check | --deep-check | --semantic-check]

  no flags        — overwrites active-wp.md
  --check           — exit 1 if active-wp.md diverges from the registry (pre-commit guard)
  --deep-check      — exit 1 if there are orphan WP-NNN (registry has no inbox/archive file,
                       or the file exists, but is absent from the registry) OR the registry row does not
                       classify (unknown status, malformed columns).
                       Day Open / periodic reconciliation.
  --semantic-check  — exit 1 if the status in the registry diverges from placement (active WP
                       only in archive/, or closed WP only in inbox/). Week Close.

Invariant (bug WP-285, 2026-07-16): a row containing a WP number is NEVER silently dropped.
Unknown status/malformed columns → the row is counted in orphan-detection + an explicit
PARSE-WARN. Previously a row with «⏸» was dropped by the parser entirely, and deep-check falsely
reported «no row in WP-REGISTRY.md», and the WP disappeared from active-wp.md.

  see peer-session 2026-06-01-21-wp-registry-drift-guard
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

# Governance-repo (where it hosts WP-REGISTRY.md) is resolved via IWE_GOVERNANCE_REPO,
# not from the script location — in a user installation the script stays inside
# IWE/scripts/, while the registry lives in a separate governance-repo (#293).
IWE_ROOT = Path(os.environ.get("IWE_ROOT", Path.home() / "IWE"))
GOV_REPO = os.environ.get("IWE_GOVERNANCE_REPO", "DS-strategy")
ROOT = IWE_ROOT / GOV_REPO
REGISTRY = ROOT / "docs" / "WP-REGISTRY.md"
OUTPUT = ROOT / "current" / "active-wp.md"
INBOX_DIR = ROOT / "inbox"
ARCHIVE_DIR = ROOT / "archive" / "wp-contexts"


def _script_invocation_hint() -> str:
    """How to tell a user to re-run this script (issue #905).

    The script's OWN location is not ROOT (see the comment above): on a
    stock install it stays inside IWE/scripts/, ROOT is
    a separate governance repo that never receives a copy. A hardcoded
    "python3 scripts/build-active-wp.py" printed a path that only resolves
    from ROOT and nowhere else -- exit code 0, message ignored, active-wp.md
    silently stale. Report the actual runtime location instead, the same
    two-place IWE/governance-repo resolution
    create-wp.sh already uses (scripts/create-wp.sh:872-875), just inverted:
    that one searches for the script from a known root, this one searches
    for a known root from the script.
    """
    self_path = Path(__file__).resolve()
    for root in (ROOT, IWE_ROOT / "IWE"):
        try:
            # Both sides must go through the same symlink resolution (e.g.
            # macOS /var -> /private/var) or an unresolved root never
            # prefix-matches a resolved self_path.
            resolved_root = root.resolve()
            return f"python3 {(Path(root.name) / self_path.relative_to(resolved_root)).as_posix()}"
        except (ValueError, OSError):
            continue
    return f"python3 {self_path}"

# Statuses are stored without U+FE0F (emoji variation selector): "arrow with VS16" and without it - same status.
# ⏹ (cancelled) and 🔁 (collapsed into sprint) - issue #473: the registry already uses them,
# the parser did not know them, both rows fell through to PARSE-WARN as "unknown status".
ACTIVE_STATUSES = {"🔄", "⏳", "🧪", "🚧", "⏸"}
CLOSED_STATUSES = {"✅", "📦", "↗", "❌", "⏹", "🔁"}
ALL_STATUSES = ACTIVE_STATUSES | CLOSED_STATUSES


def norm_status(token: str) -> str:
    return token.replace("\ufe0f", "")

# WP row-WP: `| 312 | P2 | **Title** | 🔄 | repo | 8h |`
# Done-variant: `| ~~306~~ | ~~P3~~ | ~~Title~~ | ✅ | ~~repo~~ | ~~4h~~ |`
ROW_RE = re.compile(r"^\|\s*(?:~~)?(?:\*\*)?(?:WP-)?(\d{1,4})(?:\*\*)?(?:~~)?\s*\|")

# WP filename WP in inbox/archive: WP-NNN-... .md or WP-NNN.md or folder WP-NNN/
WP_NAME_RE = re.compile(r"^WP-(\d{1,4})(?:[-.].*|/)?$")

# issue #473: registry columns were read by hard-coded position (cols[3] = status and
# e.g.), table schema `| # | P | Title | St | Repo | Budget |`. Real
# registries differ in both the number, and the order of columns (one installation added
# "Rate" between Repo and Budget, another uses "Status | Goal | Created | P"
# in a different order) - a hardcoded position was silently reading the wrong column. Index
# is now resolved by column name from the header row-header.
HEADER_RE = re.compile(r"^\|\s*#\s*\|")
_COLUMN_ALIASES = {
    "wp": {"#", "№"},
    "name": {"name"},
    "status": {"status", "st"},
    "repo": {"repo"},
    "budget": {"budget"},
    "project": {"p", "p"},
}
_REQUIRED_COLUMNS = {"name", "status"}


_TABLE_SEPARATOR_RE = re.compile(r"^\|[\s:-]+\|[\s:-]*\|?")


def find_header_columns(text: str) -> dict[str, int]:
    """Index {role: position} from the header row-header `| # | ... |`. Empty dictionary,
    if the header is not found - the calling code must explicitly handle that case,
    do not fall back to default positions.

    Discovered in a peer-session with Codex (step 3): we take only the FIRST row of the form
    "| # | ... |" in the file, because such a row could theoretically also appear
    in the status legend inside <details> before the real table header.
    A candidate is accepted, only if the next line is a markdown separator - markdown-separator
    (`|---|---|...`), as expected for a real table header."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if not HEADER_RE.match(line):
            continue
        next_line = lines[i + 1] if i + 1 < len(lines) else ""
        if not _TABLE_SEPARATOR_RE.match(next_line):
            continue
        cells = [c.strip().lower() for c in line.strip("|").split("|")]
        idx: dict[str, int] = {}
        for j, cell in enumerate(cells):
            for role, aliases in _COLUMN_ALIASES.items():
                if cell in aliases and role not in idx:
                    idx[role] = j
        return idx
    return {}


def parse_registry(text: str) -> tuple[list[dict], list[str]]:
    """Registry parsing. A row containing a WP number is never silently discarded:
    unparseable ones go into rows (for orphan-detection) + into problems (PARSE-WARN)."""
    columns = find_header_columns(text)
    missing_required = _REQUIRED_COLUMNS - columns.keys()
    if missing_required:
        raise ValueError(
            f"in the registry header (row '| # | ... |') required columns not found: "
            f"{sorted(missing_required)} - recognized: {columns}"
        )

    rows: list[dict] = []
    problems: list[str] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        m = ROW_RE.match(line)
        if not m:
            continue
        wp = int(m.group(1))
        cols = [c.strip() for c in line.strip("|").split("|")]
        max_needed = max(columns.values())
        if len(cols) <= max_needed:
            problems.append(
                f"WP-{wp} (row {lineno}): {len(cols)} columns, expected at least "
                f"{max_needed + 1} per the registry header - the row is recorded, but does not appear in active-wp.md."
            )
            cols = cols + [""] * (max_needed + 1 - len(cols))

        def cell(role: str, cols=cols) -> str:
            i = columns.get(role)
            return cols[i].strip() if i is not None and i < len(cols) else ""

        # Strip ~~ and whitespace; take only the first token, so that
        # accept variants of the form "🔄 Phase4" (status + phase marker).
        status_raw = cell("status").replace("~~", "").strip()
        token = status_raw.split()[0] if status_raw else ""
        status = norm_status(token)
        if status not in ALL_STATUSES:
            problems.append(
                f"WP-{wp} (line {lineno}): unknown status {token!r} - line counted "
                f"in the registry, but does not fall into either open, or closed active-wp.md."
            )
        rows.append({
            "wp": wp,
            "project": cell("project").replace("~~", "").strip(),
            "name": cell("name"),
            "status": status,
            "status_display": token,
            "repo": cell("repo"),
            "budget": cell("budget"),
            "raw": line,
            "_status_col": columns.get("status"),
            # Original cell text (markup intact) for re-rendering exactly the
            # header's six roles in active-wp.md (#558) — the raw line carries
            # ALL registry columns and overflowed the 6-column header,
            # spilling everything right of "Budget" outside the table. The
            # "wp" role falls back to the numeric id when the registry header
            # names its first column something un-aliased.
            "_view_cells": {
                role: (cell(role) or (str(wp) if role == "wp" else ""))
                for role in ("wp", "project", "name", "repo", "budget")
            },
        })
    return rows, problems


def render(rows: list[dict]) -> str:
    active = sorted(
        [r for r in rows if r["status"] in ACTIVE_STATUSES],
        key=lambda r: r["wp"],
        reverse=True,
    )
    closed = sorted(
        [r for r in rows if r["status"] in CLOSED_STATUSES],
        key=lambda r: r["wp"],
        reverse=True,
    )

    def table(items: list[dict]) -> str:
        if not items:
            return "_none_\n"
        # Rows are built from exactly the six roles the header declares (#558):
        # printing the raw registry line spilled every column right of
        # "Budget" (the registry has 10) outside the table as plain text.
        # find_header_columns() already reads the registry schema dynamically —
        # a schema change now affects cell PICKING, not the rendered width.
        out = ["| # | P | Name | St | Repo | Budget |",
               "|---:|---|------------------|:--:|------------------|------:|"]
        for r in items:
            v = r["_view_cells"]
            out.append(
                f"| {v['wp']} | {v['project']} | {v['name']} "
                f"| {r['status_display']} | {v['repo']} | {v['budget']} |"
            )
        return "\n".join(out) + "\n"

    lines = [
        "<!-- AUTO-GENERATED from docs/WP-REGISTRY.md by scripts/build-active-wp.py. Do not edit manually. -->",
        "<!-- index-health: skip -->",
        "",
        "# Active WPs — view of WP-REGISTRY",
        "",
        f"> Open ({len(active)}) on top, closed ({len(closed)}) below. Both sections ordered by descending number.",
        f"> Source-of-truth — `docs/WP-REGISTRY.md`. Regeneration: `{_script_invocation_hint()}`.",
        "",
        "<details>",
        "<summary><b>Status legend (St)</b></summary>",
        "",
        "| Status | Description |",
        "|:------:|-------------|",
        "| ✅ | done |",
        "| 🔄 | in_progress |",
        "| ⏳ | pending |",
        "| 🧪 | passive testing (waiting for trigger feedback) |",
        "| 🚧 | blocked |",
        "| ⏸ | paused (on hold, WP is open) |",
        "| 📦 | archived / → MAPSTRATEGIC |",
        "| ↗️ | merged into another WP |",
        "| ❌ | cancelled |",
        "",
        "</details>",
        "",
        f"## 🔄 Open ({len(active)})",
        "",
        table(active),
        "",
        f"<details><summary><b>📦 Closed ({len(closed)})</b></summary>",
        "",
        table(closed),
        "",
        "</details>",
        "",
    ]
    return "\n".join(lines)


def _is_valid_wp_entry(p: Path) -> bool:
    """WP-entity = directory OR .md/.yaml file (not .bak/.tmp/.swp/.orig etc..)."""
    if p.is_dir():
        return True
    return p.suffix in {".md", ".yaml"}


def find_wp_files(wp: int) -> dict:
    """Find all files and directories, belonging to WP-NNN.

    Returns {"inbox": [Path,...], "archive": [Path,...]}.
    Filters out .bak/.tmp/.swp/.orig .bak/.tmp/.swp/.orig — only .md/.yaml/directories.
    """
    inbox: list[Path] = []
    archive: list[Path] = []
    if INBOX_DIR.exists():
        for p in INBOX_DIR.iterdir():
            m = WP_NAME_RE.match(p.name)
            if m and int(m.group(1)) == wp and _is_valid_wp_entry(p):
                inbox.append(p)
    if ARCHIVE_DIR.exists():
        for p in ARCHIVE_DIR.iterdir():
            m = WP_NAME_RE.match(p.name)
            if m and int(m.group(1)) == wp and _is_valid_wp_entry(p):
                archive.append(p)
    return {"inbox": inbox, "archive": archive}


def scan_wp_files() -> dict:
    """Collect the set of WP-numbers, for which a file or folder was found/folder in inbox/ or archive/."""
    inbox_wps: set[int] = set()
    archive_wps: set[int] = set()
    if INBOX_DIR.exists():
        for p in INBOX_DIR.iterdir():
            m = WP_NAME_RE.match(p.name)
            if m and _is_valid_wp_entry(p):
                inbox_wps.add(int(m.group(1)))
    if ARCHIVE_DIR.exists():
        for p in ARCHIVE_DIR.iterdir():
            m = WP_NAME_RE.match(p.name)
            if m and _is_valid_wp_entry(p):
                archive_wps.add(int(m.group(1)))
    return {"inbox": inbox_wps, "archive": archive_wps}


def deep_check(rows: list[dict]) -> list[str]:
    """Orphan detection: registry vs files — bidirectionally.

    Scenarios:
      1. WP-NNN in the registry, but neither inbox/, nor archive/ file → registry-orphan.
      2. File inbox/WP-NNN or archive/wp-contexts/WP-NNN exists, but there is no row in the registry → file-orphan.
    """
    issues: list[str] = []
    registry_wps = {r["wp"] for r in rows}
    files = scan_wp_files()
    all_file_wps = files["inbox"] | files["archive"]

    for r in rows:
        wf = find_wp_files(r["wp"])
        if not wf["inbox"] and not wf["archive"]:
            issues.append(
                f"WP-{r['wp']} ({r['status']}): registry entry exists, "
                f"but neither inbox/WP-{r['wp']}* nor archive/wp-contexts/WP-{r['wp']}*."
            )

    for wp in sorted(all_file_wps - registry_wps):
        wf = find_wp_files(wp)
        locations = []
        for p in wf["inbox"]:
            locations.append(str(p.relative_to(ROOT)))
        for p in wf["archive"]:
            locations.append(str(p.relative_to(ROOT)))
        issues.append(
            f"WP-{wp}: file(s) found ({', '.join(locations)}), but there is no row in WP-REGISTRY.md."
        )

    return issues


def semantic_check(rows: list[dict]) -> list[str]:
    """Status-placement consistency: active in inbox, closed in archive.

    Scenarios:
      1. WP-NNN in the registry active (🔄 ⏳ 🧪), but the file is only in archive/ → status drift.
         (The registry says «work is in progress», but the context has already been archived.)
      2. WP-NNN in the registry closed (✅ 📦 ↗️), but the file is only in inbox/ → context drift.
         (The registry says «closed», but the context has not been moved to archive.)
    """
    issues: list[str] = []
    for r in rows:
        wf = find_wp_files(r["wp"])
        in_inbox = bool(wf["inbox"])
        in_archive = bool(wf["archive"])
        if not in_inbox and not in_archive:
            continue  # covered by deep_check
        is_active = r["status"] in ACTIVE_STATUSES
        is_closed = r["status"] in CLOSED_STATUSES
        if is_active and not in_inbox and in_archive:
            issues.append(
                f"WP-{r['wp']} (status {r['status']} ACTIVE): file only in archive/, "
                f"expected in inbox/. Registry and context are out of sync."
            )
        if is_closed and in_inbox and not in_archive:
            issues.append(
                f"WP-{r['wp']} (status {r['status']} CLOSED): file in inbox/, "
                f"not moved to archive/wp-contexts/. Candidate for migration."
            )
    return issues


def report_issues(label: str, issues: list[str]) -> None:
    print(f"\n=== {label} ({len(issues)} issue(s)) ===", file=sys.stderr)
    if not issues:
        print("  OK — no discrepancies found", file=sys.stderr)
        return
    for i in issues:
        print(f"  - {i}", file=sys.stderr)


def main() -> int:
    check_mode = "--check" in sys.argv
    deep_mode = "--deep-check" in sys.argv
    semantic_mode = "--semantic-check" in sys.argv

    if not REGISTRY.exists():
        print(f"build-active-wp: REGISTRY not found: {REGISTRY}", file=sys.stderr)
        return 2

    try:
        rows, parse_problems = parse_registry(REGISTRY.read_text(encoding="utf-8"))
    except ValueError as exc:
        print(f"build-active-wp: {exc}", file=sys.stderr)
        return 2
    if not rows:
        print("build-active-wp: no WP-rows were recognized -- check the table schema — check the table schema", file=sys.stderr)
        return 2
    if parse_problems and not (deep_mode or semantic_mode):
        report_issues("PARSE-WARN (registry rows outside classification)", parse_problems)

    if deep_mode or semantic_mode:
        total = 0
        if parse_problems:
            report_issues("PARSE-WARN (registry rows outside classification)", parse_problems)
            total += len(parse_problems)
        if deep_mode:
            issues = deep_check(rows)
            report_issues("DEEP-CHECK (orphans)", issues)
            total += len(issues)
        if semantic_mode:
            issues = semantic_check(rows)
            report_issues("SEMANTIC-CHECK (status vs placement)", issues)
            total += len(issues)
        if total:
            print(
                f"\nbuild-active-wp: integrity-check failed ({total} issue(s)). "
                f"Registry: {len(rows)} rows.",
                file=sys.stderr,
            )
            return 1
        print(f"\nbuild-active-wp: integrity-check OK ({len(rows)} rows checked).")
        return 0

    new_content = render(rows)
    current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""

    if check_mode:
        if new_content != current:
            print(f"build-active-wp: {OUTPUT.relative_to(ROOT)} differs from REGISTRY.", file=sys.stderr)
            print(f"Rebuild: {_script_invocation_hint()}", file=sys.stderr)
            return 1
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(new_content, encoding="utf-8")
    print(f"build-active-wp: {OUTPUT.relative_to(ROOT)} updated ({len(rows)} WP)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
