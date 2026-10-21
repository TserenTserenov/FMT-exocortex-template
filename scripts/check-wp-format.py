#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check-wp-format.py — linter WP-REGISTRY.md (WP-7 T2 + name contamination guard)

Checks two classes of violations:
  T2. Formatting done-lines: ✅/↗️/📦 without full ~~strikethrough~~
  NC. Name contamination: service data in the column «Name»

Usage:
  python3 check-wp-format.py [path/to/WP-REGISTRY.md] [--fix] [--exit-nonzero]

  --fix          automatically fix NC violations (fixing T2 is risky) NC-violations (T2 risky to fix)
  --exit-nonzero exit with code 1 on any violations (for pre-commit hook)

Without arguments: reads $IWE/DS-strategy/docs/WP-REGISTRY.md or ${IWE_GOVERNANCE_REPO:-DS-strategy}/...
"""

import sys
import re
import os

# --- Name pollution patterns (NC) ---
NAME_CONTAMINATION_PATTERNS = [
    re.compile(r"—\s*closed\b", re.IGNORECASE),
    re.compile(r"—\s*closed-partial\b", re.IGNORECASE),
    re.compile(r"\(peer-session\b", re.IGNORECASE),
    re.compile(r"\bPHASE\d*\s*="),
    re.compile(r"\bbacklinks\s*:"),
    re.compile(r"(?:^|\s)[0-9a-f]{40}(?:\s|$)"),  # full SHA (40 characters)
    re.compile(r"(?:^|\s)[0-9a-f]{7}(?:\s|$)"),   # short SHA (7 characters) — only with whitespace boundaries
    re.compile(r"Phase\d+[-–—]Phase\d+\s+done"),    # «Phase1-Phase5 done»
    re.compile(r"\bPhase\d+\s+done\b"),
    re.compile(r"\bPhase\d+-Phase\d+\b"),
    re.compile(r"\bpassed\b", re.IGNORECASE),
    re.compile(r"\bPASS\b"),
    re.compile(r"\btests?\b.*\d+"),          # «39 tests passed»
    re.compile(r"batch disposition"),
    re.compile(r"final closeout"),
    re.compile(r"zombie-triage"),
]

DONE_STATUS_EMOJIS = {"✅", "↗️", "📦"}
ACTIVE_STATUS_EMOJIS = {"⏳", "🔄"}

def is_table_row(line):
    stripped = line.strip()
    return stripped.startswith("|") and stripped.endswith("|") and not stripped.startswith("|---")

def parse_cells(line):
    """Split a table row into cells."""
    parts = line.strip().split("|")
    # parts[0] empty (before the first |), parts[-1] empty (after the last |)
    return [p.strip() for p in parts[1:-1]]

# Fallback-indices for the canonical 6-column schema
# (# | P | Name | St | Repo | Budget) — used only if the header
# table header not found/not recognized (see. find_column_indices).
FALLBACK_INDICES = {"#": 0, "P": 1, "Name": 2, "St": 3, "Repo": 4, "Budget": 5}

def find_column_indices(lines):
    """Determine column positions from the header row (| # | P | Name | ... |).

    issue #263: previously the column index «Name» was hardcoded (cells[2]) for
    the current 6-column layout — on a registry with an old/different layout (for example,
    | # | Name | Status | Activation |) it would silently check/cleaned the wrong cell.
    Instead of hardcoding — we read the actual table header and derive indices from it,
    so the check remains correct for any layout of the specific REGISTRY.

    Returns (indices, warning) — indices always populated (fallback on failure),
    warning — a string with an explanation, if a fallback had to be used fallback, otherwise None.
    """
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("| #"):
            cells = parse_cells(line)
            found = {name: i for i, name in enumerate(cells)}
            # Targeted fallback: a column, that is absent from the header of this specific
            # table, we substitute from the canonical layout — but columns that were found
            # (for example «Name» in the old 4-column layout) we do not discard for the sake of
            # missing neighbours (P/P/Repo are simply absent by the logic of that layout).
            missing = [name for name in FALLBACK_INDICES if name not in found]
            indices = {name: found.get(name, FALLBACK_INDICES[name]) for name in FALLBACK_INDICES}
            if missing:
                return indices, (
                    f"the table header does not contain columns {missing} "
                    f"— using indices from the canonical layout as fallback fallback"
                )
            return indices, None
    return FALLBACK_INDICES, (
        "table header (row «| # | ...») not found — "
        "using indices from the canonical 6-column layout as fallback"
    )

def is_done_row(cells):
    """A row with status done done (✅/↗️/📦)."""
    for cell in cells:
        if cell in DONE_STATUS_EMOJIS:
            return True
    return False

def has_strikethrough(text):
    """Text is wrapped in ~~ ... ~~."""
    return "~~" in text

def check_t2(cells, line_num, indices):
    """T2: done-done rows must have ~~ on fields #, P, Name, Repo."""
    issues = []
    if not is_done_row(cells):
        return issues
    # We check cells #, P, Name, Repo — positions are taken from the actual
    # table header (indices), they are not hardcoded (issue #263).
    if len(cells) >= 5:
        check_indices = sorted({indices["#"], indices["P"], indices["Name"], indices["Repo"]})
    else:
        check_indices = range(min(3, len(cells)))
    for i in check_indices:
        if i >= len(cells):
            continue
        cell = cells[i]
        if not cell or cell in DONE_STATUS_EMOJIS | ACTIVE_STATUS_EMOJIS:
            continue
        # The content field must be in ~~...~~
        if not has_strikethrough(cell):
            # Check that it is not just a dash/em-dash placeholder
            if cell not in ("—", "-", ""):
                issues.append({
                    "line": line_num,
                    "type": "T2",
                    "cell_index": i,
                    "cell_value": cell[:60],
                    "message": f"done-row, cell [{i}] without ~~strikethrough~~: «{cell[:40]}»"
                })
    return issues

def check_nc(cells, line_num, name_col):
    """NC: name pollution — auxiliary data in column «Name»."""
    issues = []
    if name_col >= len(cells):
        return issues
    name_cell = cells[name_col]
    for pattern in NAME_CONTAMINATION_PATTERNS:
        if pattern.search(name_cell):
            issues.append({
                "line": line_num,
                "type": "NC",
                "pattern": pattern.pattern,
                "cell_value": name_cell[:80],
                "message": f"name pollution (pattern «{pattern.pattern}»): «{name_cell[:60]}»"
            })
            break  # One message per row is enough
    return issues

def clean_name_cell(name_cell):
    """Strip the column «Name» of auxiliary data."""
    cleaned = name_cell

    # Remove «— closed DATE (details)»
    cleaned = re.sub(r"\s*—\s*closed(?:-partial)?\b.*$", "", cleaned, flags=re.DOTALL | re.IGNORECASE)
    # Remove «— Phase1-Phase5 done DATE (...); Phase6 — backlog» (all dash variants)
    cleaned = re.sub(r"\s*[-–—]\s*Phase\d[^|]*$", "", cleaned, flags=re.DOTALL)
    # Remove «(backlinks: WP-123 ...)»
    cleaned = re.sub(r"\s*\(backlinks\s*:[^)]*\).*$", "", cleaned, flags=re.DOTALL | re.IGNORECASE)
    # Remove «(peer-session ...) ...»
    cleaned = re.sub(r"\s*\(peer-session\b[^)]*\).*$", "", cleaned, flags=re.DOTALL | re.IGNORECASE)
    # Remove «(PHASE1=5...) ...»
    cleaned = re.sub(r"\s*\(PHASE\d*\s*=[^)]*\).*$", "", cleaned, flags=re.DOTALL | re.IGNORECASE)
    # Remove batch disposition / final closeout trailing suffixes
    cleaned = re.sub(r"\s*—\s*(?:batch disposition|final closeout|zombie-triage)\b.*$", "", cleaned,
                     flags=re.DOTALL | re.IGNORECASE)

    return cleaned.strip()


def fix_t2_row(parts, cells, indices):
    """Add ~~ around cells of the done-done row without strikethrough (#, P, Repo — not Name,
    wrapping it manually is risky because of-of markdown-markdown markup inside)."""
    # Mapping: cell_index → part_index (parts[0] empty, parts[-1] empty, cells starting at 1 1)
    cell_to_part = {i: i + 1 for i in range(len(cells))}
    changed = False
    for cell_idx in sorted({indices["#"], indices["P"], indices["Repo"]}):
        if cell_idx >= len(cells):
            continue
        part_idx = cell_to_part[cell_idx]
        if part_idx >= len(parts):
            continue
        cell = cells[cell_idx]
        if not cell or cell in DONE_STATUS_EMOJIS | ACTIVE_STATUS_EMOJIS:
            continue
        if cell in ("—", "-", ""):
            continue
        if has_strikethrough(cell):
            continue
        # Cell without ~~ → wrap it
        # Remove ** surrounding ** if present
        clean = re.sub(r"^\*\*(.+)\*\*$", r"\1", cell.strip())
        parts[part_idx] = f" ~~{clean}~~ "
        changed = True
    return parts, changed


def process_file(registry_path, fix=False, fix_t2=False, exit_nonzero=False):
    with open(registry_path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    indices, warning = find_column_indices(lines)
    if warning:
        print(f"⚠️  {warning}", file=sys.stderr)
    name_col = indices["Name"]

    all_issues = []
    new_lines = list(lines)

    for i, line in enumerate(lines):
        line_num = i + 1
        if not is_table_row(line):
            continue
        cells = parse_cells(line)
        if len(cells) < 3:
            continue

        t2_issues = check_t2(cells, line_num, indices)
        nc_issues = check_nc(cells, line_num, name_col)
        all_issues.extend(t2_issues)
        all_issues.extend(nc_issues)

        if fix_t2 and t2_issues and is_done_row(cells):
            parts = new_lines[i].rstrip("\n").split("|")
            parts, changed = fix_t2_row(parts, cells, indices)
            if changed:
                new_lines[i] = "|".join(parts) + "\n"

        if fix and nc_issues:
            # Fix NC in this line
            parts = line.rstrip("\n").split("|")
            name_part = name_col + 1  # parts[0] empty due to-leading "|"
            if len(parts) >= name_part + 1:
                original_cell = parts[name_part]
                stripped_content = original_cell.strip()

                # Handle ~~...~~ wrapper
                has_strike_before = stripped_content.startswith("~~") and "~~" in stripped_content[2:]
                if has_strike_before:
                    # Extract content from ~~...~~ with trailing text
                    inner_match = re.match(r"~~(.+?)~~(.*)", stripped_content, re.DOTALL)
                    if inner_match:
                        inner = inner_match.group(1)
                        tail = inner_match.group(2)
                        cleaned_inner = clean_name_cell(inner)
                        cleaned_tail = clean_name_cell(tail) if tail.strip() else ""
                        cleaned_cell = f"~~{cleaned_inner}~~"
                        if cleaned_tail:
                            cleaned_cell += f" {cleaned_tail}"
                    else:
                        cleaned_cell = clean_name_cell(stripped_content)
                else:
                    # Active line (without ~~)
                    inner_match = re.match(r"\*?\*?(.+?)\*?\*?$", stripped_content, re.DOTALL)
                    inner = inner_match.group(1) if inner_match else stripped_content
                    # Strip ** surrounding
                    inner = re.sub(r"^\*\*(.+)\*\*$", r"\1", inner)
                    cleaned = clean_name_cell(inner)
                    # Restore ** if present
                    if stripped_content.startswith("**"):
                        cleaned_cell = f"**{cleaned}**"
                    else:
                        cleaned_cell = cleaned

                parts[name_part] = f" {cleaned_cell} "
                new_lines[i] = "|".join(parts) + "\n"

    if (fix or fix_t2) and any(new_lines[i] != lines[i] for i in range(len(lines))):
        with open(registry_path, "w", encoding="utf-8") as f:
            f.writelines(new_lines)
        print(f"   ✅ Fixed {sum(1 for i in range(len(lines)) if new_lines[i] != lines[i])} lines")

    # Summary
    t2_count = sum(1 for iss in all_issues if iss["type"] == "T2")
    nc_count = sum(1 for iss in all_issues if iss["type"] == "NC")

    print(f"\ncheck-wp-format.py — {registry_path}")
    print(f"  T2 (formatting done-lines): {t2_count} violations")
    print(f"  NC (name pollution):          {nc_count} violations")

    if all_issues:
        print("\nDetails:")
        for iss in all_issues:
            print(f"  [{iss['type']}] line {iss['line']}: {iss['message']}")

    if not all_issues:
        print("  ✅ No violations found")

    if exit_nonzero and all_issues:
        sys.exit(1)

    return all_issues


if __name__ == "__main__":
    args = sys.argv[1:]
    fix_mode = "--fix" in args
    fix_t2_mode = "--fix-t2" in args
    exit_nonzero = "--exit-nonzero" in args
    args = [a for a in args if not a.startswith("--")]

    if args:
        registry = args[0]
    else:
        iwe = os.environ.get("IWE_ROOT", os.path.expanduser("~/IWE"))
        gov = os.environ.get("IWE_GOVERNANCE_REPO", "DS-strategy")
        # Try to find REGISTRY via env-var repo name
        for gov_name in [gov]:
            candidate = os.path.join(iwe, gov_name, "docs", "WP-REGISTRY.md")
            if os.path.exists(candidate):
                registry = candidate
                break
        else:
            print("Not found WP-REGISTRY.md. Specify the path explicitly.", file=sys.stderr)
            sys.exit(1)

    process_file(registry, fix=fix_mode, fix_t2=fix_t2_mode, exit_nonzero=exit_nonzero)
