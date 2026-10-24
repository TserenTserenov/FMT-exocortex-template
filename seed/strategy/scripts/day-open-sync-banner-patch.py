#!/usr/bin/env python3
# SNAPSHOT — synced manually via script-promote.sh from FMT-exocortex-template/scripts/. Do not edit here directly.
"""Show «Day Open input may be stale» in the DayPlan and in the digest (Refs #1245).

When Day Open could not move the shared checkout to the published tip it keeps a
sync-blocked marker (day_open_sync_blocked in day-open-pipeline.sh). The registry
of work products, the week plan and the inbox are read from that copy, so the plan
itself has to say so. This script is deterministic and runs AFTER the LLM fill, so
the fill can never overwrite the block. The block is delimited by two HTML
comments: a rerun replaces it (never duplicates it) and removes it once the marker
is gone, so a plan without a marker stays byte-for-byte what it was.

Modes:
  --dayplan F --marker M [--repo R]   patch the plan in place
  --marker M [--repo R] --print-text  print the one-line text (empty = no block)
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

START = "<!-- sync-banner:start -->"
END = "<!-- sync-banner:end -->"
BLOCK_RE = re.compile(r"\n" + re.escape(START) + r".*?" + re.escape(END) + r"\n", re.DOTALL)
TITLE_RE = re.compile(r"^# .*\n", re.MULTILINE)
REASON_LIMIT = 200


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--dayplan", help="Path to DayPlan .md (patch mode)")
    p.add_argument("--marker", required=True, help="Path to the sync-blocked marker file")
    p.add_argument("--repo", help="Checkout the marker belongs to; a marker already satisfied there is ignored")
    p.add_argument("--print-text", action="store_true", help="Print the banner text instead of patching")
    args = p.parse_args()
    if not args.print_text and not args.dayplan:
        p.error("--dayplan is required unless --print-text is given")
    return args


def read_marker(path):
    """Marker fields as a dict, or None when there is no readable marker."""
    try:
        raw = Path(path).read_text(encoding="utf-8")
    except OSError:
        return None
    fields = {}
    for line in raw.splitlines():
        key, sep, value = line.partition("=")
        if sep and re.fullmatch(r"[a-z_]+", key) and key not in fields:
            fields[key] = value
    return fields if fields else None


def marker_is_obsolete(fields, repo):
    """True when the checkout already contains the marker's target (moved by hand)."""
    target = fields.get("target", "")
    if not repo or not re.fullmatch(r"[0-9a-f]{40,64}", target):
        return False
    done = subprocess.run(
        ["git", "-C", repo, "merge-base", "--is-ancestor", target, "HEAD"],
        capture_output=True, check=False,
    )
    return done.returncode == 0


def commits_phrase(behind):
    if not behind.isdigit():
        return "отстаёт от origin"
    n = int(behind)
    if n % 10 == 1 and n % 100 != 11:
        word = "коммит"
    elif 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
        word = "коммита"
    else:
        word = "коммитов"
    return f"отстаёт от origin на {n} {word}"


def clean(text):
    return " ".join(text.split()).replace("-->", "-- >")


def banner_text(fields, repo):
    if fields is None or marker_is_obsolete(fields, repo):
        return ""
    reason = clean(fields.get("reason", "")) or "не указана"
    if len(reason) > REASON_LIMIT:
        reason = reason[:REASON_LIMIT].rstrip() + "…"
    if "paths" in fields:
        paths = clean(fields["paths"])
    else:  # marker written before the paths field existed: sig is «class|paths»
        paths = clean(fields.get("sig", "").partition("|")[2])
    detail = f"причина: {reason}"
    if paths:
        detail += f"; пересекающиеся пути: {paths}"
    return (f"Вход Day Open мог устареть: общая копия {commits_phrase(fields.get('behind', ''))} "
            f"({detail}). Реестр РП, план недели и входящие читались из этой копии.")


def apply_block(text, banner):
    """Return text with exactly one banner block (or none when banner is empty)."""
    text = BLOCK_RE.sub("", text)
    if not banner:
        return text
    block = f"\n{START}\n> ⚠️ {banner}\n{END}\n"
    title = TITLE_RE.search(text)
    if title is None:
        return block.lstrip("\n") + "\n" + text
    return text[:title.end()] + block + text[title.end():]


def main():
    args = parse_args()
    banner = banner_text(read_marker(args.marker), args.repo)
    if args.print_text:
        sys.stdout.write(banner)
        return
    dayplan = Path(args.dayplan)
    text = dayplan.read_text(encoding="utf-8")
    patched = apply_block(text, banner)
    if patched != text:
        dayplan.write_text(patched, encoding="utf-8")
    state = "written" if banner else "no marker — no block"
    print(f"sync-banner-patch: {state}", file=sys.stderr)


if __name__ == "__main__":
    main()
