#!/usr/bin/env python3
"""wp-list.py — single discovery entrypoint for WP (рабочий продукт) cards.

issue #298: WP card discovery (flat inbox/WP-NNN.md + nested folder
inbox/WP-NNN/WP-NNN.md, WP-434) was reimplemented independently in
scripts/active-wp-sweep.sh, scripts/archive-done-wp.sh,
check-wp-transfer-completeness.sh, and every pilot extension that needed
"give me all the cards" — when the on-disk convention changed (flat → folder,
WP-434), each independent reimplementation had to be found and fixed
separately. This is the one place the on-disk layout is encoded; existing
scripts are NOT migrated to call it in this pass (separate, larger,
higher-risk follow-up) — this is the reusable primitive the issue asked for.

Usage:
    python3 wp-list.py --list-cards [--source inbox|archive|all]
                        [--fields wp,title,status,status_raw,registry_done,created,closed,deferred,budget,card]
                        [--format json|tsv]
                        [--governance-repo NAME] [--iwe-root PATH]

Status: read from each card's own frontmatter `status:` field. WP-REGISTRY.md
is consulted only for the done/not-done signal (strikethrough `~~N~~` on the
row) — the one fact REGISTRY is the actual owner of (registry.md drift is
common, per-card frontmatter routinely lags a REGISTRY update) — and wins
over a stale frontmatter status when it disagrees.
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

DEFAULT_FIELDS = ["wp", "title", "status", "card"]
ALL_FIELDS = ["wp", "title", "status", "status_raw", "registry_done", "created", "closed", "deferred", "budget", "card", "pool", "decision_pending", "verification_class", "priority"]

FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n", re.DOTALL)
FIELD_RE = re.compile(r"^(\w+):\s*(.*)$")


def _clean_value(raw):
    """Strip surrounding quotes, or — only for unquoted values — a trailing
    inline `# comment` (this codebase's cards routinely write
    `status: in_progress  # 16 июля: ...` — a bare status-equality check
    against the raw line would silently miss every commented status)."""
    raw = raw.strip()
    if raw[:1] in ('"', "'"):
        quote = raw[0]
        m = re.match(re.escape(quote) + r"(.*)" + re.escape(quote) + r"\s*(?:#.*)?$", raw)
        return m.group(1) if m else raw.strip(quote)
    return re.split(r"\s+#", raw, maxsplit=1)[0].strip()


def parse_frontmatter(path):
    """Return a dict of frontmatter fields (best-effort, not full YAML).

    UnicodeDecodeError (found by review): one card anywhere in inbox/ with a
    stray non-UTF-8 byte used to crash the whole discovery run uncaught —
    every OTHER valid card silently vanished from the output along with it.
    Best-effort here means exactly that: skip the one bad card, not the run.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return {}
    m = FRONTMATTER_RE.match(text)
    if not m:
        return {}
    fields = {}
    for line in m.group(1).splitlines():
        fm = FIELD_RE.match(line)
        if fm:
            fields[fm.group(1)] = _clean_value(fm.group(2))
    return fields


def discover_cards(root):
    """Yield (wp_num, card_path) for every WP card under root — flat
    WP-NNN*.md and nested WP-NNN/WP-NNN.md, same convention on inbox/ and
    archive/wp-contexts/ (WP-434). Dedups: a folder wins over a flat file
    for the same number if both exist (folder is the current convention).

    Known exception, not specially handled: a handful of pre-WP-434 archive
    entries carry BOTH a flat file (the real closed-out card) and a folder
    stub with `results_in:` pointing at that flat file (a since-abandoned
    archival pattern) — folder-wins picks the stub. Confirmed rare (1 of 451
    in the reference install) and status is unaffected (REGISTRY still wins
    the done/not-done signal either way); not worth a `results_in` special
    case for a single-digit number of legacy rows."""
    if not root.is_dir():
        return
    found = {}
    for entry in sorted(root.iterdir()):
        if entry.is_dir():
            m = re.match(r"^WP-(\d+)$", entry.name)
            if not m:
                continue
            num = m.group(1)
            nested = entry / f"WP-{num}.md"
            if nested.is_file():
                found[num] = nested
        elif entry.is_file() and entry.suffix == ".md":
            m = re.match(r"^WP-(\d+)(?:-.*)?\.md$", entry.name)
            if m:
                num = m.group(1)
                found.setdefault(num, entry)
    for num, path in found.items():
        yield num, path


