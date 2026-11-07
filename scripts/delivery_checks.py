#!/usr/bin/env python3
# see WP-415 Ф-В2 (translation delivery tests: formal + content)
"""Delivery checks for the RU→EN translation pipeline.

Formal checks verify the translated artifact physically arrived intact.
Content checks verify glossary terms were actually translated, split by
tier (Tier-1 leftovers are a hard failure, Tier-2/3 are a warning).

Usage (CLI, called by the sync workflow):
    python3 scripts/delivery_checks.py --source docs/README.md \\
        --output ../en-out/docs/README.md
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).parent))
from glossary_source import GlossaryError, load_glossary  # noqa: E402
from translate import parse_frontmatter, strip_code_for_guard  # noqa: E402


@dataclass
class GlossaryTerm:
    term_ru: str
    tier: int


@dataclass
class ContentReport:
    tier1_violations: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def passed(self) -> bool:
        return not self.tier1_violations


def load_glossary_terms(manifest_path: Path) -> list[GlossaryTerm]:
    """Glossary terms with their check tier, from the same loader translate.py uses."""
    with manifest_path.open(encoding="utf-8") as f:
        manifest = yaml.safe_load(f) or {}
    glossary = load_glossary(manifest, manifest_path.parent)
    return [GlossaryTerm(term_ru=t.term_ru, tier=t.tier) for t in glossary.terms]


def check_formal(source_path: Path, output_path: Path) -> list[str]:
    """Return formal delivery violations (empty list = passed).

    Checks: output exists, non-empty, valid UTF-8, frontmatter parses
    (when source has frontmatter), output not older than source.
    """
    violations: list[str] = []

    if not output_path.exists():
        return [f"missing: {output_path} does not exist"]

    if output_path.stat().st_size == 0:
        violations.append(f"empty: {output_path} is 0 bytes")
        return violations  # remaining checks need readable content

    try:
        output_text = output_path.read_text(encoding="utf-8")
    except UnicodeDecodeError as e:
        return violations + [f"encoding: {output_path} is not valid UTF-8 ({e})"]

    source_meta, _ = parse_frontmatter(source_path.read_text(encoding="utf-8"))
    if source_meta:
        output_meta, _ = parse_frontmatter(output_text)
        if not output_meta:
            violations.append(f"frontmatter: {output_path} has no parsable frontmatter, source did")

    if output_path.stat().st_mtime < source_path.stat().st_mtime:
        violations.append(
            f"stale: {output_path} is older than source {source_path} — not regenerated"
        )

    return violations


def check_content(output_text: str, glossary_terms: list[GlossaryTerm]) -> ContentReport:
    """Check whether glossary terms leaked untranslated into the output.

    Tier-1 leftovers are a hard failure; Tier-2/3 leftovers are a warning.
    Cyrillic inside fenced/inline code blocks is exempt (code, not prose).
    """
    report = ContentReport()
    clean_text = strip_code_for_guard(output_text)

    for term in glossary_terms:
        pattern = r"(?<!\w)" + re.escape(term.term_ru) + r"(?!\w)"
        if not re.search(pattern, clean_text, flags=re.UNICODE):
            continue
        message = f"untranslated term (tier {term.tier}): «{term.term_ru}»"
        if term.tier == 1:
            report.tier1_violations.append(message)
        else:
            report.warnings.append(message)

    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="Delivery checks for translated documents.")
    parser.add_argument("--source", required=True, help="Path to RU source file")
    parser.add_argument("--output", required=True, help="Path to translated EN output file")
    parser.add_argument(
        "--manifest",
        default=str(Path(__file__).parent.parent / "translation-manifest.yaml"),
        help="Path to translation-manifest.yaml (its glossary: block names the term files)",
    )
    args = parser.parse_args()

    source_path = Path(args.source)
    output_path = Path(args.output)

    formal_violations = check_formal(source_path, output_path)
    if formal_violations:
        for v in formal_violations:
            print(f"FORMAL FAIL: {v}", file=sys.stderr)
        return 1

    try:
        glossary_terms = load_glossary_terms(Path(args.manifest))
    except GlossaryError as exc:
        print(f"GLOSSARY FAIL: {exc}", file=sys.stderr)
        return 1
    content_report = check_content(output_path.read_text(encoding="utf-8"), glossary_terms)

    for w in content_report.warnings:
        print(f"CONTENT WARN: {w}", file=sys.stderr)
    if not content_report.passed:
        for v in content_report.tier1_violations:
            print(f"CONTENT FAIL: {v}", file=sys.stderr)
        return 1

    print(f"OK: {output_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
