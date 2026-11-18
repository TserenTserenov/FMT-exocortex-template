#!/usr/bin/env python3
"""
Sync communication-style layers to downstream files.

Three-layer architecture (WP-388 F8, ArchGate 3 June):
  L0 (platform) - PACK-digital-platform/.../communication-style-base.md -> all downstream
  L1 (author)   - author config (--author-style)                        -> author downstream
  L2 (user)     - per-user, not managed by this script

Source of truth: PACK-digital-platform (ArchGate decision).
Downstream targets loaded from scripts/sync-communication-style.yaml (author-local, gitignored).
See scripts/sync-communication-style.yaml.example for the template.

Usage:
    # L0 only (all downstream from yaml config)
    python3 scripts/sync-communication-style.py --iwe-root ~/IWE

    # L0 + L1 (author downstream)
    python3 scripts/sync-communication-style.py --iwe-root ~/IWE \\
        --author-style path/to/communication-style-author.md

    # Check drift (Week Close)
    python3 scripts/sync-communication-style.py --iwe-root ~/IWE --check

    # Hermes memory export
    python3 scripts/sync-communication-style.py --iwe-root ~/IWE \\
        --author-style path/to/communication-style-author.md \\
        --hermes-export /tmp/hermes-style-rules.txt
"""

import argparse
import hashlib
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML required. Install: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

# L0 source of truth (Pack) - relative to IWE root
PACK_BASE_FILE = Path("PACK-digital-platform/pack/digital-platform/02-domain-entities/communication-style-base.md")

# Fallback: FMT copy (if Pack unavailable)
FMT_BASE_FILE = Path("FMT-exocortex-template/memory/communication-style-base.md")

# Markers for markdown files
MD_START = "<!-- COMMUNICATION-STYLE-BASE-START -->"
MD_END = "<!-- COMMUNICATION-STYLE-BASE-END -->"

# Markers for JS/TS files
JS_START = "// COMMUNICATION-STYLE-BASE-START"
JS_END = "// COMMUNICATION-STYLE-BASE-END"


