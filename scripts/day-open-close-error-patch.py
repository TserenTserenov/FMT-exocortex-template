#!/usr/bin/env python3
"""Patch DayPlan «Требует внимания» with last night's Close-cycle failure.

Same non-blocking-finding pattern as day-open-priorities-patch.py: when the
Close half of the night cycle (facts_digest / reflection / mechanical
governance) fails, night-cycle-day.sh no longer stops before Open runs
(WP-484 Ф113) — Open still renders and publishes today's DayPlan, and the
failure becomes a visible finding in the plan itself instead of a silently
skipped night.
"""

import re
import sys
import argparse
from pathlib import Path

ATTENTION_HEADER_RE = re.compile(r"(<summary><b>Требует внимания</b></summary>\s*\n)")


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--dayplan", required=True, help="Path to DayPlan .md")
    p.add_argument("--error", required=True, help="Close-cycle failure text (empty = no-op)")
    return p.parse_args()


def append_attention_line(text, finding):
    line = f"- ⚠️ Закрытие предыдущего дня не завершилось: {finding}\n"
    # lambda replacement: the Close-error text is arbitrary (tracebacks contain
    # backslashes) and must not be parsed as a regex replacement template
    patched, n = ATTENTION_HEADER_RE.subn(lambda m: m.group(1) + line, text, count=1)
    return patched if n else text


def main():
    args = parse_args()
    error_text = args.error.strip()
    if not error_text:
        print("close-error-patch: no close error — no-op", file=sys.stderr)
        return

    dayplan = Path(args.dayplan)
    text = dayplan.read_text(encoding="utf-8")
    patched = append_attention_line(text, error_text)
    if patched == text:
        print(
            f"close-error-patch: finding present but «Требует внимания» header not found — cannot patch, finding lost: {error_text}",
            file=sys.stderr,
        )
        return

    dayplan.write_text(patched, encoding="utf-8")
    print(f"close-error-patch: written to «Требует внимания»: {error_text}", file=sys.stderr)


if __name__ == "__main__":
    main()
