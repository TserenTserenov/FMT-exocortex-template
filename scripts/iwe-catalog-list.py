#!/usr/bin/env python3
"""
iwe-catalog-list.py — derived catalog of all skills.

Scans ~/.claude/skills/*/SKILL.md, parses frontmatter, outputs markdown table.
No persistent file — generate on demand.

Usage:
  python scripts/iwe-catalog-list.py              # print catalog
  python scripts/iwe-catalog-list.py --fmt-only   # print FMT skills only
"""
import argparse
import glob
import pathlib
import re
import sys
from typing import List

SKILLS_DIR = pathlib.Path.home() / ".claude" / "skills"
FMT_SKILLS_DIR = pathlib.Path(__file__).parent.parent / ".claude" / "skills"

FM_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)


def parse_frontmatter(text: str) -> dict:
    m = FM_RE.match(text)
    if not m:
        return {}
    raw = m.group(1)
    data = {}
    for line in raw.splitlines():
        if ":" in line and not line.strip().startswith("#"):
            k, v = line.split(":", 1)
            data[k.strip()] = v.strip().strip('"').strip("'")
    return data


def scan_skills(skills_dir: pathlib.Path, source_label: str) -> List[dict]:
    results = []
    for skill_md in sorted(skills_dir.glob("*/SKILL.md")):
        text = skill_md.read_text(encoding="utf-8")
        fm = parse_frontmatter(text)
        name = fm.get("name", skill_md.parent.name)
        desc = fm.get("description", "—")
        layer = fm.get("layer", "?")
        status = fm.get("status", "active")
        sunset = fm.get("sunset", "")
        redirects = fm.get("redirects_to", "")
        src = fm.get("source", source_label)
        results.append({
            "name": name,
            "description": desc[:60] + "..." if len(desc) > 60 else desc,
            "layer": layer,
            "status": status,
            "sunset": sunset,
            "redirects": redirects,
            "source": src,
        })
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fmt-only", action="store_true", help="FMT skills only")
    args = parser.parse_args()

    entries = []

    # FMT skills (read from FMT repo, not user home)
    if FMT_SKILLS_DIR.exists():
        entries.extend(scan_skills(FMT_SKILLS_DIR, "FMT"))

    if not args.fmt_only and SKILLS_DIR.exists():
        # L3 skills: those in user home but not in FMT
        fmt_names = {e["name"] for e in entries}
        user_entries = scan_skills(SKILLS_DIR, "IWE")
        for e in user_entries:
            if e["name"] not in fmt_names:
                entries.append(e)

    # Output markdown table
    print("# Skills Catalog")
    print("")
    print("| Skill | Layer | Status | Source | Sunset | Description |")
    print("|-------|-------|--------|--------|--------|-------------|")
    for e in entries:
        desc = e["description"].replace("|", "\\|")
        sunset = e["sunset"] or "—"
        redirects = f" → {e['redirects']}" if e["redirects"] else ""
        print(f"| {e['name']}{redirects} | {e['layer']} | {e['status']} | {e['source']} | {sunset} | {desc} |")

    print("")
    print(f"_Total: {len(entries)} skills_")


if __name__ == "__main__":
    main()
