#!/usr/bin/env python3
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
  --digest TEXT                       stdin = digest, stdout = digest + TEXT, <= 4096 UTF-16 units;
                                      only the banner is ever cut, never the digest itself
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

START = "<!-- sync-banner:start -->"
END = "<!-- sync-banner:end -->"
# The leading newline is optional: a block is removed whatever precedes it.
BLOCK_RE = re.compile(r"\n?" + re.escape(START) + r".*?" + re.escape(END) + r"\n", re.DOTALL)
REASON_LIMIT = 200
PATHS_LIMIT = 350
TELEGRAM_LIMIT = 4096
# Everything that could open or close a comment, a tag, a link or a table cell is
# replaced by a look-alike: the fields come from file names and git output.
NEUTRAL = str.maketrans({"`": "\u02bc", "<": "\u2039", ">": "\u203a", "|": "\u00a6",
                         "[": "(", "]": ")"})


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--dayplan", help="Path to DayPlan .md (patch mode)")
    p.add_argument("--marker", help="Path to the sync-blocked marker file")
    p.add_argument("--repo", help="Checkout the marker belongs to; a marker already satisfied there is ignored")
    p.add_argument("--print-text", action="store_true", help="Print the banner text instead of patching")
    p.add_argument("--digest", metavar="TEXT", help="Append TEXT to the digest read from stdin")
    args = p.parse_args()
    if args.digest is None and not args.marker:
        p.error("--marker is required unless --digest is given")
    if args.digest is None and not args.print_text and not args.dayplan:
        p.error("--dayplan is required unless --print-text or --digest is given")
    return args


def read_marker(path):
    """Marker fields as a dict; None when the marker is missing, unreadable or garbage."""
    try:
        raw = Path(path).read_bytes().decode("utf-8", errors="replace")
    except (OSError, ValueError):
        return None
    fields = {}
    for line in raw.split("\n"):  # only LF ends a field: paths may hold \r, \x1e, ...
        key, sep, value = line.partition("=")
        if sep and re.fullmatch(r"[a-z_]+", key) and key not in fields:
            fields[key] = value
    return fields or None


def marker_is_obsolete(fields, repo):
    """True when the checkout already contains the marker's target (moved by hand)."""
    target = fields.get("target", "").strip()
    if not repo or not re.fullmatch(r"[0-9a-f]{40,64}", target):
        return False
    done = subprocess.run(
        ["git", "-C", repo, "merge-base", "--is-ancestor", target, "HEAD"],
        capture_output=True, check=False,
    )
    return done.returncode == 0


def commits_phrase(behind):
    behind = behind.strip()
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
    return " ".join(text.split()).translate(NEUTRAL)


def code_span(text):
    return f"`{text}`"


def limited_paths(raw):
    """(shown, rest): at most PATHS_LIMIT characters, cut between paths when possible."""
    text = " ".join(raw.split())
    if len(text) <= PATHS_LIMIT:
        return text, 0
    cut = text[:PATHS_LIMIT]
    if not text[PATHS_LIMIT].isspace() and " " in cut:
        cut = cut.rsplit(" ", 1)[0]
    return cut, len(text[len(cut):].split())


def banner_text(fields, repo):
    if fields is None or marker_is_obsolete(fields, repo):
        return ""
    reason = " ".join(fields.get("reason", "").split()) or "не указана"
    if len(reason) > REASON_LIMIT:
        reason = reason[:REASON_LIMIT].rstrip() + "\u2026"
    if "paths" in fields:
        raw_paths = fields["paths"]
    else:  # marker written before the paths field existed: sig is \u00abclass|paths\u00bb
        raw_paths = fields.get("sig", "").partition("|")[2]
    detail = f"причина: {code_span(clean(reason))}"
    shown, rest = limited_paths(raw_paths)
    if shown:
        detail += f"; пересекающиеся пути: {code_span(clean(shown))}"
        if rest:
            detail += f" \u2026 и ещё {rest}"
    return (f"Вход Day Open мог устареть: общая копия {commits_phrase(fields.get('behind', ''))} "
            f"({detail}). Реестр РП, план недели и входящие читались из этой копии.")


def lines_of(text):
    """(offset, line) pairs split on LF only, keeping the line ends."""
    return [(m.start(), m.group()) for m in re.finditer(r"[^\n]*\n|[^\n]+", text)]


def insertion_point(text):
    """Offset after the first top-level '# ' heading, else after the frontmatter, else 0."""
    rows = lines_of(text)
    body_start = 0
    if rows and rows[0][1].rstrip("\r\n") == "---":
        for offset, line in rows[1:]:
            if line.rstrip("\r\n") in ("---", "..."):
                body_start = offset + len(line)
                break
    fence = None
    for offset, line in rows:
        if offset < body_start:
            continue
        marker = re.match(r"\s{0,3}(`{3,}|~{3,})", line)
        if fence:
            if marker and marker.group(1)[0] == fence[0] and len(marker.group(1)) >= len(fence):
                fence = None
            continue
        if marker:
            fence = marker.group(1)
            continue
        if line.startswith("# "):
            return offset + len(line) if line.endswith("\n") else None
    return body_start


def apply_block(text, banner):
    """Return text with exactly one banner block (or none when banner is empty)."""
    text = BLOCK_RE.sub("", text)
    if not banner:
        return text
    block = f"\n{START}\n> \u26a0\ufe0f {banner}\n{END}\n"
    at = insertion_point(text)
    if at is None:  # the heading is the last line and has no line end
        return text + block
    return text[:at] + block + text[at:]


def utf16_len(text):
    return len(text.encode("utf-16-le")) // 2


def cut_utf16(text, units):
    out, used = [], 0
    for char in text:
        used += utf16_len(char)
        if used > units:
            break
        out.append(char)
    return "".join(out)


def with_banner(digest, banner):
    """digest + banner within the Telegram limit; the banner alone gives way."""
    if not banner:
        return digest
    head = digest + "\n\n\u26a0\ufe0f "
    room = TELEGRAM_LIMIT - utf16_len(head)
    if utf16_len(banner) <= room:
        return head + banner
    if room < 40:
        return digest
    return head + cut_utf16(banner, room - 1).rstrip() + "\u2026"


def main():
    args = parse_args()
    if args.digest is not None:
        digest = sys.stdin.buffer.read().decode("utf-8", errors="replace")
        sys.stdout.buffer.write(with_banner(digest, args.digest).encode("utf-8"))
        return
    banner = banner_text(read_marker(args.marker), args.repo)
    if args.print_text:
        sys.stdout.buffer.write(banner.encode("utf-8"))
        return
    dayplan = Path(args.dayplan)
    text = dayplan.read_text(encoding="utf-8")
    patched = apply_block(text, banner)
    if patched != text:
        dayplan.write_text(patched, encoding="utf-8")
    state = "written" if banner else "no marker \u2014 no block"
    print(f"sync-banner-patch: {state}", file=sys.stderr)


if __name__ == "__main__":
    main()
