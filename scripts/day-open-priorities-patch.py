#!/usr/bin/env python3
"""Patch DayPlan «Требует внимания» with priorities.yaml discrepancies.

Same detection logic as the two blocking checks in extensions/day-open.checks.md
(WP-453 missing-from-plan class, phys_hours fallback class) — but writes the
finding into the DayPlan's own «Требует внимания» section instead of blocking
the commit. Runs deterministically after LLM Fill, before Checks (same slot as
day-open-budget-patch.py), so the marker is already staged by the time
day-open-checks-runner.sh's now-non-blocking versions of these checks run.
"""

import re
import sys
import argparse
from pathlib import Path

try:
    import yaml as _yaml
    _YAML_AVAILABLE = True
except ImportError:
    _YAML_AVAILABLE = False

PHYS_HOURS_CEILING = 14.0
ATTENTION_HEADER_RE = re.compile(r"(<summary><b>Требует внимания</b></summary>\s*\n)")


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--dayplan", required=True, help="Path to DayPlan .md")
    p.add_argument("--priorities", required=True, help="Path to priorities.yaml")
    return p.parse_args()


def load_priorities(path):
    text = Path(path).read_text(encoding="utf-8")
    if _YAML_AVAILABLE:
        return _yaml.safe_load(text) or {}
    # PyYAML unavailable: only the two keys this script reads, same fallback
    # class as day-open-budget-patch.py's regex path. Scope the dash-items to
    # the today: block — a bare list regex over the whole file would collect
    # WP items from ANY other yaml key (cold review 2026-08-21-17, Medium).
    today_block = re.search(
        r"^today:\s*\n((?:^[ \t]+-[^\n]*\n?)+)", text, re.MULTILINE
    )
    today = (
        re.findall(r"^\s*-\s*(WP-\d+)", today_block.group(1), re.MULTILINE)
        if today_block
        else []
    )
    m = re.search(r"^phys_hours:\s*([\d.]+)", text, re.MULTILINE)
    return {"today": today, "phys_hours": float(m.group(1)) if m else None}


def extract_plan_table(dayplan_text):
    """Same scoping fix as day-open.checks.md (bug-2026-07-01): only the
    «План на сегодня» table, not the whole file — a WP number can legitimately
    appear elsewhere (e.g. a cross-reference in another RP's row) without being
    IN the plan."""
    lines = dayplan_text.splitlines()
    out = []
    in_section = False
    for line in lines:
        if "<summary><b>План на сегодня</b></summary>" in line:
            in_section = True
            continue
        if in_section:
            if "</details>" in line:
                break
            if line.startswith("|"):
                out.append(line)
    return out


def missing_priority_wps(today_wps, plan_table):
    """Same two-format match as day-open.checks.md (bug-2026-07-16 rewrite):
    column 3 bare number OR a WP-prefixed number anywhere in that row."""
    missing = []
    for wp in today_wps:
        num = str(wp).replace("WP-", "").strip()
        found = False
        for row in plan_table:
            cells = row.split("|")
            col3 = cells[3].strip() if len(cells) > 3 else ""
            if col3 == num or re.search(rf"WP-{re.escape(num)}(?!\d)", row):
                found = True
                break
        if not found:
            missing.append(f"WP-{num}")
    return missing


def phys_hours_finding(priorities):
    """Returns a warning string, or None if phys_hours is set and sane."""
    val = priorities.get("phys_hours")
    if val is None:
        return "phys_hours не задан в priorities.yaml — физ. часы будут посчитаны с fallback 1.0x (не прогноз, а копия суммы РП)"
    if float(val) > PHYS_HOURS_CEILING:
        return f"phys_hours={val} превышает потолок пилота ({PHYS_HOURS_CEILING:.0f}ч) — физически маловероятно для одного дня"
    return None


def append_attention_lines(text, findings):
    lines = "".join(f"- ⚠️ {f}\n" for f in findings)
    patched, n = ATTENTION_HEADER_RE.subn(r"\1" + lines, text, count=1)
    return patched if n else text


def main():
    args = parse_args()
    dayplan = Path(args.dayplan)
    text = dayplan.read_text(encoding="utf-8")
    priorities = load_priorities(args.priorities)

    findings = []

    today_wps = priorities.get("today") or []
    plan_table = extract_plan_table(text)
    missing = missing_priority_wps(today_wps, plan_table)
    if missing:
        findings.append(
            f"{', '.join(missing)} из priorities.yaml отсутствует в таблице «План на сегодня»"
        )

    phys_finding = phys_hours_finding(priorities)
    if phys_finding:
        findings.append(phys_finding)

    if not findings:
        print("priorities-patch: no discrepancies found", file=sys.stderr)
        return

    patched = append_attention_lines(text, findings)
    if patched == text:
        print(
            f"priorities-patch: {len(findings)} finding(s) but «Требует внимания» header not found — cannot patch, findings lost",
            file=sys.stderr,
        )
        return

    dayplan.write_text(patched, encoding="utf-8")
    print(f"priorities-patch: {len(findings)} finding(s) written to «Требует внимания»", file=sys.stderr)
    for f in findings:
        print(f"  - {f}", file=sys.stderr)


if __name__ == "__main__":
    main()
