#!/usr/bin/env python3
"""Patch DayPlan «Требует внимания» when this host's code is stale vs origin/main.

Same non-blocking-finding pattern as day-open-close-error-patch.py: a stale
checkout must not silently pass — WP-484 Ф124 plan, Этап 0 line 1, wiring 3б
(single-host scope, no multi-host registry — that part stays open per the
2026-08-20-48 peer-session consensus).
"""

import re
import subprocess
import sys
import argparse
from pathlib import Path

ATTENTION_HEADER_RE = re.compile(r"(<summary><b>Требует внимания</b></summary>\s*\n)")


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--dayplan", required=True, help="Path to DayPlan .md")
    p.add_argument("--repo", required=True, help="Path to a git checkout to compare HEAD against origin/main")
    return p.parse_args()


def local_head_is_stale(repo):
    """True if origin/main has commits this checkout's HEAD doesn't."""
    result = subprocess.run(
        ["git", "-C", repo, "rev-list", "--count", "HEAD..origin/main"],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        print(f"version-check-patch: git rev-list failed — {result.stderr.strip()}", file=sys.stderr)
        return None
    behind = int(result.stdout.strip() or "0")
    return behind if behind > 0 else 0


def append_attention_line(text, behind_count):
    line = f"- ⚠️ Этот хост отстал от общего репозитория на {behind_count} коммит(ов) — код может быть устаревшим.\n"
    patched, n = ATTENTION_HEADER_RE.subn(r"\1" + line, text, count=1)
    return patched if n else text


def main():
    args = parse_args()
    behind = local_head_is_stale(args.repo)
    if behind is None:
        return  # git call failed — already logged, no-op rather than block Day Open
    if behind == 0:
        print("version-check-patch: host is current with origin/main — no-op", file=sys.stderr)
        return

    dayplan = Path(args.dayplan)
    text = dayplan.read_text(encoding="utf-8")
    patched = append_attention_line(text, behind)
    if patched == text:
        print(
            f"version-check-patch: stale by {behind} commits but «Требует внимания» header not found — cannot patch, finding lost",
            file=sys.stderr,
        )
        return

    dayplan.write_text(patched, encoding="utf-8")
    print(f"version-check-patch: written to «Требует внимания» — stale by {behind} commits", file=sys.stderr)


if __name__ == "__main__":
    main()
