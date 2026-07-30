#!/usr/bin/env python3
"""WP-429 Ф6.5: детерминированные пре-фильтры извлечения знаний (post-generation).

Два фильтра из карточки WP-429 §Ф6.5, оба ловят реальные кейсы 14-16.07:

(а) cross-report source-цитата: новый extraction-report сверяется с отчётами за
    последние 3 дня по хешу поля `**Источник capture:**` каждого кандидата —
    ловит R2, запускающий параллельные прогоны на одном материале (найдено
    8 раз до 16.07: 2026-06-22-3/-4, 2026-06-27, и т.д. — рекомендация в
    feedback-log.md: "сверять source-цитаты нового отчёта против ВСЕХ отчётов
    за предыдущие 2-3 дня перед формированием нового отчёта").

(б) фабрикация ID: каждый ID-паттерн (XX.TYPE.NNN), упомянутый в теле
    кандидата (`**Проверено:**`, `related.references`, `related.see_also`),
    проверяется на существование в реальных Pack-репо — ловит инцидент
    2026-07-16 (`2026-07-16-inbox-check.md`, все 5 кандидатов): DP.D.165,
    DP.SC.060, DP.FORM.001 не существовали вообще; DP.SC.195, DP.D.033,
    AS.D.001, DP.SC.150, DP.SC.140 существовали, но были тематически чужими.

Оба фильтра — advisory (WP-429 паттерн: read-only детектор, предлагает не
правит). Найденное дописывается в предупреждение в самом отчёте (frontmatter
`prefilter_warnings:`), не блокирует commit+push в extractor.sh — решение по
находке принимает R15 (живой пилот) на /apply-captures, не эта проверка.

Usage:
    python3 wp429-extractor-prefilters.py --report <path/to/new-report.md>
"""

import argparse
import hashlib
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path

ID_PATTERN = re.compile(r'\b([A-Z]{2,4}\.[A-Z]{2,10}\.\d{3})\b')
SOURCE_CAPTURE_PATTERN = re.compile(r'^\*\*Источник capture:\*\*\s*(.+)$', re.MULTILINE)


def hash_source_citation(text: str) -> str:
    normalized = re.sub(r'\s+', ' ', text.strip().lower())
    return hashlib.sha256(normalized.encode('utf-8')).hexdigest()


def extract_source_citations(report_text: str) -> list[str]:
    return [m.group(1).strip() for m in SOURCE_CAPTURE_PATTERN.finditer(report_text)]


def check_cross_report_duplicates(report_path: Path, days_back: int = 3) -> list[dict]:
    """Filter (a): hash this report's source citations against citations in
    extraction-reports from the last `days_back` days. Returns list of
    {citation, duplicate_of} for every hash collision found."""
    reports_dir = report_path.parent
    report_date_match = re.match(r'^(\d{4}-\d{2}-\d{2})', report_path.name)
    if not report_date_match:
        return []
    report_date = datetime.strptime(report_date_match.group(1), '%Y-%m-%d')

    this_report_text = report_path.read_text(encoding='utf-8')
    this_citations = extract_source_citations(this_report_text)
    this_hashes = {hash_source_citation(c): c for c in this_citations}
    if not this_hashes:
        return []

    duplicates = []
    for other_path in sorted(reports_dir.glob('*.md')):
        if other_path == report_path:
            continue
        other_date_match = re.match(r'^(\d{4}-\d{2}-\d{2})', other_path.name)
        if not other_date_match:
            continue
        other_date = datetime.strptime(other_date_match.group(1), '%Y-%m-%d')
        if not (0 <= (report_date - other_date).days <= days_back):
            continue

        other_text = other_path.read_text(encoding='utf-8')
        for other_citation in extract_source_citations(other_text):
            other_hash = hash_source_citation(other_citation)
            if other_hash in this_hashes:
                duplicates.append({
                    'citation': this_hashes[other_hash],
                    'duplicate_of': other_path.name,
                })

    return duplicates


FRONTMATTER_ID_PATTERN = re.compile(r'^id:\s*([A-Z]{2,4}\.[A-Z]{2,10}\.\d{3})', re.MULTILINE)


