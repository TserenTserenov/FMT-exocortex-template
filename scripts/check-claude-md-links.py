#!/usr/bin/env python3
"""check-claude-md-links.py — every backtick path in shipped CLAUDE.md must resolve.

issue #291: platform section (start .. SYNC-CORE-END) is what update.sh delivers
to every user via §1-7 + Agent Core — a path in backticks that doesn't exist in
this repo (and isn't in update-manifest.json's files[]) is a dead reference on
100% of installs, not just this one. {{PLACEHOLDER}} tokens are substituted by
setup.sh/update.sh at delivery time, so they're skipped here, not resolved.

Usage: python3 check-claude-md-links.py [--strict]  (--strict: exit 1 on any dead link)
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLAUDE_MD = ROOT / "CLAUDE.md"
END_MARKER = "<!-- SYNC-CORE-END -->"

PATH_RE = re.compile(r"`([\w./{}-]+\.[a-zA-Z]{2,5}(?:\s+§?[\w.]*)?)`")

# Explicitly documented as author-only / not shipped right at the point of
# reference in CLAUDE.md itself (see the surrounding sentence) — flagging them
# again here would just be noise, not a new finding.
ALLOWLIST = {
    "PACK-agent-rules/rules/AR.NNN.md",
    ".claude/rules-registry.yaml",
    "archive/wp-contexts/WP-457/CONCEPT-user-states.md",
}

manifest_files = set()
manifest_path = ROOT / "update-manifest.json"
if manifest_path.exists():
    manifest_files = {f["path"] for f in json.loads(manifest_path.read_text()).get("files", [])}

text = CLAUDE_MD.read_text(encoding="utf-8")
platform_text = text.split(END_MARKER, 1)[0]

dead = []
for m in PATH_RE.finditer(platform_text):
    candidate = m.group(1).split()[0]  # strip trailing "§5" etc.
    if "{{" in candidate or "NNN" in candidate or candidate in ALLOWLIST:
        continue
    if "/" not in candidate and "." not in candidate:
        continue
    rel = candidate.lstrip("/")
    if (ROOT / rel).exists() or rel in manifest_files or f"scripts/{Path(rel).name}" in manifest_files:
        continue
    dead.append((m.start(), candidate))

if dead:
    print(f"❌ {len(dead)} dead link(s) in CLAUDE.md platform section (start..SYNC-CORE-END):")
    for _, candidate in dead:
        print(f"   {candidate}")
    if "--strict" in sys.argv:
        sys.exit(1)
else:
    print("✅ check-claude-md-links: no dead links in platform section")
