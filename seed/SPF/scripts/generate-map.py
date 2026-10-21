#!/usr/bin/env python3
"""
Auto-MAP Generator for SPF Packs.

Reads YAML frontmatter from all .md files in a Pack directory
and generates:
1. Updated MAP file (07-map/DOMAIN.MAP.001.md)
2. Entity Index for manifest (stdout or --manifest flag)

Usage:
    python generate-map.py <pack-directory>
    python generate-map.py <pack-directory> --manifest  # also update manifest

Example:
    python generate-map.py ../PACK-digital-platform/pack/digital-platform/

Requirements:
    pip install pyyaml
"""

import sys
import os
import re
import yaml
from pathlib import Path
from datetime import datetime, date
from collections import defaultdict
from typing import Optional


def parse_frontmatter(filepath):
    # type: (Path) -> Optional[dict]
    """Extract YAML frontmatter from a markdown file."""
    try:
        content = filepath.read_text(encoding="utf-8")
    except Exception:
        return None

    # Match YAML frontmatter between --- delimiters
    match = re.match(r"^---\s*\n(.*?)\n---", content, re.DOTALL)
    if not match:
        return None

    try:
        data = yaml.safe_load(match.group(1))
        if isinstance(data, dict) and "id" in data:
            data["_filepath"] = str(filepath)
            # If no name in frontmatter, try to extract from heading or filename
            if "name" not in data:
                heading_match = re.search(
                    r"^##\s+\[.*?\]\s+(.+)$", content, re.MULTILINE
                )
                if heading_match:
                    data["name"] = heading_match.group(1).strip()
                else:
                    # Derive from filename slug
                    slug = filepath.stem
                    # Remove ID prefix (e.g., "DP.M.001-" from "DP.M.001-knowledge-extraction")
                    slug = re.sub(r"^[A-Z]+\.[A-Z]+\.\d+-?", "", slug)
                    if slug:
                        data["name"] = slug.replace("-", " ").title()
            return data
    except yaml.YAMLError:
        pass
    return None


def classify_kind(entity_id: str) -> str:
    """Extract kind code from entity ID (e.g., DP.M.001 -> M)."""
    parts = entity_id.split(".")
    if len(parts) >= 3:
        return parts[1]
    return "UNKNOWN"


KIND_LABELS = {
    "D": "Distinctions",
    "R": "Roles",
    "M": "Methods",
    "WP": "Work Products",
    "FM": "Failure Modes",
    "SOTA": "SoTA Annotations",
    "MAP": "Maps",
    "CHR": "Characteristics",
    "OA": "Objects of Attention",
}


def generate_map(pack_dir: Path, domain: str) -> str:
    """Generate MAP content from Pack directory."""
    entities = []
    warnings = []

    # Walk all .md files
    for md_file in sorted(pack_dir.rglob("*.md")):
        # Skip templates and non-entity files
        if md_file.name.startswith("_"):
            continue
        if md_file.name in ("00-pack-manifest.md", "ontology.md"):
            continue

        fm = parse_frontmatter(md_file)
        if fm:
            entities.append(fm)
            # Validation warnings
            if "summary" not in fm:
                warnings.append(f"Missing `summary`: {fm['id']} ({md_file.name})")

    # Group by kind
    by_kind = defaultdict(list)
    for e in entities:
        kind = classify_kind(e["id"])
        by_kind[kind].append(e)

    # Build MAP
    today = date.today().isoformat()
    lines = [
        f"---",
        f"id: {domain}.MAP.001",
        f"name: Pack Navigation Map",
        f"scope: full-pack",
        f"created: {today}",
        f"last_updated: {today}",
        f"generated: true",
        f"---",
        f"",
        f"# [{domain}.MAP.001] Pack Navigation Map",
        f"",
        f"> Auto-generated from frontmatter on {today}. Do not edit manually.",
        f"",
        f"---",
        f"",
        f"## Statistics",
        f"",
        f"| Kind | Count |",
        f"|------|-------|",
    ]

    for kind in sorted(by_kind.keys()):
        label = KIND_LABELS.get(kind, kind)
        lines.append(f"| {label} ({kind}) | {len(by_kind[kind])} |")

    lines.append(f"| **Total** | **{len(entities)}** |")
    lines.append("")

    # Sections per kind
    for kind in ["D", "R", "M", "WP", "FM", "SOTA", "MAP"]:
        if kind not in by_kind:
            continue
        label = KIND_LABELS.get(kind, kind)
        lines.append(f"## {label}")
        lines.append("")
        lines.append(f"| ID | Name | Summary | Status |")
        lines.append(f"|----|------|---------|--------|")

        for e in sorted(by_kind[kind], key=lambda x: x["id"]):
            eid = e["id"]
            name = e.get("name", "—")
            summary = e.get("summary", "—")
            status = e.get("status", "—")
            lines.append(f"| {eid} | {name} | {summary} | {status} |")

        lines.append("")

    # Extended kinds (not in base set)
    base_kinds = {"D", "R", "M", "WP", "FM", "SOTA", "MAP", "CHR", "OA"}
    extended = {k: v for k, v in by_kind.items() if k not in base_kinds}
    if extended:
        lines.append("## Domain-Specific Entities")
        lines.append("")
        for kind in sorted(extended.keys()):
            label = KIND_LABELS.get(kind, kind)
            lines.append(f"### {label}")
            lines.append("")
            lines.append(f"| ID | Name | Summary | Status |")
            lines.append(f"|----|------|---------|--------|")
            for e in sorted(extended[kind], key=lambda x: x["id"]):
                eid = e["id"]
                name = e.get("name", "—")
                summary = e.get("summary", "—")
                status = e.get("status", "—")
                lines.append(f"| {eid} | {name} | {summary} | {status} |")
            lines.append("")

    # Warnings
    if warnings:
        lines.append("## Warnings")
        lines.append("")
        for w in warnings:
            lines.append(f"- {w}")
        lines.append("")

    # Staleness check
    stale = []
    for e in entities:
        last_updated = e.get("last_updated")
        if last_updated:
            if isinstance(last_updated, str):
                try:
                    lu = datetime.strptime(last_updated, "%Y-%m-%d").date()
                except ValueError:
                    continue
            elif isinstance(last_updated, date):
                lu = last_updated
            else:
                continue
            days = (date.today() - lu).days
            if days > 90:
                stale.append((e["id"], days))

    if stale:
        lines.append("## Staleness Warnings (>90 days since update)")
        lines.append("")
        lines.append("| ID | Days Since Update |")
        lines.append("|----|-------------------|")
        for eid, days in sorted(stale, key=lambda x: -x[1]):
            lines.append(f"| {eid} | {days} |")
        lines.append("")

    lines.append("---")
    lines.append("")
    lines.append(f"*Generated by `scripts/generate-map.py` on {today}*")

    return "\n".join(lines)


