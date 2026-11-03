#!/usr/bin/env python3
"""Assemble the English distribution tree from the Russian source.

The set of shipped files is the source's update-manifest.json (what a user's
installation receives) minus guide-kit/ (published as iwesys/guide-kit) and
the Russian language catalog, plus the product-page files. Code and configuration are copied verbatim; markdown
is never copied from the source: it keeps the translated version already in
the output tree. Files outside the set are removed from the output tree.

Usage: assemble_distribution.py <source dir> <output dir> [--check]
Exit codes: 0 clean; 1 usage; 2 offences (untranslated markdown missing from
the output, or Cyrillic left in the assembled tree). The offence list is
printed either way; --check only skips writing.
"""

import fnmatch
import json
import re
import shutil
import sys
from pathlib import Path

import yaml

CYRILLIC = re.compile("[\u0400-\u052f\u1c80-\u1c8f\u2de0-\u2dff\ua640-\ua69f]")
# The Russian language catalog stays in the Russian version only: each version
# ships the catalogs of its own language (WP-610 F8/F9, pilot decision 03.11).
EXCLUDED_PREFIXES = ("guide-kit/", ".claude/lib/locale/ru.json")
PAGE_FILES = (
    "README.md", "LICENSE", "SECURITY.md", "CODE_OF_CONDUCT.md",
    "PRIVACY.md", "CITATION.cff", "CODEOWNERS", "params.yaml.example",
)
# Written by the pipeline itself or by translate.py; never removed here.
GENERATED = (
    "CONTRIBUTING.md", "CHANGELOG.md", "update-manifest.json",
    ".github/ISSUE_TEMPLATE/", ".github/PULL_REQUEST_TEMPLATE.md",
    ".github/workflows/no-cyrillic-gate.yml", "docs/assets/orz-cycle.svg",
    ".translation-state.yaml", "badge-data.json", ".git/",
)


def distribution_set(source: Path) -> set[str]:
    manifest = json.loads((source / "update-manifest.json").read_text(encoding="utf-8"))
    paths = {f["path"] for f in manifest["files"] if not f["path"].startswith(EXCLUDED_PREFIXES)}
    paths.update(name for name in PAGE_FILES if (source / name).is_file())
    return paths


def adapted_patterns(source: Path) -> list[str]:
    """Paths the translation manifest marks as translated or hand-adapted (categories D, I, G)."""
    manifest = yaml.safe_load((source / "translation-manifest.yaml").read_text(encoding="utf-8"))
    categories = manifest.get("categories", {})
    return [pattern for key in ("D", "I", "G") for pattern in categories.get(key, {}).get("files", [])]


def is_adapted(path: str, patterns: list[str]) -> bool:
    if path.endswith(".md"):
        return True
    for pattern in patterns:
        if pattern.endswith("/") and path.startswith(pattern):
            return True
        if fnmatch.fnmatch(path, pattern.replace("**/", "*")) or path == pattern:
            return True
    return False


def is_generated(path: str) -> bool:
    return path.startswith(GENERATED)


def has_cyrillic(path: Path) -> bool:
    try:
        return bool(CYRILLIC.search(path.read_text(encoding="utf-8")))
    except (UnicodeDecodeError, OSError):
        return False


def assemble(source: Path, output: Path, write: bool = True) -> dict[str, list[str]]:
    wanted = distribution_set(source)
    patterns = adapted_patterns(source)
    report = {"copied": [], "removed": [], "missing_translation": [], "cyrillic": []}
    for path in sorted(wanted):
        if is_adapted(path, patterns):
            if not (output / path).is_file():
                report["missing_translation"].append(path)
            continue
        report["copied"].append(path)
        if write:
            target = output / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / path, target)
    for existing in sorted(p for p in output.rglob("*") if p.is_file() or p.is_symlink()):
        relative = existing.relative_to(output).as_posix()
        if relative not in wanted and not is_generated(relative):
            report["removed"].append(relative)
            if write:
                existing.unlink()
    for existing in sorted(p for p in output.rglob("*") if p.is_file() and ".git/" not in p.as_posix()):
        relative = existing.relative_to(output).as_posix()
        if CYRILLIC.search(relative) or has_cyrillic(existing):
            report["cyrillic"].append(relative)
    return report


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if a != "--check"]
    if len(args) != 2 or not all(Path(a).is_dir() for a in args):
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 1
    report = assemble(Path(args[0]), Path(args[1]), write="--check" not in argv)
    for key, paths in report.items():
        print(f"{key}: {len(paths)}")
        for path in paths[:25]:
            print(f"  {path}")
    return 2 if report["missing_translation"] or report["cyrillic"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
