# see WP-617 Ф3 (translation engine reads graph terms snapshot)
"""Single glossary loader for the RU→EN translation pipeline.

Two inputs, both named in translation-manifest.yaml under ``glossary:``:

* ``snapshot`` — English names of graph concepts (written by
  scripts/export-glossary-snapshot.py). The graph is the source of truth.
* ``local`` — terms the graph does not have yet. A queue for moving them into
  the graph, not a second source: a local term that is already in the snapshot
  is an error, unless the local row only raises the check tier and agrees with
  the graph on the English name.

The loader reads files only; it never queries the graph. A live lookup on a
miss is allowed on the en-draft job only (decision D', WP-617 Ф4) and must not
reach the publication job — see scripts/tests/test_glossary_source.py.
"""

from __future__ import annotations

import csv
import re
from dataclasses import dataclass, field
from pathlib import Path

CYRILLIC_RE = re.compile(r"[А-Яа-яЁё]")
# Tier for a local row with a blank tier column — same default delivery_checks used before.
LOCAL_DEFAULT_TIER = 3


class GlossaryError(Exception):
    """The glossary inputs contradict each other; the pipeline must stop."""


# Where a term's English name comes from. Only GRAPH names are approved; a LOCAL
# name is a candidate awaiting approval and must be reported whenever it is used
# (WP-620 Ф4: an unapproved name never appears silently).
SOURCE_GRAPH = "graph"
SOURCE_LOCAL = "local"


@dataclass(frozen=True)
class Term:
    term_ru: str
    term_en: str
    tier: int
    source: str = SOURCE_GRAPH


@dataclass
class Glossary:
    terms: list[Term]
    notes: list[str] = field(default_factory=list)

    def as_mapping(self) -> dict[str, str]:
        return {t.term_ru: t.term_en for t in self.terms}

    def unapproved_mapping(self) -> dict[str, str]:
        """Local-glossary candidates (not approved in the graph): RU → EN."""
        return {t.term_ru: t.term_en for t in self.terms if t.source == SOURCE_LOCAL}


def _key(term_ru: str) -> str:
    return term_ru.strip().casefold()


def _read_rows(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        raise GlossaryError(f"glossary file not found: {path}")
    with path.open(encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def _graph_terms(
    rows: list[dict[str, str]], tier_by_level: dict[str, int], notes: list[str]
) -> tuple[dict[str, Term], set[str]]:
    """Snapshot rows → ({key: Term}, keys dropped for conflicting English names).

    Drops rows unusable for RU→EN and collapses duplicates that agree on English.
    """
    groups: dict[str, list[tuple[str, str, int]]] = {}
    no_cyrillic = 0
    for row in rows:
        ru = (row.get("term_ru") or "").strip()
        en = (row.get("term_en") or "").strip()
        level = (row.get("level") or "").strip()
        if not ru or not en:
            continue
        if not CYRILLIC_RE.search(ru):
            # The Russian name is filled with English text: it can never match a Russian document.
            no_cyrillic += 1
            continue
        if level not in tier_by_level:
            raise GlossaryError(
                f"snapshot level {level!r} ({row.get('code')}) has no entry in glossary.tier_by_level; "
                "decide its tier in translation-manifest.yaml"
            )
        groups.setdefault(_key(ru), []).append((ru, en, tier_by_level[level]))

    if no_cyrillic:
        notes.append(f"snapshot: {no_cyrillic} rows skipped, term_ru has no Cyrillic (graph data defect)")

    terms: dict[str, Term] = {}
    conflicted: set[str] = set()
    for key, variants in groups.items():
        english = {en for _, en, _ in variants}
        if len(english) > 1:
            notes.append(f"snapshot: «{variants[0][0]}» has conflicting English names {sorted(english)}, term skipped")
            conflicted.add(key)
            continue
        ru, en, _ = variants[0]
        terms[key] = Term(ru, en, min(tier for _, _, tier in variants))
    return terms, conflicted


def _local_terms(rows: list[dict[str, str]]) -> dict[str, Term]:
    terms: dict[str, Term] = {}
    for row in rows:
        ru = (row.get("term_ru") or "").strip()
        en = (row.get("term_en") or "").strip()
        if not ru or not en:
            continue
        tier_raw = (row.get("tier") or "").strip()
        tier = int(tier_raw) if tier_raw.isdigit() else LOCAL_DEFAULT_TIER
        if _key(ru) in terms:
            raise GlossaryError(f"local glossary lists «{ru}» twice")
        terms[_key(ru)] = Term(ru, en, tier, SOURCE_LOCAL)
    return terms


def merge(graph: dict[str, Term], conflicted: set[str], local: dict[str, Term], notes: list[str]) -> list[Term]:
    """Graph wins; a local row may only make an existing graph term stricter."""
    merged = dict(graph)
    for key, term in local.items():
        if key in conflicted:
            raise GlossaryError(
                f"«{term.term_ru}» is in the graph snapshot with conflicting English names; "
                "resolve it in the graph, the local glossary cannot override it"
            )
        g = graph.get(key)
        if g is None:
            merged[key] = term
            continue
        if term.tier >= g.tier:
            raise GlossaryError(
                f"«{term.term_ru}» is already in the graph snapshot; remove it from the local glossary"
            )
        if term.term_en != g.term_en:
            raise GlossaryError(
                f"«{term.term_ru}»: local English name {term.term_en!r} differs from graph {g.term_en!r}; "
                "fix the name in the graph, not in the local glossary"
            )
        merged[key] = Term(g.term_ru, g.term_en, term.tier)
        notes.append(f"tier map gap: «{g.term_ru}» kept at tier {term.tier} by the local glossary")
    return list(merged.values())


def load_glossary(manifest: dict, root: Path) -> Glossary:
    """Load the glossary described by ``manifest['glossary']``; paths are relative to ``root``."""
    cfg = manifest.get("glossary")
    if not isinstance(cfg, dict) or not cfg.get("snapshot") or not cfg.get("local"):
        raise GlossaryError("translation-manifest.yaml: glossary.snapshot and glossary.local are required")
    tier_by_level = {str(k): int(v) for k, v in (cfg.get("tier_by_level") or {}).items()}

    notes: list[str] = []
    graph, conflicted = _graph_terms(_read_rows(root / cfg["snapshot"]), tier_by_level, notes)
    local = _local_terms(_read_rows(root / cfg["local"]))
    return Glossary(merge(graph, conflicted, local, notes), notes)
