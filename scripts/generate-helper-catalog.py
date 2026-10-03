#!/usr/bin/env python3
"""
Generate helper-scripts-catalog.yaml from # routing: headers in shell scripts.
Covers scripts that are NOT skills (no SKILL.md) — helpers, utilities, servers, migrations.
see DP.SC.159, DP.ROLE.059
"""
import os
import re
import yaml
from pathlib import Path
from datetime import datetime, timezone

IWE = Path.home() / "IWE"
GOVERNANCE_REPO = os.environ.get("IWE_GOVERNANCE_REPO") or "DS-strategy"
SEARCH_DIRS = [
    IWE / "scripts",
    IWE / "FMT-exocortex-template" / "scripts",
    IWE / GOVERNANCE_REPO / "scripts",
]
OUTPUT = IWE / GOVERNANCE_REPO / "scripts" / "helper-scripts-catalog.yaml"

ROUTING_RE = re.compile(r"^# routing:\s+(.+)$", re.MULTILINE)
DESC_RE    = re.compile(r"^#\s+[\w\-\.]+\.sh\s+[—-]\s+(.+)$", re.MULTILINE)

def parse_routing(text: str) -> dict:
    m = ROUTING_RE.search(text)
    if not m:
        return {}
    parts = m.group(1).strip().split()
    result = {"type": parts[0]}
    for p in parts[1:]:
        if "=" in p:
            k, v = p.split("=", 1)
            result[k] = v
        else:
            result[p] = True
    return result

def parse_desc(text: str) -> str:
    m = DESC_RE.search(text)
    return m.group(1).strip() if m else ""

entries = []
for d in SEARCH_DIRS:
    for sh in sorted(d.glob("*.sh")):
        text = sh.read_text(errors="replace")
        routing = parse_routing(text)
        if not routing:
            continue
        # skip executor scripts (they're already in executor-catalog.yaml via SKILL.md)
        if routing.get("type") == "executor":
            continue
        rel = str(sh.relative_to(IWE))
        entries.append({
            "name": sh.stem,
            "path": rel,
            "routing": routing,
            "description": parse_desc(text) or "",
        })

by_type = {}
for e in entries:
    t = e["routing"].get("type", "unknown")
    by_type.setdefault(t, []).append(e["name"])

catalog = {
    "schema_version": 1,
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "source": "# routing: headers in *.sh files",
    "generator": f"{GOVERNANCE_REPO}/scripts/generate-helper-catalog.py",
    "wp": "WP-350",
    "summary": {k: len(v) for k, v in sorted(by_type.items())},
    "total": len(entries),
    "scripts": entries,
}

OUTPUT.write_text(yaml.dump(catalog, allow_unicode=True, sort_keys=False, default_flow_style=False))
print(f"Generated {OUTPUT}")
print(f"Total: {len(entries)} scripts")
for t, names in sorted(by_type.items()):
    print(f"  {t} ({len(names)}): {', '.join(names)}")