def load_downstream_files(script_dir: Path) -> list:
    """Load downstream targets from yaml config (author-local, gitignored)."""
    config_path = script_dir / "sync-communication-style.yaml"
    if not config_path.exists():
        example_path = script_dir / "sync-communication-style.yaml.example"
        if example_path.exists():
            print(f"WARNING: {config_path.name} not found.", file=sys.stderr)
            print(f"  Copy from .yaml.example and fill in your paths:", file=sys.stderr)
            print(f"  cp {example_path} {config_path}", file=sys.stderr)
            sys.exit(1)
        print(f"ERROR: No config at {config_path} or {example_path}", file=sys.stderr)
        sys.exit(1)

    with open(config_path, encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    if not cfg or "downstream" not in cfg:
        print(f"ERROR: {config_path} must have a 'downstream' key", file=sys.stderr)
        sys.exit(1)

    result = []
    for entry in cfg["downstream"]:
        p = entry.get("path", "")
        ftype = entry.get("type", "markdown")
        layer = entry.get("layer", "l0")
        if "{{" in p:
            print(f"  SKIP  {p} (unresolved placeholder)")
            continue
        result.append((p, ftype, layer))

    return result

def strip_frontmatter(text: str) -> str:
    """Strip YAML frontmatter."""
    if text.startswith("---"):
        parts = text.split("---", 2)
        if len(parts) >= 3:
            return parts[2].strip()
    return text.strip()


def read_base_content(iwe_root: Path) -> str:
    """Read L0 from Pack (SoT). Fallback: FMT copy."""
    pack_path = iwe_root / PACK_BASE_FILE
    if pack_path.exists():
        print(f"Source: Pack (SoT) - {pack_path}")
        return strip_frontmatter(pack_path.read_text(encoding="utf-8"))

    fmt_path = iwe_root / FMT_BASE_FILE
    if fmt_path.exists():
        print(f"WARNING: Pack SoT not found, falling back to FMT copy: {fmt_path}", file=sys.stderr)
        return strip_frontmatter(fmt_path.read_text(encoding="utf-8"))

    print(f"ERROR: L0 base file not found in Pack or FMT", file=sys.stderr)
    sys.exit(1)


def read_author_content(author_path: str) -> str:
    """Read L1 communication-style-author.md."""
    path = Path(author_path)
    if not path.exists():
        print(f"WARNING: L1 author file not found: {path}, skipping L1 merge")
        return ""
    return strip_frontmatter(path.read_text(encoding="utf-8"))


def merge_l0_l1(l0: str, l1: str) -> str:
    """Merge L0 + L1 into single block for author downstream."""
    if not l1:
        return l0
    return f"""{l0}

---

<!-- L1: авторские правила (поверх L0) -->

{l1}"""


def generate_hermes_export(l0: str, l1: str, output_path: str) -> None:
    """Generate compact rules text for Hermes memory/skill."""
    merged = merge_l0_l1(l0, l1)

    # Extract numbered rules
    rules = []
    for line in merged.split("\n"):
        line = line.strip()
        if re.match(r"^\d+\.\s+\*\*", line) or re.match(r"^###\s+R\d+", line):
            # Strip markdown bold
            clean = re.sub(r"\*\*([^*]+)\*\*", r"\1", line)
            rules.append(clean)

    header = "# Правила разговорного стиля IWE (L0 + L1)\n"
    header += "# Автогенерация: sync-communication-style.py\n"
    header += f"# Правил: {len(rules)}\n\n"

    content = header + "\n".join(rules) + "\n"

    Path(output_path).write_text(content, encoding="utf-8")
    print(f"  HERMES  {output_path} ({len(rules)} rules)")


def update_markdown(path: Path, content: str) -> bool:
    """Update markdown file between MD markers."""
    if not path.exists():
        print(f"WARNING: file not found: {path}")
        return False

    text = path.read_text(encoding="utf-8")
    pattern = f"({re.escape(MD_START)})\\n*.*?\\n*({re.escape(MD_END)})"
    replacement = f"{MD_START}\\n\\n{content}\\n\\n{MD_END}"
    new_text, count = re.subn(pattern, replacement, text, flags=re.DOTALL)

    if count == 0:
        print(f"WARNING: markers not found in {path}")
        return False

    path.write_text(new_text, encoding="utf-8")
    print(f"  OK  {path}")
    return True


def update_js(path: Path, content: str) -> bool:
    """Update JS/TS file between JS markers."""
    if not path.exists():
        print(f"WARNING: file not found: {path}")
        return False

    text = path.read_text(encoding="utf-8")
    escaped = content.replace("\\", "\\\\").replace("`", "\\`").replace("$", "\\$")
    pattern = f"({re.escape(JS_START)})\\n*.*?\\n*({re.escape(JS_END)})"
    replacement = f"{JS_START}\\n{escaped}\\n{JS_END}"
    new_text, count = re.subn(pattern, replacement, text, flags=re.DOTALL)

    if count == 0:
        print(f"WARNING: markers not found in {path}")
        return False

    path.write_text(new_text, encoding="utf-8")
    print(f"  OK  {path}")
    return True


def extract_between_markers(text: str, start_marker: str, end_marker: str) -> str:
    """Extract content between markers."""
    pattern = f"{re.escape(start_marker)}\\n*(.+?)\\n*{re.escape(end_marker)}"
    m = re.search(pattern, text, re.DOTALL)
    if m:
        return m.group(1).strip()
    return ""


def check_drift(iwe_root: Path, l0_content: str, downstream_files: list) -> int:
    """Check downstream copies against SoT. Returns drift count."""
    l0_hash = hashlib.md5(l0_content.encode()).hexdigest()
    drift_count = 0

    print(f"\nSoT md5: {l0_hash}")
    print(f"Checking {len(downstream_files)} downstream files...\n")

    for rel_path, ftype, layer_mode in downstream_files:
        path = iwe_root / rel_path
        if not path.exists():
            print(f"  SKIP  {rel_path} (not found)")
            continue

        text = path.read_text(encoding="utf-8")

        if ftype == "markdown":
            embedded = extract_between_markers(text, MD_START, MD_END)
        elif ftype == "js":
            embedded = extract_between_markers(text, JS_START, JS_END)
        else:
            continue

        if not embedded:
            print(f"  WARN  {rel_path} (no markers)")
            drift_count += 1
            continue

        # For l0+l1 files, take only L0 part (before "<!-- L1:")
        if layer_mode == "l0+l1" and "<!-- L1:" in embedded:
            embedded = embedded.split("<!-- L1:")[0].strip()

        # JS target stores escaped content (see update_js) - compare with escaped
        # reference, otherwise eternal DRIFT (M4, WP-388 F8 review).
        if ftype == "js":
            expected = l0_content.replace("\\", "\\\\").replace("`", "\\`").replace("$", "\\$")
            expected_hash = hashlib.md5(expected.encode()).hexdigest()
        else:
            expected_hash = l0_hash

        embedded_hash = hashlib.md5(embedded.encode()).hexdigest()

        if embedded_hash == expected_hash:
            print(f"  OK    {rel_path}")
        else:
            print(f"  DRIFT {rel_path} (md5: {embedded_hash})")
            drift_count += 1

    return drift_count


def main():
    parser = argparse.ArgumentParser(
        description="Sync communication style layers to downstream files (SoT: PACK-digital-platform)"
    )
    parser.add_argument(
        "--author-style",
        help="Path to L1 author style file (communication-style-author.md)",
    )
    parser.add_argument(
        "--hermes-export",
        help="Path to write Hermes-compatible rules export",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Only check for drift (md5 comparison), don't write",
    )
    parser.add_argument(
        "--iwe-root",
        default=str(Path.home() / "IWE"),
        help="IWE workspace root (default: ~/IWE)",
    )
    args = parser.parse_args()

    iwe_root = Path(args.iwe_root)
    script_dir = iwe_root / "FMT-exocortex-template" / "scripts"
    downstream_files = load_downstream_files(script_dir)
    l0 = read_base_content(iwe_root)
    l1 = read_author_content(args.author_style) if args.author_style else ""

    # Drift check mode
    if args.check:
        drift_count = check_drift(iwe_root, l0, downstream_files)
        if drift_count == 0:
            print(f"\nAll copies in sync.")
        else:
            print(f"\n{drift_count} drift(s) found. Run without --check to fix.")
        return 0 if drift_count == 0 else 1

    # Sync mode
    ok_count = 0
    skip_count = 0

    print(f"Syncing L0 ({len(l0)} chars)" + (f" + L1 ({len(l1)} chars)" if l1 else "") + "...")

    for rel_path, ftype, layer_mode in downstream_files:
        path = iwe_root / rel_path
        if not path.exists():
            print(f"SKIP {rel_path} (not found)")
            skip_count += 1
            continue

        # Select content based on layer
        if layer_mode == "l0+l1" and l1:
            content = merge_l0_l1(l0, l1)
        else:
            content = l0

        if ftype == "markdown":
            if update_markdown(path, content):
                ok_count += 1
        elif ftype == "js":
            if update_js(path, content):
                ok_count += 1
        else:
            print(f"UNKNOWN type {ftype} for {rel_path}")
            skip_count += 1

    # Hermes export
    if args.hermes_export:
        generate_hermes_export(l0, l1, args.hermes_export)

    print(f"Done: {ok_count} updated, {skip_count} skipped.")
    return 0 if skip_count == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