def extract_mentioned_ids(report_text: str) -> set[str]:
    """IDs referenced as EXISTING entities (`related.see_also`, `**Проверено:**`,
    `supersedes:`) — not a candidate's own proposed `id:` inside its ready-to-commit
    frontmatter block. A candidate proposing itself as `id: DP.FM.343` isn't claiming
    DP.FM.343 already exists; it's asking for that number. Found live-testing against
    a real report (2026-07-22-inbox-check.md) — the candidate's own id: false-positived
    as a "fabricated" ID before this exclusion."""
    all_ids = set(ID_PATTERN.findall(report_text))
    own_ids = set(FRONTMATTER_ID_PATTERN.findall(report_text))
    return all_ids - own_ids


def build_known_id_index(iwe_root: Path) -> set[str]:
    """One pass over PACK-*/**.md, reading frontmatter `id:` + basename ID (for
    no-slug/embedded-section cases like DP.MAP.001 — WP-429 routing.yaml comments
    document ~8 such classes per Pack) — instead of a subprocess grep/find per
    mentioned ID.

    Scoped to PACK-* top-level dirs, not iwe_root as a whole: a per-ID subprocess
    grep across all of ~/IWE (dozens of unrelated repos — DS-MCP, archives, etc.)
    took 14s for 2 IDs in a live test (2026-07-27), because the interactive shell's
    `grep` alias (ugrep, .git-excluding, hidden-aware) isn't inherited by Python's
    subprocess — plain /usr/bin/grep over the whole tree is ~25x slower and isn't
    available as a standalone binary for headless (launchd) runs anyway. Scoping to
    PACK-* via pathlib.rglob (no subprocess) brings this to ~0.2s regardless."""
    known = set()
    for pack_dir in sorted(iwe_root.glob('PACK-*')):
        for md_file in pack_dir.rglob('*.md'):
            basename_match = ID_PATTERN.search(md_file.name)
            if basename_match:
                known.add(basename_match.group(1))
            try:
                text = md_file.read_text(encoding='utf-8')
            except (OSError, UnicodeDecodeError):
                continue
            frontmatter_match = FRONTMATTER_ID_PATTERN.search(text[:500])
            if frontmatter_match:
                known.add(frontmatter_match.group(1))
    return known


def check_fabricated_ids(report_path: Path, iwe_root: Path) -> list[str]:
    """Filter (b): every ID mentioned in the report's body must exist somewhere
    under PACK-*. Returns the list of IDs that don't."""
    report_text = report_path.read_text(encoding='utf-8')
    mentioned = extract_mentioned_ids(report_text)
    if not mentioned:
        return []
    known = build_known_id_index(iwe_root)
    return sorted(mentioned - known)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--report', required=True, help='path to the new extraction-report')
    parser.add_argument('--iwe-root', default=None, help='override ~/IWE root (for tests)')
    parser.add_argument('--days-back', type=int, default=3)
    args = parser.parse_args()

    report_path = Path(args.report)
    if not report_path.is_file():
        print(f"SKIP: report not found: {report_path}", file=sys.stderr)
        sys.exit(0)

    iwe_root = Path(args.iwe_root) if args.iwe_root else Path.home() / 'IWE'

    duplicates = check_cross_report_duplicates(report_path, args.days_back)
    fabricated = check_fabricated_ids(report_path, iwe_root)

    if not duplicates and not fabricated:
        print("✅ pre-filters: чисто (0 cross-report дублей, 0 несуществующих ID)")
        sys.exit(0)

    print(f"⚠️  pre-filters: {len(duplicates)} cross-report дублей, {len(fabricated)} несуществующих ID")
    for d in duplicates:
        print(f"  [cross-report] «{d['citation']}» уже в {d['duplicate_of']}")
    for fid in fabricated:
        print(f"  [fabricated-id] {fid} не найден ни в одном Pack-репо")
    print()
    print("Advisory — не блокирует commit. Проверка при /apply-captures (R15).")
    sys.exit(1)


if __name__ == '__main__':
    main()
