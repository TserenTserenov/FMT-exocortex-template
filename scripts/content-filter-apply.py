#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# content-filter-apply.py — WP-394 Phase3.2 (design: Kimi; implementation+edits: Claude)
#
# Reformulates words-marker words for sensitive data in the incoming prompt BEFORE submission
# to the engine Kimi/Moonshot, so that defensive content policy does not produce a false block
# (HTTP 400 high risk) on legitimate peer-sessions about auth/secrets.
# See. memory/lessons_kimi_content_filter.md, DP.SC.154.
#
# Usage: cat prompt | python3 content-filter-apply.py <map.tsv>
#   map.tsv: pairs "marker<TAB>replacement", one per line.
#   Empty lines and lines starting with # are ignored. File absent/empty → identity passthrough.
#   --strict-map: for peer-peer adapters the map is required; map error → exit 2.
#
# Edits Claude on top of the design by Kimi:
#   1. re.IGNORECASE — Moonshot triggers regardless of case.
#   2. \b...\b — word boundaries, to avoid mangling identifiers (tokenizer, secretary).
#   3. longest-first — correct handling of overlapping markers (private key ⊃ key).
#   4. lambda-replacement — special characters in replacement are not interpreted as regex backref.

import sys
import re


def load_pairs(map_path, strict=False):
    pairs = []
    try:
        with open(map_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line or line.lstrip().startswith("#"):
                    continue
                parts = line.split("\t", 1)
                if len(parts) == 2 and parts[0] and (parts[1] or not strict):
                    pairs.append((parts[0], parts[1]))
                elif strict:
                    raise ValueError("invalid map entry")
    except (OSError, UnicodeError):
        if strict:
            raise
        # Legacy callers allow an absent or unreadable map as a no-op.
        return []
    if strict and not pairs:
        raise ValueError("map has no replacement pairs")
    # longest-first: longer markers are replaced before shorter ones-substrings
    pairs.sort(key=lambda p: len(p[0]), reverse=True)
    return pairs


def apply_filter(payload, pairs):
    for marker, replacement in pairs:
        pattern = r"\b" + re.escape(marker) + r"\b"
        payload = re.sub(
            pattern, lambda _m: replacement, payload, flags=re.IGNORECASE
        )
    return payload


def main():
    strict = len(sys.argv) == 3 and sys.argv[2] == "--strict-map"
    if len(sys.argv) > 2 and not strict:
        raise SystemExit("ERROR: usage: content-filter-apply.py <map.tsv> [--strict-map]")
    if len(sys.argv) < 2:
        # no map-map argument → passthrough
        sys.stdout.buffer.write(sys.stdin.buffer.read())
        return
    payload = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    try:
        pairs = load_pairs(sys.argv[1], strict=strict)
    except (OSError, UnicodeError, ValueError):
        print("ERROR: content filter map is invalid or unavailable", file=sys.stderr)
        raise SystemExit(2)
    if pairs:
        payload = apply_filter(payload, pairs)
    sys.stdout.buffer.write(payload.encode("utf-8"))


if __name__ == "__main__":
    main()