def registry_done_status(registry_path):
    """Return {wp_num: True} for every WP struck through (~~N~~) in
    WP-REGISTRY.md — the one field REGISTRY is the actual source of truth
    for (see module docstring)."""
    done = {}
    if not registry_path.is_file():
        return done
    try:
        text = registry_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return done
    for line in text.splitlines():
        m = re.match(r"^\|\s*~~0*(\d+)~~", line)
        if m:
            done[m.group(1)] = True
    return done


def build_row(num, card_path, registry_done):
    fm = parse_frontmatter(card_path)
    status_raw = fm.get("status", "")
    is_registry_done = bool(registry_done.get(num))
    status = "done" if (is_registry_done and status_raw != "done") else status_raw
    return {
        "wp": num,
        "title": fm.get("title", ""),
        # "status": REGISTRY-merged (done wins) — what a "give me the current
        # state" consumer wants. "status_raw": frontmatter only, unmerged —
        # what a drift detector wants (compare against registry_done itself
        # to find zombies: frontmatter says active, REGISTRY already ✅).
        "status": status,
        "status_raw": status_raw,
        "registry_done": "true" if is_registry_done else "false",
        "created": fm.get("created", ""),
        "closed": fm.get("closed", ""),
        "deferred": fm.get("deferred", ""),
        "budget": fm.get("budget", ""),
        "card": str(card_path),
        "pool": fm.get("pool", "false"),
        "decision_pending": fm.get("decision_pending", "false"),
        "verification_class": fm.get("verification_class", ""),
        "priority": fm.get("priority", ""),
    }


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--list-cards", action="store_true", help="list all WP cards (required — the only mode for now)")
    p.add_argument("--source", choices=["inbox", "archive", "all"], default="inbox")
    p.add_argument("--fields", default=",".join(DEFAULT_FIELDS),
                    help=f"comma-separated subset of {ALL_FIELDS}")
    p.add_argument("--format", choices=["json", "tsv"], default="tsv")
    p.add_argument("--governance-repo", default=os.environ.get("IWE_GOVERNANCE_REPO", "DS-strategy"))
    p.add_argument("--iwe-root", default=os.environ.get("IWE_ROOT", str(Path.home() / "IWE")))
    args = p.parse_args()

    if not args.list_cards:
        p.error("--list-cards is required (the only supported mode)")

    fields = [f.strip() for f in args.fields.split(",") if f.strip()]
    unknown = set(fields) - set(ALL_FIELDS)
    if unknown:
        p.error(f"unknown field(s): {sorted(unknown)} — valid: {ALL_FIELDS}")

    gov_root = Path(args.iwe_root) / args.governance_repo
    roots = []
    if args.source in ("inbox", "all"):
        roots.append(gov_root / "inbox")
    if args.source in ("archive", "all"):
        roots.append(gov_root / "archive" / "wp-contexts")

    registry_done = registry_done_status(gov_root / "docs" / "WP-REGISTRY.md")

    seen = {}
    for root in roots:
        for num, card_path in discover_cards(root):
            # inbox wins over archive on collision (shouldn't happen — same
            # WP shouldn't be both active and archived — but archive wins if
            # it does, since archival is the more recent state transition).
            if num not in seen or root.name == "wp-contexts":
                seen[num] = build_row(num, card_path, registry_done)

    rows = [seen[num] for num in sorted(seen, key=int)]
    rows = [{k: row[k] for k in fields} for row in rows]

    if args.format == "json":
        print(json.dumps(rows, ensure_ascii=False, indent=2))
    else:
        print("\t".join(fields))
        for row in rows:
            print("\t".join(str(row.get(f, "")) for f in fields))


if __name__ == "__main__":
    main()