def generate_entity_index(pack_dir: Path) -> str:
    """Generate Entity Index table for manifest."""
    entities = []
    for md_file in sorted(pack_dir.rglob("*.md")):
        if md_file.name.startswith("_"):
            continue
        if md_file.name in ("00-pack-manifest.md", "ontology.md"):
            continue
        fm = parse_frontmatter(md_file)
        if fm:
            entities.append(fm)

    lines = [
        "## Entity Index",
        "",
        "| ID | Name | Kind | Summary | Status |",
        "|----|------|------|---------|--------|",
    ]

    for e in sorted(entities, key=lambda x: x["id"]):
        eid = e["id"]
        name = e.get("name", "—")
        kind = classify_kind(eid)
        summary = e.get("summary", "—")
        status = e.get("status", "—")
        lines.append(f"| {eid} | {name} | {kind} | {summary} | {status} |")

    return "\n".join(lines)


def update_manifest_file(pack_dir: Path, entity_index: str):
    """Insert or replace Entity Index section in 00-pack-manifest.md."""
    manifest = pack_dir / "00-pack-manifest.md"
    if not manifest.exists():
        print(f"Manifest not found: {manifest}")
        return

    content = manifest.read_text(encoding="utf-8")
    today = date.today().isoformat()
    index_with_note = (
        entity_index
        + f"\n\n> *Auto-generated by `generate-map.py` on {today}*\n"
    )

    # Replace existing Entity Index section
    pattern = re.compile(
        r"## Entity Index\n.*?(?=\n## |\Z)", re.DOTALL
    )
    if pattern.search(content):
        # Lambda replacement (not a string) avoids re treating backslash
        # sequences in entity summaries (e.g. "\d") as template backreferences.
        new_content = pattern.sub(lambda m: index_with_note, content)
    else:
        # Insert before "## Upstream" or "## Changelog" or at end
        for anchor in ["## Upstream", "## Changelog", "## Maintainers"]:
            pos = content.find(anchor)
            if pos > 0:
                new_content = (
                    content[:pos] + index_with_note + "\n" + content[pos:]
                )
                break
        else:
            new_content = content.rstrip() + "\n\n" + index_with_note

    manifest.write_text(new_content, encoding="utf-8")
    print(f"Manifest updated: {manifest}")


def detect_domain(pack_dir):
    # type: (Path) -> str
    """Detect domain code from manifest."""
    manifest = pack_dir / "00-pack-manifest.md"
    if manifest.exists():
        # Try YAML frontmatter first
        fm = parse_frontmatter(manifest)
        if fm and "pack_id" in fm:
            return fm["pack_id"]
        # Try parsing from body text: "**Pack ID**: `DP`" or "pack_id: DP"
        try:
            content = manifest.read_text(encoding="utf-8")
            match = re.search(r"Pack ID[*]*:\s*`?([A-Z]{2,4})`?", content)
            if match:
                return match.group(1)
        except Exception:
            pass
    # Fallback: extract from first entity file's ID prefix
    for md_file in sorted(pack_dir.rglob("*.md")):
        if md_file.name.startswith("_") or md_file.name == "00-pack-manifest.md":
            continue
        fm = parse_frontmatter(md_file)
        if fm and "id" in fm:
            parts = fm["id"].split(".")
            if len(parts) >= 2:
                return parts[0]
    # Last fallback: directory name
    return pack_dir.name.upper()[:2]


def main():
    if len(sys.argv) < 2:
        print("Usage: python generate-map.py <pack-directory> [--manifest]")
        sys.exit(1)

    pack_dir = Path(sys.argv[1]).resolve()
    update_manifest = "--manifest" in sys.argv

    if not pack_dir.is_dir():
        print(f"Error: {pack_dir} is not a directory")
        sys.exit(1)

    domain = detect_domain(pack_dir)
    print(f"Domain: {domain}")
    print(f"Pack directory: {pack_dir}")

    # Generate MAP
    map_content = generate_map(pack_dir, domain)
    map_dir = pack_dir / "07-map"
    map_dir.mkdir(exist_ok=True)
    map_file = map_dir / f"{domain}.MAP.001.md"
    map_file.write_text(map_content, encoding="utf-8")
    print(f"MAP written to: {map_file}")

    # Generate Entity Index
    entity_index = generate_entity_index(pack_dir)
    if update_manifest:
        update_manifest_file(pack_dir, entity_index)
    print(entity_index)


if __name__ == "__main__":
    main()
